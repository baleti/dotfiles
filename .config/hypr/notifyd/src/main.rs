//! notifyd: replaces dunst. See ~/.claude2/plans/silly-percolating-rose.md
//! for the full phased plan and why dunst can't be fixed in place (it
//! invalidates a notification's actions the instant it closes, even on
//! timeout -- confirmed via `man 5 dunst` and live D-Bus testing).
//!
//! Currently on a throwaway dev bus name (`DEV_BUS_NAME`) so dunst keeps
//! serving real notifications untouched during development; Phase 10
//! switches this to the real `org.freedesktop.Notifications` name.
//!
//! Phase 3 adds popup rendering (popup.rs). The D-Bus method_call closures
//! registered below must be `Send + Sync` (gio's binding requires it even
//! though everything actually runs on one thread here -- see the comment
//! on `DBusInterfaceInfo` further down), but GTK widgets are emphatically
//! not `Send`. So the D-Bus side only ever touches `state: SharedState`
//! (`Arc<Mutex<..>>`, plain data) directly, and hands off to the GTK side
//! by pushing a `UiMsg` through a `glib::MainContext` channel -- the
//! standard bridge for exactly this situation, since `Receiver::attach`'s
//! callback has no `Send` bound and can freely capture `Rc<RefCell<..>>`
//! popup state.

mod popup;
mod state;

use std::collections::HashMap;

use gio::prelude::*;

use state::{AppState, Notification, SharedState};

const DEV_BUS_NAME: &str = "com.notifyd.Dev";
const OBJECT_PATH: &str = "/org/freedesktop/Notifications";
const INTERFACE_NAME: &str = "org.freedesktop.Notifications";

/// NotificationClosed reason codes, per the freedesktop Notifications spec.
/// `pub` so popup.rs's mouse handlers (mouse_middle_click/mouse_right_click
/// = close_current/close_all) can pass the right reason without main.rs
/// having to mediate every mouse-triggered close individually.
pub mod close_reason {
    pub const EXPIRED: u32 = 1;
    pub const DISMISSED: u32 = 2;
    pub const CLOSE_NOTIFICATION_CALLED: u32 = 3;
    #[allow(dead_code)] // reserved by spec for daemon-defined reasons
    pub const UNDEFINED: u32 = 4;
}

/// Sent from the (Send + Sync) D-Bus callbacks to the GTK-main-thread
/// receiver in `main()`. Carries only ids, not full `Notification` data --
/// the receiver re-reads `state` for the current content, so there's one
/// source of truth rather than two copies that could disagree.
enum UiMsg {
    Show { id: u32, expire_timeout: i32 },
    Close(u32),
}

const INTROSPECTION_XML: &str = r#"
<node>
  <interface name="org.freedesktop.Notifications">
    <method name="GetCapabilities">
      <arg type="as" name="capabilities" direction="out"/>
    </method>
    <method name="Notify">
      <arg type="s" name="app_name" direction="in"/>
      <arg type="u" name="replaces_id" direction="in"/>
      <arg type="s" name="app_icon" direction="in"/>
      <arg type="s" name="summary" direction="in"/>
      <arg type="s" name="body" direction="in"/>
      <arg type="as" name="actions" direction="in"/>
      <arg type="a{sv}" name="hints" direction="in"/>
      <arg type="i" name="expire_timeout" direction="in"/>
      <arg type="u" name="id" direction="out"/>
    </method>
    <method name="CloseNotification">
      <arg type="u" name="id" direction="in"/>
    </method>
    <method name="GetServerInformation">
      <arg type="s" name="name" direction="out"/>
      <arg type="s" name="vendor" direction="out"/>
      <arg type="s" name="version" direction="out"/>
      <arg type="s" name="spec_version" direction="out"/>
    </method>
    <signal name="NotificationClosed">
      <arg type="u" name="id"/>
      <arg type="u" name="reason"/>
    </signal>
    <signal name="ActionInvoked">
      <arg type="u" name="id"/>
      <arg type="s" name="action_key"/>
    </signal>
  </interface>
</node>
"#;

fn emit_notification_closed(connection: &gio::DBusConnection, id: u32, reason: u32) {
    if let Err(err) = connection.emit_signal(
        None,
        OBJECT_PATH,
        INTERFACE_NAME,
        "NotificationClosed",
        Some(&(id, reason).to_variant()),
    ) {
        eprintln!("notifyd: failed to emit NotificationClosed({id}, {reason}): {err}");
    }
}

fn emit_action_invoked(connection: &gio::DBusConnection, id: u32, action_key: &str) {
    if let Err(err) = connection.emit_signal(
        None,
        OBJECT_PATH,
        INTERFACE_NAME,
        "ActionInvoked",
        Some(&(id, action_key).to_variant()),
    ) {
        eprintln!("notifyd: failed to emit ActionInvoked({id}, {action_key:?}): {err}");
    }
}

fn handle_notify(
    state: &SharedState,
    ui_tx: &glib::Sender<UiMsg>,
    sender: &str,
    parameters: &glib::Variant,
) -> Option<u32> {
    let (app_name, replaces_id, app_icon, summary, body, actions, hints, expire_timeout): (
        String,
        u32,
        String,
        String,
        String,
        Vec<String>,
        HashMap<String, glib::Variant>,
        i32,
    ) = parameters.get()?;

    let urgency = hints
        .get("urgency")
        .and_then(|v| v.get::<u8>())
        .unwrap_or(1); // NORMAL, per spec default

    let id = {
        let mut state = state.lock().expect("state mutex poisoned");
        let id = state.allocate_id(replaces_id);
        state.active.insert(
            id,
            Notification {
                id,
                sender: sender.to_string(),
                app_name: app_name.clone(),
                summary: summary.clone(),
                body: body.clone(),
                icon: app_icon.clone(),
                actions: actions.clone(),
                urgency,
            },
        );
        id
    };

    println!(
        "Notify #{id} from {sender}: app={app_name:?} icon={app_icon:?} \
         summary={summary:?} body={body:?} actions={actions:?} \
         urgency={urgency} timeout={expire_timeout}"
    );

    let _ = ui_tx.send(UiMsg::Show { id, expire_timeout });

    Some(id)
}

fn handle_close_notification(
    state: &SharedState,
    ui_tx: &glib::Sender<UiMsg>,
    parameters: &glib::Variant,
) -> Option<()> {
    let (id,): (u32,) = parameters.get()?;

    let (removed, connection) = {
        let mut state = state.lock().expect("state mutex poisoned");
        (state.active.remove(&id).is_some(), state.connection.clone())
    };

    if removed {
        println!("CloseNotification #{id}");
        if let Some(connection) = connection {
            emit_notification_closed(&connection, id, close_reason::CLOSE_NOTIFICATION_CALLED);
        }
        let _ = ui_tx.send(UiMsg::Close(id));
    }

    Some(())
}

fn handle_method_call(
    state: &SharedState,
    ui_tx: &glib::Sender<UiMsg>,
    sender: &str,
    method_name: &str,
    parameters: &glib::Variant,
    invocation: gio::DBusMethodInvocation,
) {
    match method_name {
        "GetCapabilities" => {
            let caps: Vec<&str> = vec!["body", "actions"];
            invocation.return_value(Some(&(caps,).to_variant()));
        }
        "GetServerInformation" => {
            let info = ("notifyd", "hypr", "0.1.0", "1.2");
            invocation.return_value(Some(&info.to_variant()));
        }
        "Notify" => match handle_notify(state, ui_tx, sender, parameters) {
            Some(id) => invocation.return_value(Some(&(id,).to_variant())),
            None => invocation.return_dbus_error(
                "org.freedesktop.DBus.Error.InvalidArgs",
                "Notify: unexpected argument shape",
            ),
        },
        "CloseNotification" => match handle_close_notification(state, ui_tx, parameters) {
            Some(()) => invocation.return_value(None),
            None => invocation.return_dbus_error(
                "org.freedesktop.DBus.Error.InvalidArgs",
                "CloseNotification: unexpected argument shape",
            ),
        },
        other => {
            invocation.return_dbus_error(
                "org.freedesktop.DBus.Error.UnknownMethod",
                &format!("notifyd: method {other} not implemented yet"),
            );
        }
    }
}

fn main() {
    if gtk::init().is_err() {
        eprintln!("notifyd: failed to initialise GTK");
        std::process::exit(1);
    }

    let main_loop = glib::MainLoop::new(None, false);
    let state: SharedState = std::sync::Arc::new(std::sync::Mutex::new(AppState::new()));

    // These two are the only things popup.rs's mouse handlers and expiry
    // timers need from the D-Bus/AppState world: remove the notification
    // (any close reason) and tell the original sender about it, or forward
    // an invoked action. Everything else about closing/redrawing stays
    // inside popup.rs.
    let popups = popup::new_manager(
        {
            let state = state.clone();
            move |id, reason| {
                let connection = {
                    let mut state = state.lock().expect("state mutex poisoned");
                    let connection = state.connection.clone();
                    state.active.remove(&id);
                    connection
                };
                if let Some(connection) = connection {
                    emit_notification_closed(&connection, id, reason);
                }
            }
        },
        {
            let state = state.clone();
            move |id, action_key| {
                let connection = state.lock().expect("state mutex poisoned").connection.clone();
                if let Some(connection) = connection {
                    emit_action_invoked(&connection, id, action_key);
                }
            }
        },
    );

    let (ui_tx, ui_rx) = glib::MainContext::channel::<UiMsg>(glib::Priority::DEFAULT);

    {
        let state = state.clone();
        let popups = popups.clone();
        ui_rx.attach(None, move |msg| {
            match msg {
                UiMsg::Show { id, expire_timeout } => {
                    let notification = state
                        .lock()
                        .expect("state mutex poisoned")
                        .active
                        .get(&id)
                        .cloned();
                    if let Some(notification) = notification {
                        popup::show(&popups, &notification, expire_timeout);
                    }
                }
                UiMsg::Close(id) => popup::close(&popups, id),
            }
            glib::ControlFlow::Continue
        });
    }

    let _owner_id = gio::bus_own_name(
        gio::BusType::Session,
        DEV_BUS_NAME,
        gio::BusNameOwnerFlags::NONE,
        move |connection, _name| {
            state.lock().expect("state mutex poisoned").connection = Some(connection.clone());
            let state = state.clone();
            let ui_tx = ui_tx.clone();
            // DBusInterfaceInfo wraps a raw pointer and isn't Send/Sync, so it
            // can't be captured from outside this (Send + Sync) closure --
            // parse it fresh here instead, which is cheap and only happens
            // once per bus-name acquisition.
            let node_info = gio::DBusNodeInfo::for_xml(INTROSPECTION_XML)
                .expect("bad introspection xml");
            let interface_info = node_info
                .lookup_interface(INTERFACE_NAME)
                .expect("interface missing from introspection xml");
            let registration = connection.register_object(
                OBJECT_PATH,
                &interface_info,
                move |_connection, sender, _object_path, _interface_name, method_name, parameters, invocation| {
                    handle_method_call(&state, &ui_tx, sender, method_name, &parameters, invocation);
                },
                |_, _, _, _, _| false.to_variant(),
                |_, _, _, _, _, _| false,
            );
            match registration {
                Ok(_id) => println!("notifyd: registered {OBJECT_PATH} on {DEV_BUS_NAME}"),
                Err(err) => eprintln!("notifyd: failed to register object: {err}"),
            }
        },
        |_connection, name| println!("notifyd: acquired bus name {name}"),
        |_connection, name| eprintln!("notifyd: lost bus name {name} (already running?)"),
    );

    println!("notifyd: running as {DEV_BUS_NAME}, Ctrl+C to stop");
    main_loop.run();
}
