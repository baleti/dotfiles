//! Headless "popup" management. The old popup.rs drew GTK cards; notifyd is
//! headless as of 2026-08-30, so this writes the current popup set to
//! ~/.cache/notifyd/state.json and quickshell
//! (~/.config/quickshell/notifications/) draws it, reporting clicks back via
//! the Control interface (notifyctl invoke-action / dismiss / close-all).
//!
//! Everything else stays exactly as popup.rs did it: which notifications
//! have a card, their per-urgency timeout, and emitting NotificationClosed
//! (via `on_close`) whenever one goes away -- timer, dismiss, close-all, or
//! a client's CloseNotification.

use std::cell::RefCell;
use std::collections::HashMap;
use std::io::Write;
use std::path::PathBuf;
use std::rc::Rc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::close_reason;
use crate::config::Config;
use crate::state::SharedState;

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

pub struct RenderManager {
    /// Front = newest = top of the on-screen stack.
    order: Vec<u32>,
    timers: HashMap<u32, glib::SourceId>,
    /// id -> (expires_at unix ms, total duration ms). Only holds entries for
    /// notifications with a real timeout -- quickshell's countdown bar reads
    /// this via write_file(); an id absent here (urgency/expire_timeout says
    /// "never") gets no bar.
    expiry: HashMap<u32, (u64, u32)>,
    /// id -> total duration ms, for a notification whose timer is currently
    /// held by a card hover (see `hover_start`/`hover_end`). Removed from
    /// `expiry` while held -- no `expires_at_ms` means no countdown bar, so
    /// the card visibly stops ticking down instead of showing a frozen one.
    paused: HashMap<u32, u32>,
    config: Rc<Config>,
    state: SharedState,
    /// `(id, reason)` -> emit NotificationClosed. Same callback popup.rs took.
    on_close: Box<dyn Fn(u32, u32)>,
}

pub type SharedRender = Rc<RefCell<RenderManager>>;

pub fn new_manager(
    config: Config,
    state: SharedState,
    on_close: impl Fn(u32, u32) + 'static,
) -> SharedRender {
    Rc::new(RefCell::new(RenderManager {
        order: Vec::new(),
        timers: HashMap::new(),
        expiry: HashMap::new(),
        paused: HashMap::new(),
        config: Rc::new(config),
        state,
        on_close: Box::new(on_close),
    }))
}

pub fn state_path() -> PathBuf {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    home.join(".cache/notifyd/state.json")
}

/// dunstrc per-urgency `timeout`. `expire_timeout` is the Notify() arg: >0 is
/// an explicit override in ms, 0 = never, -1 = daemon default.
fn timeout_ms(urgency: u8, expire_timeout: i32, config: &Config) -> Option<u32> {
    match expire_timeout {
        t if t > 0 => Some(t as u32),
        0 => None,
        _ => match config.urgency(urgency).timeout_ms {
            0 => None,
            t => Some(t),
        },
    }
}

impl RenderManager {
    fn write_file(&self) {
        let json = {
            let state = self.state.lock().expect("state mutex poisoned");
            let popups: Vec<serde_json::Value> = self
                .order
                .iter()
                .filter_map(|id| state.notifications.get(id))
                .map(|n| {
                    let actions: Vec<serde_json::Value> = n
                        .action_pairs()
                        .map(|(k, l)| serde_json::json!({ "key": k, "label": l }))
                        .collect();
                    // Absent (null) for a notification with no timeout
                    // (expire_timeout == 0, or its urgency's configured
                    // timeout is 0/"never") -- quickshell skips the
                    // countdown bar for those instead of showing one stuck
                    // at some fixed position.
                    let exp = self.expiry.get(&n.id);
                    serde_json::json!({
                        "id": n.id,
                        "app_name": n.app_name,
                        // Unique D-Bus name that called Notify -- quickshell's
                        // summonSource() resolves it to a pid to find the
                        // originating window.
                        "sender": n.sender,
                        "summary": n.summary,
                        "body": n.body,
                        "icon": n.icon,
                        "image": n.image,
                        "urgency": n.urgency,
                        "timestamp": n.timestamp,
                        "actions": actions,
                        "default_action": n.default_action_key(),
                        "expires_at_ms": exp.map(|(e, _)| *e),
                        "timeout_ms": exp.map(|(_, d)| *d),
                    })
                })
                .collect();
            serde_json::to_string(&serde_json::json!({ "popups": popups }))
                .unwrap_or_else(|_| "{\"popups\":[]}".to_string())
        };

        let path = state_path();
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        // Atomic replace so quickshell's FileView never sees a half-write.
        let tmp = path.with_extension("json.tmp");
        if std::fs::File::create(&tmp)
            .and_then(|mut f| f.write_all(json.as_bytes()))
            .is_ok()
        {
            let _ = std::fs::rename(&tmp, &path);
        }
    }

    fn cancel_timer(&mut self, id: u32) {
        if let Some(src) = self.timers.remove(&id) {
            src.remove();
        }
    }
}

/// Arms (or re-arms) the expiry timer for `id` at `ms` from now. Caller must
/// have already cancelled any existing timer for `id`.
fn arm_timer(render: &SharedRender, id: u32, ms: u32) {
    render.borrow_mut().expiry.insert(id, (now_ms() + ms as u64, ms));

    let render2 = render.clone();
    let src = glib::timeout_add_local(Duration::from_millis(ms as u64), move || {
        // Clear our own handle first -- we unregister by returning Break,
        // so a later cancel_timer() must not also remove us.
        render2.borrow_mut().timers.remove(&id);
        fire_close(&render2, id, close_reason::EXPIRED);
        glib::ControlFlow::Break
    });
    render.borrow_mut().timers.insert(id, src);
}

/// Show a new popup, or refresh an already-shown one in place (replaces_id):
/// same stack position, re-armed timeout.
pub fn show(render: &SharedRender, id: u32, urgency: u8, expire_timeout: i32) {
    {
        let mut mgr = render.borrow_mut();
        mgr.cancel_timer(id);
        mgr.paused.remove(&id);
        if !mgr.order.contains(&id) {
            if mgr.order.len() >= mgr.config.notification_limit {
                // dunstrc: notification_limit -- still in history, just no
                // card right now.
                return;
            }
            mgr.order.insert(0, id);
        }
    }

    let cfg = render.borrow().config.clone();
    if let Some(ms) = timeout_ms(urgency, expire_timeout, &cfg) {
        arm_timer(render, id, ms);
    } else {
        render.borrow_mut().expiry.remove(&id);
    }

    render.borrow().write_file();
}

/// Card hover started (quickshell `notifyctl hover-start`): cancel the
/// countdown so it can't expire out from under the pointer, and remember its
/// full duration to restart on `hover_end`. A no-op for an id with no timer
/// (already paused, or never had a timeout).
pub fn hover_start(render: &SharedRender, id: u32) {
    let dur = {
        let mut mgr = render.borrow_mut();
        if !mgr.timers.contains_key(&id) {
            return;
        }
        mgr.cancel_timer(id);
        mgr.expiry.remove(&id).map(|(_, dur)| dur)
    };
    if let Some(dur) = dur {
        render.borrow_mut().paused.insert(id, dur);
        render.borrow().write_file();
    }
}

/// Card hover ended (`notifyctl hover-end`): restart the timer at its full
/// original duration -- a reset, not a resume from wherever it left off.
pub fn hover_end(render: &SharedRender, id: u32) {
    let dur = render.borrow_mut().paused.remove(&id);
    if let Some(dur) = dur {
        arm_timer(render, id, dur);
        render.borrow().write_file();
    }
}

/// Emit NotificationClosed and drop the popup. Every removal path except a
/// client CloseNotification (which emits the signal itself, see
/// `close_silent`) goes through here.
pub fn fire_close(render: &SharedRender, id: u32, reason: u32) {
    {
        let mut mgr = render.borrow_mut();
        mgr.cancel_timer(id);
        mgr.expiry.remove(&id);
        mgr.paused.remove(&id);
        mgr.order.retain(|&x| x != id);
    }
    render.borrow().on_close.as_ref()(id, reason);
    render.borrow().write_file();
}

/// CloseNotification path: main.rs has already emitted NotificationClosed,
/// so just drop the card.
pub fn close_silent(render: &SharedRender, id: u32) {
    {
        let mut mgr = render.borrow_mut();
        mgr.cancel_timer(id);
        mgr.expiry.remove(&id);
        mgr.paused.remove(&id);
        mgr.order.retain(|&x| x != id);
    }
    render.borrow().write_file();
}

pub fn close_all(render: &SharedRender, reason: u32) {
    let ids: Vec<u32> = render.borrow().order.clone();
    {
        let mut mgr = render.borrow_mut();
        for &id in &ids {
            mgr.cancel_timer(id);
            mgr.expiry.remove(&id);
            mgr.paused.remove(&id);
        }
        mgr.order.clear();
    }
    for id in &ids {
        render.borrow().on_close.as_ref()(*id, reason);
    }
    render.borrow().write_file();
}
