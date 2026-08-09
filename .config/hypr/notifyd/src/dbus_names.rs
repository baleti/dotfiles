//! Bus/path/interface names shared between the `notifyd` binary and the
//! `notifyctl` CLI. Deliberately tiny and GTK-free (unlike `state`/`popup`,
//! which stay private to the `notifyd` binary) so `notifyctl` doesn't need
//! to link GTK just to know what to call.

/// The well-known bus name notifyd owns. Real `org.freedesktop.Notifications`
/// as of the Phase 10 cutover -- Phases 1-9 developed against a throwaway
/// `com.notifyd.Dev` name instead, precisely so dunst could keep serving
/// real notifications untouched until everything up to this point was
/// verified working.
pub const BUS_NAME: &str = NOTIFICATIONS_INTERFACE;
pub const OBJECT_PATH: &str = "/org/freedesktop/Notifications";
pub const NOTIFICATIONS_INTERFACE: &str = "org.freedesktop.Notifications";
/// notifyd's own control interface, registered on the same object path
/// alongside `NOTIFICATIONS_INTERFACE` -- mirrors dunst's
/// `org.dunstproject.cmd0` sitting next to the spec interface, but
/// namespaced to this project rather than a dunst fork.
pub const CONTROL_INTERFACE: &str = "org.hypr.notifyd1.Control";
