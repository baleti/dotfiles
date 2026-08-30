//! Shared daemon state -- the notification store. A single `Mutex` guards
//! everything: gio's D-Bus callbacks must be `Send + Sync` so `Rc`/`RefCell`
//! aren't an option here (see main.rs). In practice gio dispatches those
//! callbacks on the one thread that owns the connection, so there's no real
//! contention -- it's a single-threaded program that needs thread-safe types
//! only to satisfy the API's (correct) bounds.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone, Debug)]
pub struct Notification {
    pub id: u32,
    /// Unique D-Bus name of whichever app called Notify. Not needed to route
    /// signals back (those are broadcast, clients filter by id) -- kept for
    /// history display (`notifyctl list`).
    pub sender: String,
    pub app_name: String,
    pub summary: String,
    pub body: String,
    /// Resolved by main.rs's `resolve_icon`: a themed icon name, an absolute
    /// path, or a `~/.cache/notifyd/icons/<id>.png` written from an
    /// image-data hint. quickshell renders whichever it is.
    pub icon: String,
    /// Flat [key, label, key, label, ...] pairs, exactly as the spec passes
    /// them.
    pub actions: Vec<String>,
    pub urgency: u8,
    /// Unix epoch seconds when Notify() was (last) called for this id.
    pub timestamp: u64,
}

impl Notification {
    /// Action keys only (every other element of `actions`).
    pub fn action_keys(&self) -> impl Iterator<Item = &str> {
        self.actions.iter().step_by(2).map(String::as_str)
    }

    /// (key, label) pairs.
    pub fn action_pairs(&self) -> impl Iterator<Item = (&str, &str)> {
        self.actions.chunks_exact(2).map(|p| (p[0].as_str(), p[1].as_str()))
    }

    /// dunstrc `action_name` default: the action keyed "default" if present,
    /// else the sole action if there's exactly one, else none (ambiguous --
    /// needs the action menu). Moved here from the old popup.rs.
    pub fn default_action_key(&self) -> Option<&str> {
        let mut only = None;
        let mut count = 0;
        for key in self.action_keys() {
            count += 1;
            if key == "default" {
                return Some(key);
            }
            only = Some(key);
        }
        if count == 1 {
            only
        } else {
            None
        }
    }
}

pub fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Every notification the daemon has seen, capped at `history_length`. This
/// is the point of the project: a notification is never removed just because
/// it closed, only evicted once the cap is exceeded -- so its actions stay
/// invokable indefinitely afterwards, unlike dunst.
pub struct AppState {
    pub next_id: u32,
    pub notifications: HashMap<u32, Notification>,
    /// Insertion order, oldest first, for FIFO eviction. Only touched when a
    /// genuinely new id is added -- a `replaces_id` update reuses its entry
    /// in place and doesn't move it here.
    order: VecDeque<u32>,
    history_length: usize,
    pub connection: Option<gio::DBusConnection>,
}

impl AppState {
    pub fn new(history_length: usize) -> Self {
        AppState {
            next_id: 1,
            notifications: HashMap::new(),
            order: VecDeque::new(),
            history_length,
            connection: None,
        }
    }

    /// Per spec: reuse `replaces_id` verbatim if given, otherwise mint one.
    pub fn allocate_id(&mut self, replaces_id: u32) -> u32 {
        if replaces_id != 0 {
            replaces_id
        } else {
            let id = self.next_id;
            self.next_id += 1;
            id
        }
    }

    /// Inserts a new notification or overwrites an id in place
    /// (`replaces_id`); returns the id evicted to stay under `history_length`,
    /// if any, so the caller can drop its cached icon file.
    pub fn insert(&mut self, notification: Notification) -> Option<u32> {
        let id = notification.id;
        let is_new = self.notifications.insert(id, notification).is_none();
        if is_new {
            self.order.push_back(id);
            if self.order.len() > self.history_length {
                if let Some(evicted) = self.order.pop_front() {
                    self.notifications.remove(&evicted);
                    return Some(evicted);
                }
            }
        }
        None
    }

    /// The most recently *added* id (a `replaces_id` update doesn't move its
    /// position). Used for `notifyctl invoke-last` / `actions` with no id.
    pub fn most_recent_id(&self) -> Option<u32> {
        self.order.back().copied()
    }
}

pub type SharedState = Arc<Mutex<AppState>>;
