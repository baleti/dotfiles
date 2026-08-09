//! notifyctl: control CLI for notifyd's org.hypr.notifyd1.Control
//! interface (see main.rs's INTROSPECTION_XML for the full method list).
//! Deliberately no CLI-parsing crate -- the surface is six fixed
//! subcommands, matching the plain `std::env::args()` style already used
//! by clipboard-picker/notification-picker in this same dotfiles setup.

use gio::prelude::*;
use notifyd::dbus_names::{CONTROL_INTERFACE, DEV_BUS_NAME, OBJECT_PATH};

fn usage() -> ! {
    eprintln!(
        "usage: notifyctl <invoke-last | invoke ID | invoke-action ID KEY | actions [ID] | list | close-all>"
    );
    std::process::exit(2);
}

fn connect() -> gio::DBusConnection {
    gio::bus_get_sync(gio::BusType::Session, gio::Cancellable::NONE).unwrap_or_else(|err| {
        eprintln!("notifyctl: failed to connect to the session bus: {err}");
        std::process::exit(1);
    })
}

/// Calls a Control method with no reply payload beyond the empty tuple.
fn call_unit(connection: &gio::DBusConnection, method: &str, args: Option<&glib::Variant>) {
    if let Err(err) = connection.call_sync(
        Some(DEV_BUS_NAME),
        OBJECT_PATH,
        CONTROL_INTERFACE,
        method,
        args,
        None,
        gio::DBusCallFlags::NONE,
        -1,
        gio::Cancellable::NONE,
    ) {
        eprintln!("notifyctl: {method} failed: {err}");
        std::process::exit(1);
    }
}

/// Calls a Control method that replies with a single string, and prints it.
fn call_string(connection: &gio::DBusConnection, method: &str, args: Option<&glib::Variant>) {
    match connection.call_sync(
        Some(DEV_BUS_NAME),
        OBJECT_PATH,
        CONTROL_INTERFACE,
        method,
        args,
        Some(glib::VariantTy::new("(s)").expect("valid variant type")),
        gio::DBusCallFlags::NONE,
        -1,
        gio::Cancellable::NONE,
    ) {
        Ok(reply) => {
            let (text,): (String,) = reply.get().expect("Control methods always reply (s)");
            print!("{text}");
        }
        Err(err) => {
            eprintln!("notifyctl: {method} failed: {err}");
            std::process::exit(1);
        }
    }
}

fn parse_id(s: &str) -> u32 {
    s.parse().unwrap_or_else(|_| {
        eprintln!("notifyctl: {s:?} is not a valid notification id");
        std::process::exit(2);
    })
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let connection = connect();

    match args.first().map(String::as_str) {
        Some("invoke-last") if args.len() == 1 => {
            call_unit(&connection, "InvokeLastAction", None);
        }
        Some("invoke") if args.len() == 2 => {
            let id = parse_id(&args[1]);
            call_unit(&connection, "InvokeAction", Some(&(id,).to_variant()));
        }
        Some("invoke-action") if args.len() == 3 => {
            let id = parse_id(&args[1]);
            call_unit(&connection, "InvokeActionByKey", Some(&(id, args[2].as_str()).to_variant()));
        }
        Some("actions") if args.len() <= 2 => {
            let id: u32 = args.get(1).map(|s| parse_id(s)).unwrap_or(0);
            call_string(&connection, "Actions", Some(&(id,).to_variant()));
        }
        Some("list") if args.len() == 1 => {
            call_string(&connection, "ListHistory", None);
            println!();
        }
        Some("close-all") if args.len() == 1 => {
            call_unit(&connection, "CloseAll", None);
        }
        _ => usage(),
    }
}
