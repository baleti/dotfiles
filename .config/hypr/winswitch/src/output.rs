//! NDJSON output to stdout for the Quickshell frontend: one line per event,
//! flushed immediately after each write so its `SplitParser`'s `onRead`
//! sees them as they're produced rather than batched up until this process
//! exits -- the whole point of streaming captures/enrichment in as they
//! arrive is lost if the frontend only sees them all at once anyway. See
//! `~/.config/quickshell/winswitch/` for the consumer side of this schema.

use std::io::Write;

use serde::Serialize;
use serde_json::json;

use crate::enrich::TmuxClaudeMeta;
use crate::hyprctl::Window;

fn write_line(value: &impl Serialize) {
    let Ok(line) = serde_json::to_string(value) else { return };
    let mut out = std::io::stdout();
    let _ = writeln!(out, "{line}");
    let _ = out.flush();
}

/// A tap already handled itself (this process dispatched the focus switch
/// directly) -- nothing for the frontend to show.
pub fn tap() {
    write_line(&json!({"type": "tap"}));
}

#[derive(Serialize)]
struct IndexedWindow<'a> {
    index: usize,
    #[serde(flatten)]
    window: &'a Window,
}

/// The full window list, sent once immediately after a hold is confirmed --
/// lets the frontend build the grid (with placeholders) before any
/// thumbnail or enrichment data exists.
pub fn windows(windows: &[Window]) {
    let list: Vec<IndexedWindow> = windows.iter().enumerate().map(|(index, window)| IndexedWindow { index, window }).collect();
    write_line(&json!({"type": "windows", "list": list}));
}

/// One window's thumbnail has been written to `path` (a `file://` URL) --
/// `width`/`height` are the PNG's own dimensions (see
/// `wayland_capture::MAX_THUMB_EDGE`), for the frontend to size its `Image`
/// without waiting on a decode.
pub fn thumbnail(index: usize, path: &str, width: i32, height: i32) {
    write_line(&json!({"type": "thumbnail", "index": index, "path": path, "width": width, "height": height}));
}

/// One window's tmux/Claude metadata partially (or fully) resolved --
/// mirrors `TmuxClaudeMeta::merge`'s own "apply whatever fields are set"
/// contract; a still-`None` field is simply absent from the JSON object
/// (`#[serde(skip_serializing_if)]` on every field), not sent as `null`.
pub fn enrich(index: usize, meta: &TmuxClaudeMeta) {
    write_line(&json!({"type": "enrich", "index": index, "meta": meta}));
}
