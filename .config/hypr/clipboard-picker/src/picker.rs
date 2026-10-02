//! Shared helpers used by both bins in this crate (`clipboard-picker.rs`,
//! `notification-picker.rs`). Used to be a whole GTK3 + wlr-layer-shell
//! picker engine (search box, `/verb` DSL, keyboard nav, activate
//! callback) shared by both -- see git history before 2026-09-28 for that
//! version. clipboard-picker moved its UI to Quickshell/QML on 2026-09-11
//! (`~/.config/quickshell/clipboard/ClipboardPicker.qml`), notification-
//! picker followed on 2026-09-28
//! (`~/.config/quickshell/notifications/NotificationPicker.qml`); with no
//! caller left for the GTK engine (search/filter/DSL/keyboard nav all now
//! live in QML, ported by hand into `ClipboardQueryDsl.qml`), it was
//! deleted here rather than kept around unused -- see
//! ~/.config/docs/query-dsl.md for the DSL spec both QML ports implement.
//!
//! What's left is genuinely still shared: `Entry` is the row shape both
//! bins' `list` NDJSON output serializes, `humanize_ago` builds both
//! pickers' `$age:` field the same way, and `cache_dir` is where
//! clipboard-picker's thumbnail cache lives (keyed by program name, so
//! reused if this crate ever grows a third bin with its own cache).

use std::path::PathBuf;

pub struct Entry {
    pub id: String,
    /// Text shown in the row (single line, ellipsized) unless `thumb` is set.
    pub preview: String,
    /// Lowercased text matched against the free-text part of the query --
    /// always present and always searchable with no special syntax, the
    /// same "there's always a plain-typing default" contract every picker
    /// in this repo's DSL keeps (clipboard contents here; window
    /// title+class for winswitch's alt-tab; pane scrollback for
    /// window-search.py -- see query-dsl.md's design principles).
    pub haystack: String,
    /// Named field values this entry has, for `/fv field:value` filtering and
    /// autocomplete -- e.g. `[("type", "image"), ("age", "5m")]`. A field
    /// name a caller never populates for some entries (e.g. no logged
    /// timestamp yet) is simply absent from that entry's list rather than
    /// present with an empty value.
    pub fields: Vec<(&'static str, String)>,
    /// True if this entry should render as a lazily-loaded thumbnail image
    /// instead of a text label. notification-picker never sets this --
    /// notifications carry no image payload here -- so it always ends up
    /// `false` for that bin.
    pub thumb: bool,
}

/// A Unix timestamp (seconds) as a short "how long ago" bucket -- "5m",
/// "3h", "2d", etc. Shared by any picker with a real per-entry timestamp
/// (clipboard-picker's own copy-time log, notification-picker's already-
/// real `timestamp` field) to build a `$age:` field: bucketing to
/// human-granularity keeps the *value* space small and enumerable for
/// autocomplete the same way winswitch's small, concrete field set is (see
/// ~/.config/docs/query-dsl.md's autocompletion section) -- an exact epoch
/// or ISO timestamp per entry would defeat that, since every entry would
/// have a near-unique value. Same bucket scheme tmux's focus-picker.py
/// already uses (`humanize_ago`), ported by hand for the same "recent
/// wins" reasoning, not shared code.
pub fn humanize_ago(ts: u64, now: u64) -> String {
    let delta = now.saturating_sub(ts);
    if delta < 60 {
        format!("{delta}s")
    } else if delta < 3600 {
        format!("{}m", delta / 60)
    } else if delta < 86400 {
        format!("{}h", delta / 3600)
    } else {
        format!("{}d", delta / 86400)
    }
}

pub fn cache_dir(program_name: &str) -> PathBuf {
    let base = std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".cache"));
    base.join(program_name)
}
