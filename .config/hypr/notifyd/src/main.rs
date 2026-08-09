//! notifyd: dev-bus skeleton (Phase 1 of the plan in
//! ~/.claude2/plans/silly-percolating-rose.md).
//!
//! Owns a throwaway bus name so real notification traffic keeps flowing to
//! dunst untouched during development. Implements just enough of
//! org.freedesktop.Notifications to prove the D-Bus mechanics work end to
//! end: GetCapabilities, GetServerInformation, Notify (id counter + log
//! only). No popup rendering yet -- that's Phase 3. Full Notify argument
//! handling, CloseNotification, and the NotificationClosed/ActionInvoked
//! signals are Phase 2.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;

use gio::prelude::*;

const DEV_BUS_NAME: &str = "com.notifyd.Dev";
const OBJECT_PATH: &str = "/org/freedesktop/Notifications";
const INTERFACE_NAME: &str = "org.freedesktop.Notifications";

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
    <method name="GetServerInformation">
      <arg type="s" name="name" direction="out"/>
      <arg type="s" name="vendor" direction="out"/>
      <arg type="s" name="version" direction="out"/>
      <arg type="s" name="spec_version" direction="out"/>
    </method>
  </interface>
</node>
"#;

fn handle_method_call(
    next_id: &Arc<AtomicU32>,
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
        "Notify" => {
            let (app_name, replaces_id, app_icon, summary, body, actions, hints, expire_timeout): (
                String,
                u32,
                String,
                String,
                String,
                Vec<String>,
                HashMap<String, glib::Variant>,
                i32,
            ) = match parameters.get() {
                Some(args) => args,
                None => {
                    invocation.return_dbus_error(
                        "org.freedesktop.DBus.Error.InvalidArgs",
                        "Notify: unexpected argument shape",
                    );
                    return;
                }
            };

            let id = if replaces_id != 0 {
                replaces_id
            } else {
                next_id.fetch_add(1, Ordering::SeqCst)
            };

            println!(
                "Notify #{id} from {sender}: app={app_name:?} icon={app_icon:?} \
                 summary={summary:?} body={body:?} actions={actions:?} \
                 hints={} timeout={expire_timeout}",
                hints.len()
            );

            invocation.return_value(Some(&(id,).to_variant()));
        }
        other => {
            invocation.return_dbus_error(
                "org.freedesktop.DBus.Error.UnknownMethod",
                &format!("notifyd: method {other} not implemented yet"),
            );
        }
    }
}

fn main() {
    let main_loop = glib::MainLoop::new(None, false);
    let next_id = Arc::new(AtomicU32::new(1));

    let _owner_id = gio::bus_own_name(
        gio::BusType::Session,
        DEV_BUS_NAME,
        gio::BusNameOwnerFlags::NONE,
        move |connection, _name| {
            let next_id = next_id.clone();
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
                    handle_method_call(&next_id, sender, method_name, &parameters, invocation);
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

    println!("notifyd: dev skeleton running as {DEV_BUS_NAME}, Ctrl+C to stop");
    main_loop.run();
}
