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

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

/// Maximum notifications retained after they close. dunstrc: history_length.
pub const HISTORY_LENGTH: usize = 20;

#[derive(Clone, Debug)]
pub struct Notification {
    pub id: u32,
    /// Unique D-Bus bus name of whichever app called Notify. *Not* needed
    /// to route ActionInvoked/NotificationClosed back to it -- those are
    /// broadcast signals with no destination (confirmed both in the spec
    /// and by eavesdropping on real dunst traffic), and interested clients
    /// filter by id themselves. Kept for diagnostics/history display
    /// (`notifyctl list`, Phase 7).
    pub sender: String,
    pub app_name: String,
    pub summary: String,
    pub body: String,
    pub icon: String,
    /// Flat [key, label, key, label, ...] pairs, exactly as the spec passes
    /// them.
    pub actions: Vec<String>,
    pub urgency: u8,
    /// Unix epoch seconds when Notify() was called (or last replaced it).
    pub timestamp: u64,
}

impl Notification {
    /// Action keys only (every other element of `actions`).
    pub fn action_keys(&self) -> impl Iterator<Item = &str> {
        self.actions.iter().step_by(2).map(String::as_str)
    }
}

pub fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Every notification the daemon has seen, capped at `HISTORY_LENGTH`. This
/// is the entire point of the project (see
/// ~/.claude2/plans/silly-percolating-rose.md): a notification is never
/// removed just because it closed, only evicted once the cap is exceeded,
/// so its actions stay invokable indefinitely afterwards -- unlike dunst,
/// which discards a notification's actions the instant it closes (or
/// times out), confirmed via `man 5 dunst` and live D-Bus testing.
///
/// Deliberately doesn't track which entries are currently *displayed* --
/// popup.rs owns that independently (its own `PopupManager`). This map is
/// just "everything known", full stop.
pub struct AppState {
    pub next_id: u32,
    pub notifications: HashMap<u32, Notification>,
    /// Insertion order, oldest first, for FIFO eviction. Only touched when
    /// a genuinely new id is added -- a `replaces_id` update reuses an
    /// existing entry in place and doesn't move it here.
    order: VecDeque<u32>,
    pub connection: Option<gio::DBusConnection>,
}

impl AppState {
    pub fn new() -> Self {
        AppState {
            next_id: 1,
            notifications: HashMap::new(),
            order: VecDeque::new(),
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

    /// Inserts a new notification or overwrites an existing id in place
    /// (`replaces_id`), then evicts the oldest entry if this grew the
    /// total past `HISTORY_LENGTH`.
    ///
    /// Eviction is purely by insertion order, regardless of whether the
    /// oldest entry is still on screen: this state doesn't know "still
    /// displayed" (see the struct doc), so in the rare case of
    /// `HISTORY_LENGTH`+ notifications arriving while a very old sticky
    /// one is still up, that old one's action could be evicted while still
    /// visible. Acceptable for a personal tool; not worth cross-module
    /// bookkeeping with popup.rs to close.
    pub fn insert(&mut self, notification: Notification) {
        let id = notification.id;
        let is_new = self.notifications.insert(id, notification).is_none();
        if is_new {
            self.order.push_back(id);
            if self.order.len() > HISTORY_LENGTH {
                if let Some(evicted) = self.order.pop_front() {
                    self.notifications.remove(&evicted);
                }
            }
        }
    }

    /// The most recently *added* id (a `replaces_id` update doesn't move
    /// its position here -- see `order`'s doc). Used for `notifyctl
    /// invoke-last` and `notifyctl actions` with no id given.
    pub fn most_recent_id(&self) -> Option<u32> {
        self.order.back().copied()
    }
}

pub type SharedState = Arc<Mutex<AppState>>;
