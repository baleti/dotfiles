//! Real keyboard/pointer idleness through `ext-idle-notify-v1`, on its own tiny wayland
//! connection and thread. Three notifications (15 s, 2 min, 15 min) drive one shared level:
//! 0 = input within the last 15 s, 1/2/3 = idle at least that long. `daemon.rs` polls the
//! atomic; if the compositor lacks the protocol the level stays at `UNKNOWN` and the daemon
//! falls back to pointer movement + compositor events.

use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::Arc;

use wayland_client::globals::{registry_queue_init, GlobalListContents};
use wayland_client::protocol::{wl_registry, wl_seat};
use wayland_client::{Connection, Dispatch, QueueHandle};

use crate::protocol::ext_idle_notify_v1::ext_idle_notification_v1::{self, ExtIdleNotificationV1};
use crate::protocol::ext_idle_notify_v1::ext_idle_notifier_v1::ExtIdleNotifierV1;

pub const UNKNOWN: u8 = 255;
pub const THRESHOLDS_MS: [u32; 3] = [15_000, 120_000, 900_000];

struct State {
    level: Arc<AtomicU8>,
}

impl Dispatch<wl_registry::WlRegistry, GlobalListContents> for State {
    fn event(_: &mut Self, _: &wl_registry::WlRegistry, _: wl_registry::Event, _: &GlobalListContents, _: &Connection, _: &QueueHandle<Self>) {}
}
impl Dispatch<wl_seat::WlSeat, ()> for State {
    fn event(_: &mut Self, _: &wl_seat::WlSeat, _: wl_seat::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}
impl Dispatch<ExtIdleNotifierV1, ()> for State {
    fn event(_: &mut Self, _: &ExtIdleNotifierV1, _: <ExtIdleNotifierV1 as wayland_client::Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}
impl Dispatch<ExtIdleNotificationV1, u8> for State {
    fn event(state: &mut Self, _: &ExtIdleNotificationV1, event: ext_idle_notification_v1::Event, idx: &u8, _: &Connection, _: &QueueHandle<Self>) {
        match event {
            ext_idle_notification_v1::Event::Idled => state.level.store(*idx + 1, Ordering::Relaxed),
            ext_idle_notification_v1::Event::Resumed => state.level.store(0, Ordering::Relaxed),
            _ => {}
        }
    }
}

fn run(level: Arc<AtomicU8>) -> Option<()> {
    let conn = Connection::connect_to_env().ok()?;
    let (globals, mut queue) = registry_queue_init::<State>(&conn).ok()?;
    let qh = queue.handle();
    let seat: wl_seat::WlSeat = globals.bind(&qh, 1..=1, ()).ok()?;
    let notifier: ExtIdleNotifierV1 = globals.bind(&qh, 1..=1, ()).ok()?;
    let _notes: Vec<_> = THRESHOLDS_MS
        .iter()
        .enumerate()
        .map(|(i, ms)| notifier.get_idle_notification(*ms, &seat, &qh, i as u8))
        .collect();
    level.store(0, Ordering::Relaxed);
    let mut state = State { level };
    loop {
        queue.blocking_dispatch(&mut state).ok()?;
    }
}

/// Starts the watcher thread; the returned level is `UNKNOWN` until the protocol is bound
/// (and again if the connection ever dies).
pub fn start() -> Arc<AtomicU8> {
    let level = Arc::new(AtomicU8::new(UNKNOWN));
    let l = level.clone();
    std::thread::spawn(move || {
        let _ = run(l.clone());
        l.store(UNKNOWN, Ordering::Relaxed);
    });
    level
}
