//! The grid overlay itself: a layer-shell surface holding a `GtkFlowBox` of
//! window thumbnails (icon placeholders for now -- live captures land in
//! phase 4). Two-phase key state machine: while unlocked, Tab/Shift+Tab
//! (typed directly, or forwarded over the socket from a later Alt+Tab press
//! while this instance is already open) cycles the selection and releasing
//! Alt confirms it; pressing any other printable key locks the grid into
//! search mode (a `GtkSearchEntry` filters the grid -- substring match for
//! now, the `$column:value` DSL from `query.rs`), Alt no longer
//! confirms once locked, and Enter/Escape confirm/cancel in either mode.

use std::cell::RefCell;
use std::io::Read;
use std::os::unix::io::AsRawFd;
use std::os::unix::net::UnixListener;
use std::rc::Rc;

use gtk::prelude::*;
use gtk_layer_shell::LayerShell;

use crate::hyprctl::{self, Window};

const ICON_SIZE: i32 = 96;
const CELL_WIDTH: i32 = 180;

struct State {
    windows: Vec<Window>,
    selected: RefCell<usize>,
    locked: RefCell<bool>,
}

fn lookup_icon(class: &str) -> gdk_pixbuf::Pixbuf {
    let theme = gtk::IconTheme::default();
    let candidates = [class.to_string(), class.to_lowercase()];
    if let Some(theme) = &theme {
        for name in &candidates {
            if let Some(pb) = theme
                .load_icon(name, ICON_SIZE, gtk::IconLookupFlags::FORCE_SIZE)
                .ok()
                .flatten()
            {
                return pb;
            }
        }
        if let Some(pb) = theme
            .load_icon(
                "application-x-executable",
                ICON_SIZE,
                gtk::IconLookupFlags::FORCE_SIZE,
            )
            .ok()
            .flatten()
        {
            return pb;
        }
    }
    // Last-resort blank pixbuf so callers never have to handle a missing icon.
    gdk_pixbuf::Pixbuf::new(gdk_pixbuf::Colorspace::Rgb, true, 8, ICON_SIZE, ICON_SIZE)
        .expect("blank pixbuf")
}

/// Returns the child alongside its thumbnail `Image` so callers can swap in
/// a live capture later (`wayland_capture::start`'s `on_thumbnail`
/// callback) without having to dig back through the widget tree.
fn make_child(win: &Window) -> (gtk::FlowBoxChild, gtk::Image) {
    let vbox = gtk::Box::new(gtk::Orientation::Vertical, 6);
    vbox.set_size_request(CELL_WIDTH, -1);

    let image = gtk::Image::from_pixbuf(Some(&lookup_icon(&win.class)));
    image.set_halign(gtk::Align::Center);
    vbox.pack_start(&image, false, false, 0);

    let label_text = if win.title.is_empty() {
        win.class.clone()
    } else {
        win.title.clone()
    };
    let label = gtk::Label::new(Some(&label_text));
    label.set_ellipsize(gtk::pango::EllipsizeMode::End);
    label.set_max_width_chars(1); // let ellipsize kick in early, as in picker.rs
    label.set_lines(2);
    label.set_justify(gtk::Justification::Center);
    vbox.pack_start(&label, false, false, 0);

    let child = gtk::FlowBoxChild::new();
    child.add(&vbox);
    child.set_margin(8);
    child.show_all();
    (child, image)
}

/// The monitor Hyprland considers active. Duplicated from
/// clipboard-picker/src/picker.rs's `target_monitor` -- this crate shares no
/// other machinery with that one (different widget, different key state
/// machine), so pulling in a cross-crate dependency for ~35 lines isn't
/// worth it.
fn target_monitor(display: &gdk::Display) -> Option<gdk::Monitor> {
    let focused = (|| {
        let out = std::process::Command::new("hyprctl")
            .args(["-j", "monitors"])
            .output()
            .ok()?;
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

fn select(flowbox: &gtk::FlowBox, state: &Rc<State>, idx: usize) {
    let n = state.windows.len();
    if n == 0 {
        return;
    }
    let idx = idx % n;
    *state.selected.borrow_mut() = idx;
    if let Some(child) = flowbox.child_at_index(idx as i32) {
        flowbox.select_child(&child);
        child.grab_focus();
    }
}

/// Hides the surface first and defers the actual `focuswindow` dispatch to
/// the next glib idle tick. Dispatching while our layer-shell surface still
/// holds exclusive keyboard mode is a no-op in practice -- Hyprland restores
/// focus to whatever was active before us as soon as the surface goes away,
/// silently overriding a focus dispatch issued beforehand (confirmed by a
/// live before/after test: `hl.dsp.focus` reported "ok" but `activewindow`
/// never changed while the surface was still up). Hiding first and letting
/// one mainloop iteration flush that to the compositor before dispatching
/// fixes it.
fn confirm(win: &gtk::Window, state: &Rc<State>) {
    let idx = *state.selected.borrow();
    let address = state.windows.get(idx).map(|w| w.address.clone());
    win.hide();
    glib::source::idle_add_local(move || {
        if let Some(addr) = &address {
            hyprctl::focus_window(addr);
        }
        gtk::main_quit();
        glib::ControlFlow::Break
    });
}

/// `initial_cmd` is "next" or "prev": the direction implied by whichever
/// bind (Alt+Tab / Alt+Shift+Tab) actually launched us, applied once before
/// the first frame so a single tap lands on the previously active window
/// (classic alt-tab behaviour), not the currently focused one.
pub fn run(listener: UnixListener, initial_cmd: &str) {
    let windows = hyprctl::list_windows();
    if windows.is_empty() {
        return;
    }

    if gtk::init().is_err() {
        eprintln!("winswitch: failed to initialise GTK");
        std::process::exit(1);
    }

    let state = Rc::new(State {
        windows,
        selected: RefCell::new(0),
        locked: RefCell::new(false),
    });

    let win = gtk::Window::new(gtk::WindowType::Toplevel);
    win.init_layer_shell();
    win.set_layer(gtk_layer_shell::Layer::Overlay);
    win.set_keyboard_mode(gtk_layer_shell::KeyboardMode::Exclusive);

    if let Some(display) = gdk::Display::default() {
        if let Some(mon) = target_monitor(&display) {
            win.set_monitor(&mon);
            let g = mon.geometry();
            win.set_size_request((g.width() as f64 * 0.7) as i32, (g.height() as f64 * 0.6) as i32);
        }
    }

    let flowbox = gtk::FlowBox::new();
    flowbox.set_selection_mode(gtk::SelectionMode::Single);
    flowbox.set_homogeneous(true);
    flowbox.set_valign(gtk::Align::Start);
    flowbox.set_max_children_per_line(8);
    flowbox.set_min_children_per_line(1);
    flowbox.set_row_spacing(4);
    flowbox.set_column_spacing(4);

    let mut thumb_images = Vec::with_capacity(state.windows.len());
    for win_entry in &state.windows {
        let (child, image) = make_child(win_entry);
        flowbox.add(&child);
        thumb_images.push(image);
    }

    // Live captures stream in asynchronously and replace the icon
    // placeholders as they arrive; a window's cell just keeps its icon if
    // capture fails for it (closed mid-capture, mapping didn't resolve, ...).
    crate::wayland_capture::start(&state.windows, move |index, pixbuf| {
        if let Some(image) = thumb_images.get(index) {
            let (w, h) = (pixbuf.width(), pixbuf.height());
            let scale = (CELL_WIDTH as f64 / w as f64).min(120.0 / h as f64).min(1.0);
            let (tw, th) = ((w as f64 * scale) as i32, (h as f64 * scale) as i32);
            let scaled = pixbuf
                .scale_simple(tw.max(1), th.max(1), gdk_pixbuf::InterpType::Bilinear)
                .unwrap_or(pixbuf);
            image.set_from_pixbuf(Some(&scaled));
        }
    });

    let scroll = gtk::ScrolledWindow::new(gtk::Adjustment::NONE, gtk::Adjustment::NONE);
    scroll.set_policy(gtk::PolicyType::Never, gtk::PolicyType::Automatic);
    scroll.add(&flowbox);

    // Hidden until a non-Tab/Enter/Escape key locks the grid into search
    // mode; `no_show_all` keeps `win.show_all()` below from revealing it.
    let search = gtk::SearchEntry::new();
    search.set_no_show_all(true);

    let vbox = gtk::Box::new(gtk::Orientation::Vertical, 4);
    vbox.pack_start(&search, false, false, 0);
    vbox.pack_start(&scroll, true, true, 0);
    win.add(&vbox);

    flowbox.set_filter_func(Some(Box::new({
        let state = state.clone();
        let search = search.clone();
        move |child: &gtk::FlowBoxChild| {
            if !*state.locked.borrow() {
                return true;
            }
            let q = search.text();
            state
                .windows
                .get(child.index() as usize)
                .map(|w| crate::query::matches_str(w, &q))
                .unwrap_or(false)
        }
    })));

    {
        let flowbox = flowbox.clone();
        let state = state.clone();
        search.connect_search_changed(move |entry| {
            let q = entry.text();
            flowbox.invalidate_filter();
            // Move `selected` (what Enter confirms) to the first match, but
            // without `select()`'s grab_focus() -- that would yank keyboard
            // focus back out of the search entry mid-type.
            if let Some(idx) = state.windows.iter().position(|w| crate::query::matches_str(w, &q)) {
                *state.selected.borrow_mut() = idx;
                if let Some(child) = flowbox.child_at_index(idx as i32) {
                    flowbox.select_child(&child);
                }
            }
        });
    }

    {
        let win = win.clone();
        let state = state.clone();
        flowbox.connect_child_activated(move |_, child| {
            *state.selected.borrow_mut() = child.index() as usize;
            confirm(&win, &state);
        });
    }

    let start_idx = if initial_cmd == "prev" {
        state.windows.len().saturating_sub(1)
    } else {
        1usize.min(state.windows.len() - 1)
    };

    {
        let flowbox = flowbox.clone();
        let win_for_confirm = win.clone();
        let search = search.clone();
        let state = state.clone();
        win.connect_key_press_event(move |_, ev| {
            use gdk::keys::constants as key;
            let k = ev.keyval();
            let shift = ev.state().contains(gdk::ModifierType::SHIFT_MASK);

            if k == key::Escape {
                gtk::main_quit();
                return glib::Propagation::Stop;
            }
            if k == key::Return || k == key::KP_Enter {
                confirm(&win_for_confirm, &state);
                return glib::Propagation::Stop;
            }

            let locked = *state.locked.borrow();

            // ISO_Left_Tab is what GDK reports for Shift+Tab on most
            // layouts. Only cycles in raw mode -- once locked, Tab is left
            // alone (falls through to the search entry) rather than
            // fighting with typing.
            if !locked && (k == key::Tab || k == key::ISO_Left_Tab) {
                let cur = *state.selected.borrow();
                let n = state.windows.len();
                let next = if k == key::ISO_Left_Tab || shift {
                    (cur + n - 1) % n
                } else {
                    (cur + 1) % n
                };
                select(&flowbox, &state, next);
                return glib::Propagation::Stop;
            }

            // Any other printable key, while still unlocked, locks the grid
            // into search mode: show the entry, seed it with the character
            // that was just pressed, and hand it keyboard focus. Handled
            // here (rather than left to propagate) so the triggering
            // keypress becomes the query's first character deterministically
            // instead of racing the entry's own focus-in handling.
            if !locked {
                if let Some(ch) = ev.keyval().to_unicode() {
                    if !ch.is_control() {
                        *state.locked.borrow_mut() = true;
                        search.set_no_show_all(false);
                        search.show();
                        search.set_text(&ch.to_string());
                        search.grab_focus();
                        search.set_position(-1);
                        return glib::Propagation::Stop;
                    }
                }
            }

            glib::Propagation::Proceed
        });
    }

    {
        let win_for_confirm = win.clone();
        let state = state.clone();
        win.connect_key_release_event(move |_, ev| {
            use gdk::keys::constants as key;
            let k = ev.keyval();
            if (k == key::Alt_L || k == key::Alt_R) && !*state.locked.borrow() {
                confirm(&win_for_confirm, &state);
                return glib::Propagation::Stop;
            }
            glib::Propagation::Proceed
        });
    }

    win.connect_destroy(|_| gtk::main_quit());

    // Forwarded cycle commands from later Alt+Tab/Alt+Shift+Tab presses
    // (Hyprland's binds re-fire on every press, so a held-down Alt with
    // repeated taps sends one "next"/"prev" message per tap over this
    // socket rather than spawning a second instance -- see main.rs). Only
    // acted on while unlocked; once the grid is locked into search mode a
    // stray Alt+Tab shouldn't silently jump the selection out from under
    // whatever's being typed.
    {
        let flowbox = flowbox.clone();
        let state = state.clone();
        listener.set_nonblocking(true).ok();
        let raw_fd = listener.as_raw_fd();
        glib::source::unix_fd_add_local(raw_fd, glib::IOCondition::IN, move |_, _| {
            while let Ok((mut stream, _)) = listener.accept() {
                let mut buf = [0u8; 16];
                let cmd = match stream.read(&mut buf) {
                    Ok(n) => String::from_utf8_lossy(&buf[..n]).trim().to_string(),
                    Err(_) => continue,
                };
                if *state.locked.borrow() {
                    continue;
                }
                let cur = *state.selected.borrow();
                let n = state.windows.len();
                let next = if cmd == "prev" {
                    (cur + n - 1) % n
                } else {
                    (cur + 1) % n
                };
                select(&flowbox, &state, next);
            }
            glib::ControlFlow::Continue
        });
    }

    win.show_all();
    select(&flowbox, &state, start_idx);

    gtk::main();
}
