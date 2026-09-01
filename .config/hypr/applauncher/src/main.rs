//! `applauncher` -- resident, or `applauncher [toggle|show|hide]` -- a
//! one-shot client that forwards the command to the resident instance over
//! `$XDG_RUNTIME_DIR/applauncher.sock` and exits. If nothing is listening
//! (the daemon isn't up yet), the client becomes the daemon itself and, for
//! anything but `hide`, opens straight away.
//!
//! Started once at login (`exec-once` in hyprland.lua); the mod+Super_l
//! keybind runs `applauncher toggle`.

mod apps;
mod dsl;
mod history;
mod theme;
mod ui;

use std::fs;
use std::io::Write;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;

fn socket_path() -> PathBuf {
    std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join("applauncher.sock")
}

fn main() {
    let cmd = std::env::args().nth(1).unwrap_or_default();
    let path = socket_path();

    // Client path: a running daemon takes the command and we're done.
    if matches!(cmd.as_str(), "toggle" | "show" | "hide") {
        if let Ok(mut s) = UnixStream::connect(&path) {
            let _ = s.write_all(cmd.as_bytes());
            return;
        }
    }

    // Nothing listening (or no command at all): become the daemon. Clear a
    // stale socket first -- bind() fails on an existing path.
    let _ = fs::remove_file(&path);
    let listener = match UnixListener::bind(&path) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("applauncher: cannot bind {}: {e}", path.display());
            std::process::exit(1);
        }
    };

    let show_now = matches!(cmd.as_str(), "toggle" | "show");
    ui::run_daemon(listener, show_now);

    let _ = fs::remove_file(&path);
}
