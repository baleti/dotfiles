//! GTK3 + gtk-layer-shell popup rendering (Phase 3).
//!
//! Deliberately one independent layer-shell surface per notification,
//! stacked by adjusting each window's top margin, rather than dunst's
//! literal approach of one tall surface with internal separators (dunstrc's
//! `gap_size = 0` mode). Visually near-identical -- stacked cards in the
//! corner -- and much simpler: each card just reuses GTK's normal
//! size-negotiation instead of one widget managing N notifications' layout
//! by hand. `GAP` below reuses dunstrc's `separator_height` value as the
//! spacing between cards, and each card's border reuses `frame_width`/
//! `frame_color`, so the two modes read the same even though the
//! implementation differs.
//!
//! This module only knows about GTK/rendering, not D-Bus or `AppState` --
//! `main.rs` wires the two together (e.g. the `on_expired` callback passed
//! to `show()` is what actually removes the notification from `AppState`
//! and emits `NotificationClosed`).

use std::cell::RefCell;
use std::collections::HashMap;
use std::process::Command;
use std::rc::Rc;
use std::time::Duration;

use gdk_pixbuf::Pixbuf;
use gtk::prelude::*;
use gtk_layer_shell::{Edge, KeyboardMode, Layer, LayerShell};

use crate::state::Notification;

const WIDTH: i32 = 300; // dunstrc: width
const MAX_HEIGHT: i32 = 300; // dunstrc: height = (0, 300)
const OFFSET_X: i32 = 10; // dunstrc: offset = (10, 50), origin = top-right
const OFFSET_Y: i32 = 50;
const GAP: i32 = 2; // dunstrc: separator_height
const FALLBACK_HEIGHT: i32 = 60; // stacking estimate before first size-allocate

// dunstrc: format = "<b>%s</b>\n%b". %c/%S/%i/%I/%p/%n (category, stack_tag,
// icon name with/without path, progress) are deferred along with the
// features that would ever populate them (progress bar, stack_tag) -- see
// the plan's dunstrc disposition table. Left as literal text if they ever
// appear, which they won't with the hardcoded format above.
const FORMAT: &str = "<b>%s</b>\n%b";

// dunstrc: icon_theme, icon_path, default_icon (per urgency section).
const ICON_THEME_NAME: &str = "Adwaita";
const ICON_SEARCH_PATHS: &[&str] = &[
    "/usr/share/icons/gnome/16x16/status",
    "/usr/share/icons/gnome/16x16/devices",
];
// dunstrc's min_icon_size/max_icon_size (32/128) describe a clamp -- scale
// small icons up to 32, large ones down to 128, otherwise leave native size.
// This just requests a fixed 32px: this user's icon_path points at 16x16
// theme dirs, so in practice icons almost always hit the "scale up to
// min_icon_size" branch anyway, and a fixed size keeps card layout simple.
const ICON_SIZE: i32 = 32;

const CSS: &str = "
.notifyd-card {
    padding: 8px;
    border: 3px solid #aaaaaa; /* dunstrc: frame_width, frame_color */
}
.notifyd-card.urgency-low { background-color: #222222; color: #888888; }
.notifyd-card.urgency-normal { background-color: #285577; color: #ffffff; }
.notifyd-card.urgency-critical { background-color: #900000; color: #ffffff; border-color: #ff0000; }
";

struct Popup {
    window: gtk::Window,
    label: gtk::Label,
    icon: gtk::Image,
    last_height: i32,
    timeout_source: Option<glib::SourceId>,
}

pub struct PopupManager {
    popups: HashMap<u32, Popup>,
    /// Front = newest = closest to the screen edge.
    order: Vec<u32>,
}

pub type SharedPopups = Rc<RefCell<PopupManager>>;

pub fn new_manager() -> SharedPopups {
    Rc::new(RefCell::new(PopupManager {
        popups: HashMap::new(),
        order: Vec::new(),
    }))
}

fn urgency_class(urgency: u8) -> &'static str {
    match urgency {
        0 => "urgency-low",
        2 => "urgency-critical",
        _ => "urgency-normal",
    }
}

/// dunstrc: urgency_low/normal timeout = 10s, urgency_critical timeout = 0
/// (sticky). `expire_timeout` is the Notify() argument: >0 is an explicit
/// override in milliseconds, 0 means never expire, -1 means "daemon default".
fn timeout_ms(urgency: u8, expire_timeout: i32) -> Option<u32> {
    match expire_timeout {
        t if t > 0 => Some(t as u32),
        0 => None,
        _ => {
            if urgency == 2 {
                None
            } else {
                Some(10_000)
            }
        }
    }
}

/// Plain-text fallback for when `format_markup`'s output fails to parse as
/// Pango markup (e.g. a client sent a malformed body-markup tag).
fn body_text(notification: &Notification) -> String {
    if notification.body.is_empty() {
        notification.summary.clone()
    } else {
        format!("{}\n{}", notification.summary, notification.body)
    }
}

/// Expands dunstrc's `format = "<b>%s</b>\n%b"` against a notification.
/// `%s`/`%a` (summary/app name) are escaped since the spec treats them as
/// plain text; `%b` (body) is passed through unescaped since the spec
/// allows clients to put markup there directly and we advertise the
/// `body-markup` capability -- the whole result is validated as one markup
/// blob by the caller before it's trusted.
fn format_markup(notification: &Notification) -> String {
    let mut out = String::new();
    let mut chars = FORMAT.chars();
    while let Some(c) = chars.next() {
        if c != '%' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('a') => out.push_str(&glib::markup_escape_text(&notification.app_name)),
            Some('s') => out.push_str(&glib::markup_escape_text(&notification.summary)),
            Some('b') => out.push_str(&notification.body),
            Some('%') => out.push('%'),
            Some(other) => {
                out.push('%');
                out.push(other);
            }
            None => out.push('%'),
        }
    }
    out
}

/// Applies `format_markup`'s output as Pango markup, falling back to plain
/// text (dropping all markup, including our own `<b>` wrapper) if a
/// client's body-markup didn't parse -- a malformed notification body must
/// never be allowed to just not render.
fn set_card_text(label: &gtk::Label, notification: &Notification) {
    let markup = format_markup(notification);
    if pango::parse_markup(&markup, '\0').is_ok() {
        label.set_markup(&markup);
    } else {
        label.set_text(&body_text(notification));
    }
}

fn default_icon_name(urgency: u8) -> &'static str {
    if urgency == 2 {
        "dialog-warning" // dunstrc: [urgency_critical] default_icon
    } else {
        "dialog-information" // dunstrc: [urgency_low]/[urgency_normal] default_icon
    }
}

thread_local! {
    // GTK asserts if `set_custom_theme` is called on the shared
    // `IconTheme::default()` singleton ("is_screen_singleton" in the
    // GTK-CRITICAL it raises) -- dunstrc's `icon_theme = Adwaita` override
    // needs a theme we constructed ourselves instead. One instance reused
    // for the process lifetime rather than rebuilt (and re-searching its
    // path list) on every icon load.
    static ICON_THEME: gtk::IconTheme = {
        let theme = gtk::IconTheme::new();
        theme.set_custom_theme(Some(ICON_THEME_NAME));
        for search_path in ICON_SEARCH_PATHS {
            theme.append_search_path(search_path);
        }
        theme
    };
}

/// `app_icon`/`image-path` can be a themed icon name or an absolute path
/// (optionally `file://`-prefixed); falls back to the urgency's
/// `default_icon` if neither Notify() gave us anything to show.
fn load_icon(icon: &str, urgency: u8) -> Option<Pixbuf> {
    let icon = if icon.is_empty() {
        default_icon_name(urgency)
    } else {
        icon
    };

    let path = icon.strip_prefix("file://").unwrap_or(icon);
    if path.starts_with('/') {
        return Pixbuf::from_file_at_scale(path, ICON_SIZE, ICON_SIZE, true).ok();
    }

    ICON_THEME.with(|theme| {
        theme
            .load_icon(icon, ICON_SIZE, gtk::IconLookupFlags::FORCE_SIZE)
            .ok()
            .flatten()
    })
}

/// Recomputes every popup's top margin from `order`, front-to-back.
fn reflow(popups: &SharedPopups) {
    let manager = popups.borrow();
    let mut y = OFFSET_Y;
    for id in &manager.order {
        if let Some(popup) = manager.popups.get(id) {
            popup.window.set_layer_shell_margin(Edge::Top, y);
            let height = if popup.last_height > 0 {
                popup.last_height
            } else {
                FALLBACK_HEIGHT
            };
            y += height + GAP;
        }
    }
}

/// The monitor Hyprland considers focused -- dunstrc's `follow = mouse`
/// resolves to this too on Wayland (per its own comment: "mouse and
/// keyboard are equivalent: the compositor picks the output it last saw
/// interaction on"). Ported from clipboard-picker/src/picker.rs, which
/// solved the same problem for the picker windows.
fn target_monitor(display: &gdk::Display) -> Option<gdk::Monitor> {
    let focused = (|| {
        let out = Command::new("hyprctl").args(["-j", "monitors"]).output().ok()?;
        let v: serde_json::Value = serde_json::from_slice(&out.stdout).ok()?;
        for m in v.as_array()? {
            if m.get("focused")?.as_bool() == Some(true) {
                return Some((m.get("x")?.as_i64()? as i32, m.get("y")?.as_i64()? as i32));
            }
        }
        None
    })();

    if let Some((fx, fy)) = focused {
        for i in 0..display.n_monitors() {
            if let Some(mon) = display.monitor(i) {
                let g = mon.geometry();
                if g.x() == fx && g.y() == fy {
                    return Some(mon);
                }
            }
        }
    }

    display.monitor(0)
}

fn build_window() -> gtk::Window {
    let window = gtk::Window::new(gtk::WindowType::Toplevel);
    window.init_layer_shell();
    window.set_layer(Layer::Overlay);
    // Notifications must never steal keyboard focus from whatever the user
    // is doing.
    window.set_keyboard_mode(KeyboardMode::None);
    window.set_anchor(Edge::Top, true);
    window.set_anchor(Edge::Right, true);
    window.set_layer_shell_margin(Edge::Right, OFFSET_X);
    window.set_layer_shell_margin(Edge::Top, OFFSET_Y);
    window.set_size_request(WIDTH, -1);
    if let Some(display) = gdk::Display::default() {
        if let Some(monitor) = target_monitor(&display) {
            window.set_monitor(&monitor);
        }
    }

    let provider = gtk::CssProvider::new();
    let _ = provider.load_from_data(CSS.as_bytes());
    window
        .style_context()
        .add_provider(&provider, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
    window.style_context().add_class("notifyd-card");

    window
}

/// Shows a new notification, or updates an already-displayed one in place
/// if `notification.id` matches (the spec's `replaces_id` mechanism) --
/// same position, refreshed content and timeout.
///
/// `on_expired(id)` is called (from the main loop, not synchronously) when
/// this card's timeout elapses on its own, i.e. via nothing but the passage
/// of time -- never for an explicit close. It's the caller's job to remove
/// the notification from `AppState` and emit `NotificationClosed(id,
/// EXPIRED)`; this module has no idea `AppState` exists.
pub fn show(
    popups: &SharedPopups,
    notification: &Notification,
    expire_timeout: i32,
    on_expired: impl Fn(u32) + 'static,
) {
    {
        let mut manager = popups.borrow_mut();
        if let Some(existing) = manager.popups.get_mut(&notification.id) {
            set_card_text(&existing.label, notification);
            if let Some(pixbuf) = load_icon(&notification.icon, notification.urgency) {
                existing.icon.set_from_pixbuf(Some(&pixbuf));
                existing.icon.show();
            } else {
                existing.icon.hide();
            }
            existing
                .window
                .style_context()
                .add_class(urgency_class(notification.urgency));
            if let Some(src) = existing.timeout_source.take() {
                src.remove();
            }
            existing.timeout_source = arm_timeout(popups, notification.id, notification.urgency, expire_timeout, on_expired);
            return;
        }
    }

    let window = build_window();
    window
        .style_context()
        .add_class(urgency_class(notification.urgency));

    let label = gtk::Label::new(None);
    set_card_text(&label, notification);
    label.set_xalign(0.0);
    label.set_line_wrap(true);
    label.set_max_width_chars(1); // let wrapping kick in rather than growing the window

    let scroll = gtk::ScrolledWindow::new(gtk::Adjustment::NONE, gtk::Adjustment::NONE);
    scroll.set_policy(gtk::PolicyType::Never, gtk::PolicyType::Automatic);
    scroll.set_propagate_natural_height(true);
    scroll.set_max_content_height(MAX_HEIGHT);
    scroll.add(&label);

    // dunstrc: icon_position = left
    let icon = gtk::Image::new();
    icon.set_valign(gtk::Align::Start);
    if let Some(pixbuf) = load_icon(&notification.icon, notification.urgency) {
        icon.set_from_pixbuf(Some(&pixbuf));
    } else {
        icon.hide();
    }

    // dunstrc: text_icon_padding = 0, but that reads as the icon touching the
    // text with no breathing room at all -- reusing horizontal_padding's
    // value (8) instead looks right.
    let hbox = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    hbox.pack_start(&icon, false, false, 0);
    hbox.pack_start(&scroll, true, true, 0);
    window.add(&hbox);

    let id = notification.id;
    {
        let popups = popups.clone();
        window.connect_size_allocate(move |_win, alloc| {
            let mut manager = popups.borrow_mut();
            let changed = manager
                .popups
                .get_mut(&id)
                .map(|popup| {
                    let changed = popup.last_height != alloc.height();
                    popup.last_height = alloc.height();
                    changed
                })
                .unwrap_or(false);
            drop(manager);
            if changed {
                reflow(&popups);
            }
        });
    }

    window.show_all();

    let timeout_source = arm_timeout(popups, id, notification.urgency, expire_timeout, on_expired);

    {
        let mut manager = popups.borrow_mut();
        manager.popups.insert(
            id,
            Popup {
                window,
                label,
                icon,
                last_height: 0,
                timeout_source,
            },
        );
        manager.order.insert(0, id);
    }

    reflow(popups);
}

fn arm_timeout(
    popups: &SharedPopups,
    id: u32,
    urgency: u8,
    expire_timeout: i32,
    on_expired: impl Fn(u32) + 'static,
) -> Option<glib::SourceId> {
    let ms = timeout_ms(urgency, expire_timeout)?;
    let popups = popups.clone();
    Some(glib::timeout_add_local(
        Duration::from_millis(ms as u64),
        move || {
            // Clear our own handle first: we're already unregistering by
            // returning Break below, so `close()`'s SourceId::remove() must
            // not also try to remove us -- that would double-remove a
            // source mid-callback.
            if let Some(popup) = popups.borrow_mut().popups.get_mut(&id) {
                popup.timeout_source = None;
            }
            on_expired(id);
            glib::ControlFlow::Break
        },
    ))
}

/// Closes and removes a popup (explicit CloseNotification, or a future
/// mouse-close in Phase 5). A no-op if `id` isn't currently displayed --
/// callers don't need to check first.
pub fn close(popups: &SharedPopups, id: u32) {
    {
        let mut manager = popups.borrow_mut();
        if let Some(popup) = manager.popups.remove(&id) {
            if let Some(src) = popup.timeout_source {
                src.remove();
            }
            popup.window.close();
        }
        manager.order.retain(|&x| x != id);
    }
    reflow(popups);
}
