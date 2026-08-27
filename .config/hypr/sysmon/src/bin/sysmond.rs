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
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use sysmon::{socket_path, DiskHistory, IfaceHistory, Metric, ProcEntry, Snapshot, HISTORY_LEN, SAMPLE_INTERVAL_MS};

/// Two parallel rate histories -- rx/tx for a network interface, or
/// read/write for a disk. Field names are generic on purpose.
struct TwoSeriesBuf {
    a: VecDeque<f64>,
    b: VecDeque<f64>,
}

impl TwoSeriesBuf {
    fn new() -> Self {
        TwoSeriesBuf {
            a: VecDeque::with_capacity(HISTORY_LEN),
            b: VecDeque::with_capacity(HISTORY_LEN),
        }
    }
}

struct History {
    // Every non-loopback interface seen since startup, keyed by name --
    // not just the default route, so e.g. wg-wsl and wlan0 both get their
    // own overlaid series (2026-08-27).
    net: HashMap<String, TwoSeriesBuf>,
    // Every whole-disk block device seen since startup (partitions
    // excluded), keyed by name -- same overlay treatment as net.
    disk: HashMap<String, TwoSeriesBuf>,
    cpu_total: VecDeque<f64>,
    // One ring buffer per logical CPU, index = core number, for the bar's
    // stacked per-core view.
    cpu_cores: Vec<VecDeque<f64>>,
    temp_c: VecDeque<f64>,
    mem_used_pct: VecDeque<f64>,
    mem_cached_pct: VecDeque<f64>,
    top_cpu: Vec<ProcEntry>,
    top_mem: Vec<ProcEntry>,
}

impl History {
    fn new(n_cores: usize) -> Self {
        History {
            net: HashMap::new(),
            disk: HashMap::new(),
            cpu_total: VecDeque::with_capacity(HISTORY_LEN),
            cpu_cores: (0..n_cores).map(|_| VecDeque::with_capacity(HISTORY_LEN)).collect(),
            temp_c: VecDeque::with_capacity(HISTORY_LEN),
            mem_used_pct: VecDeque::with_capacity(HISTORY_LEN),
            mem_cached_pct: VecDeque::with_capacity(HISTORY_LEN),
            top_cpu: Vec::new(),
            top_mem: Vec::new(),
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

fn push_capped(buf: &mut VecDeque<f64>, v: f64) {
    if buf.len() == HISTORY_LEN {
        buf.pop_front();
    }
    buf.push_back(v);
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
                    top_cpu_entries.push(ProcEntry { pid: *pid, name: proc_name(*pid), value: pct });
                }
            }
        }
        prev_proc_ticks = cur_proc_ticks;
        let top_cpu = top_n(top_cpu_entries, 10);

        // Top-10 by memory: instantaneous, no delta needed.
        let mut top_mem_entries = Vec::with_capacity(pids.len());
        for pid in &pids {
            if let Some(mb) = proc_rss_mb(*pid) {
                if mb > 0.0 {
                    top_mem_entries.push(ProcEntry { pid: *pid, name: proc_name(*pid), value: mb });
                }
            }
        }
        let top_mem = top_n(top_mem_entries, 10);

        let mut h = history.lock().unwrap();
        push_capped(&mut h.cpu_total, cpu_total);
        push_capped(&mut h.temp_c, temp_c);
        push_capped(&mut h.mem_used_pct, mem_used_pct);
        push_capped(&mut h.mem_cached_pct, mem_cached_pct);
        for (i, pct) in core_pcts.into_iter().enumerate() {
            if let Some(buf) = h.cpu_cores.get_mut(i) {
                push_capped(buf, pct);
            }
        }
        for (name, rx_bps, tx_bps) in rates {
            let buf = h.net.entry(name).or_insert_with(TwoSeriesBuf::new);
            push_capped(&mut buf.a, rx_bps);
            push_capped(&mut buf.b, tx_bps);
        }
        for (name, rd_bps, wr_bps) in disk_rates {
            let buf = h.disk.entry(name).or_insert_with(TwoSeriesBuf::new);
            push_capped(&mut buf.a, rd_bps);
            push_capped(&mut buf.b, wr_bps);
        }
        h.top_cpu = top_cpu;
        h.top_mem = top_mem;
    }
}

fn serve_client(stream: UnixStream, history: Arc<Mutex<History>>) {
    let mut reader = BufReader::new(stream.try_clone().expect("clone unix stream"));
    let mut request = String::new();
    if reader.read_line(&mut request).unwrap_or(0) == 0 {
        return;
    }
    let Some(metric) = Metric::parse(&request) else { return };

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
                            rx_bps: buf.a.iter().copied().collect(),
                            tx_bps: buf.b.iter().copied().collect(),
                        })
                        .collect(),
                },
                Metric::Disk => Snapshot::Disk {
                    devices: h
                        .disk
                        .iter()
                        .map(|(name, buf)| DiskHistory {
                            name: name.clone(),
                            read_bps: buf.a.iter().copied().collect(),
                            write_bps: buf.b.iter().copied().collect(),
                        })
                        .collect(),
                },
                Metric::Cpu => Snapshot::Cpu {
                    total: h.cpu_total.iter().copied().collect(),
                    cores: h.cpu_cores.iter().map(|c| c.iter().copied().collect()).collect(),
                },
                Metric::Temp => Snapshot::Temp {
                    celsius: h.temp_c.iter().copied().collect(),
                },
                Metric::Mem => Snapshot::Mem {
                    used_pct: h.mem_used_pct.iter().copied().collect(),
                    cached_pct: h.mem_cached_pct.iter().copied().collect(),
                },
                Metric::TopCpu => Snapshot::TopProcs { procs: h.top_cpu.clone() },
                Metric::TopMem => Snapshot::TopProcs { procs: h.top_mem.clone() },
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
