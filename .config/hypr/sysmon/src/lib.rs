//! Shared protocol between `sysmond` (background sampler) and `sysmon-graph`
//! (the popup client). Kept dependency-light (no gtk) so `sysmond` doesn't
//! link a GUI toolkit it never uses.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// One sample per tick, so callers can convert to a duration however they like.
pub const SAMPLE_INTERVAL_MS: u64 = 1000;

/// Every tiered series (see `Tier`) stores at most this many points,
/// regardless of the tier's span -- older points within a tier are
/// averaged together more coarsely instead of the buffer just growing, so
/// the 7-month tier costs the same memory/wire size as the 30-minute one.
pub const TIER_CAPACITY: usize = 600;

/// The five fixed granularities a history series is kept at simultaneously
/// (2026-08-27, replacing the original single flat 10-minute buffer): every
/// raw 1s sample is folded into all five at once (see sysmond.rs's
/// `TierBuf::push_raw`), each capped at `TIER_CAPACITY` stored points by
/// averaging progressively more raw samples per point as the tier's span
/// grows -- e.g. the 30m tier averages every ~3 raw seconds into one point,
/// the 7-month tier averages every ~8.4 hours into one point.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Tier {
    Min10,
    Min30,
    Hour6,
    Day7,
    Week7,
    Month7,
}

/// NOTE: order here is the on-disk/persist index order, NOT display order --
/// `Min10` was appended last (2026-08-29) so an existing history.json
/// (5 entries, Min30..Month7) still loads into the right slots by position.
/// Display/UI order lives in the quickshell bar's `tierCodes`.
pub const ALL_TIERS: [Tier; 6] = [
    Tier::Min30,
    Tier::Hour6,
    Tier::Day7,
    Tier::Week7,
    Tier::Month7,
    Tier::Min10,
];

impl Tier {
    pub fn code(self) -> &'static str {
        match self {
            Tier::Min10 => "10m",
            Tier::Min30 => "30m",
            Tier::Hour6 => "6h",
            Tier::Day7 => "7d",
            Tier::Week7 => "7w",
            Tier::Month7 => "7mo",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "10m" => Some(Tier::Min10),
            "30m" => Some(Tier::Min30),
            "6h" => Some(Tier::Hour6),
            "7d" => Some(Tier::Day7),
            "7w" => Some(Tier::Week7),
            "7mo" => Some(Tier::Month7),
            _ => None,
        }
    }

    /// Total span this tier covers, in seconds. Months are approximated as
    /// 30 days -- this only sets the rollup granularity, not a calendar.
    fn span_secs(self) -> u64 {
        match self {
            Tier::Min10 => 10 * 60,
            Tier::Min30 => 30 * 60,
            Tier::Hour6 => 6 * 60 * 60,
            Tier::Day7 => 7 * 24 * 60 * 60,
            Tier::Week7 => 7 * 7 * 24 * 60 * 60,
            Tier::Month7 => 7 * 30 * 24 * 60 * 60,
        }
    }

    /// How many raw 1-second samples get averaged into one stored point in
    /// this tier.
    pub fn raw_samples_per_point(self) -> u64 {
        (self.span_secs() / TIER_CAPACITY as u64).max(1)
    }
}

pub fn socket_path() -> PathBuf {
    let base = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    base.join("sysmond.sock")
}

/// A client connects, writes one request line -- `<metric>` or
/// `<metric>:<tier>` (bare metric defaults to the 10-minute tier; `Top*`
/// metrics ignore the tier entirely, they're point-in-time, not history) --
/// then reads one JSON `Snapshot` line per second until it disconnects.
/// Switching tiers means disconnecting and reconnecting with a new request,
/// not a second request on the same stream (see quickshell's
/// TieredSocket.qml).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Metric {
    Net,
    Cpu,
    Temp,
    Mem,
    Disk,
    Gpu,
    TopCpu,
    TopMem,
    TopNet,
    TopDisk,
    TopGpu,
}

impl Metric {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "net" => Some(Metric::Net),
            "cpu" => Some(Metric::Cpu),
            "temp" => Some(Metric::Temp),
            "mem" => Some(Metric::Mem),
            "disk" => Some(Metric::Disk),
            "gpu" => Some(Metric::Gpu),
            "topgpu" => Some(Metric::TopGpu),
            "topcpu" => Some(Metric::TopCpu),
            "topmem" => Some(Metric::TopMem),
            "topnet" => Some(Metric::TopNet),
            "topdisk" => Some(Metric::TopDisk),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Request {
    pub metric: Metric,
    pub tier: Tier,
}

impl Request {
    pub fn parse(s: &str) -> Option<Self> {
        let s = s.trim();
        let (metric_str, tier_str) = s.split_once(':').unwrap_or((s, "10m"));
        Some(Request { metric: Metric::parse(metric_str)?, tier: Tier::parse(tier_str)? })
    }
}

/// One interface's history at one tier, oldest-first, up to `TIER_CAPACITY`
/// long.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IfaceHistory {
    pub name: String,
    pub rx_bps: Vec<f64>,
    pub tx_bps: Vec<f64>,
}

/// One block device's history at one tier, oldest-first, up to
/// `TIER_CAPACITY` long.
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
    /// Net: combined sent+received KB over the last ~1s (nethogs trace mode).
    /// Disk: combined read+write KB/s over the last sample tick.
    pub value: f64,
    /// A short distinguishing hint the bare `name` (comm) doesn't give --
    /// the command-line tail (`--resume <uuid>` for one of many `claude`s)
    /// or, failing that, the ~-relative working directory. `#[serde(default)]`
    /// so a client/daemon version mismatch just sees an empty string.
    #[serde(default)]
    pub detail: String,
}

/// Oldest-first ring-buffer snapshots for whichever tier was requested, up
/// to `TIER_CAPACITY` long (fewer while that tier is still filling its
/// initial buffer just after startup).
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
    // both are visible instead of only the "true" used figure. `swap_used_pct`
    // is a third overlaid line, percent of SwapTotal in use (2026-08-29).
    // `#[serde(default)]` so an old sysmond (pre-swap) doesn't break a
    // rebuilt client expecting this field.
    Mem { used_pct: Vec<f64>, cached_pct: Vec<f64>, #[serde(default)] swap_used_pct: Vec<f64> },
    // One entry per whole-disk block device (partitions excluded), same
    // overlay-per-device treatment as Net.
    Disk { devices: Vec<DiskHistory> },
    // NVIDIA GPU (via a long-lived `nvidia-smi ... -l 1` subprocess -- see
    // sysmond.rs's `gpu_loop`). `util_pct` (compute/graphics engine load)
    // and `vram_pct` (VRAM *occupancy*, used/total -- not the memory
    // controller's bandwidth utilisation) are the two overlaid history
    // series, same treatment as Mem's used/cached. The rest are
    // point-in-time detail readings shown in the expanded panel, not
    // history -- all `#[serde(default)]` so a client/daemon version skew or
    // a field nvidia-smi reports as `[N/A]` (older/mobile parts often do for
    // power.limit / fan.speed) degrades to 0 rather than breaking the parse.
    Gpu {
        util_pct: Vec<f64>,
        vram_pct: Vec<f64>,
        // Board power draw as a percent of the enforced power limit (TGP) --
        // a third history line on the same 0..100 axis as util/vram. Empty
        // (not zero-filled) from a daemon that predates it.
        #[serde(default)]
        power_pct: Vec<f64>,
        #[serde(default)]
        name: String,
        #[serde(default)]
        temp_c: f64,
        #[serde(default)]
        power_w: f64,
        #[serde(default)]
        power_limit_w: f64,
        #[serde(default)]
        vram_used_mb: f64,
        #[serde(default)]
        vram_total_mb: f64,
        #[serde(default)]
        sm_clock_mhz: f64,
        #[serde(default)]
        mem_clock_mhz: f64,
        #[serde(default)]
        enc_pct: f64,
        #[serde(default)]
        dec_pct: f64,
        #[serde(default)]
        fan_pct: f64,
    },
    // Point-in-time top-10, refreshed every tick like the history metrics,
    // just not itself a time series.
    TopProcs { procs: Vec<ProcEntry> },
}
