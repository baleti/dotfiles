//! Bus/path/interface names shared between the `notifyd` binary and the
//! `notifyctl` CLI. Deliberately tiny and GTK-free (unlike `state`/`popup`,
//! which stay private to the `notifyd` binary) so `notifyctl` doesn't need
//! to link GTK just to know what to call.

/// Throwaway bus name for development (see the plan doc) -- Phase 10
/// switches this to the real `org.freedesktop.Notifications`.
pub const DEV_BUS_NAME: &str = "com.notifyd.Dev";
pub const OBJECT_PATH: &str = "/org/freedesktop/Notifications";
pub const NOTIFICATIONS_INTERFACE: &str = "org.freedesktop.Notifications";
/// notifyd's own control interface, registered on the same object path
/// alongside `NOTIFICATIONS_INTERFACE` -- mirrors dunst's
/// `org.dunstproject.cmd0` sitting next to the spec interface, but
/// namespaced to this project rather than a dunst fork.
pub const CONTROL_INTERFACE: &str = "org.hypr.notifyd1.Control";
