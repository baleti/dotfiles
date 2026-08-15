//! Entry point: decides whether this invocation is the one that opens the
//! grid, or a later Alt+Tab/Alt+Shift+Tab press that should just forward a
//! cycle command to the instance already showing it.
//!
//! No pidfile: a Unix socket at `$XDG_RUNTIME_DIR/winswitch.sock` doubles as
//! both the IPC channel and the "is an instance already running" check --
//! connect() succeeding means someone is listening.

mod hyprctl;
mod protocol;
mod query;
mod ui;
mod wayland_capture;

use std::fs;
use std::io::Write;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;

fn socket_path() -> PathBuf {
    let base = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    base.join("winswitch.sock")
}

fn main() {
    let cmd = std::env::args().nth(1).unwrap_or_else(|| "next".to_string());
    let path = socket_path();

    if let Ok(mut stream) = UnixStream::connect(&path) {
        let _ = stream.write_all(cmd.as_bytes());
        return;
    }

    // Quick-tap detection: a fast press-release of Alt+Tab with no real
    // intent to browse the grid shouldn't show it at all. Wait long enough
    // that a genuine tap has already released Alt, then check whether it
    // has -- if so, do the classic single quick-switch and exit without
    // ever touching GTK, instead of the grid appearing and then getting
    // stuck open. That's the actual bug this works around: a fast enough
    // tap can complete before the layer-shell surface has mapped and
    // acquired keyboard focus, so its key-release-event handler never sees
    // the release, and the grid is left waiting for one that already
    // happened. Checking real key state via `hl.is_key_down` sidesteps the
    // race entirely instead of trying to win it.
    std::thread::sleep(std::time::Duration::from_millis(130));
    if !hyprctl::is_alt_down() {
        hyprctl::quick_switch(&cmd);
        return;
    }

    // Connect failed: either nothing is running, or a stale socket file is
    // left over from a process that didn't exit cleanly. Either way, a fresh
    // bind is the right move -- remove it first since bind() fails on an
    // existing path.
    let _ = fs::remove_file(&path);
    let listener = match UnixListener::bind(&path) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("winswitch: failed to bind {}: {e}", path.display());
            std::process::exit(1);
        }
    };

    ui::run(listener, &cmd);

    let _ = fs::remove_file(&path);
}
