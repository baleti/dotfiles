//! Picker over dunst's notification history (`dunstctl history`), built on
//! the shared `picker` engine (see picker.rs, extracted from
//! clipboard-picker). Bound to CTRL+mod+n as the "browse all past
//! notifications" counterpart to mod+n's "act on the last one".
//!
//! Activating a row re-triggers that notification's default action even
//! though it's long gone from screen: dunst has no dbus call to invoke an
//! action by history ID directly (`NotificationAction`/`dunstctl action`
//! only address the *currently displayed* stack by position), so we
//! redisplay it first via `history-pop <id>` and then act on it. Any
//! notifications currently on screen are closed first so that redisplayed
//! one is unambiguously the one `action 0` reaches.

use std::process::Command;

use serde_json::Value;

use clipboard_picker::picker::{self, Entry, PickerConfig};

fn get_str(obj: &Value, key: &str) -> String {
    obj.get(key)
        .and_then(|v| v.get("data"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string()
}

fn get_id(obj: &Value) -> Option<String> {
    obj.get("id")?.get("data")?.as_i64().map(|n| n.to_string())
}

/// `dunstctl history` returns newest-first already, so entries are kept in
/// the order dunst gives them.
fn history_entries() -> (Vec<Entry>, Vec<String>) {
    let out = match Command::new("dunstctl").arg("history").output() {
        Ok(o) => o.stdout,
        Err(_) => return (Vec::new(), Vec::new()),
    };
    let Ok(v) = serde_json::from_slice::<Value>(&out) else {
        return (Vec::new(), Vec::new());
    };
    let Some(list) = v.get("data").and_then(|d| d.get(0)).and_then(|d| d.as_array()) else {
        return (Vec::new(), Vec::new());
    };

    let mut type_names: Vec<String> = Vec::new();
    let mut entries = Vec::new();
    for n in list {
        let Some(id) = get_id(n) else { continue };
        let appname = get_str(n, "appname");
        let summary = get_str(n, "summary");
        let body = get_str(n, "body");

        let appname_label = if appname.is_empty() { "(unnamed)" } else { appname.as_str() };
        let kind = match type_names.iter().position(|t| t == appname_label) {
            Some(i) => i,
            None => {
                type_names.push(appname_label.to_string());
                type_names.len() - 1
            }
        };

        let text = if !body.is_empty() && body != summary {
            format!("{summary} — {body}")
        } else {
            summary.clone()
        };
        let preview = if appname.is_empty() { text } else { format!("[{appname}] {text}") };
        let haystack = format!("{appname} {summary} {body}").to_lowercase();

        entries.push(Entry { id, preview, haystack, kind, thumb: false });
    }
    (entries, type_names)
}

/// Redisplay notification `id` and invoke its default action. See the
/// module doc for why this needs close-all + history-pop rather than a
/// single direct call.
fn activate(entry: &Entry) {
    let _ = Command::new("dunstctl").arg("close-all").status();
    let _ = Command::new("dunstctl").args(["history-pop", &entry.id]).status();
    let _ = Command::new("dunstctl").args(["action", "0"]).status();
}

fn main() {
    let (entries, type_names) = history_entries();

    let config = PickerConfig {
        program_name: "notification-picker",
        type_names,
        placeholder: "search notifications   ·   $appname".to_string(),
        width_fraction: 0.5,
        height_fraction: 0.8,
        thumb_height: 0,
        initial_rows: 60,
        chunk_rows: 120,
    };

    picker::run(entries, config, None, Box::new(activate));
}
