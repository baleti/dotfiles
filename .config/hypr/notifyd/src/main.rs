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

use notifyd::dbus_names::{CONTROL_INTERFACE, DEV_BUS_NAME, NOTIFICATIONS_INTERFACE, OBJECT_PATH};
use state::{AppState, Notification, SharedState};

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
    CloseAll,
}

/// Both interfaces notifyd registers at `OBJECT_PATH`, in one document --
/// `DBusNodeInfo::for_xml` happily parses multiple `<interface>` elements
/// under one `<node>`, and `lookup_interface` then finds either by name.
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
  <interface name="org.hypr.notifyd1.Control">
    <!-- Invokes the resolved default action (dunstrc: action_name's
         default -- see popup::default_action_key) without needing a
         popup on screen at all: unlike dunst/mako, closing a notification
         here never invalidates it (state.rs), so there's no
         redisplay-then-act dance to do. id = 0 means "the most recently
         received notification". -->
    <method name="InvokeLastAction"/>
    <method name="InvokeAction">
      <arg type="u" name="id" direction="in"/>
    </method>
    <method name="InvokeActionByKey">
      <arg type="u" name="id" direction="in"/>
      <arg type="s" name="action_key" direction="in"/>
    </method>
    <!-- "key\tlabel\n" per action, id = 0 means most recent. -->
    <method name="Actions">
      <arg type="u" name="id" direction="in"/>
      <arg type="s" name="actions" direction="out"/>
    </method>
    <method name="ListHistory">
      <arg type="s" name="json" direction="out"/>
    </method>
    <method name="CloseAll"/>
  </interface>
</node>
"#;

fn emit_notification_closed(connection: &gio::DBusConnection, id: u32, reason: u32) {
    if let Err(err) = connection.emit_signal(
        None,
        OBJECT_PATH,
        NOTIFICATIONS_INTERFACE,
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
        NOTIFICATIONS_INTERFACE,
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
        state.insert(Notification {
            id,
            sender: sender.to_string(),
            app_name: app_name.clone(),
            summary: summary.clone(),
            body: body.clone(),
            icon: app_icon.clone(),
            actions: actions.clone(),
            urgency,
            timestamp: state::now_unix(),
        });
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

    // Known-id check only, not removal: Phase 6 keeps every notification in
    // `state` after it closes (that's the whole point -- see state.rs), so
    // there's no "remove and see if it was there" signal to key off
    // anymore. This can't distinguish "currently displayed" from "already
    // history" (state.rs doesn't track that), so CloseNotification on an
    // id that's already closed is a harmless no-op re-emission rather than
    // a true no-op -- popup::close() (via UiMsg::Close below) already
    // no-ops correctly either way.
    let (known, connection) = {
        let state = state.lock().expect("state mutex poisoned");
        (state.notifications.contains_key(&id), state.connection.clone())
    };

    if known {
        println!("CloseNotification #{id}");
        if let Some(connection) = connection {
            emit_notification_closed(&connection, id, close_reason::CLOSE_NOTIFICATION_CALLED);
        }
        let _ = ui_tx.send(UiMsg::Close(id));
    }

    Some(())
}

/// `id == 0` means "the most recently received notification" throughout
/// the control interface, matching the spec's own convention that 0 is
/// never a real notification id (`replaces_id = 0` means "not applicable").
fn resolve_target_id(state: &SharedState, id: u32) -> Option<u32> {
    if id != 0 {
        Some(id)
    } else {
        state.lock().expect("state mutex poisoned").most_recent_id()
    }
}

/// Emits ActionInvoked for `id`, resolving to the default action
/// (`popup::default_action_key`) if `key` is `None`, or that exact key if
/// it's actually one of the notification's actions. Returns whether
/// anything was actually emitted -- false for an unknown id, an
/// unresolvable default (see `default_action_key`'s doc), or a `key` that
/// doesn't belong to this notification.
fn invoke_action(state: &SharedState, id: u32, key: Option<&str>) -> bool {
    let (notification, connection) = {
        let state = state.lock().expect("state mutex poisoned");
        (state.notifications.get(&id).cloned(), state.connection.clone())
    };
    let Some(notification) = notification else {
        return false;
    };
    let key = match key {
        Some(k) => notification.action_keys().find(|&k2| k2 == k),
        None => popup::default_action_key(&notification),
    };
    let Some(key) = key else {
        return false;
    };
    if let Some(connection) = connection {
        emit_action_invoked(&connection, id, key);
    }
    true
}

/// "key\tlabel\n" per action -- same tab-separated convention as
/// `cliphist list`/`dunstctl history`, easy to pipe into `rofi -dmenu`.
fn actions_string(state: &SharedState, id: u32) -> String {
    let notification = state
        .lock()
        .expect("state mutex poisoned")
        .notifications
        .get(&id)
        .cloned();
    let Some(notification) = notification else {
        return String::new();
    };
    let mut out = String::new();
    for pair in notification.actions.chunks(2) {
        if let [key, label] = pair {
            out.push_str(key);
            out.push('\t');
            out.push_str(label);
            out.push('\n');
        }
    }
    out
}

/// Newest first, matching the order dunst's own `dunstctl history` returns
/// (confirmed earlier this session).
fn list_history_json(state: &SharedState) -> String {
    let state = state.lock().expect("state mutex poisoned");
    let mut items: Vec<&Notification> = state.notifications.values().collect();
    items.sort_by(|a, b| b.timestamp.cmp(&a.timestamp).then(b.id.cmp(&a.id)));

    let json: Vec<serde_json::Value> = items
        .iter()
        .map(|n| {
            let actions: Vec<serde_json::Value> = n
                .actions
                .chunks(2)
                .filter_map(|pair| match pair {
                    [key, label] => Some(serde_json::json!({"key": key, "label": label})),
                    _ => None,
                })
                .collect();
            serde_json::json!({
                "id": n.id,
                "sender": n.sender,
                "app_name": n.app_name,
                "summary": n.summary,
                "body": n.body,
                "icon": n.icon,
                "urgency": n.urgency,
                "timestamp": n.timestamp,
                "actions": actions,
            })
        })
        .collect();
    serde_json::to_string(&json).unwrap_or_else(|_| "[]".to_string())
}

fn handle_control_call(
    state: &SharedState,
    ui_tx: &glib::Sender<UiMsg>,
    method_name: &str,
    parameters: &glib::Variant,
    invocation: gio::DBusMethodInvocation,
) {
    match method_name {
        "InvokeLastAction" => {
            if let Some(id) = resolve_target_id(state, 0) {
                invoke_action(state, id, None);
            }
            invocation.return_value(None);
        }
        "InvokeAction" => {
            let Some((id,)): Option<(u32,)> = parameters.get() else {
                invocation.return_dbus_error(
                    "org.freedesktop.DBus.Error.InvalidArgs",
                    "InvokeAction: unexpected argument shape",
                );
                return;
            };
            invoke_action(state, id, None);
            invocation.return_value(None);
        }
        "InvokeActionByKey" => {
            let Some((id, key)): Option<(u32, String)> = parameters.get() else {
                invocation.return_dbus_error(
                    "org.freedesktop.DBus.Error.InvalidArgs",
                    "InvokeActionByKey: unexpected argument shape",
                );
                return;
            };
            invoke_action(state, id, Some(&key));
            invocation.return_value(None);
        }
        "Actions" => {
            let Some((id,)): Option<(u32,)> = parameters.get() else {
                invocation.return_dbus_error(
                    "org.freedesktop.DBus.Error.InvalidArgs",
                    "Actions: unexpected argument shape",
                );
                return;
            };
            let target = resolve_target_id(state, id).unwrap_or(0);
            invocation.return_value(Some(&(actions_string(state, target),).to_variant()));
        }
        "ListHistory" => {
            invocation.return_value(Some(&(list_history_json(state),).to_variant()));
        }
        "CloseAll" => {
            let _ = ui_tx.send(UiMsg::CloseAll);
            invocation.return_value(None);
        }
        other => {
            invocation.return_dbus_error(
                "org.freedesktop.DBus.Error.UnknownMethod",
                &format!("notifyd control: method {other} not implemented"),
            );
        }
    }
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
    // timers need from the D-Bus/AppState world: tell the original sender a
    // notification closed (any reason) or that one of its actions was
    // invoked. Notably this does *not* remove anything from `state` --
    // closing just stops the popup being displayed, it doesn't stop the
    // notification being invokable later (that's the entire point of
    // Phase 6, see state.rs). Everything about closing/redrawing itself
    // stays inside popup.rs.
    let popups = popup::new_manager(
        {
            let state = state.clone();
            move |id, reason| {
                let connection = state.lock().expect("state mutex poisoned").connection.clone();
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
                        .notifications
                        .get(&id)
                        .cloned();
                    if let Some(notification) = notification {
                        popup::show(&popups, &notification, expire_timeout);
                    }
                }
                UiMsg::Close(id) => popup::close(&popups, id),
                UiMsg::CloseAll => popup::close_all(&popups),
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
            // DBusInterfaceInfo wraps a raw pointer and isn't Send/Sync, so it
            // can't be captured from outside this (Send + Sync) closure --
            // parse it fresh here instead, which is cheap and only happens
            // once per bus-name acquisition. Both interfaces live in the one
            // document (see INTROSPECTION_XML's doc comment).
            let node_info = gio::DBusNodeInfo::for_xml(INTROSPECTION_XML)
                .expect("bad introspection xml");

            let notifications_info = node_info
                .lookup_interface(NOTIFICATIONS_INTERFACE)
                .expect("Notifications interface missing from introspection xml");
            let registration = {
                let state = state.clone();
                let ui_tx = ui_tx.clone();
                connection.register_object(
                    OBJECT_PATH,
                    &notifications_info,
                    move |_connection, sender, _object_path, _interface_name, method_name, parameters, invocation| {
                        handle_method_call(&state, &ui_tx, sender, method_name, &parameters, invocation);
                    },
                    |_, _, _, _, _| false.to_variant(),
                    |_, _, _, _, _, _| false,
                )
            };
            match registration {
                Ok(_id) => println!("notifyd: registered {NOTIFICATIONS_INTERFACE} on {DEV_BUS_NAME}"),
                Err(err) => eprintln!("notifyd: failed to register {NOTIFICATIONS_INTERFACE}: {err}"),
            }

            let control_info = node_info
                .lookup_interface(CONTROL_INTERFACE)
                .expect("Control interface missing from introspection xml");
            let control_registration = {
                let state = state.clone();
                let ui_tx = ui_tx.clone();
                connection.register_object(
                    OBJECT_PATH,
                    &control_info,
                    move |_connection, _sender, _object_path, _interface_name, method_name, parameters, invocation| {
                        handle_control_call(&state, &ui_tx, method_name, &parameters, invocation);
                    },
                    |_, _, _, _, _| false.to_variant(),
                    |_, _, _, _, _, _| false,
                )
            };
            match control_registration {
                Ok(_id) => println!("notifyd: registered {CONTROL_INTERFACE} on {DEV_BUS_NAME}"),
                Err(err) => eprintln!("notifyd: failed to register {CONTROL_INTERFACE}: {err}"),
            }
        },
        |_connection, name| println!("notifyd: acquired bus name {name}"),
        |_connection, name| eprintln!("notifyd: lost bus name {name} (already running?)"),
    );

    println!("notifyd: running as {DEV_BUS_NAME}, Ctrl+C to stop");
    main_loop.run();
}
