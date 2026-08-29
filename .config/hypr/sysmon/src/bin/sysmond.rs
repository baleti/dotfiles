//! Background sampler for the alt+mod+n/p/t/m graph popups
//! (`~/.config/hypr/sysmon/src/bin/sysmon-graph.rs`) and the quickshell
//! bar's hover graphs. Autostarted from hyprland.lua's `hyprland.start`
//! handler, same as notifyd, so history is already warm the first time a
//! popup/hover opens rather than starting empty.
//!
//! Keeps a 10-minute ring buffer per metric in memory and serves it over a
//! Unix socket -- no persistence needed, this is throwaway monitoring data.

use std::collections::{HashMap, VecDeque};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use sysmon::{socket_path, DiskHistory, IfaceHistory, Metric, ProcEntry, Request, Snapshot, Tier, ALL_TIERS, SAMPLE_INTERVAL_MS, TIER_CAPACITY};

/// One of the five fixed granularities' worth of a single raw metric --
/// raw 1s samples get averaged together (accum_sum/accum_n) until enough
/// have arrived for this tier's own resolution, then one point is pushed
/// into `buf` (capped at TIER_CAPACITY, oldest dropped). See `Tier` in
/// lib.rs for why the averaging window differs per tier.
struct TierBuf {
    interval: u64,
    buf: VecDeque<f64>,
    accum_sum: f64,
    accum_n: u64,
}

impl TierBuf {
    fn new(tier: Tier) -> Self {
        TierBuf {
            interval: tier.raw_samples_per_point(),
            buf: VecDeque::with_capacity(TIER_CAPACITY),
            accum_sum: 0.0,
            accum_n: 0,
        }
    }

    fn push_raw(&mut self, v: f64) {
        self.accum_sum += v;
        self.accum_n += 1;
        if self.accum_n >= self.interval {
            let avg = self.accum_sum / self.accum_n as f64;
            if self.buf.len() == TIER_CAPACITY {
                self.buf.pop_front();
            }
            self.buf.push_back(avg);
            self.accum_sum = 0.0;
            self.accum_n = 0;
        }
    }
}

/// Persisted form of one TierBuf -- just the finalized points. The partial
/// accum_sum/accum_n (at most one tier-interval's worth of raw samples,
/// i.e. seconds to hours depending on the tier) is deliberately not
/// persisted; losing at most one in-progress bucket on restart isn't worth
/// the complexity.
#[derive(Serialize, Deserialize, Default)]
struct PersistedSeries {
    tiers: Vec<Vec<f64>>, // index matches ALL_TIERS order
}

/// One raw metric's history across all five tiers at once. Every push_raw
/// call fans out to all five simultaneously -- that's the whole "tiered"
/// design: no separate rollup pass, each tier just has its own averaging
/// window over the same incoming raw stream.
struct TieredSeries {
    tiers: [TierBuf; ALL_TIERS.len()], // index matches ALL_TIERS order
}

impl TieredSeries {
    fn new() -> Self {
        TieredSeries { tiers: ALL_TIERS.map(TierBuf::new) }
    }

    fn push_raw(&mut self, v: f64) {
        for t in &mut self.tiers {
            t.push_raw(v);
        }
    }

    fn get(&self, tier: Tier) -> Vec<f64> {
        let idx = ALL_TIERS.iter().position(|&t| t == tier).unwrap();
        self.tiers[idx].buf.iter().copied().collect()
    }

    fn to_persisted(&self) -> PersistedSeries {
        PersistedSeries { tiers: self.tiers.iter().map(|t| t.buf.iter().copied().collect()).collect() }
    }

    fn load_persisted(&mut self, p: &PersistedSeries) {
        for (tier_buf, points) in self.tiers.iter_mut().zip(p.tiers.iter()) {
            tier_buf.buf = points.iter().copied().collect();
        }
    }
}

/// Two parallel tiered series -- rx/tx for a network interface, or
/// read/write for a disk. Field names are generic on purpose.
struct TwoSeriesBuf {
    a: TieredSeries,
    b: TieredSeries,
}

impl TwoSeriesBuf {
    fn new() -> Self {
        TwoSeriesBuf { a: TieredSeries::new(), b: TieredSeries::new() }
    }
}

#[derive(Serialize, Deserialize, Default)]
struct PersistedHistory {
    cpu_total: PersistedSeries,
    cpu_cores: Vec<PersistedSeries>,
    temp_c: PersistedSeries,
    mem_used_pct: PersistedSeries,
    mem_cached_pct: PersistedSeries,
    net: HashMap<String, (PersistedSeries, PersistedSeries)>,
    disk: HashMap<String, (PersistedSeries, PersistedSeries)>,
}

fn persist_path() -> PathBuf {
    let base = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".local/state"));
    base.join("sysmond/history.json")
}

struct History {
    // Every non-loopback interface seen since startup, keyed by name --
    // not just the default route, so e.g. wg-wsl and wlan0 both get their
    // own overlaid series (2026-08-27).
    net: HashMap<String, TwoSeriesBuf>,
    // Every whole-disk block device seen since startup (partitions
    // excluded), keyed by name -- same overlay treatment as net.
    disk: HashMap<String, TwoSeriesBuf>,
    cpu_total: TieredSeries,
    // One tiered series per logical CPU, index = core number, for the
    // bar's overlay per-core view.
    cpu_cores: Vec<TieredSeries>,
    temp_c: TieredSeries,
    mem_used_pct: TieredSeries,
    mem_cached_pct: TieredSeries,
    top_cpu: Vec<ProcEntry>,
    top_mem: Vec<ProcEntry>,
    // Per-process network attribution needs packet capture (nethogs, via
    // its own cap_net_raw/cap_net_admin/cap_dac_read_search/cap_sys_ptrace
    // file capabilities -- already set on this system's /usr/bin/nethogs,
    // confirmed 2026-08-27, so sysmond itself stays fully unprivileged and
    // never needs root). Empty if nethogs isn't installed or isn't
    // capable-enabled -- see nethogs_loop's graceful skip.
    top_net: Vec<ProcEntry>,
}

impl History {
    fn new(n_cores: usize) -> Self {
        let mut h = History {
            net: HashMap::new(),
            disk: HashMap::new(),
            cpu_total: TieredSeries::new(),
            cpu_cores: (0..n_cores).map(|_| TieredSeries::new()).collect(),
            temp_c: TieredSeries::new(),
            mem_used_pct: TieredSeries::new(),
            mem_cached_pct: TieredSeries::new(),
            top_cpu: Vec::new(),
            top_mem: Vec::new(),
            top_net: Vec::new(),
        };
        h.load_from_disk();
        h
    }

    /// Best-effort: a missing/corrupt/shape-mismatched file just leaves
    /// history empty (fresh start), same as sysmond's very first ever run.
    fn load_from_disk(&mut self) {
        let Ok(text) = fs::read_to_string(persist_path()) else { return };
        let Ok(p) = serde_json::from_str::<PersistedHistory>(&text) else { return };
        self.cpu_total.load_persisted(&p.cpu_total);
        self.temp_c.load_persisted(&p.temp_c);
        self.mem_used_pct.load_persisted(&p.mem_used_pct);
        self.mem_cached_pct.load_persisted(&p.mem_cached_pct);
        for (core, saved) in self.cpu_cores.iter_mut().zip(p.cpu_cores.iter()) {
            core.load_persisted(saved);
        }
        for (name, (a, b)) in p.net {
            let buf = self.net.entry(name).or_insert_with(TwoSeriesBuf::new);
            buf.a.load_persisted(&a);
            buf.b.load_persisted(&b);
        }
        for (name, (a, b)) in p.disk {
            let buf = self.disk.entry(name).or_insert_with(TwoSeriesBuf::new);
            buf.a.load_persisted(&a);
            buf.b.load_persisted(&b);
        }
        eprintln!("sysmond: loaded persisted history from {}", persist_path().display());
    }

    fn save_to_disk(&self) {
        let p = PersistedHistory {
            cpu_total: self.cpu_total.to_persisted(),
            cpu_cores: self.cpu_cores.iter().map(TieredSeries::to_persisted).collect(),
            temp_c: self.temp_c.to_persisted(),
            mem_used_pct: self.mem_used_pct.to_persisted(),
            mem_cached_pct: self.mem_cached_pct.to_persisted(),
            net: self.net.iter().map(|(k, v)| (k.clone(), (v.a.to_persisted(), v.b.to_persisted()))).collect(),
            disk: self.disk.iter().map(|(k, v)| (k.clone(), (v.a.to_persisted(), v.b.to_persisted()))).collect(),
        };
        let Ok(text) = serde_json::to_string(&p) else { return };
        let path = persist_path();
        if let Some(dir) = path.parent() {
            let _ = fs::create_dir_all(dir);
        }
        // Write to a temp file and rename over the real one -- avoids a
        // half-written file if sysmond is killed mid-save (this file can
        // get into the hundreds of KB with several interfaces/disks/cores
        // all at 5 tiers x 600 points each).
        let tmp = path.with_extension("json.tmp");
        if fs::write(&tmp, text).is_ok() {
            let _ = fs::rename(&tmp, &path);
        }
    }
}

/// MemAvailable-based "actually used" plus separately, Buffers+Cached (the
/// reclaimable page cache) as its own overlay -- so both are visible
/// instead of only the "true" used figure swallowing the cache.
fn read_mem_pcts() -> (f64, f64) {
    let Ok(meminfo) = fs::read_to_string("/proc/meminfo") else { return (0.0, 0.0) };
    let mut total = 0.0_f64;
    let mut avail = 0.0_f64;
    let mut buffers = 0.0_f64;
    let mut cached = 0.0_f64;
    for line in meminfo.lines() {
        let Some((key, rest)) = line.split_once(':') else { continue };
        let kb: f64 = rest.trim().trim_end_matches(" kB").parse().unwrap_or(0.0);
        match key {
            "MemTotal" => total = kb,
            "MemAvailable" => avail = kb,
            "Buffers" => buffers = kb,
            "Cached" => cached = kb,
            _ => {}
        }
    }
    if total <= 0.0 {
        return (0.0, 0.0);
    }
    let used_pct = 100.0 * (1.0 - avail / total);
    let cached_pct = 100.0 * (buffers + cached) / total;
    (used_pct, cached_pct)
}

/// Parses one `/proc/stat` cpu line (aggregate `cpu ` or per-core `cpuN `):
/// user nice system idle iowait irq softirq steal guest guest_nice.
/// `guest`/`guest_nice` are already folded into `user`/`nice` (Linux >=
/// 2.6.24), so summing only the first 8 avoids double-counting them.
fn parse_cpu_line(line: &str) -> Option<(u64, u64)> {
    let fields: Vec<u64> = line.split_whitespace().skip(1).filter_map(|f| f.parse().ok()).collect();
    if fields.len() < 8 {
        return None;
    }
    let idle_all = fields[3] + fields[4]; // idle + iowait
    let total: u64 = fields[0..8].iter().sum();
    Some((idle_all, total))
}

/// Index 0 is the aggregate `cpu ` line; the rest are `cpu0`, `cpu1`, ...
/// in order.
fn read_all_cpu_lines() -> Vec<(u64, u64)> {
    let Ok(stat) = fs::read_to_string("/proc/stat") else { return Vec::new() };
    stat.lines()
        .take_while(|l| l.starts_with("cpu"))
        .filter_map(parse_cpu_line)
        .collect()
}

fn count_cores() -> usize {
    read_all_cpu_lines().len().saturating_sub(1).max(1)
}

/// Every interface's current rx/tx byte counters except loopback -- unlike
/// the single-default-route version this replaces, so wifi/ethernet/VPN
/// tunnels etc. can all be graphed as separate overlaid series at once.
fn read_all_iface_bytes() -> HashMap<String, (u64, u64)> {
    let mut out = HashMap::new();
    let Ok(dev) = fs::read_to_string("/proc/net/dev") else { return out };
    for line in dev.lines() {
        let Some((name, rest)) = line.split_once(':') else { continue }; // header lines have no ':'
        let name = name.trim();
        if name.is_empty() || name == "lo" {
            continue;
        }
        let values: Vec<u64> = rest.split_whitespace().filter_map(|f| f.parse().ok()).collect();
        if values.len() < 9 {
            continue;
        }
        out.insert(name.to_string(), (values[0], values[8])); // rx bytes, tx bytes
    }
    out
}

/// Whole-disk block devices only (no partitions) -- /sys/block/* has one
/// entry per whole disk; a partition like sda1 lives nested under
/// /sys/block/sda/sda1 instead of getting its own top-level entry, so this
/// sidesteps needing a name-pattern heuristic to exclude them.
fn whole_disk_names() -> Vec<String> {
    let Ok(entries) = fs::read_dir("/sys/block") else { return Vec::new() };
    entries.flatten().filter_map(|e| e.file_name().to_str().map(String::from)).collect()
}

/// Current read/write byte counters (sectors * 512, per `/proc/diskstats`'s
/// documented fixed 512-byte sector unit) for each whole-disk device.
fn read_all_disk_bytes(names: &[String]) -> HashMap<String, (u64, u64)> {
    let mut out = HashMap::new();
    let Ok(stat) = fs::read_to_string("/proc/diskstats") else { return out };
    for line in stat.lines() {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() < 10 {
            continue;
        }
        let name = fields[2];
        if !names.iter().any(|n| n == name) {
            continue;
        }
        let Ok(rd_sectors) = fields[5].parse::<u64>() else { continue };
        let Ok(wr_sectors) = fields[9].parse::<u64>() else { continue };
        out.insert(name.to_string(), (rd_sectors * 512, wr_sectors * 512));
    }
    out
}

/// `x86_pkg_temp` is the whole-package sensor on this Comet Lake box
/// (confirmed via `/sys/class/thermal/thermal_zone*/type`); fall back to
/// anything CPU-ish, then to whatever the first zone is, so the popup still
/// shows *something* on different hardware instead of silently reading 0.
fn find_cpu_thermal_zone() -> Option<std::path::PathBuf> {
    let mut fallback: Option<std::path::PathBuf> = None;
    let entries = fs::read_dir("/sys/class/thermal").ok()?;
    for entry in entries.flatten() {
        let path = entry.path();
        let type_path = path.join("type");
        let Ok(zone_type) = fs::read_to_string(&type_path) else { continue };
        let zone_type = zone_type.trim().to_lowercase();
        if zone_type == "x86_pkg_temp" {
            return Some(path.join("temp"));
        }
        if fallback.is_none() && (zone_type.contains("cpu") || zone_type.contains("pkg")) {
            fallback = Some(path.join("temp"));
        }
        if fallback.is_none() {
            fallback = Some(path.join("temp"));
        }
    }
    fallback
}

fn list_pids() -> Vec<i32> {
    let Ok(entries) = fs::read_dir("/proc") else { return Vec::new() };
    entries
        .flatten()
        .filter_map(|e| e.file_name().to_str().and_then(|s| s.parse::<i32>().ok()))
        .collect()
}

fn proc_name(pid: i32) -> String {
    fs::read_to_string(format!("/proc/{pid}/comm"))
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|_| format!("pid {pid}"))
}

fn truncate_ellipsis(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        return s.to_string();
    }
    let mut out: String = s.chars().take(max.saturating_sub(1)).collect();
    out.push('…');
    out
}

fn tilde(path: &str) -> String {
    match std::env::var("HOME") {
        Ok(home) if !home.is_empty() && path.starts_with(&home) => {
            format!("~{}", &path[home.len()..])
        }
        _ => path.to_string(),
    }
}

/// A short "which one is this" string for a process whose comm is
/// ambiguous on its own (many `claude` / `node` / `python`): the
/// command-line tail (everything after argv[0]) and the ~-relative cwd,
/// whichever are available, joined by "  ·  ". The cwd is what tells two
/// `claude --dangerously-skip-permissions` apart. Only ever called for the
/// final top-10 of each metric, so the extra syscalls are negligible.
fn proc_detail(pid: i32) -> String {
    const MAX: usize = 80;
    let mut bits: Vec<String> = Vec::new();

    if let Ok(raw) = fs::read(format!("/proc/{pid}/cmdline")) {
        let parts: Vec<String> = raw
            .split(|b| *b == 0)
            .filter(|s| !s.is_empty())
            .map(|s| String::from_utf8_lossy(s).into_owned())
            .collect();
        if parts.len() > 1 {
            let tail = parts[1..].join(" ");
            let tail = tail.split_whitespace().collect::<Vec<_>>().join(" ");
            if !tail.is_empty() {
                bits.push(tail);
            }
        }
    }

    if let Ok(target) = fs::read_link(format!("/proc/{pid}/cwd")) {
        let cwd = tilde(&target.to_string_lossy());
        if cwd != "~" {
            bits.push(cwd);
        }
    }

    // Always end with the pid -- the last-resort unique handle when several
    // processes share a comm AND an identical cmdline/cwd (e.g. several
    // `claude --dangerously-skip-permissions` all launched from $HOME).
    bits.push(format!("pid {pid}"));

    truncate_ellipsis(&bits.join("  \u{b7}  "), MAX)
}

/// Fills in `ProcEntry::detail` for an already-truncated top-N list.
fn enrich_details(entries: &mut [ProcEntry]) {
    for e in entries.iter_mut() {
        e.detail = proc_detail(e.pid);
    }
}

/// `/proc/[pid]/stat`'s utime+stime (fields 14, 15 -- but field 2 is the
/// comm in parens and can itself contain spaces/parens, so field indices
/// are counted from the *last* ')' rather than split_whitespace() alone).
fn proc_cpu_ticks(pid: i32) -> Option<u64> {
    let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let after_comm = stat.rsplit_once(')')?.1;
    let fields: Vec<&str> = after_comm.split_whitespace().collect();
    // fields[0] here is field 3 (state) of the real /proc/[pid]/stat layout;
    // utime is field 14 overall -> index 14-3 = 11, stime is index 12.
    let utime: u64 = fields.get(11)?.parse().ok()?;
    let stime: u64 = fields.get(12)?.parse().ok()?;
    Some(utime + stime)
}

fn proc_rss_mb(pid: i32) -> Option<f64> {
    let status = fs::read_to_string(format!("/proc/{pid}/status")).ok()?;
    for line in status.lines() {
        if let Some(rest) = line.strip_prefix("VmRSS:") {
            let kb: f64 = rest.trim().trim_end_matches(" kB").parse().ok()?;
            return Some(kb / 1024.0);
        }
    }
    None
}

fn top_n(mut entries: Vec<ProcEntry>, n: usize) -> Vec<ProcEntry> {
    entries.sort_by(|a, b| b.value.partial_cmp(&a.value).unwrap_or(std::cmp::Ordering::Equal));
    entries.truncate(n);
    entries
}

/// One line of `nethogs -t` output: `<name>/<pid>/<uid>\t<sent_kb>\t<recv_kb>`
/// for an attributed process, but also unattributed lines this skips --
/// `unknown TCP/0/0\t..\t..` (packet seen, no matching /proc socket owner
/// yet) and raw `ip:port-ip:port/0/0\t..\t..` connection identifiers (same
/// cause). `<name>` is nethogs' own resolved program path/name and can
/// itself contain `/`, so split from the right, not the left.
fn parse_nethogs_line(line: &str) -> Option<ProcEntry> {
    let fields: Vec<&str> = line.split('\t').collect();
    if fields.len() < 3 {
        return None;
    }
    let sent: f64 = fields[1].parse().ok()?;
    let recv: f64 = fields[2].parse().ok()?;
    let mut segs = fields[0].rsplitn(3, '/');
    let _uid = segs.next()?;
    let pid: i32 = segs.next()?.parse().ok()?;
    let path = segs.next()?;
    if pid <= 0 {
        return None; // "unknown TCP/0/0" and raw ip:port/0/0 connection lines
    }
    let name = path.rsplit('/').next().unwrap_or(path).to_string();
    Some(ProcEntry { pid, name, value: sent + recv, detail: String::new() })
}

/// Runs `nethogs -t` (trace mode: plain text, one block per ~1s refresh
/// rather than the interactive ncurses UI) as a subprocess for the life of
/// sysmond, and keeps `history.top_net` updated with each block's top-10.
/// A no-op forever (not a crash) if nethogs isn't installed -- this metric
/// just stays empty, same as any other missing sensor here.
fn nethogs_loop(history: Arc<Mutex<History>>) {
    let Ok(child) = Command::new("nethogs")
        .args(["-t", "-d", "1"])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    else {
        eprintln!("sysmond: nethogs not available, top-network-processes will stay empty");
        return;
    };
    let Some(stdout) = child.stdout else { return };
    let reader = BufReader::new(stdout);

    let mut current: HashMap<i32, ProcEntry> = HashMap::new();
    for line in reader.lines().map_while(Result::ok) {
        if line.starts_with("Refreshing:") {
            let entries: Vec<ProcEntry> = current.drain().map(|(_, v)| v).collect();
            let mut top_net = top_n(entries, 10);
            enrich_details(&mut top_net);
            history.lock().unwrap().top_net = top_net;
            continue;
        }
        if let Some(entry) = parse_nethogs_line(&line) {
            current.insert(entry.pid, entry);
        }
    }
}

fn sample_loop(history: Arc<Mutex<History>>, clk_tck: f64) {
    let thermal_zone = find_cpu_thermal_zone();
    let disk_names = whole_disk_names();
    let mut prev_cpu_lines = read_all_cpu_lines();
    let mut prev_net: HashMap<String, (u64, u64, Instant)> = HashMap::new();
    let mut prev_disk: HashMap<String, (u64, u64, Instant)> = HashMap::new();
    let mut prev_proc_ticks: HashMap<i32, u64> = HashMap::new();

    loop {
        std::thread::sleep(Duration::from_millis(SAMPLE_INTERVAL_MS));

        let cur_cpu_lines = read_all_cpu_lines();
        let pct_of = |cur: (u64, u64), prev: (u64, u64)| -> f64 {
            let d_total = cur.1.saturating_sub(prev.1);
            let d_idle = cur.0.saturating_sub(prev.0);
            if d_total > 0 {
                100.0 * (1.0 - d_idle as f64 / d_total as f64)
            } else {
                0.0
            }
        };
        let cpu_total = match (cur_cpu_lines.first(), prev_cpu_lines.first()) {
            (Some(&c), Some(&p)) => pct_of(c, p),
            _ => 0.0,
        };
        let core_pcts: Vec<f64> = cur_cpu_lines
            .iter()
            .skip(1)
            .zip(prev_cpu_lines.iter().skip(1))
            .map(|(&c, &p)| pct_of(c, p))
            .collect();
        prev_cpu_lines = cur_cpu_lines;

        let temp_c = thermal_zone
            .as_ref()
            .and_then(|p| fs::read_to_string(p).ok())
            .and_then(|s| s.trim().parse::<f64>().ok())
            .map(|millideg| millideg / 1000.0)
            .unwrap_or(0.0);

        let now = Instant::now();
        let current = read_all_iface_bytes();
        let mut rates: Vec<(String, f64, f64)> = Vec::with_capacity(current.len());
        for (name, (rx, tx)) in &current {
            let rate = match prev_net.get(name) {
                Some((prev_rx, prev_tx, prev_time)) => {
                    let elapsed = now.duration_since(*prev_time).as_secs_f64().max(0.001);
                    (
                        rx.saturating_sub(*prev_rx) as f64 / elapsed,
                        tx.saturating_sub(*prev_tx) as f64 / elapsed,
                    )
                }
                None => (0.0, 0.0), // first sample of a newly-seen interface
            };
            rates.push((name.clone(), rate.0, rate.1));
        }
        // Only keep interfaces seen this tick, so one that reappears later
        // (e.g. a VPN tunnel bounced) starts fresh rather than computing a
        // rate against a stale, arbitrarily old timestamp.
        prev_net = current.into_iter().map(|(name, (rx, tx))| (name, (rx, tx, now))).collect();

        let cur_disk = read_all_disk_bytes(&disk_names);
        let mut disk_rates: Vec<(String, f64, f64)> = Vec::with_capacity(cur_disk.len());
        for (name, (rd, wr)) in &cur_disk {
            let rate = match prev_disk.get(name) {
                Some((prev_rd, prev_wr, prev_time)) => {
                    let elapsed = now.duration_since(*prev_time).as_secs_f64().max(0.001);
                    (
                        rd.saturating_sub(*prev_rd) as f64 / elapsed,
                        wr.saturating_sub(*prev_wr) as f64 / elapsed,
                    )
                }
                None => (0.0, 0.0),
            };
            disk_rates.push((name.clone(), rate.0, rate.1));
        }
        prev_disk = cur_disk.into_iter().map(|(name, (rd, wr))| (name, (rd, wr, now))).collect();

        let (mem_used_pct, mem_cached_pct) = read_mem_pcts();

        // Top-10 by CPU: needs a tick-over-tick delta per pid, same idea as
        // the aggregate/per-core calc above, just keyed by pid instead of
        // core index. Ticks -> % of one core via clk_tck and the real
        // elapsed wall time (SAMPLE_INTERVAL_MS, not measured, since the
        // sleep above is already that fixed interval).
        let pids = list_pids();
        let mut cur_proc_ticks: HashMap<i32, u64> = HashMap::with_capacity(pids.len());
        let mut top_cpu_entries = Vec::with_capacity(pids.len());
        let elapsed_s = SAMPLE_INTERVAL_MS as f64 / 1000.0;
        for pid in &pids {
            let Some(ticks) = proc_cpu_ticks(*pid) else { continue };
            cur_proc_ticks.insert(*pid, ticks);
            if let Some(prev_ticks) = prev_proc_ticks.get(pid) {
                let d_ticks = ticks.saturating_sub(*prev_ticks);
                let pct = 100.0 * (d_ticks as f64 / clk_tck) / elapsed_s;
                if pct > 0.05 {
                    top_cpu_entries.push(ProcEntry { pid: *pid, name: proc_name(*pid), value: pct, detail: String::new() });
                }
            }
        }
        prev_proc_ticks = cur_proc_ticks;
        let mut top_cpu = top_n(top_cpu_entries, 10);
        enrich_details(&mut top_cpu);

        // Top-10 by memory: instantaneous, no delta needed.
        let mut top_mem_entries = Vec::with_capacity(pids.len());
        for pid in &pids {
            if let Some(mb) = proc_rss_mb(*pid) {
                if mb > 0.0 {
                    top_mem_entries.push(ProcEntry { pid: *pid, name: proc_name(*pid), value: mb, detail: String::new() });
                }
            }
        }
        let mut top_mem = top_n(top_mem_entries, 10);
        enrich_details(&mut top_mem);

        let mut h = history.lock().unwrap();
        h.cpu_total.push_raw(cpu_total);
        h.temp_c.push_raw(temp_c);
        h.mem_used_pct.push_raw(mem_used_pct);
        h.mem_cached_pct.push_raw(mem_cached_pct);
        for (i, pct) in core_pcts.into_iter().enumerate() {
            if let Some(series) = h.cpu_cores.get_mut(i) {
                series.push_raw(pct);
            }
        }
        for (name, rx_bps, tx_bps) in rates {
            let buf = h.net.entry(name).or_insert_with(TwoSeriesBuf::new);
            buf.a.push_raw(rx_bps);
            buf.b.push_raw(tx_bps);
        }
        for (name, rd_bps, wr_bps) in disk_rates {
            let buf = h.disk.entry(name).or_insert_with(TwoSeriesBuf::new);
            buf.a.push_raw(rd_bps);
            buf.b.push_raw(wr_bps);
        }
        h.top_cpu = top_cpu;
        h.top_mem = top_mem;
    }
}

/// Saves the full tiered history to disk periodically so the coarser tiers
/// (7d/7w/7mo) survive a sysmond restart instead of restarting empty --
/// those spans are exactly the ones that take the longest to refill
/// otherwise. Runs on its own thread/interval, independent of the 1s
/// sampling loop; every 60s is frequent enough given the coarsest tier's
/// own resolution is measured in hours.
fn persist_loop(history: Arc<Mutex<History>>) {
    loop {
        std::thread::sleep(Duration::from_secs(60));
        history.lock().unwrap().save_to_disk();
    }
}

fn serve_client(stream: UnixStream, history: Arc<Mutex<History>>) {
    let mut reader = BufReader::new(stream.try_clone().expect("clone unix stream"));
    let mut request_line = String::new();
    if reader.read_line(&mut request_line).unwrap_or(0) == 0 {
        return;
    }
    let Some(Request { metric, tier }) = Request::parse(&request_line) else { return };

    let mut writer = stream;
    loop {
        let snapshot = {
            let h = history.lock().unwrap();
            match metric {
                Metric::Net => Snapshot::Net {
                    interfaces: h
                        .net
                        .iter()
                        .map(|(name, buf)| IfaceHistory {
                            name: name.clone(),
                            rx_bps: buf.a.get(tier),
                            tx_bps: buf.b.get(tier),
                        })
                        .collect(),
                },
                Metric::Disk => Snapshot::Disk {
                    devices: h
                        .disk
                        .iter()
                        .map(|(name, buf)| DiskHistory {
                            name: name.clone(),
                            read_bps: buf.a.get(tier),
                            write_bps: buf.b.get(tier),
                        })
                        .collect(),
                },
                Metric::Cpu => Snapshot::Cpu {
                    total: h.cpu_total.get(tier),
                    cores: h.cpu_cores.iter().map(|c| c.get(tier)).collect(),
                },
                Metric::Temp => Snapshot::Temp {
                    celsius: h.temp_c.get(tier),
                },
                Metric::Mem => Snapshot::Mem {
                    used_pct: h.mem_used_pct.get(tier),
                    cached_pct: h.mem_cached_pct.get(tier),
                },
                Metric::TopCpu => Snapshot::TopProcs { procs: h.top_cpu.clone() },
                Metric::TopMem => Snapshot::TopProcs { procs: h.top_mem.clone() },
                Metric::TopNet => Snapshot::TopProcs { procs: h.top_net.clone() },
            }
        };
        let Ok(line) = serde_json::to_string(&snapshot) else { return };
        if writer.write_all(line.as_bytes()).is_err() || writer.write_all(b"\n").is_err() {
            return; // client disconnected
        }
        if writer.flush().is_err() {
            return;
        }
        std::thread::sleep(Duration::from_millis(SAMPLE_INTERVAL_MS));
    }
}

fn main() {
    let clk_tck = unsafe { libc::sysconf(libc::_SC_CLK_TCK) } as f64;
    let n_cores = count_cores();
    let history = Arc::new(Mutex::new(History::new(n_cores)));

    {
        let history = history.clone();
        std::thread::spawn(move || sample_loop(history, clk_tck));
    }
    {
        let history = history.clone();
        std::thread::spawn(move || nethogs_loop(history));
    }
    {
        // Periodic save only, deliberately no SIGTERM/SIGINT handler --
        // taking the History mutex and doing file I/O from a raw signal
        // handler risks a self-deadlock if the signal lands while
        // sample_loop already holds that same lock (signal handlers aren't
        // async-signal-safe for mutex locks or allocation). At most 60s of
        // the finest tiers is ever at risk on an unclean stop.
        let history = history.clone();
        std::thread::spawn(move || persist_loop(history));
    }

    let path = socket_path();
    let _ = fs::remove_file(&path); // stale socket from a crashed previous run

    let listener = match UnixListener::bind(&path) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("sysmond: failed to bind {}: {e}", path.display());
            std::process::exit(1);
        }
    };

    for conn in listener.incoming() {
        let Ok(stream) = conn else { continue };
        let history = history.clone();
        std::thread::spawn(move || serve_client(stream, history));
    }
}
