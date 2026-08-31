//! notifyd: owns the real `org.freedesktop.Notifications` bus name and does
//! all notification tracking / timeout / action-routing. Headless since
//! 2026-08-30 -- the GTK popup layer (old src/popup.rs) was replaced by
//! quickshell rendering (~/.config/quickshell/notifications/). notifyd now
//! writes the current popup set to ~/.cache/notifyd/state.json (see
//! render.rs) for quickshell to draw, and quickshell reports card clicks
//! back through the Control interface below (notifyctl invoke-action /
//! dismiss / close-all).
//!
//! Why not just use quickshell's own Quickshell.Services.Notifications: that
//! module fuses "the Notification object exists" with "the notification is
//! open" -- emitting NotificationClosed destroys the object, and you can't
//! invoke an action on a destroyed one. notifyd's whole point is that a
//! notification's actions stay invokable after it closes (dunst couldn't do
//! that). So notifyd keeps owning the bus; quickshell is just the renderer.
//!
//! The D-Bus method_call closures gio registers must be `Send + Sync` (its
//! binding requires it even though everything runs on one thread here), and
//! the render state is `Rc<RefCell<..>>` which isn't -- so the D-Bus side
//! only touches `state: SharedState` (Arc<Mutex<..>>, plain data) directly
//! and hands UI work to the glib-main-thread receiver via a channel.

mod config;
mod render;
mod state;

use config::Config;

use std::collections::HashMap;
use std::path::PathBuf;

use gio::prelude::*;

use notifyd::dbus_names::{BUS_NAME, CONTROL_INTERFACE, NOTIFICATIONS_INTERFACE, OBJECT_PATH};
use state::{AppState, Notification, SharedState};

/// NotificationClosed reason codes, per the freedesktop spec. `pub` so
/// render.rs can pass the right reason for each close path.
pub mod close_reason {
    pub const EXPIRED: u32 = 1;
    pub const DISMISSED: u32 = 2;
    pub const CLOSE_NOTIFICATION_CALLED: u32 = 3;
    #[allow(dead_code)]
    pub const UNDEFINED: u32 = 4;
}

/// Sent from the (Send + Sync) D-Bus callbacks to the glib-main-thread
/// receiver in `main()`. Carries ids, not full data -- the receiver
/// re-reads `state` so there's one source of truth.
enum UiMsg {
    Show { id: u32, urgency: u8, expire_timeout: i32 },
    /// A client's CloseNotification -- the signal is already emitted.
    Close(u32),
    /// quickshell middle-click on a card.
    Dismiss(u32),
    /// quickshell right-click, or `notifyctl close-all`.
    CloseAll,
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
  <interface name="org.hypr.notifyd1.Control">
    <!-- Invokes the resolved default action without needing a popup on
         screen: closing a notification here never invalidates it, unlike
         dunst/mako. id = 0 means "the most recently received". -->
    <method name="InvokeLastAction"/>
    <method name="InvokeAction">
      <arg type="u" name="id" direction="in"/>
    </method>
    <method name="InvokeActionByKey">
      <arg type="u" name="id" direction="in"/>
      <arg type="s" name="action_key" direction="in"/>
    </method>
    <!-- Drop one card without invoking anything (quickshell middle-click /
         `notifyctl dismiss`). Emits NotificationClosed(dismissed) but keeps
         the notification in history. -->
    <method name="DismissPopup">
      <arg type="u" name="id" direction="in"/>
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

fn cache_dir(sub: &str) -> PathBuf {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    home.join(".cache/notifyd").join(sub)
}

/// Resolve the icon Notify() gave us to something quickshell can load: a
/// themed icon name, an absolute path, or a PNG we wrote from an image-data
/// hint. Spec priority: image-data > image-path > app_icon > desktop-entry.
fn resolve_icon(id: u32, app_icon: &str, hints: &HashMap<String, glib::Variant>) -> String {
    for key in ["image-data", "image_data", "icon_data"] {
        if let Some(v) = hints.get(key) {
            if let Some(path) = decode_image_data(id, v) {
                return path;
            }
        }
    }
    if let Some(p) = hints.get("image-path").and_then(|v| v.get::<String>()) {
        if !p.is_empty() {
            return p;
        }
    }
    if !app_icon.is_empty() {
        return app_icon.to_string();
    }
    if let Some(de) = hints.get("desktop-entry").and_then(|v| v.get::<String>()) {
        if !de.is_empty() {
            return de;
        }
    }
    String::new()
}

/// The "large image" for a card, kept separate from the app/source icon:
/// rssd's private `x-rssd-image-path` hint, then the spec's `image-data` /
/// `image-path`. Returns "" when there's none. (`resolve_icon` is unchanged,
/// so an app that only sends image-data still gets it as its icon too; the
/// renderer skips this when it equals the icon.)
fn resolve_image(id: u32, hints: &HashMap<String, glib::Variant>) -> String {
    if let Some(p) = hints.get("x-rssd-image-path").and_then(|v| v.get::<String>()) {
        if !p.is_empty() {
            return p;
        }
    }
    for key in ["image-data", "image_data"] {
        if let Some(v) = hints.get(key) {
            if let Some(path) = decode_image_data(id, v) {
                return path;
            }
        }
    }
    if let Some(p) = hints.get("image-path").and_then(|v| v.get::<String>()) {
        if !p.is_empty() {
            return p;
        }
    }
    String::new()
}

/// Decode the spec's `(iiibiiay)` image-data hint (width, height, rowstride,
/// has_alpha, bits_per_sample, channels, data) to a PNG at
/// ~/.cache/notifyd/icons/<id>.png. Returns its path, or None if the hint
/// is malformed / an unsupported shape.
fn decode_image_data(id: u32, v: &glib::Variant) -> Option<String> {
    let (w, h, rowstride, _has_alpha, bits, channels, data): (
        i32,
        i32,
        i32,
        bool,
        i32,
        i32,
        Vec<u8>,
    ) = v.get()?;
    if w <= 0 || h <= 0 || rowstride <= 0 || bits != 8 || !(channels == 3 || channels == 4) {
        return None;
    }
    let (w, h, rowstride, channels) =
        (w as usize, h as usize, rowstride as usize, channels as usize);
    if rowstride < w * channels || data.len() < rowstride * (h - 1) + w * channels {
        return None;
    }

    let dir = cache_dir("icons");
    std::fs::create_dir_all(&dir).ok()?;
    let path = dir.join(format!("{id}.png"));
    let file = std::io::BufWriter::new(std::fs::File::create(&path).ok()?);

    let mut enc = png::Encoder::new(file, w as u32, h as u32);
    enc.set_color(if channels == 4 { png::ColorType::Rgba } else { png::ColorType::Rgb });
    enc.set_depth(png::BitDepth::Eight);
    let mut writer = enc.write_header().ok()?;

    let mut packed = Vec::with_capacity(w * h * channels);
    for row in 0..h {
        let start = row * rowstride;
        packed.extend_from_slice(&data[start..start + w * channels]);
    }
    writer.write_image_data(&packed).ok()?;
    drop(writer);

    Some(path.to_string_lossy().into_owned())
}

fn drop_icon_file(id: u32) {
    let _ = std::fs::remove_file(cache_dir("icons").join(format!("{id}.png")));
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
        .unwrap_or(1); // NORMAL

    let id = {
        let mut state = state.lock().expect("state mutex poisoned");
        let id = state.allocate_id(replaces_id);
        let icon = resolve_icon(id, &app_icon, &hints);
        // libnotify 0.8 sends `notify-send -i <path>` as the image-path hint,
        // which resolve_icon already used -- so drop image when it's just that
        // same file again (no distinct large image was supplied).
        let image = match resolve_image(id, &hints) {
            im if im == icon => String::new(),
            im => im,
        };
        let evicted = state.insert(Notification {
            id,
            sender: sender.to_string(),
            app_name: app_name.clone(),
            summary: summary.clone(),
            body: body.clone(),
            icon,
            image,
            actions: actions.clone(),
            urgency,
            timestamp: state::now_unix(),
        });
        drop(state);
        if let Some(old) = evicted {
            drop_icon_file(old);
        }
        id
    };

    println!(
        "Notify #{id} from {sender}: app={app_name:?} summary={summary:?} \
         actions={actions:?} urgency={urgency} timeout={expire_timeout}"
    );

    let _ = ui_tx.send(UiMsg::Show { id, urgency, expire_timeout });
    Some(id)
}

fn handle_close_notification(
    state: &SharedState,
    ui_tx: &glib::Sender<UiMsg>,
    config: &Config,
    parameters: &glib::Variant,
) -> Option<()> {
    let (id,): (u32,) = parameters.get()?;

    if config.ignore_dbusclose {
        return Some(());
    }

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

fn resolve_target_id(state: &SharedState, id: u32) -> Option<u32> {
    if id != 0 {
        Some(id)
    } else {
        state.lock().expect("state mutex poisoned").most_recent_id()
    }
}

/// Emits ActionInvoked for `id`, resolving to the default action if `key` is
/// None, or that exact key if it's one of the notification's actions.
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
        None => notification.default_action_key(),
    };
    let Some(key) = key else {
        return false;
    };
    if let Some(connection) = connection {
        emit_action_invoked(&connection, id, key);
    }
    true
}

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
    for (key, label) in notification.action_pairs() {
        out.push_str(key);
        out.push('\t');
        out.push_str(label);
        out.push('\n');
    }
    out
}

/// Newest first, matching `dunstctl history`.
fn list_history_json(state: &SharedState) -> String {
    let state = state.lock().expect("state mutex poisoned");
    let mut items: Vec<&Notification> = state.notifications.values().collect();
    items.sort_by(|a, b| b.timestamp.cmp(&a.timestamp).then(b.id.cmp(&a.id)));

    let json: Vec<serde_json::Value> = items
        .iter()
        .map(|n| {
            let actions: Vec<serde_json::Value> = n
                .action_pairs()
                .map(|(key, label)| serde_json::json!({ "key": key, "label": label }))
                .collect();
            serde_json::json!({
                "id": n.id,
                "sender": n.sender,
                "app_name": n.app_name,
                "summary": n.summary,
                "body": n.body,
                "icon": n.icon,
                "image": n.image,
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
        "DismissPopup" => {
            let Some((id,)): Option<(u32,)> = parameters.get() else {
                invocation.return_dbus_error(
                    "org.freedesktop.DBus.Error.InvalidArgs",
                    "DismissPopup: unexpected argument shape",
                );
                return;
            };
            let _ = ui_tx.send(UiMsg::Dismiss(id));
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
    config: &Config,
    sender: &str,
    method_name: &str,
    parameters: &glib::Variant,
    invocation: gio::DBusMethodInvocation,
) {
    match method_name {
        "GetCapabilities" => {
            let caps: Vec<&str> = vec!["body", "body-markup", "actions", "icon-static"];
            invocation.return_value(Some(&(caps,).to_variant()));
        }
        "GetServerInformation" => {
            let info = ("notifyd", "hypr", "0.2.0", "1.2");
            invocation.return_value(Some(&info.to_variant()));
        }
        "Notify" => match handle_notify(state, ui_tx, sender, parameters) {
            Some(id) => invocation.return_value(Some(&(id,).to_variant())),
            None => invocation.return_dbus_error(
                "org.freedesktop.DBus.Error.InvalidArgs",
                "Notify: unexpected argument shape",
            ),
        },
        "CloseNotification" => match handle_close_notification(state, ui_tx, config, parameters) {
            Some(()) => invocation.return_value(None),
            None => invocation.return_dbus_error(
                "org.freedesktop.DBus.Error.InvalidArgs",
                "CloseNotification: unexpected argument shape",
            ),
        },
        other => {
            invocation.return_dbus_error(
                "org.freedesktop.DBus.Error.UnknownMethod",
                &format!("notifyd: method {other} not implemented"),
            );
        }
    }
}

fn main() {
    let main_loop = glib::MainLoop::new(None, false);
    let config = Config::load();
    let config_arc = std::sync::Arc::new(config.clone());
    let state: SharedState =
        std::sync::Arc::new(std::sync::Mutex::new(AppState::new(config.history_length)));

    // Fresh start: no leftover cards / icons from a previous run.
    let _ = std::fs::remove_dir_all(cache_dir("icons"));
    if let Some(dir) = render::state_path().parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let _ = std::fs::write(render::state_path(), "{\"popups\":[]}");

    let render = render::new_manager(config, state.clone(), {
        let state = state.clone();
        move |id, reason| {
            let connection = state.lock().expect("state mutex poisoned").connection.clone();
            if let Some(connection) = connection {
                emit_notification_closed(&connection, id, reason);
            }
        }
    });

    let (ui_tx, ui_rx) = glib::MainContext::channel::<UiMsg>(glib::Priority::DEFAULT);

    {
        let state = state.clone();
        let render = render.clone();
        ui_rx.attach(None, move |msg| {
            match msg {
                UiMsg::Show { id, urgency, expire_timeout } => {
                    let exists = state
                        .lock()
                        .expect("state mutex poisoned")
                        .notifications
                        .contains_key(&id);
                    if exists {
                        render::show(&render, id, urgency, expire_timeout);
                    }
                }
                UiMsg::Close(id) => render::close_silent(&render, id),
                UiMsg::Dismiss(id) => render::fire_close(&render, id, close_reason::DISMISSED),
                UiMsg::CloseAll => render::close_all(&render, close_reason::DISMISSED),
            }
            glib::ControlFlow::Continue
        });
    }

    let _owner_id = gio::bus_own_name(
        gio::BusType::Session,
        BUS_NAME,
        gio::BusNameOwnerFlags::NONE,
        move |connection, _name| {
            state.lock().expect("state mutex poisoned").connection = Some(connection.clone());

            let node_info =
                gio::DBusNodeInfo::for_xml(INTROSPECTION_XML).expect("bad introspection xml");

            let notifications_info = node_info
                .lookup_interface(NOTIFICATIONS_INTERFACE)
                .expect("Notifications interface missing from introspection xml");
            let registration = {
                let state = state.clone();
                let ui_tx = ui_tx.clone();
                let config_arc = config_arc.clone();
                connection.register_object(
                    OBJECT_PATH,
                    &notifications_info,
                    move |_connection, sender, _object_path, _interface_name, method_name, parameters, invocation| {
                        handle_method_call(&state, &ui_tx, &config_arc, sender, method_name, &parameters, invocation);
                    },
                    |_, _, _, _, _| false.to_variant(),
                    |_, _, _, _, _, _| false,
                )
            };
            match registration {
                Ok(_id) => println!("notifyd: registered {NOTIFICATIONS_INTERFACE} on {BUS_NAME}"),
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
                Ok(_id) => println!("notifyd: registered {CONTROL_INTERFACE} on {BUS_NAME}"),
                Err(err) => eprintln!("notifyd: failed to register {CONTROL_INTERFACE}: {err}"),
            }
        },
        |_connection, name| println!("notifyd: acquired bus name {name}"),
        |_connection, name| eprintln!("notifyd: lost bus name {name} (already running?)"),
    );

    println!("notifyd: running headless as {BUS_NAME}, Ctrl+C to stop");
    main_loop.run();
}
