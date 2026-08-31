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
use std::time::Duration;

use crate::close_reason;
use crate::config::Config;
use crate::state::SharedState;

pub struct RenderManager {
    /// Front = newest = top of the on-screen stack.
    order: Vec<u32>,
    timers: HashMap<u32, glib::SourceId>,
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
                    serde_json::json!({
                        "id": n.id,
                        "app_name": n.app_name,
                        "summary": n.summary,
                        "body": n.body,
                        "icon": n.icon,
                        "image": n.image,
                        "urgency": n.urgency,
                        "timestamp": n.timestamp,
                        "actions": actions,
                        "default_action": n.default_action_key(),
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

/// Show a new popup, or refresh an already-shown one in place (replaces_id):
/// same stack position, re-armed timeout.
pub fn show(render: &SharedRender, id: u32, urgency: u8, expire_timeout: i32) {
    {
        let mut mgr = render.borrow_mut();
        mgr.cancel_timer(id);
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

    render.borrow().write_file();
}

/// Emit NotificationClosed and drop the popup. Every removal path except a
/// client CloseNotification (which emits the signal itself, see
/// `close_silent`) goes through here.
pub fn fire_close(render: &SharedRender, id: u32, reason: u32) {
    {
        let mut mgr = render.borrow_mut();
        mgr.cancel_timer(id);
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
        }
        mgr.order.clear();
    }
    for id in &ids {
        render.borrow().on_close.as_ref()(*id, reason);
    }
    render.borrow().write_file();
}
