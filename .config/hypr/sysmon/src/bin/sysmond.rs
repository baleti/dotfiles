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
use sysmon::{socket_path, DiskHistory, GpuHistory, IfaceHistory, Metric, ProcEntry, Request, Snapshot, Tier, ALL_TIERS, SAMPLE_INTERVAL_MS, TIER_CAPACITY};

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
    // Total points ever finalized into `buf` over this TierBuf's whole
    // life, never reset by capacity eviction (unlike buf.len(), which caps
    // at TIER_CAPACITY) -- lets a delta-streaming client's "I've seen N
    // points" bookmark be compared against this monotonic counter to know
    // exactly how many new points to send, even once eviction means buf's
    // own length stops growing. See TieredSeries::delta_since.
    total_pushed: u64,
}

impl TierBuf {
    fn new(tier: Tier) -> Self {
        TierBuf {
            interval: tier.raw_samples_per_point(),
            buf: VecDeque::with_capacity(TIER_CAPACITY),
            accum_sum: 0.0,
            accum_n: 0,
            total_pushed: 0,
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
            self.total_pushed += 1;
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

    fn total_pushed(&self, tier: Tier) -> u64 {
        let idx = ALL_TIERS.iter().position(|&t| t == tier).unwrap();
        self.tiers[idx].total_pushed
    }

    /// Points appended since `since` (a prior `total_pushed()` reading),
    /// oldest-first, clamped to whatever's still buffered. `since: 0`
    /// naturally returns the entire current buffer (nothing "missing" is
    /// ever more than what's stored), so a full send is just this with
    /// `since = 0` -- same call, no separate code path. Self-correcting by
    /// construction: whatever comes back is always exactly the true
    /// current tail for `since`, regardless of what the caller already
    /// had, so there's no way for a client to accumulate drift from this
    /// call alone -- the worst case (a caller's `since` so stale the
    /// missing span exceeds the buffer) just silently degrades to
    /// returning the whole buffer instead of erroring.
    fn delta_since(&self, tier: Tier, since: u64) -> Vec<f64> {
        let idx = ALL_TIERS.iter().position(|&t| t == tier).unwrap();
        let tb = &self.tiers[idx];
        let missing = (tb.total_pushed.saturating_sub(since) as usize).min(tb.buf.len());
        tb.buf.iter().skip(tb.buf.len() - missing).copied().collect()
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

/// Percent of swap space in use (SwapTotal - SwapFree over SwapTotal),
/// 0.0 when the system has no swap configured at all.
fn read_swap_pct() -> f64 {
    let Ok(meminfo) = fs::read_to_string("/proc/meminfo") else { return 0.0 };
    let mut total = 0.0_f64;
    let mut free = 0.0_f64;
    for line in meminfo.lines() {
        let Some((key, rest)) = line.split_once(':') else { continue };
        let kb: f64 = rest.trim().trim_end_matches(" kB").parse().unwrap_or(0.0);
        match key {
            "SwapTotal" => total = kb,
            "SwapFree" => free = kb,
            _ => {}
        }
    }
    if total <= 0.0 {
        return 0.0;
    }
    100.0 * (1.0 - free / total)
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
    // `#[serde(default)]` so a history.json saved before swap tracking
    // existed still loads -- without it, a missing key fails the whole
    // parse and every other series (cpu/mem/net/disk) would restart empty
    // too, not just swap.
    #[serde(default)]
    swap_used_pct: PersistedSeries,
    // Per-GPU util/vram/power history, keyed by GPU name. `#[serde(default)]`
    // for the same reason as swap. The pre-multi-GPU `gpu_util_pct` /
    // `gpu_vram_pct` / `gpu_power_pct` flat fields are simply dropped on the
    // upgrade -- throwaway monitoring history, not worth a migration.
    #[serde(default)]
    gpus: Vec<PersistedGpu>,
    net: HashMap<String, (PersistedSeries, PersistedSeries)>,
    disk: HashMap<String, (PersistedSeries, PersistedSeries)>,
}

#[derive(Serialize, Deserialize, Default)]
struct PersistedGpu {
    name: String,
    #[serde(default)]
    vendor: String,
    util: PersistedSeries,
    #[serde(default)]
    vram: PersistedSeries,
    #[serde(default)]
    power: PersistedSeries,
}

/// Point-in-time GPU detail readings (everything that isn't a history
/// series) -- refreshed each sample by `gpu_loop` (nvidia-smi) or
/// `intel_gpu_loop` (i915 fdinfo). Zero/empty where a given GPU doesn't
/// report that field.
#[derive(Default, Clone)]
struct GpuLatest {
    temp_c: f64,
    power_w: f64,
    power_limit_w: f64,
    vram_used_mb: f64,
    vram_total_mb: f64,
    sm_clock_mhz: f64,
    mem_clock_mhz: f64,
    enc_pct: f64,
    dec_pct: f64,
    fan_pct: f64,
}

/// One GPU's in-memory history: the three tiered series, its latest detail
/// block, and its own top-processes list. `History::gpus` is built once at
/// startup (`enumerate_gpus`) and never resized -- each sampler thread
/// updates its own vendor's entry in place.
struct GpuHist {
    name: String,
    vendor: String, // "nvidia" | "intel"
    util: TieredSeries,
    vram: TieredSeries,
    power: TieredSeries,
    detail: GpuLatest,
    top: Vec<ProcEntry>,
}

impl GpuHist {
    fn new(name: String, vendor: String) -> Self {
        GpuHist {
            name,
            vendor,
            util: TieredSeries::new(),
            vram: TieredSeries::new(),
            power: TieredSeries::new(),
            detail: GpuLatest::default(),
            top: Vec::new(),
        }
    }
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
    swap_used_pct: TieredSeries,
    // One entry per GPU (iGPU + dGPU on a hybrid laptop), built once by
    // `enumerate_gpus` and updated in place by `gpu_loop` (nvidia) and
    // `intel_gpu_loop` (i915). Empty if the machine has no supported GPU.
    gpus: Vec<GpuHist>,
    top_cpu: Vec<ProcEntry>,
    top_mem: Vec<ProcEntry>,
    // Per-process network attribution needs packet capture (nethogs, via
    // its own cap_net_raw/cap_net_admin/cap_dac_read_search/cap_sys_ptrace
    // file capabilities -- already set on this system's /usr/bin/nethogs,
    // confirmed 2026-08-27, so sysmond itself stays fully unprivileged and
    // never needs root). Empty if nethogs isn't installed or isn't
    // capable-enabled -- see nethogs_loop's graceful skip.
    top_net: Vec<ProcEntry>,
    // Per-process disk I/O, from /proc/[pid]/io's read_bytes/write_bytes --
    // readable for the daemon's own user's processes UNLESS a given one has
    // marked itself non-dumpable (prctl PR_SET_DUMPABLE 0, e.g. systemd
    // --user itself, pam sessions), which /proc/[pid]/io gates even for its
    // owning user as an anti-side-channel measure; those just silently drop
    // out of proc_io_bytes's None rather than the whole feature failing.
    // No capability/setcap needed (unlike nethogs) since this never reads
    // another user's processes on this single-user machine.
    top_disk: Vec<ProcEntry>,
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
            swap_used_pct: TieredSeries::new(),
            gpus: enumerate_gpus(),
            top_cpu: Vec::new(),
            top_mem: Vec::new(),
            top_net: Vec::new(),
            top_disk: Vec::new(),
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
        self.swap_used_pct.load_persisted(&p.swap_used_pct);
        for saved in &p.gpus {
            if let Some(g) = self.gpus.iter_mut().find(|g| g.name == saved.name) {
                g.util.load_persisted(&saved.util);
                g.vram.load_persisted(&saved.vram);
                g.power.load_persisted(&saved.power);
            }
        }
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
            swap_used_pct: self.swap_used_pct.to_persisted(),
            gpus: self
                .gpus
                .iter()
                .map(|g| PersistedGpu {
                    name: g.name.clone(),
                    vendor: g.vendor.clone(),
                    util: g.util.to_persisted(),
                    vram: g.vram.to_persisted(),
                    power: g.power.to_persisted(),
                })
                .collect(),
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

    // Used to always end with "pid {pid}" here as the last-resort unique
    // handle when several processes share a comm AND an identical
    // cmdline/cwd (e.g. several `claude --dangerously-skip-permissions`
    // all launched from $HOME) -- dropped now that every client renders
    // pid as its own dedicated column (request 2026-09-06), which makes
    // that disambiguation redundant here and just clutters the detail
    // text (confirmed live: multiple bare "alacritty" rows used to each
    // end in a visually-merged "...pid 2562907" right up against the new
    // pid column's own "2562907").
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

/// `/proc/[pid]/io`'s read_bytes/write_bytes -- actual block I/O (not
/// rchar/wchar, which also count cache-served reads/writes with no disk
/// activity behind them), matching what the per-device read_bps/write_bps
/// history already measures. None for a process this user can't read
/// (someone else's, or one that's marked itself non-dumpable) -- callers
/// just skip it, same as any other pid that vanished mid-scan.
fn proc_io_bytes(pid: i32) -> Option<(u64, u64)> {
    let io = fs::read_to_string(format!("/proc/{pid}/io")).ok()?;
    let mut read_bytes = None;
    let mut write_bytes = None;
    for line in io.lines() {
        if let Some(rest) = line.strip_prefix("read_bytes:") {
            read_bytes = rest.trim().parse::<u64>().ok();
        } else if let Some(rest) = line.strip_prefix("write_bytes:") {
            write_bytes = rest.trim().parse::<u64>().ok();
        }
    }
    Some((read_bytes?, write_bytes?))
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
    Some(ProcEntry { pid, name, value: sent + recv, detail: String::new(), util_pct: 0.0 })
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

/// Runs `f` against the first GPU of the given vendor, if the machine has
/// one. `History::gpus` is fixed-size after startup so this is just a short
/// linear scan under the lock.
fn with_gpu<F: FnOnce(&mut GpuHist)>(history: &Mutex<History>, vendor: &str, f: F) {
    let mut h = history.lock().unwrap();
    if let Some(g) = h.gpus.iter_mut().find(|g| g.vendor == vendor) {
        f(g);
    }
}

/// Enumerates every GPU on the machine, iGPU first. Intel: a DRM card whose
/// PCI vendor is 0x8086 with a render-capable `gt` node. NVIDIA: one line
/// per name from `nvidia-smi`. Names here are what the bar shows and what
/// persisted history is keyed by.
fn enumerate_gpus() -> Vec<GpuHist> {
    let mut out = Vec::new();

    if let Ok(cards) = fs::read_dir("/sys/class/drm") {
        let mut cards: Vec<_> = cards.flatten().map(|e| e.path()).collect();
        cards.sort();
        for p in cards {
            let Some(n) = p.file_name().and_then(|s| s.to_str()) else { continue };
            if !(n.starts_with("card") && n[4..].chars().all(|c| c.is_ascii_digit())) {
                continue;
            }
            let vendor = fs::read_to_string(p.join("device/vendor")).unwrap_or_default();
            if vendor.trim() != "0x8086" {
                continue;
            }
            if !p.join("gt_cur_freq_mhz").exists() && !p.join("gt").exists() {
                continue; // headless / non-render Intel device
            }
            let slot = fs::read_link(p.join("device"))
                .ok()
                .and_then(|t| t.file_name().map(|s| s.to_string_lossy().into_owned()))
                .unwrap_or_default();
            out.push(GpuHist::new(intel_gpu_name(&slot), "intel".into()));
        }
    }

    if let Ok(o) = Command::new("nvidia-smi")
        .args(["--query-gpu=name", "--format=csv,noheader"])
        .stderr(Stdio::null())
        .output()
    {
        if o.status.success() {
            for line in String::from_utf8_lossy(&o.stdout).lines() {
                let name = line.trim();
                if !name.is_empty() {
                    out.push(GpuHist::new(name.to_string(), "nvidia".into()));
                }
            }
        }
    }

    if out.is_empty() {
        eprintln!("sysmond: no GPU detected, gpu metric will stay empty");
    } else {
        eprintln!(
            "sysmond: GPUs: {}",
            out.iter().map(|g| format!("{} ({})", g.name, g.vendor)).collect::<Vec<_>>().join(", ")
        );
    }
    out
}

/// A friendly name for the Intel GPU at PCI `slot` (e.g. "0000:00:02.0"),
/// from `lspci`. `"CometLake-H GT2 [UHD Graphics]"` -> `"Intel UHD
/// Graphics"`; falls back to `"Intel GPU"`.
fn intel_gpu_name(slot: &str) -> String {
    let short = slot.strip_prefix("0000:").unwrap_or(slot);
    let out = Command::new("lspci")
        .args(["-mm", "-s", short])
        .stderr(Stdio::null())
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();
    // lspci -mm: `slot "class" "vendor" "device" ...` -- the device field is
    // the 4th quoted token (index 5 after splitting on '"').
    let device = out.split('"').nth(5).unwrap_or("").trim().to_string();
    let pretty = match (device.find('['), device.find(']')) {
        (Some(a), Some(b)) if b > a => device[a + 1..b].to_string(),
        _ => device,
    };
    if pretty.is_empty() {
        "Intel GPU".to_string()
    } else if pretty.to_lowercase().contains("intel") {
        pretty
    } else {
        format!("Intel {pretty}")
    }
}

/// Reads a `key value [unit]` line (i915 fdinfo memory fields) as KiB:
/// `"28204 KiB"` -> 28204, `"8 MiB"` -> 8192, bare number -> as-is.
fn parse_kib(s: &str) -> f64 {
    let mut it = s.split_whitespace();
    let n: f64 = it.next().and_then(|x| x.parse().ok()).unwrap_or(0.0);
    match it.next() {
        Some("MiB") => n * 1024.0,
        Some("GiB") => n * 1024.0 * 1024.0,
        _ => n,
    }
}

/// Full-process scan for DRM clients: checks every pid's open fds for a
/// `/dev/dri/` symlink. This is the expensive part of `intel_gpu_loop` --
/// readdir + readlink per fd across every process on the machine -- so it's
/// only re-run every `GPU_RESCAN_TICKS` samples instead of every tick; see
/// that constant's doc comment.
fn find_drm_pids() -> Vec<i32> {
    let mut out = Vec::new();
    for pid in list_pids() {
        let Ok(fds) = fs::read_dir(format!("/proc/{pid}/fd")) else { continue };
        let is_drm = fds.flatten().any(|fd| {
            fs::read_link(fd.path())
                .map(|t| t.to_string_lossy().starts_with("/dev/dri/"))
                .unwrap_or(false)
        });
        if is_drm {
            out.push(pid);
        }
    }
    out
}

/// How often, in `intel_gpu_loop` samples (roughly seconds), `find_drm_pids`
/// re-scans every process on the machine for new DRM clients. A new client
/// only shows up within one window of this instead of instantly -- an
/// acceptable trade since GPU-process attribution doesn't need to be
/// sub-second, and it turns the loop's dominant cost (full-process fd
/// enumeration, ~1000 pids on this machine) from once a second into once
/// every few.
const GPU_RESCAN_TICKS: u64 = 4;

/// Intel iGPU utilisation and per-process breakdown from `/proc/*/fdinfo`
/// i915 engine counters -- cumulative per-engine nanoseconds, exposed
/// unprivileged for the caller's own processes (the same source nvtop
/// uses). Sums the render-engine busy time across all DRM clients for the
/// total and per-pid for the top-processes list; there's no dedicated VRAM
/// total (the iGPU shares system RAM), so only `util` gets a history line
/// and the resident-memory sum / current frequency go in the detail block.
///
/// Which pids even have a `/dev/dri/` fd open (`find_drm_pids`) is only
/// re-scanned every `GPU_RESCAN_TICKS` samples; every tick in between just
/// re-reads fdinfo for the pids that last scan found, which stays cheap
/// since it's scoped to a handful of pids instead of every process.
fn intel_gpu_loop(history: Arc<Mutex<History>>) {
    let mut prev: HashMap<u64, (u64, u64)> = HashMap::new(); // client-id -> (render_ns, video_ns)
    let mut last = Instant::now();
    let mut drm_pids: Vec<i32> = find_drm_pids();
    let mut ticks_since_rescan: u64 = 0;

    loop {
        std::thread::sleep(Duration::from_millis(SAMPLE_INTERVAL_MS));
        let now = Instant::now();
        let wall_ns = now.duration_since(last).as_nanos() as f64;
        last = now;
        if wall_ns <= 0.0 {
            continue;
        }

        if ticks_since_rescan == 0 {
            drm_pids = find_drm_pids();
        }
        ticks_since_rescan = (ticks_since_rescan + 1) % GPU_RESCAN_TICKS;

        // client-id -> (render_ns, video_ns, pid, resident_kib)
        let mut cur: HashMap<u64, (u64, u64, i32, f64)> = HashMap::new();
        let mut still_alive = Vec::with_capacity(drm_pids.len());
        for pid in drm_pids.iter().copied() {
            // Missing fdinfo means the process exited since the last scan --
            // just drop it, the next scan won't re-add it.
            let Ok(entries) = fs::read_dir(format!("/proc/{pid}/fdinfo")) else { continue };
            still_alive.push(pid);
            for ent in entries.flatten() {
                let Ok(text) = fs::read_to_string(ent.path()) else { continue };
                let is_i915 = text.lines().any(|l| {
                    l.strip_prefix("drm-driver:").map(|v| v.trim() == "i915").unwrap_or(false)
                });
                if !is_i915 {
                    continue;
                }
                let mut cid = None;
                let mut render = 0u64;
                let mut video = 0u64;
                let mut resident_kib = 0.0;
                for l in text.lines() {
                    if let Some(v) = l.strip_prefix("drm-client-id:") {
                        cid = v.trim().parse::<u64>().ok();
                    } else if let Some(v) = l.strip_prefix("drm-engine-render:") {
                        render = v.split_whitespace().next().and_then(|x| x.parse().ok()).unwrap_or(0);
                    } else if let Some(v) = l.strip_prefix("drm-engine-video:") {
                        video = v.split_whitespace().next().and_then(|x| x.parse().ok()).unwrap_or(0);
                    } else if let Some(v) = l.strip_prefix("drm-resident-system0:") {
                        resident_kib = parse_kib(v.trim());
                    }
                }
                let Some(cid) = cid else { continue };
                // Several fds can share one client-id with identical
                // counters -- keep the first.
                cur.entry(cid).or_insert((render, video, pid, resident_kib));
            }
        }
        drm_pids = still_alive;

        let mut total_render = 0.0;
        let mut total_video = 0.0;
        let mut per_pid: HashMap<i32, (f64, f64)> = HashMap::new(); // pid -> (busy_ns, resident_kib)
        for (cid, &(render, video, pid, resident_kib)) in &cur {
            let (dr, dv) = match prev.get(cid) {
                Some(&(pr, pv)) => (render.saturating_sub(pr) as f64, video.saturating_sub(pv) as f64),
                None => (0.0, 0.0),
            };
            total_render += dr;
            total_video += dv;
            let e = per_pid.entry(pid).or_insert((0.0, 0.0));
            e.0 += dr + dv;
            e.1 += resident_kib;
        }
        prev = cur.iter().map(|(cid, &(r, v, _, _))| (*cid, (r, v))).collect();

        let util = (100.0 * total_render / wall_ns).min(100.0);
        let video_pct = (100.0 * total_video / wall_ns).min(100.0);
        let resident_mb = per_pid.values().map(|v| v.1).sum::<f64>() / 1024.0;
        // The iGPU has no dedicated VRAM -- its buffers are GEM objects in
        // system RAM -- so its "memory" line is resident bytes as a percent
        // of MemTotal.
        let ram_total_mb = fs::read_to_string("/proc/meminfo")
            .ok()
            .and_then(|s| {
                s.lines().find_map(|l| {
                    l.strip_prefix("MemTotal:")
                        .and_then(|r| r.trim().trim_end_matches(" kB").trim().parse::<f64>().ok())
                })
            })
            .map(|kb| kb / 1024.0)
            .unwrap_or(0.0);
        let mem_pct = if ram_total_mb > 0.0 { 100.0 * resident_mb / ram_total_mb } else { 0.0 };
        let freq = fs::read_to_string("/sys/class/drm/card0/gt_cur_freq_mhz")
            .ok()
            .or_else(|| find_intel_freq())
            .and_then(|s| s.trim().parse::<f64>().ok())
            .unwrap_or(0.0);

        let mut ranked: Vec<(ProcEntry, f64)> = per_pid
            .into_iter()
            .filter(|(_, (busy, res))| *busy > 0.0 || *res > 0.0)
            .map(|(pid, (busy, res))| {
                let pct = (100.0 * busy / wall_ns).min(100.0);
                (ProcEntry { pid, name: proc_name(pid), value: res / 1024.0, detail: String::new(), util_pct: 0.0 }, pct)
            })
            .collect();
        ranked.sort_by(|a, b| {
            b.1.partial_cmp(&a.1)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then(b.0.value.partial_cmp(&a.0.value).unwrap_or(std::cmp::Ordering::Equal))
        });
        ranked.truncate(10);
        let mut top: Vec<ProcEntry> = ranked.iter().map(|(e, _)| e.clone()).collect();
        enrich_details(&mut top);
        // util_pct is its own field now (request 2026-09-06), not folded
        // into `detail` text -- `entry.detail` stays just the cmdline/cwd
        // hint, same shape as every other metric's ProcEntry.
        for (entry, (_, pct)) in top.iter_mut().zip(ranked.iter()) {
            entry.util_pct = *pct;
        }

        with_gpu(&history, "intel", |g| {
            g.util.push_raw(util);
            g.vram.push_raw(mem_pct);
            g.detail.vram_used_mb = resident_mb;
            g.detail.vram_total_mb = ram_total_mb;
            g.detail.sm_clock_mhz = freq;
            g.detail.dec_pct = video_pct;
            g.top = top;
        });
    }
}

/// Fallback for the current-frequency read when the Intel card isn't
/// `card0` -- scans for the 0x8086 DRM card's `gt_cur_freq_mhz`.
fn find_intel_freq() -> Option<String> {
    let cards = fs::read_dir("/sys/class/drm").ok()?;
    for c in cards.flatten() {
        let p = c.path();
        if fs::read_to_string(p.join("device/vendor")).map(|v| v.trim() == "0x8086").unwrap_or(false) {
            if let Ok(s) = fs::read_to_string(p.join("gt_cur_freq_mhz")) {
                return Some(s);
            }
        }
    }
    None
}

/// Streams one CSV line per second from a long-lived
/// `nvidia-smi --query-gpu=... -l 1` subprocess, pushing engine load, VRAM
/// occupancy and board power (as % of the enforced power limit / TGP) into
/// the nvidia GPU's tiered history and refreshing its detail block.
///
/// Same "missing sensor just stays empty, never a crash" contract as
/// `nethogs_loop`: if `nvidia-smi` isn't installed the thread logs once and
/// returns. It respawns the subprocess if it exits (driver reload,
/// suspend/resume).
///
/// Query fields: utilization.gpu, memory.used, memory.total, temperature.gpu,
/// power.draw, enforced.power.limit, clocks.sm, clocks.mem, fan.speed,
/// utilization.encoder, utilization.decoder, name. `enforced.power.limit` is
/// used rather than `power.limit` because the latter is often `[N/A]` on
/// mobile parts while the former still reports the TGP.
fn gpu_loop(history: Arc<Mutex<History>>) {
    const QUERY: &str = "--query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,enforced.power.limit,clocks.sm,clocks.mem,fan.speed,utilization.encoder,utilization.decoder,name";

    let parse_num = |s: &str| -> f64 {
        let t = s.trim();
        if t.eq_ignore_ascii_case("[n/a]") || t.eq_ignore_ascii_case("n/a") {
            0.0
        } else {
            t.parse().unwrap_or(0.0)
        }
    };

    loop {
        let child = match Command::new("nvidia-smi")
            .args([QUERY, "--format=csv,noheader,nounits", "-l", "1"])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
        {
            Ok(c) => c,
            Err(_) => {
                eprintln!("sysmond: nvidia-smi not available, nvidia gpu metric will stay empty");
                return;
            }
        };
        let Some(stdout) = child.stdout else { return };

        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            let f: Vec<&str> = line.split(',').collect();
            if f.len() < 12 {
                continue;
            }
            let util = parse_num(f[0]);
            let vram_used = parse_num(f[1]);
            let vram_total = parse_num(f[2]);
            let vram_pct = if vram_total > 0.0 { 100.0 * vram_used / vram_total } else { 0.0 };
            let power_w = parse_num(f[4]);
            let power_limit_w = parse_num(f[5]);
            let power_pct = if power_limit_w > 0.0 { 100.0 * power_w / power_limit_w } else { 0.0 };
            let detail = GpuLatest {
                temp_c: parse_num(f[3]),
                power_w,
                power_limit_w,
                vram_used_mb: vram_used,
                vram_total_mb: vram_total,
                sm_clock_mhz: parse_num(f[6]),
                mem_clock_mhz: parse_num(f[7]),
                fan_pct: parse_num(f[8]),
                enc_pct: parse_num(f[9]),
                dec_pct: parse_num(f[10]),
            };

            with_gpu(&history, "nvidia", |g| {
                g.util.push_raw(util);
                g.vram.push_raw(vram_pct);
                g.power.push_raw(power_pct);
                g.detail = detail;
            });
        }

        eprintln!("sysmond: nvidia-smi stream ended, respawning in 5s");
        std::thread::sleep(Duration::from_secs(5));
    }
}

/// Ranks the current pmon cycle and stores it on the nvidia GPU: per-process
/// SM utilisation first (matching the pill's own "utilisation" metric), VRAM
/// as the tiebreak. `ProcEntry::value` carries the VRAM MiB (what the list
/// shows); `util_pct` carries the SM% as its own field (request
/// 2026-09-06 -- used to be folded into `detail` text).
fn gpu_flush(cur: &mut HashMap<i32, (ProcEntry, f64)>, history: &Mutex<History>) {
    let mut v: Vec<(ProcEntry, f64)> = cur.drain().map(|(_, e)| e).collect();
    v.sort_by(|a, b| {
        b.1.partial_cmp(&a.1)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(b.0.value.partial_cmp(&a.0.value).unwrap_or(std::cmp::Ordering::Equal))
    });
    v.truncate(10);

    let mut top: Vec<ProcEntry> = v.iter().map(|(e, _)| e.clone()).collect();
    enrich_details(&mut top);
    for (entry, (_, sm)) in top.iter_mut().zip(v.iter()) {
        entry.util_pct = *sm;
    }
    with_gpu(history, "nvidia", move |g| g.top = top);
}

/// Per-process GPU stats from a long-lived `nvidia-smi pmon -s um` stream
/// (one row per process per second; graphics *and* compute clients). Silent
/// no-op if nvidia-smi is missing (gpu_loop already logs that once);
/// respawns if the stream ends.
fn gpu_proc_loop(history: Arc<Mutex<History>>) {
    // pmon -s um row layout (driver 5xx):
    //   gpu(0) pid(1) type(2) sm(3) mem(4) enc(5) dec(6) jpg(7) ofa(8) fb(9) ccpm(10) command(11)
    let col = |s: &str| -> f64 {
        if s == "-" { 0.0 } else { s.parse().unwrap_or(0.0) }
    };

    loop {
        let child = match Command::new("nvidia-smi")
            .args(["pmon", "-s", "um"])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
        {
            Ok(c) => c,
            Err(_) => return,
        };
        let Some(stdout) = child.stdout else { return };

        // pmon has no per-cycle delimiter -- it just re-emits the same pids
        // every second. A pid reappearing marks the next cycle: flush what
        // we've accumulated, then start the new cycle with this row.
        let mut cur: HashMap<i32, (ProcEntry, f64)> = HashMap::new();
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            let tok: Vec<&str> = line.split_whitespace().collect();
            if tok.len() < 12 || tok[0].starts_with('#') {
                continue;
            }
            let Ok(pid) = tok[1].parse::<i32>() else { continue };
            let sm = col(tok[3]);
            let fb = col(tok[9]);
            let name = tok[11].to_string();

            if cur.contains_key(&pid) {
                gpu_flush(&mut cur, &history);
            }
            cur.insert(pid, (ProcEntry { pid, name, value: fb, detail: String::new(), util_pct: 0.0 }, sm));
        }

        eprintln!("sysmond: nvidia-smi pmon stream ended, respawning in 5s");
        std::thread::sleep(Duration::from_secs(5));
    }
}

fn sample_loop(history: Arc<Mutex<History>>, clk_tck: f64) {
    let thermal_zone = find_cpu_thermal_zone();
    let disk_names = whole_disk_names();
    let mut prev_cpu_lines = read_all_cpu_lines();
    let mut prev_net: HashMap<String, (u64, u64, Instant)> = HashMap::new();
    let mut prev_disk: HashMap<String, (u64, u64, Instant)> = HashMap::new();
    let mut prev_proc_ticks: HashMap<i32, u64> = HashMap::new();
    let mut prev_proc_io: HashMap<i32, (u64, u64)> = HashMap::new();

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
        let swap_used_pct = read_swap_pct();

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
                    top_cpu_entries.push(ProcEntry { pid: *pid, name: proc_name(*pid), value: pct, detail: String::new(), util_pct: 0.0 });
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
                    top_mem_entries.push(ProcEntry { pid: *pid, name: proc_name(*pid), value: mb, detail: String::new(), util_pct: 0.0 });
                }
            }
        }
        let mut top_mem = top_n(top_mem_entries, 10);
        enrich_details(&mut top_mem);

        // Top-10 by disk I/O: tick-over-tick delta like CPU, keyed by pid,
        // combined read+write KB/s. Silently excludes any pid proc_io_bytes
        // can't read (see its own comment) rather than failing the feature.
        let mut cur_proc_io: HashMap<i32, (u64, u64)> = HashMap::with_capacity(pids.len());
        let mut top_disk_entries = Vec::with_capacity(pids.len());
        for pid in &pids {
            let Some(io) = proc_io_bytes(*pid) else { continue };
            cur_proc_io.insert(*pid, io);
            if let Some(prev_io) = prev_proc_io.get(pid) {
                let d_read = io.0.saturating_sub(prev_io.0) as f64;
                let d_write = io.1.saturating_sub(prev_io.1) as f64;
                let kb_per_s = (d_read + d_write) / 1024.0 / elapsed_s;
                if kb_per_s > 1.0 {
                    top_disk_entries.push(ProcEntry { pid: *pid, name: proc_name(*pid), value: kb_per_s, detail: String::new(), util_pct: 0.0 });
                }
            }
        }
        prev_proc_io = cur_proc_io;
        let mut top_disk = top_n(top_disk_entries, 10);
        enrich_details(&mut top_disk);

        let mut h = history.lock().unwrap();
        h.cpu_total.push_raw(cpu_total);
        h.temp_c.push_raw(temp_c);
        h.mem_used_pct.push_raw(mem_used_pct);
        h.mem_cached_pct.push_raw(mem_cached_pct);
        h.swap_used_pct.push_raw(swap_used_pct);
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
        h.top_disk = top_disk;
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

/// How often (in ticks -- each client thread ticks on its own ~1s cadence,
/// not synchronized with sysmond's sampler threads) a live connection
/// forces a full resend of its history series even though nothing
/// structurally changed. `TieredSeries::delta_since` is mathematically
/// self-correcting on its own (a caller's tracked "since" can only ever be
/// stale, never wrong -- see its own doc comment), but re-syncing from
/// scratch on a fixed cadence regardless means any future bug in this
/// bookkeeping, or a client that silently missed messages without
/// noticing, can't compound for longer than this window before the wire
/// re-syncs from the daemon's real buffers. This is the periodic
/// drift-check for the delta stream, built into the protocol itself
/// rather than a separate audit job.
const FULL_RESYNC_TICKS: u64 = 30;

fn serve_client(stream: UnixStream, history: Arc<Mutex<History>>) {
    let mut reader = BufReader::new(stream.try_clone().expect("clone unix stream"));
    let mut request_line = String::new();
    if reader.read_line(&mut request_line).unwrap_or(0) == 0 {
        return;
    }
    let Some(Request { metric, tier }) = Request::parse(&request_line) else { return };

    let mut writer = stream;

    // Per-connection delta bookkeeping -- only whichever of these this
    // connection's own `metric` actually is ever gets touched. Each
    // "_since" value is a prior `TieredSeries::total_pushed()` reading (see
    // `delta_since`); tick 0 always goes out full, seeding all of these.
    let mut cpu_total_since: u64 = 0;
    let mut cpu_cores_since: Vec<u64> = Vec::new();
    let mut temp_since: u64 = 0;
    let mut mem_since: (u64, u64, u64) = (0, 0, 0);
    let mut net_since: HashMap<String, (u64, u64)> = HashMap::new();
    let mut disk_since: HashMap<String, (u64, u64)> = HashMap::new();
    let mut gpu_since: Vec<(u64, u64, u64)> = Vec::new();
    let mut tick: u64 = 0;

    loop {
        // True on tick 0 (first message on a fresh connection always goes
        // out full) and then every FULL_RESYNC_TICKS after that.
        let resync = tick % FULL_RESYNC_TICKS == 0;
        let snapshot = {
            let h = history.lock().unwrap();
            match metric {
                Metric::Net => {
                    // A name net_since doesn't know about yet (a new
                    // interface, e.g. a VPN tunnel that just came up) forces
                    // the whole message full -- simpler and safe, and rare.
                    let full = resync || h.net.keys().any(|k| !net_since.contains_key(k));
                    let interfaces: Vec<IfaceHistory> = h
                        .net
                        .iter()
                        .map(|(name, buf)| {
                            let (rx_since, tx_since) =
                                if full { (0, 0) } else { net_since.get(name).copied().unwrap_or((0, 0)) };
                            IfaceHistory {
                                name: name.clone(),
                                rx_bps: buf.a.delta_since(tier, rx_since),
                                tx_bps: buf.b.delta_since(tier, tx_since),
                            }
                        })
                        .collect();
                    net_since = h
                        .net
                        .iter()
                        .map(|(name, buf)| (name.clone(), (buf.a.total_pushed(tier), buf.b.total_pushed(tier))))
                        .collect();
                    Snapshot::Net { full, interfaces }
                }
                Metric::Disk => {
                    let full = resync || h.disk.keys().any(|k| !disk_since.contains_key(k));
                    let devices: Vec<DiskHistory> = h
                        .disk
                        .iter()
                        .map(|(name, buf)| {
                            let (rd_since, wr_since) =
                                if full { (0, 0) } else { disk_since.get(name).copied().unwrap_or((0, 0)) };
                            DiskHistory {
                                name: name.clone(),
                                read_bps: buf.a.delta_since(tier, rd_since),
                                write_bps: buf.b.delta_since(tier, wr_since),
                            }
                        })
                        .collect();
                    disk_since = h
                        .disk
                        .iter()
                        .map(|(name, buf)| (name.clone(), (buf.a.total_pushed(tier), buf.b.total_pushed(tier))))
                        .collect();
                    Snapshot::Disk { full, devices }
                }
                Metric::Gpu => {
                    // The GPU list itself is fixed after startup (see
                    // History::gpus), so the only reason this length check
                    // would ever trip is the very first tick.
                    let full = resync || gpu_since.len() != h.gpus.len();
                    if full {
                        gpu_since = vec![(0, 0, 0); h.gpus.len()];
                    }
                    let gpus: Vec<GpuHistory> = h
                        .gpus
                        .iter()
                        .zip(gpu_since.iter())
                        .map(|(g, &(util_since, vram_since, power_since))| GpuHistory {
                            name: g.name.clone(),
                            vendor: g.vendor.clone(),
                            util_pct: g.util.delta_since(tier, util_since),
                            vram_pct: g.vram.delta_since(tier, vram_since),
                            power_pct: g.power.delta_since(tier, power_since),
                            // Point-in-time already, not a history buffer --
                            // always sent fresh in full, delta or not.
                            temp_c: g.detail.temp_c,
                            power_w: g.detail.power_w,
                            power_limit_w: g.detail.power_limit_w,
                            vram_used_mb: g.detail.vram_used_mb,
                            vram_total_mb: g.detail.vram_total_mb,
                            sm_clock_mhz: g.detail.sm_clock_mhz,
                            mem_clock_mhz: g.detail.mem_clock_mhz,
                            enc_pct: g.detail.enc_pct,
                            dec_pct: g.detail.dec_pct,
                            fan_pct: g.detail.fan_pct,
                            procs: g.top.clone(),
                        })
                        .collect();
                    gpu_since = h
                        .gpus
                        .iter()
                        .map(|g| (g.util.total_pushed(tier), g.vram.total_pushed(tier), g.power.total_pushed(tier)))
                        .collect();
                    Snapshot::Gpu { full, gpus }
                }
                Metric::Cpu => {
                    let full = resync || cpu_cores_since.len() != h.cpu_cores.len();
                    let total_since = if full { 0 } else { cpu_total_since };
                    let cores_since: Vec<u64> = if full { vec![0; h.cpu_cores.len()] } else { cpu_cores_since.clone() };
                    let total = h.cpu_total.delta_since(tier, total_since);
                    let cores: Vec<Vec<f64>> =
                        h.cpu_cores.iter().zip(cores_since.iter()).map(|(c, &s)| c.delta_since(tier, s)).collect();
                    cpu_total_since = h.cpu_total.total_pushed(tier);
                    cpu_cores_since = h.cpu_cores.iter().map(|c| c.total_pushed(tier)).collect();
                    Snapshot::Cpu { full, total, cores }
                }
                Metric::Temp => {
                    let full = resync;
                    let since = if full { 0 } else { temp_since };
                    let celsius = h.temp_c.delta_since(tier, since);
                    temp_since = h.temp_c.total_pushed(tier);
                    Snapshot::Temp { full, celsius }
                }
                Metric::Mem => {
                    let full = resync;
                    let (used_since, cached_since, swap_since) = if full { (0, 0, 0) } else { mem_since };
                    let used_pct = h.mem_used_pct.delta_since(tier, used_since);
                    let cached_pct = h.mem_cached_pct.delta_since(tier, cached_since);
                    let swap_used_pct = h.swap_used_pct.delta_since(tier, swap_since);
                    mem_since = (
                        h.mem_used_pct.total_pushed(tier),
                        h.mem_cached_pct.total_pushed(tier),
                        h.swap_used_pct.total_pushed(tier),
                    );
                    Snapshot::Mem { full, used_pct, cached_pct, swap_used_pct }
                }
                Metric::TopCpu => Snapshot::TopProcs { procs: h.top_cpu.clone() },
                Metric::TopMem => Snapshot::TopProcs { procs: h.top_mem.clone() },
                Metric::TopNet => Snapshot::TopProcs { procs: h.top_net.clone() },
                Metric::TopDisk => Snapshot::TopProcs { procs: h.top_disk.clone() },
            }
        };
        tick += 1;
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

    let (has_nvidia, has_intel) = {
        let h = history.lock().unwrap();
        (
            h.gpus.iter().any(|g| g.vendor == "nvidia"),
            h.gpus.iter().any(|g| g.vendor == "intel"),
        )
    };

    {
        let history = history.clone();
        std::thread::spawn(move || sample_loop(history, clk_tck));
    }
    {
        let history = history.clone();
        std::thread::spawn(move || nethogs_loop(history));
    }
    if has_nvidia {
        {
            let history = history.clone();
            std::thread::spawn(move || gpu_loop(history));
        }
        {
            let history = history.clone();
            std::thread::spawn(move || gpu_proc_loop(history));
        }
    }
    if has_intel {
        let history = history.clone();
        std::thread::spawn(move || intel_gpu_loop(history));
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
