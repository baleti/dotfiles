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

/// One GPU's history at one tier plus its point-in-time detail block and
/// its own top-processes list -- so a machine with an iGPU + dGPU serves
/// both as separate entries in one `Snapshot::Gpu`. `vendor` is `"nvidia"`
/// (nvidia-smi) or `"intel"` (i915 `/proc/*/fdinfo` engine counters). Every
/// field except `name`/`vendor`/`util_pct` is `#[serde(default)]` and left
/// zero/empty where it doesn't apply -- an iGPU has no dedicated VRAM total,
/// no board-power telemetry, etc.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GpuHistory {
    pub name: String,
    pub vendor: String,
    pub util_pct: Vec<f64>,
    #[serde(default)]
    pub vram_pct: Vec<f64>,
    #[serde(default)]
    pub power_pct: Vec<f64>,
    #[serde(default)]
    pub temp_c: f64,
    #[serde(default)]
    pub power_w: f64,
    #[serde(default)]
    pub power_limit_w: f64,
    #[serde(default)]
    pub vram_used_mb: f64,
    #[serde(default)]
    pub vram_total_mb: f64,
    #[serde(default)]
    pub sm_clock_mhz: f64,
    #[serde(default)]
    pub mem_clock_mhz: f64,
    #[serde(default)]
    pub enc_pct: f64,
    #[serde(default)]
    pub dec_pct: f64,
    #[serde(default)]
    pub fan_pct: f64,
    /// Per-process use of THIS GPU (top 10), ranked utilisation-then-memory.
    #[serde(default)]
    pub procs: Vec<ProcEntry>,
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
    /// GPU only: this process's share of the GPU's engine (sm/render)
    /// time, 0-100. Zero/unset for cpu/mem/net/disk entries, which have
    /// no equivalent metric. Used to be folded into `detail` as
    /// "NN% GPU · ..." text; broken out as its own field (request
    /// 2026-09-06: "add utilization as its own column") since a client
    /// wants to display and reason about it as a number, not parse it
    /// back out of a formatted string.
    #[serde(default)]
    pub util_pct: f64,
}

fn default_full() -> bool {
    true
}

/// Ring-buffer snapshots for whichever tier was requested, up to
/// `TIER_CAPACITY` long (fewer while that tier is still filling its initial
/// buffer just after startup) -- oldest-first.
///
/// Every history-series variant (all but `TopProcs`, which has no buffer to
/// begin with) carries a `full` flag (2026-09-05, the delta-streaming
/// rework): `full: true` means every array below is the COMPLETE current
/// buffer for its tier, same as this protocol always worked; `full: false`
/// means every array is just the point(s) appended since the previous
/// message on this connection (usually 0 or 1 -- more only if a client
/// briefly fell behind), and the receiver is expected to append them to
/// whatever it already has and drop points off the front past
/// `TIER_CAPACITY`, mirroring the server's own ring-buffer eviction. A
/// client that's never held a value for a series yet (freshly connected)
/// always gets `full: true` first; after that, sysmond re-forces a full
/// resend periodically (see sysmond.rs's `FULL_RESYNC_TICKS`) purely as a
/// self-healing measure, independent of any bug -- so the delta stream
/// can never drift out of sync with the daemon's real buffers for longer
/// than that window. GPU's `procs` and its point-in-time detail scalars
/// (temp_c, power_w, ...) are never deltas -- they're small and already
/// point-in-time, so every message (full or not) carries their current
/// values directly.
#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "metric", rename_all = "lowercase")]
pub enum Snapshot {
    // Every non-loopback interface that's been seen since sysmond started,
    // not just the default route -- so e.g. wg-wsl and wlan0 both show up
    // as separate overlaid series, same as the KDE Plasma network widget
    // this replaces (2026-08-27). A newly-seen interface always forces a
    // `full` message (see sysmond.rs's serve_client) so a delta message's
    // `interfaces` list is always a subset the client has already seen.
    Net { #[serde(default = "default_full")] full: bool, interfaces: Vec<IfaceHistory> },
    // `total` is the aggregate line (unchanged shape for old clients);
    // `cores` is one history per logical CPU, for a stacked per-core view.
    Cpu { #[serde(default = "default_full")] full: bool, total: Vec<f64>, cores: Vec<Vec<f64>> },
    Temp { #[serde(default = "default_full")] full: bool, celsius: Vec<f64> },
    // `used_pct` excludes reclaimable cache (same calc as before, matches
    // MemAvailable); `cached_pct` is Buffers+Cached, overlaid separately so
    // both are visible instead of only the "true" used figure. `swap_used_pct`
    // is a third overlaid line, percent of SwapTotal in use (2026-08-29).
    // `#[serde(default)]` so an old sysmond (pre-swap) doesn't break a
    // rebuilt client expecting this field.
    Mem { #[serde(default = "default_full")] full: bool, used_pct: Vec<f64>, cached_pct: Vec<f64>, #[serde(default)] swap_used_pct: Vec<f64> },
    // One entry per whole-disk block device (partitions excluded), same
    // overlay-per-device treatment as Net (same new-device-forces-full rule).
    Disk { #[serde(default = "default_full")] full: bool, devices: Vec<DiskHistory> },
    // Every GPU on the machine, each its own `GpuHistory` (util/vram/power
    // history at the requested tier + a detail block + a top-processes
    // list). One entry on a single-GPU box; iGPU + dGPU both appear on a
    // hybrid laptop. See sysmond.rs's `gpu_loop` (nvidia-smi) and
    // `intel_gpu_loop` (i915 fdinfo). The GPU list itself never changes
    // after sysmond starts, so unlike Net/Disk there's no "new entry"
    // case to force a full resend for.
    Gpu {
        #[serde(default = "default_full")]
        full: bool,
        gpus: Vec<GpuHistory>,
    },
    // Point-in-time top-10, refreshed every tick like the history metrics,
    // just not itself a time series -- no `full` flag, there's no buffer
    // here for one to describe.
    TopProcs { procs: Vec<ProcEntry> },
}
