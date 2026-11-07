//! `winswitch --daemon`: keeps the thumbnail cache (`$XDG_RUNTIME_DIR/winswitch/<address>-<ms>.png`)
//! moderately fresh in the background, so alt-tab and `/sw` never have to capture ~80 windows at
//! the moment the user presses the key (which froze Hyprland under memory pressure).
//!
//! It captures a *few* windows at a time by running this same binary as a worker
//! (`WINSWITCH_ONLY=addr,..`, the path that already holds the screencopy grant), and decides
//! how often and how much from:
//!   * input idleness (`ext-idle-notify-v1`; pointer + compositor events as fallback) and its
//!     recent intensity: busy 3 s, light 8 s, idle >15 s 25 s, >2 min 90 s, >15 min 10 min;
//!   * a learned hour-of-week habit table (`~/.local/state/winswitchd/habit.json`): when the user
//!     usually sits at the desk, idle intervals are capped (45-90 s) so thumbnails are warm
//!     before the first alt-tab, also during the last 5 minutes before such an hour;
//!   * resource pressure, gating *every* attempt: memory PSI, CPU PSI, swap traffic and, above
//!     all, the measured round-trip of a trivial request to Hyprland's own socket. High load
//!     skips the attempt and backs off exponentially (10 s ... 2 min); medium load doubles the
//!     interval;
//!   * a stall check while a batch runs (probe every 25 ms): if the compositor answered slower
//!     than 60 ms the batch size drops to 1 and the interval is stretched; clean batches grow it
//!     back (AIMD, 1..3 windows).
//! Focus changes queue the window just left (its newest content) and new windows are captured
//! after they have had time to draw; closed windows' files are deleted at once (addresses are
//! reused by Hyprland, so a stale file could be shown for a different window).

use std::collections::{HashMap, VecDeque};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::Ordering;
use std::sync::mpsc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::Deserialize;

use crate::idle;

const STALL_MS: f64 = 60.0;
const MAX_BATCH: usize = 3;
const MIN_SPACING: Duration = Duration::from_millis(1500);

fn runtime_dir() -> PathBuf {
    std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/tmp"))
}

fn now_ms() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0)
}

/// The live Hyprland instance: the env signature if its socket answers, else the newest one that does.
fn find_instance() -> Option<String> {
    let base = runtime_dir().join("hypr");
    let alive = |sig: &str| UnixStream::connect(base.join(sig).join(".socket.sock")).is_ok();
    if let Ok(sig) = std::env::var("HYPRLAND_INSTANCE_SIGNATURE") {
        if alive(&sig) {
            return Some(sig);
        }
    }
    let mut dirs: Vec<_> = std::fs::read_dir(&base).ok()?.flatten().filter_map(|e| Some((e.metadata().ok()?.modified().ok()?, e.file_name().to_string_lossy().to_string()))).collect();
    dirs.sort();
    dirs.into_iter().rev().map(|(_, n)| n).find(|n| alive(n))
}

fn ipc(sig: &str, req: &str) -> Option<Vec<u8>> {
    let mut s = UnixStream::connect(runtime_dir().join("hypr").join(sig).join(".socket.sock")).ok()?;
    s.set_read_timeout(Some(Duration::from_secs(3))).ok()?;
    s.set_write_timeout(Some(Duration::from_secs(3))).ok()?;
    s.write_all(req.as_bytes()).ok()?;
    let mut out = Vec::new();
    s.read_to_end(&mut out).ok()?;
    Some(out)
}

/// Round-trip of a trivial request, in ms (a stuck compositor reads as the 3 s timeout).
fn probe(sig: &str) -> f64 {
    let t = Instant::now();
    let _ = ipc(sig, "j/version");
    t.elapsed().as_secs_f64() * 1000.0
}

#[derive(Deserialize)]
struct WsName {
    name: String,
}
#[derive(Deserialize)]
struct Client {
    address: String,
    mapped: bool,
    #[serde(default)]
    hidden: bool,
    workspace: WsName,
    #[serde(rename = "focusHistoryID")]
    focus_history_id: i64,
}

fn clients(sig: &str) -> Vec<Client> {
    let mut v: Vec<Client> = ipc(sig, "j/clients").and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
    v.retain(|c| c.mapped && !c.workspace.name.starts_with("special:"));
    let _ = v.iter().any(|c| c.hidden);
    v
}

enum Ev {
    Activity,
    Focus(String),
    Open(String),
    Close(String),
}

fn spawn_events(sig: String, tx: mpsc::Sender<Ev>) {
    std::thread::spawn(move || loop {
        match find_instance() {
            Some(cur) if cur == sig => {
                if let Ok(s) = UnixStream::connect(runtime_dir().join("hypr").join(&sig).join(".socket2.sock")) {
                    for line in BufReader::new(s).lines().map_while(Result::ok) {
                        let Some((name, data)) = line.split_once(">>") else { continue };
                        let ev = match name {
                            "activewindowv2" => Ev::Focus(format!("0x{data}")),
                            "openwindow" => Ev::Open(format!("0x{}", data.split(',').next().unwrap_or(""))),
                            "closewindow" => Ev::Close(format!("0x{data}")),
                            _ => Ev::Activity,
                        };
                        if tx.send(ev).is_err() {
                            return;
                        }
                    }
                }
            }
            // The compositor restarted (relogin): this daemon belongs to the old session.
            Some(_) | None if find_instance().is_some() => std::process::exit(0),
            _ => {}
        }
        std::thread::sleep(Duration::from_secs(3));
    });
}

fn psi(name: &str, kind: &str) -> f64 {
    let Ok(text) = std::fs::read_to_string(format!("/proc/pressure/{name}")) else { return 0.0 };
    text.lines()
        .find(|l| l.starts_with(kind))
        .and_then(|l| l.split_whitespace().find_map(|f| f.strip_prefix("avg10=")))
        .and_then(|v| v.parse().ok())
        .unwrap_or(0.0)
}

fn swap_pages() -> u64 {
    let Ok(text) = std::fs::read_to_string("/proc/vmstat") else { return 0 };
    text.lines().filter(|l| l.starts_with("pswpin ") || l.starts_with("pswpout ")).filter_map(|l| l.split_whitespace().nth(1)?.parse::<u64>().ok()).sum()
}

fn cache_dir() -> PathBuf {
    runtime_dir().join("winswitch")
}

/// address -> newest capture time (ms), from the file names.
fn scan_cache() -> HashMap<String, u128> {
    let mut m: HashMap<String, u128> = HashMap::new();
    if let Ok(rd) = std::fs::read_dir(cache_dir()) {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            let Some(stem) = name.strip_suffix(".png") else { continue };
            let Some((addr, run)) = stem.split_once('-') else { continue };
            let Ok(run) = run.parse::<u128>() else { continue };
            let slot = m.entry(addr.to_string()).or_insert(0);
            *slot = (*slot).max(run);
        }
    }
    m
}

fn remove_cached(addr: &str) {
    let prefix = format!("{addr}-");
    if let Ok(rd) = std::fs::read_dir(cache_dir()) {
        for e in rd.flatten() {
            if e.file_name().to_string_lossy().starts_with(&prefix) {
                let _ = std::fs::remove_file(e.path());
            }
        }
    }
}

fn log(msg: &str) {
    let Some(home) = std::env::var_os("HOME") else { return };
    let path = PathBuf::from(home).join(".cache/winswitchd.log");
    if std::fs::metadata(&path).map_or(false, |m| m.len() > 256 * 1024) {
        let _ = std::fs::remove_file(&path);
    }
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(f, "[{}] {msg}", now_ms());
    }
}

// ---- habit table (hour of week -> how often the user is at the desk) ----

struct Habit {
    table: Vec<f32>,
    path: PathBuf,
    bucket: usize,
    active_secs: u32,
}

fn bucket_now() -> usize {
    unsafe {
        let t = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&t, &mut tm);
        (tm.tm_wday as usize) * 24 + tm.tm_hour as usize
    }
}

fn secs_to_hour_end() -> u32 {
    unsafe {
        let t = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&t, &mut tm);
        3600 - (tm.tm_min as u32 * 60 + tm.tm_sec as u32)
    }
}

impl Habit {
    fn load() -> Habit {
        let path = PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/state/winswitchd/habit.json");
        let mut table: Vec<f32> = std::fs::read_to_string(&path).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default();
        table.resize(168, 0.0);
        Habit { table, path, bucket: bucket_now(), active_secs: 0 }
    }
    fn tick(&mut self, active: bool) {
        let b = bucket_now();
        if b != self.bucket {
            let frac = (self.active_secs as f32 / 3600.0).min(1.0);
            let old = self.table[self.bucket];
            self.table[self.bucket] = if old == 0.0 { frac } else { 0.75 * old + 0.25 * frac };
            self.bucket = b;
            self.active_secs = 0;
            self.save();
        }
        if active {
            self.active_secs += 1;
        }
    }
    fn save(&self) {
        if let Some(dir) = self.path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(t) = serde_json::to_string(&self.table) {
            let _ = std::fs::write(&self.path, t);
        }
    }
    /// How likely the user is at the desk now (or within 5 minutes, if the next hour is a usual one).
    fn expected(&self) -> f32 {
        let now = self.table[self.bucket];
        if secs_to_hour_end() < 300 {
            now.max(self.table[(self.bucket + 1) % 168])
        } else {
            now
        }
    }
}

// ---- the daemon ----

struct Pace {
    batch: usize,
    clean: u32,
    stall_mult: f64,
    hold_secs: u64,
}

pub fn run() {
    // Nothing here is urgent: yield to everything else.
    unsafe {
        libc::setpriority(libc::PRIO_PROCESS, 0, 19);
    }
    if std::env::var_os("WAYLAND_DISPLAY").is_none() {
        if let Ok(rd) = std::fs::read_dir(runtime_dir()) {
            let mut socks: Vec<String> = rd.flatten().map(|e| e.file_name().to_string_lossy().to_string()).filter(|n| n.starts_with("wayland-") && !n.ends_with(".lock")).collect();
            socks.sort();
            if let Some(s) = socks.first() {
                std::env::set_var("WAYLAND_DISPLAY", s);
            }
        }
    }
    let sig = loop {
        if let Some(s) = find_instance() {
            break s;
        }
        std::thread::sleep(Duration::from_secs(3));
    };
    log(&format!("daemon start, instance {sig}"));
    // Fixed path (not /proc/self/exe, which reads "(deleted)" after a rebuild); it is also the binary the screencopy permission allows.
    let exe = PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".config/hypr/winswitch/target/release/winswitch");
    let idle_level = idle::start();
    let (tx, rx) = mpsc::channel();
    spawn_events(sig.clone(), tx);
    let _ = std::fs::create_dir_all(cache_dir());

    let mut habit = Habit::load();
    let mut pace = Pace { batch: 1, clean: 0, stall_mult: 1.0, hold_secs: 10 };
    let mut urgent: VecDeque<(String, Instant)> = VecDeque::new();
    let mut focused: Option<String> = None;
    let mut ring: u64 = 0;
    let mut events_since_tick = 0u32;
    let mut last_input = Instant::now();
    let mut last_cursor = (0i64, 0i64);
    let mut last_tick = Instant::now();
    let mut last_attempt = Instant::now() - Duration::from_secs(3600);
    let mut hold_until = Instant::now();
    let mut swap_prev = (swap_pages(), Instant::now());
    let mut load_mult = 1.0f64;

    loop {
        match rx.recv_timeout(Duration::from_millis(500)) {
            Ok(first) => {
                for ev in std::iter::once(first).chain(std::iter::from_fn(|| rx.try_recv().ok())) {
                    events_since_tick += 1;
                    match ev {
                        Ev::Activity => {}
                        Ev::Focus(addr) => {
                            if let Some(prev) = focused.replace(addr.clone()) {
                                if prev != addr {
                                    urgent.push_back((prev, Instant::now() + Duration::from_millis(400)));
                                }
                            }
                        }
                        Ev::Open(addr) => {
                            remove_cached(&addr);
                            urgent.push_back((addr.clone(), Instant::now() + Duration::from_millis(2500)));
                            urgent.push_back((addr, Instant::now() + Duration::from_secs(8)));
                        }
                        Ev::Close(addr) => {
                            remove_cached(&addr);
                            urgent.retain(|(a, _)| *a != addr);
                        }
                    }
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => return,
        }

        // 1 s activity sample.
        while last_tick.elapsed() >= Duration::from_secs(1) {
            last_tick += Duration::from_secs(1);
            let lvl = idle_level.load(Ordering::Relaxed);
            let active = if lvl != idle::UNKNOWN {
                lvl == 0
            } else {
                let moved = ipc(&sig, "j/cursorpos")
                    .and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok())
                    .map(|v| (v["x"].as_i64().unwrap_or(0), v["y"].as_i64().unwrap_or(0)))
                    .map_or(false, |p| std::mem::replace(&mut last_cursor, p) != p);
                if moved || events_since_tick > 0 {
                    last_input = Instant::now();
                }
                last_input.elapsed() < Duration::from_secs(15)
            };
            events_since_tick = 0;
            ring = (ring << 1) | active as u64;
            habit.tick(active);
        }
        let now = Instant::now();
        if now < hold_until {
            continue;
        }

        let lvl = idle_level.load(Ordering::Relaxed);
        let idle_secs: u64 = match lvl {
            0 => 0,
            1 => 15,
            2 => 120,
            3 => 900,
            _ => last_input.elapsed().as_secs(),
        };
        let intensity = ring.count_ones() as f64 / 64.0;
        let expected = habit.expected();
        let mut interval = if idle_secs < 15 {
            if intensity > 0.5 { 3.0 } else { 8.0 }
        } else if idle_secs < 120 {
            25.0
        } else if idle_secs < 900 {
            90.0
        } else {
            600.0
        };
        if idle_secs >= 120 {
            if expected > 0.5 {
                interval = f64::min(interval, 45.0);
            } else if expected > 0.25 {
                interval = f64::min(interval, 90.0);
            }
        }
        let interval = Duration::from_secs_f64(interval * pace.stall_mult * load_mult);
        let urgent_due = urgent.front().map_or(false, |(_, t)| *t <= now) && now.duration_since(last_attempt) >= MIN_SPACING;
        if !(urgent_due || now >= last_attempt + interval) {
            continue;
        }
        // an urgent entry can sit behind a later-due one: pull due entries to the front
        urgent.make_contiguous().sort_by_key(|(_, t)| *t);

        // ---- resource gate ----
        let p = (0..3).map(|_| { let v = probe(&sig); std::thread::sleep(Duration::from_millis(4)); v }).fold(0.0f64, f64::max);
        let swap_now = swap_pages();
        let dt = swap_prev.1.elapsed().as_secs_f64().max(0.5);
        let swap_rate = swap_now.saturating_sub(swap_prev.0) as f64 / dt;
        swap_prev = (swap_now, Instant::now());
        let load = [psi("memory", "full") / 8.0, psi("memory", "some") / 25.0, psi("cpu", "some") / 60.0, swap_rate / 8000.0, p / 30.0].into_iter().fold(0.0f64, f64::max);
        if load >= 1.0 {
            hold_until = Instant::now() + Duration::from_secs(pace.hold_secs);
            log(&format!("hold {}s (load {load:.2}, probe {p:.0}ms, swap {swap_rate:.0}/s)", pace.hold_secs));
            pace.hold_secs = (pace.hold_secs * 2).min(120);
            continue;
        }
        pace.hold_secs = 10;
        load_mult = if load >= 0.5 { 2.0 } else { 1.0 };

        // ---- choose the batch ----
        last_attempt = Instant::now();
        let live = clients(&sig);
        if live.is_empty() {
            continue;
        }
        let cache = scan_cache();
        // forget captures of windows that are gone
        for addr in cache.keys() {
            if !live.iter().any(|c| &c.address == addr) {
                remove_cached(addr);
            }
        }
        let mut batch: Vec<String> = Vec::new();
        while batch.len() < pace.batch.max(1) {
            match urgent.front() {
                Some((_, t)) if *t <= Instant::now() => {
                    let (a, _) = urgent.pop_front().unwrap();
                    if live.iter().any(|c| c.address == a) && !batch.contains(&a) {
                        batch.push(a);
                    }
                }
                _ => break,
            }
        }
        if batch.len() < pace.batch.max(1) {
            let now_ms = now_ms();
            let mut scored: Vec<(f64, &str)> = live
                .iter()
                .filter(|c| !batch.contains(&c.address))
                .filter_map(|c| {
                    let age = cache.get(&c.address).map_or(7200.0, |t| now_ms.saturating_sub(*t) as f64 / 1000.0);
                    (age >= 20.0).then(|| (age.min(7200.0) / (1.0 + c.focus_history_id.max(0) as f64 / 3.0), c.address.as_str()))
                })
                .collect();
            scored.sort_by(|a, b| b.0.total_cmp(&a.0));
            for (_, a) in scored.into_iter().take(pace.batch.max(1) - batch.len()) {
                batch.push(a.to_string());
            }
        }
        if batch.is_empty() {
            continue;
        }

        // ---- run the worker, watching the compositor ----
        let t0 = Instant::now();
        let child = Command::new(&exe)
            .env("WINSWITCH_ONLY", batch.join(","))
            .env("WINSWITCH_SKIP_BLANK", "1")
            .env("WINSWITCH_NO_ENRICH", "1")
            .env("HYPRLAND_INSTANCE_SIGNATURE", &sig)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();
        let mut worst = 0.0f64;
        if let Ok(mut child) = child {
            loop {
                match child.try_wait() {
                    Ok(None) => {}
                    _ => break,
                }
                if t0.elapsed() > Duration::from_secs(15) {
                    let _ = child.kill();
                    let _ = child.wait();
                    break;
                }
                worst = worst.max(probe(&sig));
                std::thread::sleep(Duration::from_millis(25));
            }
        }
        if worst > STALL_MS {
            pace.batch = 1;
            pace.clean = 0;
            pace.stall_mult = (pace.stall_mult * 2.0).min(16.0);
        } else {
            pace.clean += 1;
            if pace.clean >= 6 && pace.batch < MAX_BATCH {
                pace.batch += 1;
                pace.clean = 0;
            }
            pace.stall_mult = (pace.stall_mult * 0.85).max(1.0);
        }
        log(&format!(
            "captured {} in {}ms (worst probe {worst:.0}ms) | idle {idle_secs}s intensity {intensity:.2} habit {expected:.2} load {load:.2} -> batch {} interval x{:.1}",
            batch.len(),
            t0.elapsed().as_millis(),
            pace.batch,
            pace.stall_mult * load_mult
        ));
        write_status(idle_secs, intensity, expected, load, &pace, interval);
        last_attempt = Instant::now();
    }
}

fn write_status(idle_secs: u64, intensity: f64, expected: f32, load: f64, pace: &Pace, interval: Duration) {
    let p: &Path = &runtime_dir();
    let _ = std::fs::write(
        p.join("winswitchd.status"),
        serde_json::json!({"idle_secs": idle_secs, "intensity": intensity, "habit": expected, "load": load, "batch": pace.batch, "stall_mult": pace.stall_mult, "interval_secs": interval.as_secs_f64(), "at": now_ms() as u64}).to_string(),
    );
}
