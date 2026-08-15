//! Thin wrappers around `hyprctl`: the window list we build the grid from,
//! and the one dispatcher call that actually changes focus.

use std::process::Command;

use serde::Deserialize;

#[derive(Deserialize)]
struct WorkspaceInfo {
    name: String,
}

#[derive(Deserialize)]
struct RawClient {
    address: String,
    mapped: bool,
    class: String,
    title: String,
    workspace: WorkspaceInfo,
    pid: i32,
    #[serde(rename = "focusHistoryID")]
    focus_history_id: i64,
}

pub struct Window {
    pub address: String,
    pub class: String,
    pub title: String,
    pub workspace: String,
    pub pid: i32,
}

/// Open windows ordered by recency: index 0 is the currently active window,
/// 1 is the previously active one (so a single Alt+Tab tap lands there),
/// and so on -- mirrors every other alt-tab implementation's default order.
pub fn list_windows() -> Vec<Window> {
    let out = match Command::new("hyprctl").args(["-j", "clients"]).output() {
        Ok(o) => o.stdout,
        Err(_) => return Vec::new(),
    };
    let mut clients: Vec<RawClient> = serde_json::from_slice(&out).unwrap_or_default();
    clients.retain(|c| c.mapped);
    // Special workspaces (scratchpads, "special:foo") are intentionally
    // hidden until summoned -- alt-tab shouldn't surface them any more than
    // it surfaces windows minimized some other way.
    clients.retain(|c| !c.workspace.name.starts_with("special:"));
    clients.sort_by_key(|c| c.focus_history_id);
    clients
        .into_iter()
        .map(|c| Window {
            address: c.address,
            class: c.class,
            title: c.title,
            workspace: c.workspace.name,
            pid: c.pid,
        })
        .collect()
}

/// True if either Alt key is currently physically held, per Hyprland's own
/// real-seat key-state tracking (not whatever our own process's keyboard
/// focus has or hasn't seen -- that's the whole point, see the quick-tap
/// comment in `main.rs`).
pub fn is_alt_down() -> bool {
    let out = Command::new("hyprctl")
        .args([
            "repl",
            r#"return tostring(hl.is_key_down("Alt_L") or hl.is_key_down("Alt_R"))"#,
        ])
        .output();
    matches!(out, Ok(o) if String::from_utf8_lossy(&o.stdout).trim() == "true")
}

/// The classic single-tap alt-tab: focus the previous (or, for `prev`,
/// least-recent) window directly, with no grid involved at all. Mirrors
/// `ui.rs`'s `start_idx` so a tap and a held-then-immediately-released hold
/// land on the same window either way.
pub fn quick_switch(cmd: &str) {
    let windows = list_windows();
    if windows.is_empty() {
        return;
    }
    let idx = if cmd == "prev" {
        windows.len() - 1
    } else {
        1.min(windows.len() - 1)
    };
    focus_window(&windows[idx].address);
}

/// `hyprctl dispatch focuswindow address:...` doesn't work on this build:
/// this Hyprland install uses the native Lua config system, under which
/// `hyprctl dispatch <name> <args>` is routed through string-concatenated
/// `hl.dispatch(<name> <args>)`, which isn't valid Lua for traditional
/// hyprctl dispatcher syntax. `hl.get_windows({address = ...})` also doesn't
/// filter by address (confirmed empirically -- it silently returns the full
/// unfiltered list), so the address match has to happen window-side in the
/// Lua snippet itself, then dispatch through `hl.dsp.focus`.
pub fn focus_window(address: &str) {
    let script = format!(
        r#"local ws = hl.get_windows({{}})
for i, w in ipairs(ws) do
    if tostring(w.address) == "{address}" then
        hl.dispatch(hl.dsp.focus({{ window = w }}))
        break
    end
end"#
    );
    let _ = Command::new("hyprctl").args(["repl", &script]).status();
}
