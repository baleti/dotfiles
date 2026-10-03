//! notifyd retained-notification-history picker headless backend. UI moved
//! to Quickshell/QML (~/.config/quickshell/notifications/NotificationPicker.qml,
//! mirroring clipboard-picker's own GTK->Quickshell move, 2026-09-11) on
//! 2026-09-28; this binary now just talks to `notifyctl` and prints NDJSON,
//! the same split clipboard-picker.rs settled on. Bound to CTRL+mod+n as
//! the "browse all past notifications" counterpart to mod+n's "act on the
//! last one" (`notifyctl invoke-last`, see ~/.config/hypr/scripts/).
//!
//! This used to work around dunst by redisplaying a notification
//! (`history-pop`) before invoking its action, because dunst invalidates a
//! notification's actions the instant it closes and only its *currently
//! displayed* stack was actionable by position. notifyd doesn't have that
//! problem -- it never discards a notification's actions on close (that's
//! the entire reason notifyd exists; see
//! ~/.claude2/plans/silly-percolating-rose.md) -- so activating a row here
//! is just `notifyctl invoke <id>`, no redisplay dance needed.
//!
//! Subcommands:
//!   list          one NDJSON line per retained notification, then exit
//!   activate <id> invoke that notification's default action

use std::io::Write;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

use clipboard_picker::picker::{self, Entry};

const NOTIFYCTL: &str = "/home/user1/.config/hypr/notifyd/target/release/notifyctl";
const PROGRAM_NAME: &str = "notification-picker";

fn get_str(obj: &Value, key: &str) -> String {
    obj.get(key).and_then(|v| v.as_str()).unwrap_or("").to_string()
}

/// `notifyctl list` returns newest-first already (see notifyd's own
/// `list_history_json`), so entries are kept in the order notifyd gives
/// them.
fn history_entries() -> Vec<(Entry, String)> {
    let out = match Command::new(NOTIFYCTL).arg("list").output() {
        Ok(o) => o.stdout,
        Err(_) => return Vec::new(),
    };
    let Ok(list) = serde_json::from_slice::<Vec<Value>>(&out) else {
        return Vec::new();
    };
    let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);

    let mut entries = Vec::new();
    for n in &list {
        let Some(id) = n.get("id").and_then(|v| v.as_u64()) else {
            continue;
        };
        let app_name = get_str(n, "app_name");
        let summary = get_str(n, "summary");
        let body = get_str(n, "body");

        let app_label = if app_name.is_empty() { "(unnamed)" } else { app_name.as_str() };

        // No "[app_name]" prefix (there used to be one) -- NotificationPicker.qml
        // shows app in its own column now (defaultColumns, 2026-09-28), so
        // repeating it inline just wasted space and duplicated the column.
        let preview = if !body.is_empty() && body != summary {
            format!("{summary} — {body}")
        } else {
            summary.clone()
        };
        let haystack = format!("{app_name} {summary} {body}").to_lowercase();

        // Unlike clipboard-picker's $age (which needed a whole side-log,
        // see cliphist-store-logged.sh), notifyd already tracks a real
        // per-notification `timestamp` -- nothing extra to build here.
        let mut fields = vec![("app", app_label.to_string())];
        if let Some(ts) = n.get("timestamp").and_then(|v| v.as_u64()) {
            fields.push(("age", picker::humanize_ago(ts, now)));
        }

        let icon = get_str(n, "icon");
        entries.push((Entry {
            id: id.to_string(),
            preview,
            haystack,
            fields,
            thumb: false,
        }, icon));
    }
    entries
}

/// One NDJSON line per entry: `{id, preview, haystack, fields}` --
/// NotificationPicker.qml is the field-name registry now (was
/// notification-picker's own `FIELD_NAMES`/`field_descs` here, before the
/// GTK engine went away). No `thumb`/`chars`/`lines` the way
/// clipboard-picker's NDJSON carries -- notifications have no image
/// payload and no size badge to show.
fn print_list(entries: &[(Entry, String)]) {
    let mut out = std::io::stdout().lock();
    for (e, icon) in entries {
        let fields: serde_json::Map<String, serde_json::Value> =
            e.fields.iter().map(|(k, v)| ((*k).to_string(), json!(v))).collect();
        let line = json!({
            "id": e.id,
            "preview": e.preview,
            "haystack": e.haystack,
            "fields": fields,
            "icon": icon,
        });
        let _ = writeln!(out, "{line}");
    }
}

/// Same rule as notifyd's `default_action_key`: an action keyed "default",
/// else the sole action. With one, invoke it; without, fall back to what a
/// card click does -- summon the window that sent the notification (e.g. the
/// Hyprland window running the finished claude session).
fn activate(id: &str) {
    let out = Command::new(NOTIFYCTL).arg("list").output().map(|o| o.stdout).unwrap_or_default();
    let list: Vec<Value> = serde_json::from_slice(&out).unwrap_or_default();
    let n = list.iter().find(|n| n.get("id").and_then(|v| v.as_u64()).map(|i| i.to_string()).as_deref() == Some(id));
    let actions = n.and_then(|n| n.get("actions")).and_then(|a| a.as_array());
    let has_default = actions.is_some_and(|a| {
        a.len() == 1 || a.iter().any(|x| x.get("key").and_then(|k| k.as_str()) == Some("default"))
    });
    match n {
        Some(n) if !has_default => {
            let home = std::env::var("HOME").unwrap_or_default();
            let _ = Command::new(format!("{home}/.config/hypr/scripts/notify-summon.sh"))
                .args([get_str(n, "app_name"), get_str(n, "sender")])
                .status();
        }
        _ => {
            let _ = Command::new(NOTIFYCTL).args(["invoke", id]).status();
        }
    }
}

fn main() {
    let mut args = std::env::args().skip(1);
    match args.next().as_deref() {
        Some("activate") => {
            let Some(id) = args.next() else {
                eprintln!("usage: {PROGRAM_NAME} activate <id>");
                std::process::exit(1);
            };
            activate(&id);
        }
        None | Some("list") => print_list(&history_entries()),
        Some(other) => {
            eprintln!("{PROGRAM_NAME}: unknown subcommand {other:?}");
            std::process::exit(1);
        }
    }
}
