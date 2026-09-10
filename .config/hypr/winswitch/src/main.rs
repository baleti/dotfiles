//! Entry point: a pure capture worker now, not a tap/hold decision-maker.
//! Streams NDJSON thumbnail/enrichment results to stdout for the Quickshell
//! frontend (`~/.config/quickshell/winswitch/`) to render, keyed by window
//! *address* rather than a positional index (see `output.rs`'s own doc for
//! why). No socket server here: unlike the old GTK version, this process
//! never stays open waiting for further Tab presses -- once shown, the
//! Quickshell panel handles its own repeat cycling locally.
//!
//! ## Not on the critical path
//!
//! Key handling, window order and tap-vs-hold live in
//! `~/.config/hypr/winswitch.lua` + `services/WinSwitchState.qml` (no
//! processes spawned per keypress). This binary is spawned only once a grid
//! is actually shown, to do what QML can't: live thumbnail capture via
//! wayland-toplevel-export/dmabuf and tmux/Claude correlation.
//! `hyprctl::list_windows()` here only decides what to capture.

mod enrich;
mod hyprctl;
mod output;
mod protocol;
mod wayland_capture;

use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use hyprctl::Window;

/// How long to keep draining thumbnail/enrichment results before giving up
/// on stragglers and exiting -- a slow compositor-side copy queue (see
/// wayland_capture.rs's debug timings: up to ~150ms for the last window in
/// a large batch) or a huge Claude transcript read shouldn't hang this
/// process indefinitely; a window that misses the deadline just never gets
/// a thumbnail/enrichment line, same as a capture that fails outright.
const DEADLINE: Duration = Duration::from_millis(2500);

fn thumb_dir() -> PathBuf {
    let base = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/tmp"));
    base.join("winswitch")
}

/// Always-on (not debug-gated, unlike wayland_capture.rs's opt-in
/// capture-timing log) -- one line per invocation, cheap, and this is
/// exactly the "which invocation saw what, in what order" question that's
/// otherwise invisible once the process has exited. Diagnostic for the
/// 2026-09-09 rapid-tap investigation; fine to keep permanently, it's a
/// negligible cost for real troubleshooting value.
fn log_line(msg: &str) {
    let Some(home) = std::env::var_os("HOME") else { return };
    let path = PathBuf::from(home).join(".cache/winswitch-backend.log");
    let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(path) else { return };
    use std::io::Write;
    let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0);
    let _ = writeln!(f, "[{secs} pid={}] {msg}", std::process::id());
}

/// Thumbnails are named `<address>-<run id>.png`. Drops `.tmp` leftovers from
/// a killed run, the pre-2026-09-10 `thumb-<index>.png` files, and captures of
/// windows that no longer exist.
fn prune_thumb_dir(dir: &Path, windows: &[Window]) {
    let live: HashSet<&str> = windows.iter().map(|w| w.address.as_str()).collect();
    let Ok(entries) = fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        let keep = !name.ends_with(".tmp") && name.split_once('-').is_some_and(|(addr, _)| live.contains(addr));
        if !keep {
            let _ = fs::remove_file(entry.path());
        }
    }
}

/// Keeps only `keep` for this window -- the frontend holds the older image in
/// memory already and switches to the new path on the NDJSON line.
fn remove_older_thumbs(dir: &Path, address: &str, keep: &Path) {
    let prefix = format!("{address}-");
    let Ok(entries) = fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name.starts_with(&prefix) && !name.ends_with(".tmp") && path != keep {
            let _ = fs::remove_file(path);
        }
    }
}

fn write_png(path: &Path, width: u32, height: u32, rgba: &[u8]) -> std::io::Result<()> {
    let file = fs::File::create(path)?;
    let mut encoder = png::Encoder::new(std::io::BufWriter::new(file), width, height);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder.write_header().map_err(std::io::Error::other)?;
    writer.write_image_data(rgba).map_err(std::io::Error::other)?;
    Ok(())
}

fn main() {
    let start = Instant::now();
    log_line("start (capture worker)");

    // QML has already confirmed a hold and shown the placeholder grid by
    // the time this process even exists (see module doc) -- straight to
    // capture, no tap/hold branch here any more.
    let windows = hyprctl::list_windows();
    log_line(&format!("{} windows ({}us)", windows.len(), start.elapsed().as_micros()));
    if windows.is_empty() {
        return;
    }

    let thumb_dir = thumb_dir();
    let _ = fs::create_dir_all(&thumb_dir);
    prune_thumb_dir(&thumb_dir, &windows);
    let run_id = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0);

    let thumb_rx = wayland_capture::start(&windows);
    let enrich_rx = enrich::start(&windows);

    let deadline = Instant::now() + DEADLINE;
    let mut thumbs_done = 0usize;
    loop {
        let mut progressed = false;
        while let Ok(msg) = thumb_rx.try_recv() {
            progressed = true;
            thumbs_done += 1;
            let Some(w) = windows.get(msg.index) else { continue };
            // A fresh name per capture: the frontend's Image pixmap cache is
            // keyed by URL, so reusing a path would show a stale picture.
            let path = thumb_dir.join(format!("{}-{run_id}.png", w.address));
            let tmp = path.with_extension("png.tmp");
            if write_png(&tmp, msg.width as u32, msg.height as u32, &msg.rgba).is_ok() && fs::rename(&tmp, &path).is_ok() {
                remove_older_thumbs(&thumb_dir, &w.address, &path);
                output::thumbnail(&w.address, &format!("file://{}", path.display()), msg.width, msg.height);
            }
        }
        while let Ok((idx, meta)) = enrich_rx.try_recv() {
            progressed = true;
            if let Some(w) = windows.get(idx) {
                output::enrich(&w.address, &meta);
            }
        }
        if thumbs_done >= windows.len() || Instant::now() >= deadline {
            break;
        }
        if !progressed {
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    log_line(&format!("done ({thumbs_done}/{} thumbnails, {}us total)", windows.len(), start.elapsed().as_micros()));
    // Falling off main() here exits immediately -- wayland_capture's
    // background thread runs an unbounded `blocking_dispatch` loop by
    // design (see its own module doc) and is never joined; that's fine,
    // its connection just gets torn down along with the process.
}
