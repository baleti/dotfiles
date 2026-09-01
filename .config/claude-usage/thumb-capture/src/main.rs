//! Hover-thumbnail capture helper for the claude-usage bar panel: given a
//! Hyprland window address (already resolved by claude-usage-daemon.py's
//! tty/pid correlation, see hyprland_windows_by_tmux_session()), captures
//! one frame via hyprland-toplevel-export-v1 and saves it as a PNG.
//!
//! Deliberately a standalone crate (see wayland_capture.rs's own doc
//! comment for why) rather than reusing Quickshell's built-in
//! ScreencopyView -- that only identifies windows by appId/title via the
//! generic wlr protocol, which can't disambiguate this machine's many
//! identically-titled "Alacritty" windows. Address-keyed capture has no
//! such ambiguity.
//!
//! Usage: thumb-capture <address> <out.png>
//! Exits 0 with out.png written on success. Exits 1 (nothing written) on
//! capture failure or a 5s timeout -- a window that's since closed, or
//! whose compositor-side export never completes, shouldn't hang the
//! caller indefinitely.

mod hyprctl;
#[path = "protocol.rs"]
mod protocol;
mod wayland_capture;

use std::path::Path;
use std::time::Duration;

fn main() {
    let mut args = std::env::args().skip(1);
    let (Some(address), Some(out_path)) = (args.next(), args.next()) else {
        eprintln!("usage: thumb-capture <address> <out.png>");
        std::process::exit(2);
    };

    let win = hyprctl::Window { address };
    let main_loop = glib::MainLoop::new(None, false);

    let ml_done = main_loop.clone();
    let out = out_path.clone();
    wayland_capture::start(&[win], move |_idx, pixbuf| {
        if let Err(e) = pixbuf.savev(&out, "png", &[]) {
            eprintln!("failed to save {out}: {e}");
        }
        ml_done.quit();
    });

    let ml_timeout = main_loop.clone();
    glib::timeout_add_local_once(Duration::from_secs(5), move || {
        eprintln!("capture timed out");
        ml_timeout.quit();
    });

    main_loop.run();

    if !Path::new(&out_path).exists() {
        std::process::exit(1);
    }
}
