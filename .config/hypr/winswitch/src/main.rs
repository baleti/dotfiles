//! Entry point: the tap/hold check, then either a plain focus-switch (tap)
//! or a full NDJSON stream of the window list, thumbnails, and tmux/Claude
//! enrichment (hold) for the Quickshell frontend
//! (`~/.config/quickshell/winswitch/`) to render. No socket server here any
//! more: unlike the old GTK version, this process never stays open waiting
//! for further Tab presses -- once shown, the Quickshell panel handles its
//! own repeat cycling locally, so a second `winswitch next` while the grid
//! is open is simply never spawned in the first place.
//!
//! ## Why the tap/hold check is debounced (2026-09-09)
//!
//! The old GTK version's own check (`hyprctl::is_alt_down()`, still just a
//! direct `hyprctl repl` query with no state of its own) was read exactly
//! once, right when a freshly-created invisible layer-shell surface
//! received keyboard focus -- which, because acquiring a compositor-side
//! keyboard grab isn't instant, already imposed a small, natural delay
//! before the read happened. This process has no window of its own to wait
//! on for an equivalent delay, so an early Quickshell-side version of this
//! rewrite instead grabbed keyboard input *immediately*, before knowing
//! tap vs. hold at all, specifically to not miss a quick release. That
//! traded one problem for three worse ones: every press, taps included,
//! briefly mapped a real (if tiny/transparent) layer-shell surface --
//! visible as a flicker on this compositor regardless of Quickshell-side
//! opacity/size tricks; a single instantaneous `is_alt_down()` read is
//! itself noisy (whichever side of the flip the ~5-30ms `hyprctl repl`
//! subprocess call happens to land on); and worst, a grab that hadn't
//! actually completed yet by the time Alt was released left the grid
//! stuck open with no way to close it but Enter/Escape.
//!
//! The fix moves the debounce here instead, where it belongs: sleep a
//! short beat before the read (`TAP_HOLD_DEBOUNCE`), so a genuine quick tap
//! has already released Alt by the time this checks, and a genuine hold is
//! comfortably still down. Quickshell then only ever creates a surface
//! once a `hold` is already confirmed (see WinSwitch.qml), so it's back to
//! never doing anything visible for a tap, and by the time it *does* grab
//! keyboard input the compositor has ample headroom (this debounce, plus
//! window enumeration) to finish that grab before a human can react and
//! release Alt.

mod enrich;
mod hyprctl;
mod output;
mod protocol;
mod wayland_capture;

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// See main.rs's own module doc for why this exists. Long enough that a
/// genuine tap's Alt release (a human can release within a handful of ms of
/// their own Tab press) has reliably already landed by the time
/// `hyprctl::is_alt_down()` is read; short enough to stay imperceptible on
/// top of a genuine hold, and on a tap's own focus-switch latency.
const TAP_HOLD_DEBOUNCE: Duration = Duration::from_millis(35);

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
    let cmd = std::env::args().nth(1).unwrap_or_else(|| "next".to_string());
    let start = Instant::now();
    log_line(&format!("start cmd={cmd}"));

    std::thread::sleep(TAP_HOLD_DEBOUNCE);
    let held = hyprctl::is_alt_down();
    log_line(&format!("is_alt_down={held} ({}us)", start.elapsed().as_micros()));

    if !held {
        // Tap: a fast press-release already completed before we got a
        // chance to check -- do the classic single quick-switch directly
        // and tell the frontend there's nothing to show (see main.rs's
        // module doc for why no wait-for-focus step is needed here, unlike
        // the old GTK version's equivalent check).
        let windows = hyprctl::list_windows();
        let idx = if cmd == "prev" { windows.len().saturating_sub(1) } else { 1.min(windows.len().saturating_sub(1)) };
        log_line(&format!("tap: {} windows, switching to idx={idx} ({:?})", windows.len(), windows.get(idx).map(|w| &w.title)));
        if let Some(w) = windows.get(idx) {
            hyprctl::focus_window(&w.address);
        }
        output::tap();
        log_line(&format!("tap done, exiting ({}us total)", start.elapsed().as_micros()));
        return;
    }

    // Held: now do the real work.
    let windows = hyprctl::list_windows();
    log_line(&format!("hold: {} windows, printing windows line ({}us)", windows.len(), start.elapsed().as_micros()));
    if windows.is_empty() {
        return;
    }
    output::windows(&windows);

    let thumb_dir = thumb_dir();
    let _ = fs::create_dir_all(&thumb_dir);

    let thumb_rx = wayland_capture::start(&windows);
    let enrich_rx = enrich::start(&windows);

    let deadline = Instant::now() + DEADLINE;
    let mut thumbs_done = 0usize;
    loop {
        let mut progressed = false;
        while let Ok(msg) = thumb_rx.try_recv() {
            progressed = true;
            thumbs_done += 1;
            let path = thumb_dir.join(format!("thumb-{}.png", msg.index));
            if write_png(&path, msg.width as u32, msg.height as u32, &msg.rgba).is_ok() {
                output::thumbnail(msg.index, &format!("file://{}", path.display()), msg.width, msg.height);
            }
        }
        while let Ok((idx, meta)) = enrich_rx.try_recv() {
            progressed = true;
            output::enrich(idx, &meta);
        }
        if thumbs_done >= windows.len() || Instant::now() >= deadline {
            break;
        }
        if !progressed {
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    log_line(&format!("hold done, exiting ({thumbs_done}/{} thumbnails, {}us total)", windows.len(), start.elapsed().as_micros()));
    // Falling off main() here exits immediately -- wayland_capture's
    // background thread runs an unbounded `blocking_dispatch` loop by
    // design (see its own module doc) and is never joined; that's fine,
    // its connection just gets torn down along with the process.
}
