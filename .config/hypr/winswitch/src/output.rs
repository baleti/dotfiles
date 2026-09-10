//! NDJSON output to stdout for the Quickshell frontend: one line per event,
//! flushed immediately after each write so its `SplitParser`'s `onRead`
//! sees them as they're produced rather than batched up until this process
//! exits -- the whole point of streaming captures/enrichment in as they
//! arrive is lost if the frontend only sees them all at once anyway. See
//! `~/.config/quickshell/winswitch/` for the consumer side of this schema.
//!
//! Keyed by window *address* (2026-09-10), not a positional index: the
//! frontend now builds its own window list independently (from
//! `Hyprland.toplevels`, in-process, before this binary is even spawned --
//! see main.rs's own module doc) rather than waiting on one from here, so
//! there's no shared "index into whose list" to agree on any more. Address
//! is the one identity both sides already have and can't disagree about.

use std::io::Write;

use serde::Serialize;
use serde_json::json;

use crate::enrich::TmuxClaudeMeta;

fn write_line(value: &impl Serialize) {
    let Ok(line) = serde_json::to_string(value) else { return };
    let mut out = std::io::stdout();
    let _ = writeln!(out, "{line}");
    let _ = out.flush();
}

/// One window's thumbnail has been written to `path` (a `file://` URL) --
/// `width`/`height` are the PNG's own dimensions (see
/// `wayland_capture::MAX_THUMB_EDGE`), for the frontend to size its `Image`
/// without waiting on a decode.
pub fn thumbnail(address: &str, path: &str, width: i32, height: i32) {
    write_line(&json!({"type": "thumbnail", "address": address, "path": path, "width": width, "height": height}));
}

/// One window's tmux/Claude metadata partially (or fully) resolved --
/// mirrors `TmuxClaudeMeta::merge`'s own "apply whatever fields are set"
/// contract; a still-`None` field is simply absent from the JSON object
/// (`#[serde(skip_serializing_if)]` on every field), not sent as `null`.
pub fn enrich(address: &str, meta: &TmuxClaudeMeta) {
    write_line(&json!({"type": "enrich", "address": address, "meta": meta}));
}
