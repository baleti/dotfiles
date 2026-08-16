//! Shared GTK3 + wlr-layer-shell picker engine: a search box over a
//! GtkListBox, with `$type` selectors, keyboard navigation and an
//! activate callback. Extracted from the original clipboard-picker so the
//! same window/search/filter/keyboard machinery can back other pickers
//! (e.g. a dunst notification-history picker) without duplicating it.
//!
//! Callers own everything source-specific: how entries are fetched, how
//! (or whether) thumbnails are loaded, and what activating a row does.

use std::cell::RefCell;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::rc::Rc;

use gdk_pixbuf::Pixbuf;
use gtk::prelude::*;
use gtk_layer_shell::LayerShell;

/// Sentinel kind no entry can have, used when a `$token` matches no known
/// type so the result is empty rather than silently unfiltered.
pub const KIND_NONE: usize = usize::MAX;

pub struct Entry {
    pub id: String,
    /// Text shown in the row (single line, ellipsized) unless `thumb` is set.
    pub preview: String,
    /// Lowercased text matched against the free-text part of the query.
    pub haystack: String,
    /// Index into `PickerConfig::type_names`, or `KIND_NONE`.
    pub kind: usize,
    /// True if this entry should render as a lazily-loaded thumbnail image
    /// instead of a text label (requires `load_thumb` to be set in `run`).
    pub thumb: bool,
}

/// A parsed search box string: zero or more `$type` selectors plus free text.
struct Query {
    kinds: Vec<usize>,
    text: String,
}

struct State {
    entries: Vec<Entry>,
    query: RefCell<Query>,
}

/// True if every char of `needle` appears in `hay` in order, so "mg" matches
/// "image" and "i" matches "image" but not "text".
fn subsequence(needle: &str, hay: &str) -> bool {
    let mut chars = hay.chars();
    needle.chars().all(|c| chars.any(|h| h == c))
}

fn parse_query(input: &str, type_names: &[String]) -> Query {
    let mut kinds: Vec<usize> = Vec::new();
    let mut words: Vec<&str> = Vec::new();
    let mut saw_selector = false;

    for token in input.split_whitespace() {
        match token.strip_prefix('$') {
            // A bare "$" means the user is still typing the selector.
            Some("") => {}
            Some(rest) => {
                saw_selector = true;
                let rest = rest.to_lowercase();
                for (i, name) in type_names.iter().enumerate() {
                    if subsequence(&rest, &name.to_lowercase()) && !kinds.contains(&i) {
                        kinds.push(i);
                    }
                }
            }
            None => words.push(token),
        }
    }

    if saw_selector && kinds.is_empty() {
        kinds.push(KIND_NONE);
    }

    Query {
        kinds,
        text: words.join(" ").to_lowercase(),
    }
}

pub fn cache_dir(program_name: &str) -> PathBuf {
    let base = std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".cache"));
    base.join(program_name)
}

fn pidfile(program_name: &str) -> PathBuf {
    let base = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    base.join(format!("{program_name}.pid"))
}

/// Second press of the launching keybind acts like Escape. A pidfile rather
/// than pkill, so we can't match (and kill) an unrelated process that merely
/// mentions the path. The pidfile can go stale and PIDs get recycled, so
/// confirm the process really is this program before signalling it.
fn toggle_closed_existing(path: &Path, program_name: &str) -> bool {
    let Ok(txt) = fs::read_to_string(path) else {
        return false;
    };
    let Ok(pid) = txt.trim().parse::<i32>() else {
        return false;
    };
    if pid == std::process::id() as i32 {
        return false;
    }
    let Ok(cmdline) = fs::read(format!("/proc/{pid}/cmdline")) else {
        return false; // process is gone; stale pidfile
    };
    if !String::from_utf8_lossy(&cmdline).contains(program_name) {
        return false; // PID recycled by something unrelated
    }
    unsafe { libc::kill(pid, libc::SIGTERM) == 0 }
}

/// The monitor Hyprland considers active.
///
/// Deliberately not the monitor under the pointer: with focus-follows-mouse
/// off the pointer routinely sits on a different screen than the focused
/// one, which put the picker on the wrong monitor. Match Hyprland's
/// `focused` flag to a GdkMonitor by logical origin, which both report
/// identically even under mixed scaling.
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

    // Fall back to the pointer, then the first monitor.
    if let Some(seat) = display.default_seat() {
        if let Some(ptr) = seat.pointer() {
            let (_s, x, y) = ptr.position();
            if let Some(mon) = display.monitor_at_point(x, y) {
                return Some(mon);
            }
        }
    }
    display.monitor(0)
}

pub struct PickerConfig {
    /// Used for the pidfile name and the toggle-closed cmdline match, so
    /// must be unique per picker binary.
    pub program_name: &'static str,
    /// Names selectable from the search box with `$name`; empty if this
    /// picker has no meaningful type dimension.
    pub type_names: Vec<String>,
    pub placeholder: String,
    pub width_fraction: f64,
    /// Maximum height as a fraction of the monitor height; the window shrinks
    /// below this to fit fewer entries but never grows past it.
    pub height_fraction: f64,
    /// Row height for thumbnail entries; ignored if no entry has `thumb: true`.
    pub thumb_height: i32,
    /// Rows built before the first frame, then per idle tick afterwards.
    /// GtkListBox doesn't virtualise, so laying out everything up front
    /// dominates time-to-first-frame on large lists.
    pub initial_rows: usize,
    pub chunk_rows: usize,
}

fn make_row(
    state: &State,
    idx: usize,
    thumb_height: i32,
    pending: &Rc<RefCell<Vec<(gtk::Image, String)>>>,
) -> gtk::ListBoxRow {
    let entry = &state.entries[idx];
    let row = gtk::ListBoxRow::new();
    if entry.thumb {
        // Placeholder keeps the row at its final height so the list doesn't
        // jump around as thumbnails stream in.
        let img = gtk::Image::new();
        img.set_size_request(-1, thumb_height);
        img.set_halign(gtk::Align::Start);
        row.add(&img);
        pending.borrow_mut().push((img, entry.id.clone()));
    } else {
        let label = gtk::Label::new(Some(&entry.preview));
        label.set_xalign(0.0);
        label.set_ellipsize(gtk::pango::EllipsizeMode::End);
        label.set_max_width_chars(1); // let ellipsize kick in early
        row.add(&label);
    }
    row.show_all(); // rows added after the window is mapped need this
    row
}

/// Runs the picker window until a row is activated or it's dismissed.
/// `load_thumb` is only consulted for entries with `thumb: true`.
pub fn run(
    entries: Vec<Entry>,
    config: PickerConfig,
    load_thumb: Option<Rc<dyn Fn(&str) -> Option<Pixbuf>>>,
    on_activate: Box<dyn Fn(&Entry)>,
) {
    let pid_path = pidfile(config.program_name);
    if toggle_closed_existing(&pid_path, config.program_name) {
        return;
    }
    if entries.is_empty() {
        return;
    }

    if gtk::init().is_err() {
        eprintln!("{}: failed to initialise GTK", config.program_name);
        std::process::exit(1);
    }

    let _ = fs::write(&pid_path, std::process::id().to_string());

    let type_names = config.type_names.clone();
    let state = Rc::new(State {
        entries,
        query: RefCell::new(parse_query("", &type_names)),
    });
    let pending: Rc<RefCell<Vec<(gtk::Image, String)>>> = Rc::new(RefCell::new(Vec::new()));

    let win = gtk::Window::new(gtk::WindowType::Toplevel);
    win.init_layer_shell();
    win.set_layer(gtk_layer_shell::Layer::Overlay);
    win.set_keyboard_mode(gtk_layer_shell::KeyboardMode::Exclusive);

    // Layer surfaces take their natural size unless anchored to opposing
    // edges, and in practice that "natural size" comes out tiny (GTK's
    // height-for-width/scrolled-window natural-size machinery doesn't feed
    // gtk-layer-shell reliably). So width and height are both driven by
    // explicit set_size_request calls rather than left to negotiate; height
    // is recomputed from actual content (see `resize_to_content` below) so
    // it still shrinks to fit fewer entries and grows for taller rows
    // (e.g. image thumbnails), capped at `max_list_height`.
    let mut width_px: i32 = 0;
    let mut max_list_height: i32 = i32::MAX;
    if let Some(display) = gdk::Display::default() {
        if let Some(mon) = target_monitor(&display) {
            win.set_monitor(&mon);
            let g = mon.geometry();
            width_px = (g.width() as f64 * config.width_fraction) as i32;
            max_list_height = (g.height() as f64 * config.height_fraction) as i32;
        }
    }

    let search = gtk::SearchEntry::new();
    search.set_placeholder_text(Some(config.placeholder.as_str()));
    let listbox = gtk::ListBox::new();
    listbox.set_selection_mode(gtk::SelectionMode::Browse);

    // Recomputes the window height from the search box's and the (filtered,
    // currently-realized) list's actual preferred heights, capped at
    // `max_list_height`. Uses real GTK size requests rather than a
    // rows-times-row-height estimate so it accounts for mixed row heights
    // (text rows vs. taller image thumbnails) without knowing about them.
    let resize_to_content: Rc<dyn Fn()> = {
        let win = win.clone();
        let search = search.clone();
        let listbox = listbox.clone();
        Rc::new(move || {
            let search_h = search.preferred_height().1.max(1);
            let list_h = listbox.preferred_height().1;
            let target = (search_h + list_h).clamp(search_h, max_list_height);
            win.set_size_request(width_px, target);
        })
    };

    {
        let state = state.clone();
        listbox.set_filter_func(Some(Box::new(move |row: &gtk::ListBoxRow| {
            let q = state.query.borrow();
            // Rows are appended in order and never removed, so a row's index
            // is its index into `entries`.
            let Some(entry) = state.entries.get(row.index() as usize) else {
                return true;
            };
            if !q.kinds.is_empty() && !q.kinds.contains(&entry.kind) {
                return false;
            }
            q.text.is_empty() || entry.haystack.contains(q.text.as_str())
        })));
    }

    {
        let state = state.clone();
        let listbox = listbox.clone();
        let type_names = type_names.clone();
        let resize_to_content = resize_to_content.clone();
        // "changed", not "search-changed": GtkSearchEntry deliberately delays
        // search-changed by 150ms after the last keystroke, which reads as lag.
        // Filtering the whole list measures in single-digit ms.
        search.connect_changed(move |entry| {
            // Resolve the needle once per keystroke rather than once per row,
            // and drop the borrow before the filter func takes it.
            *state.query.borrow_mut() = parse_query(entry.text().as_str(), &type_names);
            listbox.invalidate_filter();
            let mut i = 0;
            while let Some(row) = listbox.row_at_index(i) {
                if row.is_child_visible() {
                    listbox.select_row(Some(&row));
                    break;
                }
                i += 1;
            }
            resize_to_content();
        });
    }

    {
        let state = state.clone();
        listbox.connect_row_activated(move |_, row| {
            if let Some(e) = state.entries.get(row.index() as usize) {
                on_activate(e);
            }
            gtk::main_quit();
        });
    }

    let scroll = gtk::ScrolledWindow::new(gtk::Adjustment::NONE, gtk::Adjustment::NONE);
    scroll.set_policy(gtk::PolicyType::Never, gtk::PolicyType::Automatic);
    scroll.add(&listbox);

    let vbox = gtk::Box::new(gtk::Orientation::Vertical, 0);
    vbox.pack_start(&search, false, false, 0);
    vbox.pack_start(&scroll, true, true, 0);
    win.add(&vbox);

    // Only enough rows to fill the visible list before the first frame.
    let cursor = Rc::new(RefCell::new(0usize));
    {
        let mut c = cursor.borrow_mut();
        let end = config.initial_rows.min(state.entries.len());
        for i in *c..end {
            listbox.add(&make_row(&state, i, config.thumb_height, &pending));
        }
        *c = end;
    }
    if let Some(first) = listbox.row_at_index(0) {
        listbox.select_row(Some(&first));
    }
    resize_to_content();

    {
        let listbox = listbox.clone();
        let search = search.clone();
        win.connect_key_press_event(move |_, ev| {
            use gdk::keys::constants as key;
            let k = ev.keyval();
            if k == key::Escape {
                gtk::main_quit();
                return glib::Propagation::Stop;
            }
            if k == key::Return || k == key::KP_Enter {
                if let Some(row) = listbox.selected_row() {
                    row.activate();
                }
                return glib::Propagation::Stop;
            }
            if k == key::Tab || k == key::ISO_Left_Tab {
                // Toggle instead of GTK's default focus-chain Tab, which
                // would walk into the list and then between individual rows.
                if search.is_focus() {
                    if listbox.selected_row().is_none() {
                        if let Some(row) = listbox.row_at_index(0) {
                            listbox.select_row(Some(&row));
                        }
                    }
                    if let Some(row) = listbox.selected_row() {
                        row.grab_focus();
                    }
                } else {
                    search.grab_focus();
                }
                return glib::Propagation::Stop;
            }
            let step: i32 = if k == key::Up {
                -1
            } else if k == key::Down {
                1
            } else if k == key::Page_Up {
                -10
            } else if k == key::Page_Down {
                10
            } else {
                return glib::Propagation::Proceed; // let the search entry have it
            };

            let mut visible = Vec::new();
            let mut i = 0;
            while let Some(row) = listbox.row_at_index(i) {
                if row.is_child_visible() {
                    visible.push(row);
                }
                i += 1;
            }
            if visible.is_empty() {
                return glib::Propagation::Stop;
            }
            let cur = listbox
                .selected_row()
                .and_then(|s| visible.iter().position(|r| r == &s))
                .unwrap_or(0) as i32;
            let idx = (cur + step).clamp(0, visible.len() as i32 - 1) as usize;
            let target = &visible[idx];
            listbox.select_row(Some(target));
            target.grab_focus();
            glib::Propagation::Stop
        });
    }

    win.connect_destroy(|_| gtk::main_quit());

    // atexit equivalents don't run on SIGTERM, which is exactly how the toggle
    // closes us.
    {
        let pid_path = pid_path.clone();
        glib::unix_signal_add_local(libc::SIGTERM, move || {
            let _ = fs::remove_file(&pid_path);
            gtk::main_quit();
            glib::ControlFlow::Break
        });
    }

    win.show_all();
    search.grab_focus();

    // Preferred-height queries against unrealized rows come back too small
    // (GTK hasn't run a size-allocate pass yet), so the accurate resize has
    // to happen after the window is shown, once.
    {
        let resize_to_content = resize_to_content.clone();
        glib::idle_add_local(move || {
            resize_to_content();
            glib::ControlFlow::Break
        });
    }

    // Stream the rest of the entries, then thumbnails, once we're already up.
    {
        let state = state.clone();
        let listbox = listbox.clone();
        let pending_rows = pending.clone();
        let cursor = cursor.clone();
        let chunk_rows = config.chunk_rows;
        let thumb_height = config.thumb_height;
        let resize_to_content = resize_to_content.clone();
        glib::idle_add_local(move || {
            let mut c = cursor.borrow_mut();
            let end = (*c + chunk_rows).min(state.entries.len());
            for i in *c..end {
                listbox.add(&make_row(&state, i, thumb_height, &pending_rows));
            }
            *c = end;
            resize_to_content();
            if *c < state.entries.len() {
                return glib::ControlFlow::Continue;
            }
            drop(c);

            // `load_thumb` is only cloned (never moved) out of the outer
            // closure's capture, since that closure runs on every chunk tick
            // and only the final tick reaches this branch.
            if let Some(load_thumb) = load_thumb.clone() {
                let pending_thumbs = pending_rows.clone();
                glib::idle_add_local(move || {
                    let next = pending_thumbs.borrow_mut().pop();
                    match next {
                        Some((img, id)) => {
                            if let Some(pb) = load_thumb(&id) {
                                img.set_from_pixbuf(Some(&pb));
                                img.set_size_request(-1, -1); // real image drives row height
                            }
                            glib::ControlFlow::Continue
                        }
                        None => glib::ControlFlow::Break,
                    }
                });
            }
            glib::ControlFlow::Break
        });
    }

    gtk::main();
    let _ = fs::remove_file(&pid_path);
}
