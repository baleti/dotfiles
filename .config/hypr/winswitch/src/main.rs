//! Entry point: decides whether this invocation is the one that opens the
//! grid, or a later Alt+Tab/Alt+Shift+Tab press that should just forward a
//! cycle command to the instance already showing it.
//!
//! No pidfile: a Unix socket at `$XDG_RUNTIME_DIR/winswitch.sock` doubles as
//! both the IPC channel and the "is an instance already running" check --
//! connect() succeeding means someone is listening.

mod enrich;
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
