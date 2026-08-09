//! Picker over notifyd's retained notification history (`notifyctl list`),
//! built on the shared `picker` engine (see picker.rs, extracted from
//! clipboard-picker). Bound to CTRL+mod+n as the "browse all past
//! notifications" counterpart to mod+n's "act on the last one"
//! (`notifyctl invoke-last`, see ~/.config/hypr/scripts/).
//!
//! This used to work around dunst by redisplaying a notification
//! (`history-pop`) before invoking its action, because dunst invalidates a
//! notification's actions the instant it closes and only its *currently
//! displayed* stack was actionable by position. notifyd doesn't have that
//! problem -- it never discards a notification's actions on close (that's
//! the entire reason notifyd exists; see
//! ~/.claude2/plans/silly-percolating-rose.md) -- so activating a row here
//! is just `notifyctl invoke <id>`, no redisplay dance needed.

use std::process::Command;

use serde_json::Value;

use clipboard_picker::picker::{self, Entry, PickerConfig};

const NOTIFYCTL: &str = "/home/user1/.config/hypr/notifyd/target/release/notifyctl";

fn get_str(obj: &Value, key: &str) -> String {
    obj.get(key).and_then(|v| v.as_str()).unwrap_or("").to_string()
}

/// `notifyctl list` returns newest-first already (see main.rs's
/// list_history_json), so entries are kept in the order notifyd gives them.
fn history_entries() -> (Vec<Entry>, Vec<String>) {
    let out = match Command::new(NOTIFYCTL).arg("list").output() {
        Ok(o) => o.stdout,
        Err(_) => return (Vec::new(), Vec::new()),
    };
    let Ok(list) = serde_json::from_slice::<Vec<Value>>(&out) else {
        return (Vec::new(), Vec::new());
    };

    let mut type_names: Vec<String> = Vec::new();
    let mut entries = Vec::new();
    for n in &list {
        let Some(id) = n.get("id").and_then(|v| v.as_u64()) else {
            continue;
        };
        let app_name = get_str(n, "app_name");
        let summary = get_str(n, "summary");
        let body = get_str(n, "body");

        let app_label = if app_name.is_empty() { "(unnamed)" } else { app_name.as_str() };
        let kind = match type_names.iter().position(|t| t == app_label) {
            Some(i) => i,
            None => {
                type_names.push(app_label.to_string());
                type_names.len() - 1
            }
        };

        let text = if !body.is_empty() && body != summary {
            format!("{summary} — {body}")
        } else {
            summary.clone()
        };
        let preview = if app_name.is_empty() { text } else { format!("[{app_name}] {text}") };
        let haystack = format!("{app_name} {summary} {body}").to_lowercase();

        entries.push(Entry {
            id: id.to_string(),
            preview,
            haystack,
            kind,
            thumb: false,
        });
    }
    (entries, type_names)
}

fn activate(entry: &Entry) {
    let _ = Command::new(NOTIFYCTL).args(["invoke", &entry.id]).status();
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
