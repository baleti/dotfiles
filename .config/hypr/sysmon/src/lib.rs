//! Shared protocol between `sysmond` (background sampler) and `sysmon-graph`
//! (the popup client). Kept dependency-light (no gtk) so `sysmond` doesn't
//! link a GUI toolkit it never uses.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// One sample per tick, so callers can convert to a duration however they like.
pub const SAMPLE_INTERVAL_MS: u64 = 1000;

/// 10 minutes of history at one sample/sec (bumped from the original 5 for
/// the quickshell bar's hover-graphs, 2026-08-27).
pub const HISTORY_LEN: usize = 600;

pub fn socket_path() -> PathBuf {
    let base = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    base.join("sysmond.sock")
}

/// A client connects, writes one `Metric` variant's lowercase name (e.g.
/// `"net\n"`) as the request, then reads one JSON `Snapshot` line per second
/// until it disconnects.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Metric {
    Net,
    Cpu,
    Temp,
    Mem,
    Disk,
    TopCpu,
    TopMem,
}

impl Metric {
    pub fn parse(s: &str) -> Option<Self> {
        match s.trim() {
            "net" => Some(Metric::Net),
            "cpu" => Some(Metric::Cpu),
            "temp" => Some(Metric::Temp),
            "mem" => Some(Metric::Mem),
            "disk" => Some(Metric::Disk),
            "topcpu" => Some(Metric::TopCpu),
            "topmem" => Some(Metric::TopMem),
            _ => None,
        }
    }
}

/// One interface's history, oldest-first, `HISTORY_LEN` long.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IfaceHistory {
    pub name: String,
    pub rx_bps: Vec<f64>,
    pub tx_bps: Vec<f64>,
}

/// One block device's history, oldest-first, `HISTORY_LEN` long.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiskHistory {
    pub name: String,
    pub read_bps: Vec<f64>,
    pub write_bps: Vec<f64>,
}

/// One process's ranking entry -- a point-in-time snapshot, not history.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcEntry {
    pub pid: i32,
    pub name: String,
    /// CPU: percent of one core (0-100*n_cores). Mem: resident set in MB.
    pub value: f64,
}

/// Oldest-first ring-buffer snapshots, `HISTORY_LEN` long (fewer while the
/// daemon is still filling its initial buffer just after startup).
#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "metric", rename_all = "lowercase")]
pub enum Snapshot {
    // Every non-loopback interface that's been seen since sysmond started,
    // not just the default route -- so e.g. wg-wsl and wlan0 both show up
    // as separate overlaid series, same as the KDE Plasma network widget
    // this replaces (2026-08-27).
    Net { interfaces: Vec<IfaceHistory> },
    // `total` is the aggregate line (unchanged shape for old clients);
    // `cores` is one history per logical CPU, for a stacked per-core view.
    Cpu { total: Vec<f64>, cores: Vec<Vec<f64>> },
    Temp { celsius: Vec<f64> },
    // `used_pct` excludes reclaimable cache (same calc as before, matches
    // MemAvailable); `cached_pct` is Buffers+Cached, overlaid separately so
    // both are visible instead of only the "true" used figure.
    Mem { used_pct: Vec<f64>, cached_pct: Vec<f64> },
    // One entry per whole-disk block device (partitions excluded), same
    // overlay-per-device treatment as Net.
    Disk { devices: Vec<DiskHistory> },
    // Point-in-time top-10, refreshed every tick like the history metrics,
    // just not itself a time series.
    TopProcs { procs: Vec<ProcEntry> },
}
