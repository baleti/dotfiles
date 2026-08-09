//! Shared daemon state. A single `Mutex` guards everything: the D-Bus
//! callbacks that touch this run on gio's worker machinery and must be
//! `Send + Sync`, so `Rc`/`RefCell` (used freely elsewhere in this
//! session's GTK picker code, where everything stays on one thread by
//! construction) aren't an option here -- see the comment in main.rs on
//! why `DBusInterfaceInfo` can't even be captured across that boundary.
//! In practice there's no real contention: gio dispatches D-Bus callbacks
//! on the thread that owns the connection's main context, so this is a
//! single-threaded program that happens to need thread-safe types to
//! satisfy the API's (correctly conservative) bounds.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

/// A currently-active (not yet closed) notification. Phase 2 removes these
/// from `AppState::active` once closed -- Phase 6 changes that to move them
/// into a capped history instead, which is the entire point of this project
/// (see ~/.claude2/plans/silly-percolating-rose.md).
#[derive(Clone, Debug)]
pub struct Notification {
    pub id: u32,
    /// Unique D-Bus bus name of whichever app called Notify -- this is what
    /// makes ActionInvoked routable back to the right app later.
    pub sender: String,
    pub app_name: String,
    pub summary: String,
    pub body: String,
    pub icon: String,
    /// Flat [key, label, key, label, ...] pairs, exactly as the spec passes
    /// them.
    pub actions: Vec<String>,
    pub urgency: u8,
}

impl Notification {
    /// Action keys only (every other element), skipping the spec's implicit
    /// "default" entry when it has no visible label to show in a menu.
    pub fn action_keys(&self) -> impl Iterator<Item = &str> {
        self.actions.iter().step_by(2).map(String::as_str)
    }
}

pub struct AppState {
    pub next_id: u32,
    pub active: HashMap<u32, Notification>,
    pub connection: Option<gio::DBusConnection>,
}

impl AppState {
    pub fn new() -> Self {
        AppState {
            next_id: 1,
            active: HashMap::new(),
            connection: None,
        }
    }

    /// Per the spec: reuse `replaces_id` verbatim if given, otherwise mint a
    /// fresh one.
    pub fn allocate_id(&mut self, replaces_id: u32) -> u32 {
        if replaces_id != 0 {
            replaces_id
        } else {
            let id = self.next_id;
            self.next_id += 1;
            id
        }
    }
}

pub type SharedState = Arc<Mutex<AppState>>;
