//! Thin wrappers around `hyprctl`: the window list we build the grid from,
//! and the one dispatcher call that actually changes focus.

use std::process::Command;

use serde::{Deserialize, Serialize};

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
    size: (i32, i32),
}

#[derive(Clone, Serialize)]
pub struct Window {
    pub address: String,
    pub class: String,
    pub title: String,
    pub workspace: String,
    pub pid: i32,
    /// The window's actual on-screen size, straight from `hyprctl clients`.
    /// Used to size a cell's thumbnail frame to this window's real aspect
    /// ratio before any capture has arrived -- see `ui.rs::frame_size`.
    pub width: i32,
    pub height: i32,
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
            width: c.size.0,
            height: c.size.1,
        })
        .collect()
}

// Alt-state tracking and focus dispatch live in ~/.config/hypr/winswitch.lua
// (driven by services/WinSwitchState.qml) -- see main.rs's module doc.
