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

const MIN_ICON: i32 = 64;
const MAX_ICON: i32 = 240;
// A 2-line label plus its spacing under the icon.
const LABEL_ALLOWANCE: i32 = 54;
// Per-cell margin + flowbox row/column spacing, horizontal and vertical.
const CELL_H_OVERHEAD: i32 = 24;
const CELL_V_OVERHEAD: i32 = 24;

/// A near-square column/row split so the grid's cells arrange sensibly for
/// however many windows there are. Cols is clamped to [2, 6]: below 2, a
/// single window would sit in an oddly narrow sliver; above 6, more windows
/// mostly grows the grid *taller* rather than wider than it is tall, since a
/// wide wall of icons reads worse than a taller rectangle.
fn grid_dims(n: usize) -> (i32, i32) {
    let n = n.max(1) as f64;
    let cols = (n.sqrt().ceil() as i32).clamp(2, 6);
    let rows = (n / cols as f64).ceil() as i32;
    (cols, rows)
}

/// Given the grid window's (fixed) size and how many columns/rows it needs,
/// how big each cell -- and therefore its icon/thumbnail -- gets to be.
/// Windows scale up to fill whatever room a fixed-size grid gives them,
/// rather than the grid shrinking around a few small icons.
fn cell_size(win_w: i32, win_h: i32, cols: i32, rows: i32) -> (i32, i32) {
    let cell_w = (win_w / cols - CELL_H_OVERHEAD).max(MIN_ICON);
    let cell_h = (win_h / rows - CELL_V_OVERHEAD).max(MIN_ICON + LABEL_ALLOWANCE);
    let icon = cell_w.min(cell_h - LABEL_ALLOWANCE).clamp(MIN_ICON, MAX_ICON);
    (cell_w, icon)
}

struct State {
    windows: Vec<Window>,
    selected: RefCell<usize>,
    locked: RefCell<bool>,
}

fn lookup_icon(class: &str, icon_size: i32) -> gdk_pixbuf::Pixbuf {
    let theme = gtk::IconTheme::default();
    let candidates = [class.to_string(), class.to_lowercase()];
    if let Some(theme) = &theme {
        for name in &candidates {
            if let Some(pb) = theme
                .load_icon(name, icon_size, gtk::IconLookupFlags::FORCE_SIZE)
                .ok()
                .flatten()
            {
                return pb;
            }
        }
        if let Some(pb) = theme
            .load_icon(
                "application-x-executable",
                icon_size,
                gtk::IconLookupFlags::FORCE_SIZE,
            )
            .ok()
            .flatten()
        {
            return pb;
        }
    }
    // Last-resort blank pixbuf so callers never have to handle a missing icon.
    gdk_pixbuf::Pixbuf::new(gdk_pixbuf::Colorspace::Rgb, true, 8, icon_size, icon_size)
        .expect("blank pixbuf")
}

/// Returns the child alongside its thumbnail `Image` so callers can swap in
/// a live capture later (`wayland_capture::start`'s `on_thumbnail`
/// callback) without having to dig back through the widget tree.
///
/// The image sits in a `frame_h`-tall frame (background fill via the
/// "thumb-frame" CSS class set up in `run()`) that's the same size whether
/// it's holding the small icon placeholder or the eventual live thumbnail --
/// otherwise a cell visibly resizing (and its row along with it) the moment
/// a capture lands in place of its icon reads as a flicker.
fn make_child(win: &Window, cell_w: i32, icon_size: i32, frame_h: i32) -> (gtk::FlowBoxChild, gtk::Image) {
    let vbox = gtk::Box::new(gtk::Orientation::Vertical, 6);
    vbox.set_size_request(cell_w, -1);

    let frame = gtk::Box::new(gtk::Orientation::Vertical, 0);
    frame.set_size_request(cell_w, frame_h);
    frame.style_context().add_class("thumb-frame");

    let image = gtk::Image::from_pixbuf(Some(&lookup_icon(&win.class, icon_size)));
    image.set_halign(gtk::Align::Center);
    image.set_valign(gtk::Align::Center);
    frame.pack_start(&image, true, true, 0);
    vbox.pack_start(&frame, false, false, 0);

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
    if gtk::init().is_err() {
        eprintln!("winswitch: failed to initialise GTK");
        std::process::exit(1);
    }

    // A bare, empty, invisible layer-shell surface -- just enough to
    // acquire exclusive keyboard focus so we can tell a genuine
    // hold-and-browse apart from a tap that's already finished by the time
    // we get focus (see the focus-in handler below), *before* paying for
    // anything else: fetching the window list, icon lookups, building the
    // grid, thumbnail capture setup. None of that is needed for a tap, but
    // it used to all happen unconditionally first -- that (not the
    // wayland_capture reordering alone) was the rest of the lag.
    let win = gtk::Window::new(gtk::WindowType::Toplevel);
    win.init_layer_shell();
    win.set_layer(gtk_layer_shell::Layer::Overlay);
    win.set_keyboard_mode(gtk_layer_shell::KeyboardMode::Exclusive);
    win.set_opacity(0.0);
    win.set_size_request(1, 1);

    let monitor = gdk::Display::default().and_then(|d| target_monitor(&d));
    if let Some(mon) = &monitor {
        win.set_monitor(mon);
    }

    let checked = Rc::new(std::cell::Cell::new(false));
    let held = Rc::new(std::cell::Cell::new(false));
    {
        let checked = checked.clone();
        let held = held.clone();
        win.connect_focus_in_event(move |_, _| {
            if !checked.get() {
                checked.set(true);
                held.set(hyprctl::is_alt_down());
            }
            glib::Propagation::Proceed
        });
    }

    win.show_all();
    while !checked.get() {
        gtk::main_iteration();
    }

    if !held.get() {
        // Tap: a fast press-release completed before we could see the
        // release ourselves (this window didn't have keyboard focus yet
        // when it happened). Do the classic single quick-switch directly
        // and quit -- there was never a grid worth building here.
        let windows = hyprctl::list_windows();
        let idx = if initial_cmd == "prev" {
            windows.len().saturating_sub(1)
        } else {
            1.min(windows.len().saturating_sub(1))
        };
        if let Some(w) = windows.get(idx) {
            let addr = w.address.clone();
            win.hide();
            glib::source::idle_add_local(move || {
                hyprctl::focus_window(&addr);
                gtk::main_quit();
                glib::ControlFlow::Break
            });
            for _ in 0..5 {
                gtk::main_iteration_do(false);
            }
            gtk::main();
        }
        return;
    }

    // Held: now do the real work.
    let windows = hyprctl::list_windows();
    if windows.is_empty() {
        return;
    }

    let state = Rc::new(State {
        windows,
        selected: RefCell::new(0),
        locked: RefCell::new(false),
    });

    let (cols, rows) = grid_dims(state.windows.len());

    // Fixed fraction of the monitor regardless of window count -- cells
    // scale up via `cell_size` below to fill it instead of the window
    // shrinking around however many there are.
    let (mut win_w, mut win_h) = (900, 600);
    if let Some(mon) = &monitor {
        let g = mon.geometry();
        win_w = (g.width() as f64 * 0.7) as i32;
        win_h = (g.height() as f64 * 0.6) as i32;
    }
    win.set_size_request(win_w, win_h);
    let (cell_w, icon_size) = cell_size(win_w, win_h, cols, rows);
    // Thumbnails get a taller budget than a square icon (1.25x) since
    // captures are usually wider-than-tall windows, not app icons; this is
    // also the fixed frame height every cell's image sits in from the
    // start (see `make_child`), so a live capture landing later doesn't
    // resize its cell.
    let max_h = (icon_size as f64 * 1.25) as i32;

    if let Some(screen) = gdk::Screen::default() {
        let css = gtk::CssProvider::new();
        let _ = css.load_from_data(b".thumb-frame { background-color: rgba(255,255,255,0.06); border-radius: 6px; }");
        gtk::StyleContext::add_provider_for_screen(&screen, &css, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
    }

    let flowbox = gtk::FlowBox::new();
    flowbox.set_selection_mode(gtk::SelectionMode::Single);
    // Not homogeneous: cells keep a fixed *width* (each child vbox below
    // requests `cell_w` explicitly), but height follows each row's actual
    // tallest content instead of every row being stretched to match
    // whichever cell anywhere in the grid happens to be biggest.
    flowbox.set_homogeneous(false);
    flowbox.set_valign(gtk::Align::Start);
    // Forcing min == max locks in the `grid_dims` column count instead of
    // letting FlowBox reflow based on available width, which is what was
    // producing a handful of icons bunched in a mostly-empty box.
    flowbox.set_max_children_per_line(cols as u32);
    flowbox.set_min_children_per_line(cols as u32);
    flowbox.set_row_spacing(4);
    flowbox.set_column_spacing(4);

    let mut thumb_images = Vec::with_capacity(state.windows.len());
    for win_entry in &state.windows {
        let (child, image) = make_child(win_entry, cell_w, icon_size, max_h);
        flowbox.add(&child);
        thumb_images.push(image);
    }

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

            // Locking in doesn't mean Alt got released -- holding Alt,
            // tapping Tab a few times, then typing while *still* holding
            // Alt is a completely normal sequence. GTK's own input-method
            // handling won't insert text for a key event with Alt in its
            // modifier state (that's reserved for mnemonics/accelerators),
            // which is why only the triggering key -- inserted manually,
            // below -- ever showed up: every key after it was silently
            // swallowed for as long as Alt stayed down. So: once locked, if
            // Alt is still down, take over editing by hand instead of
            // letting it fall through to the entry's normal handling.
            if locked && ev.state().contains(gdk::ModifierType::MOD1_MASK) {
                let mut pos = search.position();
                let len = search.text().chars().count() as i32;
                if k == key::BackSpace {
                    if pos > 0 {
                        search.delete_text(pos - 1, pos);
                        search.set_position(pos - 1);
                    }
                    return glib::Propagation::Stop;
                }
                if k == key::Delete {
                    if pos < len {
                        search.delete_text(pos, pos + 1);
                    }
                    return glib::Propagation::Stop;
                }
                if k == key::Left {
                    search.set_position((pos - 1).max(0));
                    return glib::Propagation::Stop;
                }
                if k == key::Right {
                    search.set_position((pos + 1).min(len));
                    return glib::Propagation::Stop;
                }
                if let Some(ch) = ev.keyval().to_unicode() {
                    if !ch.is_control() {
                        search.insert_text(&ch.to_string(), &mut pos);
                        search.set_position(pos);
                    }
                }
                return glib::Propagation::Stop;
            }

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

            // Arrow keys move the grid selection the same way Tab/Shift+Tab
            // do (Left/Right) plus a real 2D jump by a row (Up/Down),
            // wrapping around like Tab already does.
            if !locked && matches!(k, key::Left | key::Right | key::Up | key::Down) {
                let cur = *state.selected.borrow();
                let n = state.windows.len();
                let delta: i64 = match k {
                    key::Left => -1,
                    key::Right => 1,
                    key::Up => -(cols as i64),
                    _ => cols as i64,
                };
                let next = ((cur as i64 + delta).rem_euclid(n as i64)) as usize;
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

    // The window's already mapped and keyboard-focused (from the bare
    // pre-check above) -- just reveal it and add the real content's
    // widgets to what's shown.
    win.show_all();
    win.set_opacity(1.0);
    select(&flowbox, &state, start_idx);

    // A few more iterations so the newly-built grid actually gets painted
    // and flushed to the compositor before wayland_capture::start()'s own
    // blocking roundtrips below run.
    for _ in 0..5 {
        gtk::main_iteration_do(false);
    }

    // Live captures stream in asynchronously and replace the icon
    // placeholders as they arrive; a window's cell just keeps its icon if
    // capture fails for it (closed mid-capture, mapping didn't resolve, ...).
    let max_h = max_h as f64;
    crate::wayland_capture::start(&state.windows, move |index, pixbuf| {
        if let Some(image) = thumb_images.get(index) {
            let (w, h) = (pixbuf.width(), pixbuf.height());
            let scale = (cell_w as f64 / w as f64).min(max_h / h as f64).min(1.0);
            let (tw, th) = ((w as f64 * scale) as i32, (h as f64 * scale) as i32);
            let scaled = pixbuf
                .scale_simple(tw.max(1), th.max(1), gdk_pixbuf::InterpType::Bilinear)
                .unwrap_or(pixbuf);
            image.set_from_pixbuf(Some(&scaled));
        }
    });

    gtk::main();
}
