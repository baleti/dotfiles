//! The grid overlay itself: a layer-shell surface holding a `GtkFlowBox` of
//! window thumbnails (icon placeholders for now -- live captures land in
//! phase 4). Two-phase key state machine: while unlocked, Tab/Shift+Tab
//! (typed directly, or forwarded over the socket from a later Alt+Tab press
//! while this instance is already open) cycles the selection and releasing
//! Alt confirms it; pressing any other printable key locks the grid into
//! search mode (a `GtkSearchEntry` filters the grid -- the `/verb`
//! command DSL from `query.rs`), Alt no longer confirms once locked, and
//! Enter/Escape confirm/cancel in either mode.
//!
//! **A window-identity subtlety worth knowing before touching filtering,
//! sorting, or selection**: `state.selected` and the arrow-key/Tab
//! navigation in `run()`'s key handler are all built around *visual grid
//! position* (a `FlowBoxChild`'s live index in the box), because that's
//! what "arrow right" spatially means once `/sort` can reorder the grid --
//! `state.windows`' own index into that Vec is a *separate*, stable
//! identity that survives any resort. `child_window_idx` (reading a small
//! integer stashed in each child's `widget_name` at creation, since
//! `FlowBoxChild::index()` itself changes under a custom sort func and so
//! can't be used to recover "which window is this") is what bridges the
//! two: filtering, sorting, and `confirm()` all resolve *from* a
//! FlowBoxChild *to* a window index this way rather than assuming the two
//! numbers are ever the same.

use std::cell::RefCell;
use std::io::Read;
use std::os::unix::io::AsRawFd;
use std::os::unix::net::UnixListener;
use std::rc::Rc;

use gtk::prelude::*;
use gtk_layer_shell::LayerShell;

use crate::enrich::TmuxClaudeMeta;
use crate::hyprctl::{self, Window};
use crate::query::{self, ResolvedField};

const MIN_FRAME: i32 = 64;
// Raised from 240: aspect-matched cells (see `grid_dims`) now often earn a
// taller height budget for portrait windows, and capping the thumbnail
// itself well below that budget would just turn the extra room back into
// dead space under/over the frame instead of a bigger, more legible
// thumbnail.
const MAX_FRAME: i32 = 320;
// A 2-line label plus its spacing under the frame.
const LABEL_ALLOWANCE: i32 = 54;
// Per-cell margin + flowbox row/column spacing, horizontal and vertical.
const CELL_H_OVERHEAD: i32 = 24;
const CELL_V_OVERHEAD: i32 = 24;

/// The grid's baseline shown column -- just the title. `workspace`/`pid`
/// and any `tmux`/`claude` field stay hidden until `/at` (or a surviving
/// `/ft`) brings them in.
const DEFAULT_COLUMNS: [ResolvedField; 1] = [ResolvedField::Flat("title")];

/// The aspect ratio (height/width) most windows in this set share, so
/// `grid_dims` can shape the grid's cells to match instead of assuming
/// they're roughly square. Median rather than mean so one or two outliers
/// (an ultra-wide terminal next to a stack of portrait browsers) can't drag
/// the whole grid's shape away from what most cells actually need.
fn typical_aspect(windows: &[Window]) -> f64 {
    let mut ratios: Vec<f64> = windows
        .iter()
        .filter(|w| w.width > 0 && w.height > 0)
        .map(|w| (w.height as f64 / w.width as f64).clamp(0.3, 3.0))
        .collect();
    if ratios.is_empty() {
        return 1.0;
    }
    ratios.sort_by(|a, b| a.partial_cmp(b).unwrap());
    ratios[ratios.len() / 2]
}

/// A column/row split shaped so each cell's own budget box comes out close
/// to `aspect` (the typical window's height/width), rather than always a
/// near-square split. A near-square grid is fine when windows are
/// themselves roughly square, but boxing mostly-portrait windows into
/// near-square cells forces `frame_size` to letterbox them -- fit to the
/// cell's height and leave the rest of the cell's width empty -- which is
/// what reads as oversized gaps between thumbnails. Solving cell_h/cell_w =
/// aspect for a grid that tiles an `avail_w` x `avail_h` box (cell_w =
/// avail_w/cols, cell_h ~= avail_h*cols/n since rows ~= n/cols) gives
/// `cols = sqrt(aspect * n * avail_w / avail_h)`. Clamped to [2, 8]: below
/// 2, a single window sits in an oddly narrow sliver; above 8 a wall of
/// cells reads worse than more rows.
fn grid_dims(n: usize, aspect: f64, avail_w: i32, avail_h: i32) -> (i32, i32) {
    let n = n.max(1);
    if n == 1 {
        return (1, 1);
    }
    let n_f = n as f64;
    let ideal_cols = (aspect * n_f * avail_w.max(1) as f64 / avail_h.max(1) as f64).sqrt();
    let cols = (ideal_cols.round() as i32).clamp(2, (n as i32).min(8));
    let rows = (n_f / cols as f64).ceil() as i32;
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

/// A grid label is a one-line caption under a thumbnail, not a text
/// viewer -- cap how much of any one field's value it will render. Without
/// this, a field like `claude.contents` (up to 20,000 chars of transcript
/// text, see `enrich.rs`) landing in the active columns -- whether typed
/// explicitly or picked up incidentally by an ambiguous substring match
/// (`/at cla` matches `class` *and* `claude`, and a bare group expands to
/// every subfield) -- means every window's label markup-escapes and lays
/// out tens of thousands of characters on *every keystroke*
/// (`connect_search_changed` re-renders all labels), which is slow enough
/// on the GTK main thread to look and feel like the whole grid froze.
const MAX_LABEL_VALUE_CHARS: usize = 80;

fn truncate_for_label(v: &str) -> std::borrow::Cow<'_, str> {
    if v.chars().count() <= MAX_LABEL_VALUE_CHARS {
        return std::borrow::Cow::Borrowed(v);
    }
    let head: String = v.chars().take(MAX_LABEL_VALUE_CHARS).collect();
    std::borrow::Cow::Owned(format!("{head}…"))
}

/// `seriesPalette` out of gen-theme.py's live scheme file -- 8 hues spaced
/// off the current wallpaper-derived primary color, picked there
/// specifically "to color distinguishable series (CPU cores, network
/// interfaces, disk devices)" (see that script's `build_scheme`), which is
/// exactly the shape this needs: a handful of columns that all need to
/// read as different things at a glance, recoloring itself with the rest
/// of the theme rather than a color this crate would have to keep in sync
/// by hand. Empty (never an error) if the file is missing or malformed --
/// gen-theme.py hasn't run yet, or this machine has no wallpaper-driven
/// theme at all -- and every call site below already treats an empty
/// palette as "render plain," so there's nothing further to fall back to.
fn load_theme_palette() -> Vec<String> {
    let Some(home) = std::env::var_os("HOME") else { return Vec::new() };
    let path = std::path::PathBuf::from(home).join(".local/state/quickshell/scheme.json");
    let Ok(content) = std::fs::read_to_string(path) else { return Vec::new() };
    let Ok(v) = serde_json::from_str::<serde_json::Value>(&content) else { return Vec::new() };
    v.get("seriesPalette")
        .and_then(|p| p.as_array())
        .map(|arr| arr.iter().filter_map(|c| c.as_str().map(str::to_string)).collect())
        .unwrap_or_default()
}

/// Which palette entry a field gets -- a simple string hash of its dotted
/// key (`"claude.contents"`), not an assignment order, so the same field
/// keeps the same color across different `/at` combinations and across
/// relaunches (as long as the palette itself doesn't change). `None` if
/// the palette is empty.
fn field_color<'a>(field: ResolvedField, palette: &'a [String]) -> Option<&'a str> {
    if palette.is_empty() {
        return None;
    }
    let hash = field.key().bytes().fold(5381u32, |h, b| h.wrapping_mul(33).wrapping_add(b as u32));
    Some(palette[hash as usize % palette.len()].as_str())
}

/// Builds the markup for a grid cell's label from the currently active
/// columns, in order -- `workspace` keeps its existing small-muted "#N"
/// treatment wherever it appears, everything else renders plain, space-
/// joined. `title` falls back to `win.class` when empty, the same
/// long-standing behaviour from before columns were configurable. An empty
/// value (a `tmux`/`claude` field not yet enriched in, or genuinely blank)
/// is simply omitted rather than shown as a placeholder, so a still-loading
/// column doesn't flash empty brackets into the label. Long values are
/// truncated first (see `truncate_for_label`) -- this is a caption, not a
/// text viewer, and the untruncated value is still what filtering/sorting
/// compare against.
///
/// Any column that isn't one of `DEFAULT_COLUMNS` -- i.e. one the user
/// brought in with `/at` (or a surviving `/ft`) -- gets colored from
/// `palette` (see `load_theme_palette`/`field_color`) so several added
/// types read as visually distinct at a glance instead of one run-on
/// string; `title` (the only default) and an empty palette both render
/// plain, same as before this existed.
fn render_label(label: &gtk::Label, win: &Window, meta: &TmuxClaudeMeta, columns: &[ResolvedField], palette: &[String]) {
    if columns.is_empty() {
        label.set_text("");
        return;
    }
    let mut parts = Vec::new();
    for &field in columns {
        let mut v = query::sort_field_value(win, meta, field);
        if field == ResolvedField::Flat("title") && v.is_empty() {
            v = win.class.clone();
        }
        if v.is_empty() {
            continue;
        }
        let v = truncate_for_label(&v);
        let escaped = glib::markup_escape_text(&v);
        let color = if DEFAULT_COLUMNS.contains(&field) { None } else { field_color(field, palette) };
        let is_workspace = field == ResolvedField::Flat("workspace");
        let text = match (is_workspace, color) {
            (true, Some(c)) => format!("<span size=\"smaller\" foreground=\"{c}\">#{escaped}</span>"),
            (true, None) => format!("<span size=\"smaller\" alpha=\"55%\">#{escaped}</span>"),
            (false, Some(c)) => format!("<span foreground=\"{c}\">{escaped}</span>"),
            (false, None) => escaped.to_string(),
        };
        parts.push(text);
    }
    label.set_markup(&parts.join(" "));
}

/// Which of the four completion stages the popup is currently offering --
/// determines what `accept_suggestion` splices into the query text. Only
/// one stage is ever live at once (`query::completion_context` returns a
/// single `Completion`), so this only needs to remember which, not
/// several.
#[derive(Clone)]
enum SuggestionKind {
    /// A verb short form being typed (`/f` -> `fv`, `ft`). Accepting
    /// inserts `/<chosen> ` (trailing space) for a path-taking verb so
    /// completion re-triggers at the path stage, or `/rv ` for `/reverse`
    /// which takes no argument.
    Verb,
    /// A type path being typed as an argument. Accepting a group leaves a
    /// trailing `.` ready for a subfield (`query::is_group`); a flat type
    /// or an explicit subfield completes the token, plus a trailing `:`
    /// when the governing verb is `/fv` (ready for a value).
    TypePath(query::Verb),
    /// Sort direction. Accepting inserts `<chosen> ` (trailing space,
    /// complete term).
    SortDirection,
    /// Filter value for `/fv`. Accepting inserts `/fv <field>:<value> `
    /// (re-quoted if it contains whitespace), trailing-space "complete
    /// term".
    Value(String),
    /// Filter value for a field-verb shorthand (`/claude.contents`) -
    /// same live-value corpus as `Value`, but the verb already named the
    /// field, so accepting just inserts `<value> ` with no `field:`
    /// prefix.
    FieldValue,
}

struct State {
    windows: Vec<Window>,
    /// Parallel to `windows` (same index) -- tmux/claude metadata, filled in
    /// asynchronously by `enrich::start` well after the grid is already
    /// shown. All-default until then; see query.rs's `/tmux/*`/`/claude/*`
    /// handling for why an unfilled field just doesn't match yet rather
    /// than needing special-casing here.
    tmux_claude: Vec<RefCell<TmuxClaudeMeta>>,
    /// Visual grid position of the current selection -- see this module's
    /// own doc comment for why that's a distinct thing from a window's
    /// index into `windows` once `/sort` can reorder the grid.
    selected: RefCell<usize>,
    locked: RefCell<bool>,
    active_columns: RefCell<Vec<ResolvedField>>,
    sort_actions: RefCell<query::Actions>,
    /// Autocomplete popup state, live only while `query::completion_context`
    /// matches the current query. `suggestions` empty means the popup is
    /// hidden; `suggestion_start` is the byte offset in the query text
    /// that a chosen suggestion replaces; `suggestion_kind` is `None`
    /// exactly when `suggestions` is empty.
    suggestions: RefCell<Vec<String>>,
    suggestion_idx: RefCell<usize>,
    suggestion_start: RefCell<usize>,
    suggestion_kind: RefCell<Option<SuggestionKind>>,
    /// The current theme's `seriesPalette` (see `load_theme_palette`), read
    /// once at startup -- immutable for the life of the grid, so every
    /// `render_label` call site reads it from here rather than threading
    /// its own copy through each closure.
    palette: Vec<String>,
}

/// The window index stashed in a `FlowBoxChild`'s `widget_name` at creation
/// (`make_child`) -- see this module's doc comment for why this, and not
/// `FlowBoxChild::index()`, is what every lookup from a child back to "which
/// window is this" has to go through once a custom sort func is in play.
fn child_window_idx(child: &gtk::FlowBoxChild) -> Option<usize> {
    child.widget_name().parse().ok()
}

/// Returns the child alongside its thumbnail `Image` and its metadata
/// `Label` so callers can swap in a live capture later
/// (`wayland_capture::start`'s `on_thumbnail` callback) or re-render the
/// label (`render_label`, on every keystroke and on enrichment) without
/// having to dig back through the widget tree.
///
/// No icon placeholder: the image starts empty in a `frame_size`-sized
/// frame (outline via the "thumb-frame" CSS class set up in `run()`) that
/// already approximates the real window's shape, and just stays that way
/// until (unless) a live capture lands in it -- a small icon swapped out
/// for a live capture used to read as a flicker even once it stopped
/// resizing the cell.
fn make_child(
    win: &Window,
    meta: &TmuxClaudeMeta,
    columns: &[ResolvedField],
    palette: &[String],
    idx: usize,
    cell_w: i32,
    max_h: i32,
) -> (gtk::FlowBoxChild, gtk::Image, gtk::Label) {
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

    let label = gtk::Label::new(None);
    render_label(&label, win, meta, columns, palette);
    label.set_ellipsize(gtk::pango::EllipsizeMode::End);
    label.set_max_width_chars(1); // let ellipsize kick in early, as in picker.rs
    label.set_lines(2);
    label.set_justify(gtk::Justification::Center);
    vbox.pack_start(&label, false, false, 0);

    let child = gtk::FlowBoxChild::new();
    child.set_widget_name(&idx.to_string());
    child.add(&vbox);
    child.set_margin(8);
    child.show_all();
    (child, image, label)
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

/// `(long-form alias, one-line description)` for a short verb form, for the
/// marginalia-style autocomplete hints (query-dsl.md's "Suggestion row
/// anatomy"). Keep in sync with that doc's table, picker.rs's `verb_meta`
/// and QueryDsl.qml's `verbInfo`.
fn verb_meta(short: &str) -> (&'static str, &'static str) {
    match short {
        "fv" => ("/filter-value", "keep windows whose value matches (substring)"),
        "ft" => ("/filter-type", "show only the matching columns"),
        "at" => ("/add-type", "add the matching columns"),
        "rt" => ("/remove-type", "drop the matching columns"),
        "s" => ("/sort", "order windows by one field, optional asc / desc"),
        "rv" => ("/reverse", "flip the current order"),
        _ => ("", ""),
    }
}

/// One-line description of a type path (flat type or group) for the
/// type-path autocomplete stage. `""` -> no description shown.
fn type_desc(path: &str) -> &'static str {
    match path {
        "title" => "the window title",
        "workspace" => "the Hyprland workspace",
        "pid" => "the process id",
        "tmux" => "tmux session / window on this terminal",
        "tmux.session" => "tmux session name",
        "tmux.window" => "tmux window name",
        "tmux.title" => "tmux window title",
        "claude" => "Claude Code session on this terminal",
        "claude.title" => "Claude Code session title",
        "claude.path" => "Claude Code working directory",
        "claude.session" => "Claude Code session id",
        "claude.time" => "how long ago the transcript last changed",
        "claude.contents" => "Claude Code transcript text",
        _ => "",
    }
}

/// Greyed marginalia label -- Pango `alpha` is relative to the resolved
/// text colour, so it stays readable on both the normal and selected-row
/// backgrounds (same trick the result-grid `#N` prefix uses).
fn dim_label(text: &str) -> gtk::Label {
    let l = gtk::Label::new(None);
    l.set_markup(&format!("<span alpha=\"55%\">{}</span>", glib::markup_escape_text(text)));
    l.set_halign(gtk::Align::Start);
    l
}

/// One rendered autocomplete row: visible label + greyed alias + greyed
/// description (any of the latter two empty -> omitted).
struct SuggestRow {
    label: String,
    alias: String,
    desc: String,
}

/// Populates `list` with one row per entry in `rows` and reveals it -- the
/// shared tail end of `update_suggestions` regardless of which completion
/// stage is live.
fn populate_suggestions(list: &gtk::ListBox, rows: &[SuggestRow]) {
    for r in rows {
        let row = gtk::ListBoxRow::new();
        let hbox = gtk::Box::new(gtk::Orientation::Horizontal, 8);

        let label = gtk::Label::new(Some(&r.label));
        label.set_halign(gtk::Align::Start);
        hbox.add(&label);
        label.show();
        if !r.alias.is_empty() {
            let a = dim_label(&format!("({})", r.alias));
            hbox.add(&a);
            a.show();
        }
        if !r.desc.is_empty() {
            let d = dim_label(&r.desc);
            hbox.add(&d);
            d.show();
        }

        row.add(&hbox);
        hbox.show();
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
        // `search` already uses a few lines up in `run()`. The row's
        // children are shown as they're built above.
        row.show();
    }
    list.show();
}

/// Re-derives the autocomplete popup from the query text on every
/// keystroke -- cheap (at most a handful of fields, or a couple dozen
/// windows' worth of one field's values, to filter), so no need to diff
/// against the previous state. One `query::completion_context` call
/// decides which of the four stages (if any) is live; this just renders
/// whichever it is.
fn update_suggestions(query_text: &str, list: &gtk::ListBox, state: &Rc<State>) {
    for child in list.children() {
        list.remove(&child);
    }

    let Some(completion) = query::completion_context(query_text) else {
        hide_suggestions(list, state);
        return;
    };
    let metas = snapshot_metas(state);
    let items = query::completion_candidates(&completion, &state.windows, &metas);
    if items.is_empty() {
        hide_suggestions(list, state);
        return;
    }

    let (start, kind) = match &completion {
        query::Completion::Verb { start, .. } => (*start, SuggestionKind::Verb),
        query::Completion::TypePath { start, verb, .. } => (*start, SuggestionKind::TypePath(*verb)),
        query::Completion::SortDirection { start, .. } => (*start, SuggestionKind::SortDirection),
        query::Completion::Value { start, field, .. } => (*start, SuggestionKind::Value(field.key())),
        query::Completion::FieldValue { start, .. } => (*start, SuggestionKind::FieldValue),
    };

    let rows: Vec<SuggestRow> = items
        .iter()
        .map(|item| match &kind {
            SuggestionKind::Verb => {
                // Core verbs (fv/ft/...) get a long-form alias from
                // `verb_meta`; field-verbs (`claude`, `claude.contents`,
                // ...) have no alias of their own, but reuse the same
                // per-field description `type_desc` already carries for
                // the type-path stage.
                let (alias, desc) = verb_meta(item);
                let desc = if desc.is_empty() { type_desc(item) } else { desc };
                SuggestRow { label: format!("/{item}"), alias: alias.into(), desc: desc.into() }
            }
            SuggestionKind::TypePath(_) => {
                SuggestRow { label: item.clone(), alias: String::new(), desc: type_desc(item).into() }
            }
            SuggestionKind::SortDirection | SuggestionKind::Value(_) | SuggestionKind::FieldValue => {
                SuggestRow { label: item.clone(), alias: String::new(), desc: String::new() }
            }
        })
        .collect();

    populate_suggestions(list, &rows);
    *state.suggestions.borrow_mut() = items;
    *state.suggestion_start.borrow_mut() = start;
    *state.suggestion_kind.borrow_mut() = Some(kind);
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
/// chosen completion -- see `SuggestionKind`'s own doc for what each stage
/// splices in. A value containing whitespace is re-quoted on the way back
/// in -- otherwise splicing it in unquoted would immediately re-split into
/// two tokens the moment this fires, undoing the very quote-aware
/// tokenizing that made it matchable in the first place (see query.rs's
/// module doc).
fn accept_suggestion(search: &gtk::SearchEntry, list: &gtk::ListBox, state: &Rc<State>) {
    let idx = *state.suggestion_idx.borrow();
    let Some(chosen) = state.suggestions.borrow().get(idx).cloned() else {
        return;
    };
    let Some(kind) = state.suggestion_kind.borrow().clone() else {
        return;
    };
    let start = *state.suggestion_start.borrow();
    let query_text = search.text();
    let prefix = &query_text[..start];
    let new_query = match kind {
        SuggestionKind::Verb => {
            // "rv"/"reverse" take no argument; everything else does, so
            // leave a trailing space to re-trigger path completion.
            format!("{prefix}/{chosen} ")
        }
        SuggestionKind::TypePath(verb) => {
            if query::is_group(&chosen) {
                // ready for `.sub`, or to stand on its own
                format!("{prefix}{chosen}")
            } else if verb == query::Verb::FilterValue {
                format!("{prefix}{chosen}:")
            } else {
                format!("{prefix}{chosen} ")
            }
        }
        SuggestionKind::SortDirection => format!("{prefix}{chosen} "),
        SuggestionKind::Value(field_key) => {
            // `prefix` already ends in `/fv ` -- the last token is just
            // `path:frag`, so only the `path:value ` is spliced back.
            let value = if chosen.contains(char::is_whitespace) {
                format!("\"{chosen}\"")
            } else {
                chosen
            };
            format!("{prefix}{field_key}:{value} ")
        }
        SuggestionKind::FieldValue => {
            // `prefix` already ends in `/claude.contents ` -- the verb
            // named the field, so just the bare value is spliced back, no
            // `field:` prefix.
            let value = if chosen.contains(char::is_whitespace) {
                format!("\"{chosen}\"")
            } else {
                chosen
            };
            format!("{prefix}{value} ")
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
///
/// Resolves the confirmed window from the *visual* selection position via
/// `flowbox` (see this module's doc comment on why that's not the same as
/// an index into `state.windows` once `/sort` may have reordered the grid).
fn confirm(win: &gtk::Window, state: &Rc<State>, flowbox: &gtk::FlowBox) {
    let visual_idx = *state.selected.borrow();
    let address = flowbox
        .child_at_index(visual_idx as i32)
        .and_then(|c| child_window_idx(&c))
        .and_then(|wi| state.windows.get(wi))
        .map(|w| w.address.clone());
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
        active_columns: RefCell::new(DEFAULT_COLUMNS.to_vec()),
        sort_actions: RefCell::new(query::Actions::default()),
        suggestions: RefCell::new(Vec::new()),
        suggestion_idx: RefCell::new(0),
        suggestion_start: RefCell::new(0),
        suggestion_kind: RefCell::new(None),
        palette: load_theme_palette(),
    });

    // The box the grid may claim -- height's fraction raised from the old
    // fixed 0.6 to 0.78 so a portrait-heavy window set (see `grid_dims`) has
    // room to actually use the extra rows it now prefers, instead of being
    // squeezed back toward letterboxed near-square cells.
    let (avail_w, avail_h) = match &monitor {
        Some(mon) => {
            let g = mon.geometry();
            ((g.width() as f64 * 0.7) as i32, (g.height() as f64 * 0.78) as i32)
        }
        None => (900, 700),
    };

    let aspect = typical_aspect(&state.windows);
    let (cols, rows) = grid_dims(state.windows.len(), aspect, avail_w, avail_h);

    // Cells are sized to match the *typical* window's aspect ratio instead
    // of splitting `avail_w`/`avail_h` evenly -- see `grid_dims`. The window
    // then only claims however much of that box it actually needs (rows *
    // cell_h_budget, cols * cell_w_budget), rather than always the full
    // fraction regardless of what's being shown.
    let cell_w_budget = (avail_w / cols).max(MIN_FRAME + CELL_H_OVERHEAD);
    let cell_h_budget = (((cell_w_budget as f64) * aspect) as i32)
        .min(avail_h / rows)
        .max(MIN_FRAME + LABEL_ALLOWANCE + CELL_V_OVERHEAD);
    let win_w = (cell_w_budget * cols).min(avail_w);
    let win_h = (cell_h_budget * rows).min(avail_h);

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
    let mut cell_labels: Vec<gtk::Label> = Vec::with_capacity(state.windows.len());
    {
        let columns = state.active_columns.borrow();
        for (i, win_entry) in state.windows.iter().enumerate() {
            let meta = state.tmux_claude[i].borrow();
            let (child, image, label) = make_child(win_entry, &meta, &columns, &state.palette, i, cell_w, max_h);
            flowbox.add(&child);
            thumb_images.push(image);
            cell_labels.push(label);
        }
    }

    let scroll = gtk::ScrolledWindow::new(gtk::Adjustment::NONE, gtk::Adjustment::NONE);
    scroll.set_policy(gtk::PolicyType::Never, gtk::PolicyType::Automatic);
    scroll.add(&flowbox);

    // Hidden until a non-Tab/Enter/Escape key locks the grid into search
    // mode; `no_show_all` keeps `win.show_all()` below from revealing it.
    let search = gtk::SearchEntry::new();
    search.set_no_show_all(true);

    // Field/action autocomplete popup: an in-layout ListBox directly under
    // the search entry (not a GtkPopover) -- gtk-layer-shell's layer
    // surface has no xdg_popup positioner to anchor a real popover to, so
    // this just reserves its own row in the same vbox and is shown/hidden
    // as query text comes and goes -- see ~/.config/docs/query-dsl.md's
    // autocompletion section.
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

    // Grows (never shrinks below the original grid layout) the window's
    // fixed layer-shell height to fit whatever's actually showing:
    // `search` once search mode locks it in, the autocomplete popup, and
    // the grid itself -- whose row height isn't fixed either, since
    // `make_child`'s `set_lines(2)` lets a label wrap onto a second line
    // once enough `/at` columns are active, which the original
    // `LABEL_ALLOWANCE` budget (sized for the single-line default) doesn't
    // reserve room for. Without this, extra columns or the search box just
    // pushed rows below the surface's fixed height with nothing to scroll
    // back to them -- confirmed by testing `/at pid /at workspace`, which
    // grows two of the three joined label parts onto a wrapped second
    // line. `win_w` never changes -- only height does. Clamped at
    // `max_win_h`, a bit past the original `avail_h`, so it can't grow
    // past a usable fraction of the monitor; beyond that the grid's own
    // `ScrolledWindow` (vertical `Automatic`) takes over as before.
    let max_win_h = match &monitor {
        Some(mon) => ((mon.geometry().height() as f64) * 0.92) as i32,
        None => avail_h,
    };
    let resize_to_content: Rc<dyn Fn()> = {
        let win = win.clone();
        let search = search.clone();
        let suggestions_list = suggestions_list.clone();
        let flowbox = flowbox.clone();
        let state = state.clone();
        Rc::new(move || {
            let search_h = if *state.locked.borrow() { search.preferred_height().1 } else { 0 };
            let sugg_h = if !state.suggestions.borrow().is_empty() { suggestions_list.preferred_height().1 } else { 0 };
            let grid_h = flowbox.preferred_height().1;
            let target = (search_h + sugg_h + grid_h).max(win_h).min(max_win_h);
            win.set_size_request(win_w, target);
        })
    };

    flowbox.set_filter_func(Some(Box::new({
        let state = state.clone();
        let search = search.clone();
        move |child: &gtk::FlowBoxChild| {
            if !*state.locked.borrow() {
                return true;
            }
            let Some(idx) = child_window_idx(child) else { return false };
            let Some(w) = state.windows.get(idx) else { return false };
            let meta = state.tmux_claude.get(idx).map(|m| m.borrow().clone()).unwrap_or_default();
            let q = search.text();
            crate::query::matches_str(w, &meta, &q)
        }
    })));

    flowbox.set_sort_func(Some(Box::new({
        let state = state.clone();
        move |a: &gtk::FlowBoxChild, b: &gtk::FlowBoxChild| -> i32 {
            let (Some(ia), Some(ib)) = (child_window_idx(a), child_window_idx(b)) else {
                return 0;
            };
            let actions = state.sort_actions.borrow();
            let mut ord = match &actions.sort {
                Some((field, direction)) => {
                    let meta_a = state.tmux_claude.get(ia).map(|m| m.borrow().clone()).unwrap_or_default();
                    let meta_b = state.tmux_claude.get(ib).map(|m| m.borrow().clone()).unwrap_or_default();
                    let va = state.windows.get(ia).map(|w| query::sort_field_value(w, &meta_a, *field)).unwrap_or_default();
                    let vb = state.windows.get(ib).map(|w| query::sort_field_value(w, &meta_b, *field)).unwrap_or_default();
                    query::compare_with_direction(&va, &vb, *direction)
                }
                // No /sort/ typed: keep the grid's own default (recency)
                // order, i.e. compare by the stable window index itself.
                None => ia.cmp(&ib),
            };
            if actions.reverse {
                ord = ord.reverse();
            }
            match ord {
                std::cmp::Ordering::Less => -1,
                std::cmp::Ordering::Equal => 0,
                std::cmp::Ordering::Greater => 1,
            }
        }
    })));

    {
        let flowbox = flowbox.clone();
        let suggestions_list = suggestions_list.clone();
        let state = state.clone();
        let cell_labels = cell_labels.clone();
        let resize_to_content = resize_to_content.clone();
        search.connect_search_changed(move |entry| {
            let q = entry.text();
            *state.active_columns.borrow_mut() = crate::query::active_columns(&q, &DEFAULT_COLUMNS);
            *state.sort_actions.borrow_mut() = crate::query::parse_actions(&q);
            for (i, label) in cell_labels.iter().enumerate() {
                let meta = state.tmux_claude[i].borrow();
                render_label(label, &state.windows[i], &meta, &state.active_columns.borrow(), &state.palette);
            }
            flowbox.invalidate_filter();
            flowbox.invalidate_sort();
            // Move `selected` (what Enter confirms) to the first *visually
            // positioned* match, but without `select()`'s grab_focus() --
            // that would yank keyboard focus back out of the search entry
            // mid-type. Has to walk the flowbox's own current child order
            // (not `state.windows` directly), since that order is what
            // "first" means once /sort has reordered it.
            let mut i = 0;
            while let Some(child) = flowbox.child_at_index(i) {
                if child.is_child_visible() {
                    *state.selected.borrow_mut() = i as usize;
                    flowbox.select_child(&child);
                    break;
                }
                i += 1;
            }
            update_suggestions(&q, &suggestions_list, &state);
            resize_to_content();
        });
    }

    {
        let win = win.clone();
        let state = state.clone();
        let flowbox_for_activate = flowbox.clone();
        flowbox.connect_child_activated(move |_, child| {
            *state.selected.borrow_mut() = child.index() as usize;
            confirm(&win, &state, &flowbox_for_activate);
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
        let resize_to_content = resize_to_content.clone();
        win.connect_key_press_event(move |_, ev| {
            use gdk::keys::constants as key;
            let k = ev.keyval();
            let shift = ev.state().contains(gdk::ModifierType::SHIFT_MASK);
            let ctrl = ev.state().contains(gdk::ModifierType::CONTROL_MASK);
            let locked = *state.locked.borrow();

            // Autocomplete popup takes over Ctrl+j/k, Tab, and Escape while
            // it's showing -- checked before any of those keys' normal
            // meaning below, and before the generic Escape-quits-the-grid
            // handling right after this block, since the popup's own
            // Escape only dismisses itself.
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
                confirm(&win_for_confirm, &state, &flowbox);
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
                        // `search-changed` (connected above) is rate-limited
                        // by GTK, so resize right away too -- otherwise the
                        // entry appearing at all (even before its debounced
                        // text-changed callback fires) still needs the extra
                        // row `resize_to_content` accounts for.
                        resize_to_content();
                        return glib::Propagation::Stop;
                    }
                }
            }

            glib::Propagation::Proceed
        });
    }

    {
        let win_for_confirm = win.clone();
        let flowbox_for_confirm = flowbox.clone();
        let state = state.clone();
        win.connect_key_release_event(move |_, ev| {
            use gdk::keys::constants as key;
            let k = ev.keyval();
            if (k == key::Alt_L || k == key::Alt_R) && !*state.locked.borrow() {
                confirm(&win_for_confirm, &state, &flowbox_for_confirm);
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

    // Preferred-height queries against just-realized rows can come back too
    // small (no size-allocate pass has run yet) -- same gotcha picker.rs's
    // own `resize_to_content` documents -- so the first accurate measurement
    // has to happen once the window is actually up.
    {
        let resize_to_content = resize_to_content.clone();
        glib::idle_add_local(move || {
            resize_to_content();
            glib::ControlFlow::Break
        });
    }

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
    // `/tmux/*`/`/claude/*` query already typed keeps matching live -- see
    // enrich.rs's module doc for why this has to stay off the critical path
    // (a slow tmux server or a large transcript read must never delay the
    // grid's first paint, which by this point has already happened). Labels
    // are re-rendered too, in case the newly-landed data now shows up in an
    // already-active column.
    let state_for_enrich = state.clone();
    let flowbox_for_enrich = flowbox.clone();
    let cell_labels_for_enrich = cell_labels;
    crate::enrich::start(&state.windows, move |index, meta| {
        if let Some(cell) = state_for_enrich.tmux_claude.get(index) {
            cell.borrow_mut().merge(meta);
            if let (Some(label), Some(win)) = (cell_labels_for_enrich.get(index), state_for_enrich.windows.get(index)) {
                let m = cell.borrow();
                render_label(label, win, &m, &state_for_enrich.active_columns.borrow(), &state_for_enrich.palette);
            }
            flowbox_for_enrich.invalidate_filter();
            flowbox_for_enrich.invalidate_sort();
        }
    });

    gtk::main();
}
