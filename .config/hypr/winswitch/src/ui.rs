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

use crate::enrich::TmuxClaudeMeta;
use crate::hyprctl::{self, Window};

const MIN_FRAME: i32 = 64;
const MAX_FRAME: i32 = 240;
// A 2-line label plus its spacing under the frame.
const LABEL_ALLOWANCE: i32 = 54;
// Per-cell margin + flowbox row/column spacing, horizontal and vertical.
const CELL_H_OVERHEAD: i32 = 24;
const CELL_V_OVERHEAD: i32 = 24;

/// A near-square column/row split so the grid's cells arrange sensibly for
/// however many windows there are. Cols is clamped to [2, 6]: below 2, a
/// single window would sit in an oddly narrow sliver; above 6, more windows
/// mostly grows the grid *taller* rather than wider than it is tall, since a
/// wide wall of cells reads worse than a taller rectangle.
fn grid_dims(n: usize) -> (i32, i32) {
    let n = n.max(1) as f64;
    let cols = (n.sqrt().ceil() as i32).clamp(2, 6);
    let rows = (n / cols as f64).ceil() as i32;
    (cols, rows)
}

/// Given the grid window's (fixed) size and how many columns/rows it needs,
/// how big each cell's thumbnail budget gets to be. Windows scale up to
/// fill whatever room a fixed-size grid gives them, rather than the grid
/// shrinking around a few small cells.
fn cell_size(win_w: i32, win_h: i32, cols: i32, rows: i32) -> (i32, i32) {
    let cell_w = (win_w / cols - CELL_H_OVERHEAD).max(MIN_FRAME);
    let cell_h = (win_h / rows - CELL_V_OVERHEAD).max(MIN_FRAME + LABEL_ALLOWANCE);
    let max_h = (cell_h - LABEL_ALLOWANCE).clamp(MIN_FRAME, MAX_FRAME);
    (cell_w, max_h)
}

/// How big a cell's thumbnail frame should be for one specific window,
/// given its real on-screen size (from `hyprctl clients`) and the cell's
/// width/height budget: fit *that window's* actual aspect ratio into the
/// budget box, instead of every cell getting the same generic size. A live
/// capture's dimensions closely track the window's reported size, so the
/// empty placeholder frame shown before any capture has arrived is already
/// close to the real thumbnail's shape -- nothing to visibly resize (or, no
/// icon to flicker away from) once it lands.
fn frame_size(win_w: i32, win_h: i32, budget_w: i32, budget_h: i32) -> (i32, i32) {
    if win_w <= 0 || win_h <= 0 {
        return (budget_w, budget_h);
    }
    let aspect = win_h as f64 / win_w as f64;
    let h_at_full_width = (budget_w as f64 * aspect).round() as i32;
    if h_at_full_width <= budget_h {
        (budget_w, h_at_full_width.max(MIN_FRAME))
    } else {
        let w_at_max_h = (budget_h as f64 / aspect).round() as i32;
        (w_at_max_h.max(MIN_FRAME), budget_h)
    }
}

/// Which of the two things the autocomplete popup is currently offering --
/// determines what `accept_suggestion` splices into the query text. Field
/// and value completion are mutually exclusive per `update_suggestions`
/// (query.rs's `trailing_field_fragment`/`trailing_value_fragment` can never
/// both match the same query), so this only ever needs to remember which
/// one is live, not both at once.
#[derive(Clone)]
enum SuggestionKind {
    /// Popup lists column/group entries; accepting inserts `$<name>:` (or
    /// `$<name>` again with the dot still open, for a group -- see
    /// `update_suggestions`).
    Field,
    /// Popup lists this field's live values across `state.windows`;
    /// accepting inserts `$<field.key()>:<value> ` (trailing space -- a
    /// value is always a *complete* term once chosen, unlike a field name,
    /// which still needs its value typed next). Stored as the already-
    /// formatted key text (`"title"`, `"tmux.session"`) rather than
    /// `ResolvedField` itself, since that's exactly what gets spliced back
    /// into the query.
    Value(String),
}

struct State {
    windows: Vec<Window>,
    /// Parallel to `windows` (same index) -- tmux/claude metadata, filled in
    /// asynchronously by `enrich::start` well after the grid is already
    /// shown. All-default until then; see query.rs's `$tmux.*`/`$claude.*`
    /// handling for why an unfilled field just doesn't match yet rather
    /// than needing special-casing here.
    tmux_claude: Vec<RefCell<TmuxClaudeMeta>>,
    selected: RefCell<usize>,
    locked: RefCell<bool>,
    /// Autocomplete popup state, live only while `trailing_field_fragment`
    /// or `trailing_value_fragment` matches the current query (see
    /// `update_suggestions`). `suggestions` empty means the popup is
    /// hidden; `suggestion_start` is the byte offset in the query text
    /// that a chosen suggestion replaces; `suggestion_kind` is `None`
    /// exactly when `suggestions` is empty.
    suggestions: RefCell<Vec<String>>,
    suggestion_idx: RefCell<usize>,
    suggestion_start: RefCell<usize>,
    suggestion_kind: RefCell<Option<SuggestionKind>>,
}

/// Returns the child alongside its thumbnail `Image` so callers can swap in
/// a live capture later (`wayland_capture::start`'s `on_thumbnail`
/// callback) without having to dig back through the widget tree.
///
/// No icon placeholder: the image starts empty in a `frame_size`-sized
/// frame (outline via the "thumb-frame" CSS class set up in `run()`) that
/// already approximates the real window's shape, and just stays that way
/// until (unless) a live capture lands in it -- a small icon swapped out
/// for a live capture used to read as a flicker even once it stopped
/// resizing the cell.
fn make_child(win: &Window, cell_w: i32, max_h: i32) -> (gtk::FlowBoxChild, gtk::Image) {
    let vbox = gtk::Box::new(gtk::Orientation::Vertical, 6);
    vbox.set_size_request(cell_w, -1);

    let (frame_w, frame_h) = frame_size(win.width, win.height, cell_w, max_h);
    let frame = gtk::Box::new(gtk::Orientation::Vertical, 0);
    frame.set_size_request(frame_w, frame_h);
    frame.set_halign(gtk::Align::Center);
    frame.style_context().add_class("thumb-frame");

    let image = gtk::Image::new();
    image.set_halign(gtk::Align::Center);
    image.set_valign(gtk::Align::Center);
    frame.pack_start(&image, true, true, 0);
    vbox.pack_start(&frame, false, false, 0);

    // The workspace number rides on the *same* line as the title (a muted
    // "#N" prefix) rather than a dedicated line above it, so it costs
    // nothing when the title is short and simply falls out of view under
    // the label's own ellipsize/2-line budget when it isn't -- "if there's
    // space" is exactly what set_ellipsize already guarantees per line, no
    // separate layout logic needed. Built with set_markup rather than
    // plain text so the "#N" prefix can be styled distinctly; both pieces
    // are escaped since title/class/workspace all come from whatever the
    // window (or the user's Hyprland workspace naming) put there.
    let base_text = if win.title.is_empty() {
        win.class.clone()
    } else {
        win.title.clone()
    };
    let label = gtk::Label::new(None);
    label.set_markup(&format!(
        "<span size=\"smaller\" alpha=\"55%\">#{}</span> {}",
        glib::markup_escape_text(&win.workspace),
        glib::markup_escape_text(&base_text),
    ));
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

/// Highlights `idx` in the suggestions list (clamped, not wrapped -- Ctrl+j
/// past the last entry just stays on the last one, same as most completion
/// UIs) and records it in `state` so `accept_suggestion` knows what Tab
/// should insert.
fn select_suggestion(list: &gtk::ListBox, state: &Rc<State>, idx: usize) {
    let n = state.suggestions.borrow().len();
    if n == 0 {
        return;
    }
    let idx = idx.min(n - 1);
    *state.suggestion_idx.borrow_mut() = idx;
    if let Some(row) = list.row_at_index(idx as i32) {
        list.select_row(Some(&row));
    }
}

fn hide_suggestions(list: &gtk::ListBox, state: &Rc<State>) {
    list.hide();
    state.suggestions.borrow_mut().clear();
    *state.suggestion_kind.borrow_mut() = None;
}

/// Populates `list` with one row per entry in `items` and reveals it -- the
/// shared tail end of both `update_suggestions` branches below (field-name
/// and value completion differ only in *where the candidate strings come
/// from*, not in how they're rendered).
fn populate_suggestions(list: &gtk::ListBox, items: &[String]) {
    for item in items {
        let row = gtk::ListBoxRow::new();
        let label = gtk::Label::new(Some(item));
        label.set_halign(gtk::Align::Start);
        row.add(&label);
        list.add(&row);
        // `no-show-all` on `list` (set at construction, so the one-time
        // `win.show_all()` in `run()` doesn't prematurely reveal an empty
        // popup) means `list.show_all()` would *skip* list itself --
        // "no-show-all: gtk_widget_show_all() will not affect this widget"
        // applies to the widget it's set on too, not just its ancestors'
        // recursive calls. So each row/label is shown explicitly here
        // instead of relying on a later show_all() to reach them, and
        // `list.show()` below (a direct call, unlike show_all(), always
        // works regardless of no-show-all) is what actually reveals the
        // list -- same "set_no_show_all(false)-or-explicit-show()" pattern
        // `search` already uses a few lines up in `run()`.
        row.show();
        label.show();
    }
    list.show();
}

/// Re-derives the autocomplete popup from the query text on every keystroke
/// -- cheap (at most a handful of columns, or a couple dozen windows' worth
/// of one column's values, to filter), so no need to diff against the
/// previous state. Field-name completion (`trailing_field_fragment`, no `:`
/// yet) and value completion (`trailing_value_fragment`, `:` typed and the
/// column before it unambiguous) are mutually exclusive, so value
/// completion is tried first and field-name completion is the fallback --
/// see query.rs's doc comments on both for why they can't both match.
fn update_suggestions(query: &str, list: &gtk::ListBox, state: &Rc<State>) {
    for child in list.children() {
        list.remove(&child);
    }

    if let Some((start, field, frag)) = crate::query::trailing_value_fragment(query) {
        let metas = snapshot_metas(state);
        let vals = crate::query::value_suggestions(&state.windows, &metas, field, &frag);
        if vals.is_empty() {
            hide_suggestions(list, state);
            return;
        }
        populate_suggestions(list, &vals);
        *state.suggestions.borrow_mut() = vals;
        *state.suggestion_start.borrow_mut() = start;
        *state.suggestion_kind.borrow_mut() = Some(SuggestionKind::Value(field.key()));
        select_suggestion(list, state, 0);
        return;
    }

    let Some((start, frag)) = crate::query::trailing_field_fragment(query) else {
        hide_suggestions(list, state);
        return;
    };
    let cols = crate::query::column_suggestions(&frag);
    if cols.is_empty() {
        hide_suggestions(list, state);
        return;
    }
    populate_suggestions(list, &cols);
    *state.suggestions.borrow_mut() = cols;
    *state.suggestion_start.borrow_mut() = start;
    *state.suggestion_kind.borrow_mut() = Some(SuggestionKind::Field);
    select_suggestion(list, state, 0);
}

/// Owned copy of every window's current metadata, for call sites that need
/// to hand `&[TmuxClaudeMeta]` to query.rs -- cheap (a handful of small
/// `Option<String>` fields, at most a couple dozen windows) and sidesteps
/// holding a `Ref` across a call that also wants `&state` more broadly.
fn snapshot_metas(state: &State) -> Vec<TmuxClaudeMeta> {
    state.tmux_claude.iter().map(|m| m.borrow().clone()).collect()
}

/// Replaces the trailing fragment the suggestions were built from with the
/// chosen completion -- `$<column>:` for a field name (ready for the value
/// to be typed next) or `$<column>:<value> ` for a value (a trailing space,
/// since a value is always a *complete* AND term once chosen, unlike a
/// field name). Mirrors focus-picker.py's `tab:transform-query` completion
/// (same "tab accepts what the popup already shows highlighted" contract),
/// just via direct GtkEntry text splicing instead of fzf's own
/// transform-query bind. A value containing whitespace is re-quoted on the
/// way back in -- otherwise splicing it in unquoted would immediately
/// re-split into two tokens the moment this fires, undoing the very
/// quote-aware tokenizing that made it matchable in the first place (see
/// query.rs's module doc).
fn accept_suggestion(search: &gtk::SearchEntry, list: &gtk::ListBox, state: &Rc<State>) {
    let idx = *state.suggestion_idx.borrow();
    let Some(chosen) = state.suggestions.borrow().get(idx).cloned() else {
        return;
    };
    let Some(kind) = state.suggestion_kind.borrow().clone() else {
        return;
    };
    let start = *state.suggestion_start.borrow();
    let query = search.text();
    let new_query = match kind {
        SuggestionKind::Field => format!("{}${}:", &query[..start], chosen),
        SuggestionKind::Value(col) => {
            let value = if chosen.contains(char::is_whitespace) {
                format!("\"{chosen}\"")
            } else {
                chosen
            };
            format!("{}${}:{} ", &query[..start], col, value)
        }
    };
    hide_suggestions(list, state);
    search.set_text(&new_query);
    search.set_position(-1);
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

    let tmux_claude = windows.iter().map(|_| RefCell::new(TmuxClaudeMeta::default())).collect();
    let state = Rc::new(State {
        windows,
        tmux_claude,
        selected: RefCell::new(0),
        locked: RefCell::new(false),
        suggestions: RefCell::new(Vec::new()),
        suggestion_idx: RefCell::new(0),
        suggestion_start: RefCell::new(0),
        suggestion_kind: RefCell::new(None),
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
    let (cell_w, max_h) = cell_size(win_w, win_h, cols, rows);

    if let Some(screen) = gdk::Screen::default() {
        let css = gtk::CssProvider::new();
        // An outline, not a filled block: this is a placeholder for a
        // window frame, not a loading skeleton.
        let _ = css.load_from_data(
            b".thumb-frame { border: 1px solid rgba(255,255,255,0.18); background-color: rgba(255,255,255,0.02); border-radius: 4px; } \
              .suggestions { border: 1px solid rgba(255,255,255,0.18); border-radius: 4px; } \
              .suggestions row { padding: 2px 6px; } \
              .suggestions row:selected { background-color: rgba(255,255,255,0.18); }",
        );
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
        let (child, image) = make_child(win_entry, cell_w, max_h);
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

    // Column-name autocomplete popup: an in-layout ListBox directly under
    // the search entry (not a GtkPopover) -- gtk-layer-shell's layer
    // surface has no xdg_popup positioner to anchor a real popover to, so
    // this just reserves its own row in the same vbox and is shown/hidden
    // as query text comes and goes. `COLUMNS` (query.rs) is small (4
    // entries today) and fully enumerable, so a fixed unscrolled list is
    // enough -- see ~/.config/docs/query-dsl.md's autocompletion section.
    let suggestions_list = gtk::ListBox::new();
    suggestions_list.set_selection_mode(gtk::SelectionMode::Browse);
    suggestions_list.set_no_show_all(true);
    suggestions_list.style_context().add_class("suggestions");
    suggestions_list.hide();

    let vbox = gtk::Box::new(gtk::Orientation::Vertical, 4);
    vbox.pack_start(&search, false, false, 0);
    vbox.pack_start(&suggestions_list, false, false, 0);
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
            let idx = child.index() as usize;
            let Some(w) = state.windows.get(idx) else { return false };
            let meta = state.tmux_claude.get(idx).map(|m| m.borrow().clone()).unwrap_or_default();
            crate::query::matches_str(w, &meta, &q)
        }
    })));

    {
        let flowbox = flowbox.clone();
        let suggestions_list = suggestions_list.clone();
        let state = state.clone();
        search.connect_search_changed(move |entry| {
            let q = entry.text();
            flowbox.invalidate_filter();
            // Move `selected` (what Enter confirms) to the first match, but
            // without `select()`'s grab_focus() -- that would yank keyboard
            // focus back out of the search entry mid-type.
            let first_match = state.windows.iter().enumerate().position(|(i, w)| {
                let meta = state.tmux_claude.get(i).map(|m| m.borrow().clone()).unwrap_or_default();
                crate::query::matches_str(w, &meta, &q)
            });
            if let Some(idx) = first_match {
                *state.selected.borrow_mut() = idx;
                if let Some(child) = flowbox.child_at_index(idx as i32) {
                    flowbox.select_child(&child);
                }
            }
            update_suggestions(&q, &suggestions_list, &state);
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
        let suggestions_list = suggestions_list.clone();
        let state = state.clone();
        win.connect_key_press_event(move |_, ev| {
            use gdk::keys::constants as key;
            let k = ev.keyval();
            let shift = ev.state().contains(gdk::ModifierType::SHIFT_MASK);
            let ctrl = ev.state().contains(gdk::ModifierType::CONTROL_MASK);
            let locked = *state.locked.borrow();

            // Column-name autocomplete popup takes over Ctrl+j/k, Tab, and
            // Escape while it's showing -- checked before any of those
            // keys' normal meaning below, and before the generic
            // Escape-quits-the-grid handling right after this block, since
            // the popup's own Escape only dismisses itself.
            if locked && !state.suggestions.borrow().is_empty() {
                if ctrl && k == key::j {
                    let idx = *state.suggestion_idx.borrow();
                    select_suggestion(&suggestions_list, &state, idx + 1);
                    return glib::Propagation::Stop;
                }
                if ctrl && k == key::k {
                    let idx = *state.suggestion_idx.borrow();
                    select_suggestion(&suggestions_list, &state, idx.saturating_sub(1));
                    return glib::Propagation::Stop;
                }
                if k == key::Tab {
                    accept_suggestion(&search, &suggestions_list, &state);
                    return glib::Propagation::Stop;
                }
                if k == key::Escape {
                    hide_suggestions(&suggestions_list, &state);
                    return glib::Propagation::Stop;
                }
            }

            if k == key::Escape {
                gtk::main_quit();
                return glib::Propagation::Stop;
            }
            if k == key::Return || k == key::KP_Enter {
                confirm(&win_for_confirm, &state);
                return glib::Propagation::Stop;
            }

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

    // Live captures stream in asynchronously and fill in the empty
    // placeholder frames as they arrive; a window's cell just stays an
    // empty frame if capture fails for it (closed mid-capture, mapping
    // didn't resolve, ...). Scaled to the same per-window `frame_size` its
    // placeholder frame already used, not a generic budget -- since that
    // was sized from this window's own real dimensions, a live capture
    // (whose actual pixel size can differ slightly, e.g. if it resized
    // between listing and capture) still lands in a frame the right shape
    // for it rather than getting letterboxed inside a mismatched one.
    let state_for_thumbs = state.clone();
    crate::wayland_capture::start(&state.windows, move |index, pixbuf| {
        if let (Some(image), Some(win)) = (thumb_images.get(index), state_for_thumbs.windows.get(index)) {
            let (frame_w, frame_h) = frame_size(win.width, win.height, cell_w, max_h);
            let (w, h) = (pixbuf.width(), pixbuf.height());
            let scale = (frame_w as f64 / w as f64).min(frame_h as f64 / h as f64).min(1.0);
            let (tw, th) = ((w as f64 * scale) as i32, (h as f64 * scale) as i32);
            let scaled = pixbuf
                .scale_simple(tw.max(1), th.max(1), gdk_pixbuf::InterpType::Bilinear)
                .unwrap_or(pixbuf);
            image.set_from_pixbuf(Some(&scaled));
        }
    });

    // Same fire-and-forget shape as wayland_capture::start just above:
    // tmux/claude metadata streams in well after the grid is already up and
    // interactive, merged into `state.tmux_claude` as it lands so a
    // `$tmux.*`/`$claude.*` query already typed keeps matching live -- see
    // enrich.rs's module doc for why this has to stay off the critical path
    // (a slow tmux server or a large transcript read must never delay the
    // grid's first paint, which by this point has already happened).
    let state_for_enrich = state.clone();
    let flowbox_for_enrich = flowbox.clone();
    crate::enrich::start(&state.windows, move |index, meta| {
        if let Some(cell) = state_for_enrich.tmux_claude.get(index) {
            cell.borrow_mut().merge(meta);
            flowbox_for_enrich.invalidate_filter();
        }
    });

    gtk::main();
}
