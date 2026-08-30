//! Shared GTK3 + wlr-layer-shell picker engine: a search box over a
//! GtkListBox, with the `/verb` command DSL (autocompleted, see
//! `update_suggestions`), keyboard navigation and an activate callback.
//! Extracted from the original clipboard-picker so the same
//! window/search/filter/keyboard machinery can back other pickers (e.g. a
//! dunst notification-history picker) without duplicating it.
//!
//! Callers own everything source-specific: how entries are fetched
//! (including their named `fields`, see `Entry`), how (or whether)
//! thumbnails are loaded, and what activating a row does.
//!
//! The grammar, its quoting, and its autocomplete popup are deliberately
//! the same design winswitch's `query.rs` uses (ported by hand, not shared
//! code -- see ~/.config/docs/query-dsl.md for why and for the full spec
//! this is one more implementation of). Two things worth knowing before
//! touching either: (1) this picker only *acts* on `/fv` (and bare text,
//! the same thing) - it renders no columns and has no re-sort, so `/ft`,
//! `/at`, `/rt`, `/s`, `/rv` are recognised-but-inert; (2) winswitch's
//! bare free words are ANDed independently, this picker's join into one
//! phrase matched as a single literal run against `Entry::haystack` -
//! original clipboard-picker behaviour, predates this DSL, left as-is.

use std::cell::RefCell;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::rc::Rc;

use gdk_pixbuf::Pixbuf;
use gtk::prelude::*;
use gtk_layer_shell::LayerShell;

pub struct Entry {
    pub id: String,
    /// Text shown in the row (single line, ellipsized) unless `thumb` is set.
    pub preview: String,
    /// Lowercased text matched against the free-text part of the query --
    /// always present and always searchable with no special syntax, the
    /// same "there's always a plain-typing default" contract every picker
    /// in this repo's DSL keeps (clipboard contents here; window
    /// title+class for winswitch's alt-tab; pane scrollback for
    /// window-search.py -- see query-dsl.md's design principles).
    pub haystack: String,
    /// Named field values this entry has, for `/fv field:value` filtering and
    /// autocomplete -- e.g. `[("type", "image"), ("date", "5m")]`. A field
    /// name a caller never populates for some entries (e.g. no logged
    /// timestamp yet) is simply absent from that entry's list rather than
    /// present with an empty value; see `field_value`.
    pub fields: Vec<(&'static str, String)>,
    /// True if this entry should render as a lazily-loaded thumbnail image
    /// instead of a text label (requires `load_thumb` to be set in `run`).
    pub thumb: bool,
}

fn field_value<'a>(entry: &'a Entry, field: &str) -> Option<&'a str> {
    entry.fields.iter().find(|(k, _)| *k == field).map(|(_, v)| v.as_str())
}

/// Case-insensitive substring containment - the one matching rule for
/// every field name and every filter value (see
/// ~/.config/docs/query-dsl.md). Empty needle always matches.
fn substr(needle: &str, hay: &str) -> bool {
    hay.to_lowercase().contains(&needle.to_lowercase())
}

/// Every accepted verb spelling (short and long). This picker only *acts*
/// on `/fv` / `/filter-value` (and bare text, which is the same thing) -
/// it renders no columns and has no re-sort, so `/ft`, `/at`, `/rt`,
/// `/s`, `/rv` and their long forms are recognised (so they don't fall
/// into the free-text phrase) but otherwise inert. See query-dsl.md.
const VERB_FORMS: &[&str] = &[
    "fv", "ft", "at", "rt", "s", "rv", "filter-value", "filter-type", "add-type", "remove-type", "sort",
    "reverse",
];

fn is_filter_value_verb(rest: &str) -> bool {
    rest == "fv" || rest == "filter-value"
}

/// A non-empty prefix of some verb form - a `/s...` token still on its way
/// to being a verb, kept inert rather than searched for literally.
fn is_verb_prefix(s: &str) -> bool {
    !s.is_empty() && VERB_FORMS.iter().any(|v| v.starts_with(s))
}

fn is_verb(rest: &str) -> bool {
    VERB_FORMS.contains(&rest)
}

/// `(long-form alias, one-line description)` for a short verb form, for the
/// marginalia-style autocomplete hints (query-dsl.md's "Suggestion row
/// anatomy"). Keep these strings in sync with that doc's table and
/// QueryDsl.qml's `verbInfo`.
fn verb_meta(short: &str) -> (&'static str, &'static str) {
    match short {
        "fv" => ("/filter-value", "keep rows whose value matches (substring)"),
        "ft" => ("/filter-type", "show only the matching columns"),
        "at" => ("/add-type", "add the matching columns"),
        "rt" => ("/remove-type", "drop the matching columns"),
        "s" => ("/sort", "order rows by one field, optional asc / desc"),
        "rv" => ("/reverse", "flip the current order"),
        _ => ("", ""),
    }
}

/// One `/fv field:value` selector. `field` is resolved by substring
/// against the picker's known field names (unioned - an ambiguous typed
/// field matches if any resolved field's value matches); `value` is
/// substring-matched against those fields' actual value on each entry.
struct FieldTerm {
    fields: Vec<&'static str>,
    value: String,
}

/// A parsed search box string: the free-text phrase (see `Entry::haystack`
/// for why this stays one joined phrase, not independent AND'd words) plus
/// zero or more `/fv field:value` selectors.
struct Query {
    field_terms: Vec<FieldTerm>,
    text: String,
}

/// Which completion stage is live - determines what `accept_suggestion`
/// splices in. Only one is ever live at a time.
#[derive(Clone)]
enum SuggestionKind {
    /// A verb short form being typed. Accepting inserts `/<verb> `.
    Verb,
    /// A field name being typed as `/fv`'s path. Accepting inserts
    /// `<field>:`.
    Field,
    /// A field's live values. Accepting inserts `<field>:<value> `
    /// (re-quoted if it contains whitespace).
    Value(&'static str),
}

struct State {
    entries: Vec<Entry>,
    query: RefCell<Query>,
    field_names: Vec<&'static str>,
    field_descs: Vec<(&'static str, &'static str)>,
    suggestions: RefCell<Vec<String>>,
    suggestion_idx: RefCell<usize>,
    suggestion_start: RefCell<usize>,
    suggestion_kind: RefCell<Option<SuggestionKind>>,
}

/// One token: byte offset in the source, text (quotes stripped, interior
/// whitespace kept), and whether the source run *started* with a `"` -
/// which makes it a literal, never a command. Same shape as winswitch's
/// `query.rs::Tok`.
struct Tok {
    start: usize,
    text: String,
    lead_quote: bool,
}

/// Whitespace split, `"..."` runs kept whole, unterminated quote still
/// closes at end-of-input. `lead_quote` records a `"`-led run.
fn tokenize(query: &str) -> Vec<Tok> {
    let mut tokens = Vec::new();
    let mut cur = String::new();
    let mut start: Option<usize> = None;
    let mut lead_quote = false;
    let mut in_quotes = false;
    for (i, c) in query.char_indices() {
        if c == '"' {
            if start.is_none() {
                lead_quote = true;
            }
            in_quotes = !in_quotes;
            start.get_or_insert(i);
            continue;
        }
        if c.is_whitespace() && !in_quotes {
            if let Some(s) = start.take() {
                tokens.push(Tok { start: s, text: std::mem::take(&mut cur), lead_quote });
                lead_quote = false;
            }
            continue;
        }
        start.get_or_insert(i);
        cur.push(c);
    }
    if let Some(s) = start {
        tokens.push(Tok { start: s, text: cur, lead_quote });
    }
    tokens
}

/// True if a token begins (or continues typing) a command rather than
/// serving as an argument.
fn starts_cmd(tok: &Tok) -> bool {
    if tok.lead_quote {
        return false;
    }
    match tok.text.strip_prefix('/') {
        Some(rest) => is_verb(rest) || is_verb_prefix(rest),
        None => false,
    }
}

fn resolve_fields<'a>(query: &str, field_names: &[&'a str]) -> Vec<&'a str> {
    field_names.iter().copied().filter(|f| substr(query, f)).collect()
}

fn push_fv_arg(arg: &str, field_names: &[&'static str], field_terms: &mut Vec<FieldTerm>, words: &mut Vec<String>) {
    match arg.split_once(':') {
        // `fields` may come back empty (typo'd field) - pushed anyway so
        // the query "narrows to nothing" rather than silently dropping a
        // selector the user clearly typed (see query-dsl.md).
        Some((f, v)) => field_terms.push(FieldTerm { fields: resolve_fields(f, field_names), value: v.to_string() }),
        None => words.push(arg.to_string()),
    }
}

fn parse_query(input: &str, field_names: &[&'static str]) -> Query {
    let toks = tokenize(input);
    let mut field_terms = Vec::new();
    let mut words: Vec<String> = Vec::new();

    let mut i = 0;
    while i < toks.len() {
        let tok = &toks[i];
        if !tok.lead_quote {
            if let Some(rest) = tok.text.strip_prefix('/') {
                if is_filter_value_verb(rest) {
                    i += 1;
                    if let Some(arg) = toks.get(i).filter(|t| !starts_cmd(t)) {
                        push_fv_arg(&arg.text, field_names, &mut field_terms, &mut words);
                        i += 1;
                    }
                    continue;
                }
                if is_verb(rest) {
                    // recognised but inert here - swallow its argument (if
                    // any) so it doesn't fall into the free-text phrase.
                    i += 1;
                    let n: usize = if rest == "rv" || rest == "reverse" { 0 } else { 1 };
                    let mut c = 0;
                    while c < n && toks.get(i).map(|t| !starts_cmd(t)).unwrap_or(false) {
                        i += 1;
                        c += 1;
                    }
                    continue;
                }
                if is_verb_prefix(rest) {
                    i += 1; // mid-typing a verb - inert
                    continue;
                }
                // a literal `/usr/bin` etc - real phrase text
            }
        }
        words.push(tok.text.clone());
        i += 1;
    }

    Query { field_terms, text: words.join(" ").to_lowercase() }
}

/// Which completion stage a query is in.
enum Suggest {
    Verb { start: usize, frag: String },
    Field { start: usize, frag: String },
    Value { start: usize, field: &'static str, frag: String },
}

/// Whether the last complete command in `context` is a `/fv` still
/// waiting for its argument.
fn fv_open(context: &[Tok]) -> bool {
    let mut open = false;
    let mut pending: usize = 0; // args still owed to a non-fv verb
    for tok in context {
        if pending > 0 && !starts_cmd(tok) {
            pending -= 1;
            open = false;
            continue;
        }
        pending = 0;
        if !tok.lead_quote {
            if let Some(rest) = tok.text.strip_prefix('/') {
                if is_filter_value_verb(rest) {
                    open = true;
                    continue;
                }
                if is_verb(rest) {
                    open = false;
                    pending = if rest == "rv" || rest == "reverse" { 0 } else { 1 };
                    continue;
                }
                if is_verb_prefix(rest) {
                    open = false;
                    continue;
                }
            }
        }
        // a bare word or literal - if a /fv was open, this was its arg
        open = false;
    }
    open
}

fn completion_context(query: &str, field_names: &[&'static str]) -> Option<Suggest> {
    let toks = tokenize(query);
    if toks.is_empty() {
        return None;
    }
    let trailing_space = query.ends_with(char::is_whitespace);
    let (context, start, frag, lead_quote) = if trailing_space {
        (&toks[..], query.len(), String::new(), false)
    } else {
        let last = toks.last().unwrap();
        (&toks[..toks.len() - 1], last.start, last.text.clone(), last.lead_quote)
    };
    if lead_quote {
        return None;
    }

    if let Some(verb_frag) = frag.strip_prefix('/') {
        return Some(Suggest::Verb { start, frag: verb_frag.to_string() });
    }

    if !fv_open(context) {
        return None; // fresh phrase text - nothing to complete
    }
    match frag.split_once(':') {
        Some((f, val_frag)) => {
            let mut resolved = field_names.iter().copied().filter(|c| substr(f, c));
            let field = resolved.next()?;
            if resolved.next().is_some() {
                return None; // ambiguous field - no single value set
            }
            Some(Suggest::Value { start, field, frag: val_frag.to_string() })
        }
        None => Some(Suggest::Field { start, frag }),
    }
}

fn verb_suggestions(frag: &str) -> Vec<String> {
    ["fv", "ft", "at", "rt", "s", "rv"].iter().filter(|v| substr(frag, v)).map(|v| v.to_string()).collect()
}

/// Every configured field name, in order, whose name contains `fragment`
/// as a substring - an empty fragment lists them all.
fn field_suggestions(field_names: &[&'static str], fragment: &str) -> Vec<&'static str> {
    field_names.iter().copied().filter(|f| substr(fragment, f)).collect()
}

/// Every distinct, non-empty value `field` actually has across `entries`
/// right now, substring-narrowed by `fragment`, deduplicated and
/// sorted for a stable order. Mirrors winswitch's
/// `query.rs::value_suggestions` -- see its doc for why this only works as
/// a *complete, browsable* list at a corpus this small (a few hundred
/// clipboard/notification entries at most, and realistically a much
/// smaller number of *distinct* field values among them).
fn value_suggestions(entries: &[Entry], field: &str, fragment: &str) -> Vec<String> {
    let mut seen = std::collections::BTreeSet::new();
    for e in entries {
        if let Some(v) = field_value(e, field) {
            if !v.is_empty() && substr(fragment, v) {
                seen.insert(v.to_string());
            }
        }
    }
    seen.into_iter().collect()
}

/// A Unix timestamp (seconds) as a short "how long ago" bucket -- "5m",
/// "3h", "2d", etc. Shared by any picker with a real per-entry timestamp
/// (clipboard-picker's own copy-time log, notification-picker's already-
/// real `timestamp` field) to build a `$date:` field: bucketing to
/// human-granularity keeps the *value* space small and enumerable for
/// autocomplete's `value_suggestions` the same way winswitch's small,
/// concrete field set is (see ~/.config/docs/query-dsl.md's autocompletion
/// section) -- an exact epoch or ISO timestamp per entry would defeat that,
/// since every entry would have a near-unique value. Same bucket scheme
/// tmux's focus-picker.py already uses (`humanize_ago`), ported by hand for
/// the same "recent wins" reasoning, not shared code.
pub fn humanize_ago(ts: u64, now: u64) -> String {
    let delta = now.saturating_sub(ts);
    if delta < 60 {
        format!("{delta}s")
    } else if delta < 3600 {
        format!("{}m", delta / 60)
    } else if delta < 86400 {
        format!("{}h", delta / 3600)
    } else {
        format!("{}d", delta / 86400)
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
    /// Field names selectable with `/fv field:value`
    /// (autocompleted, see `update_suggestions`); empty if this picker has
    /// no named-field dimension at all, just free-text search.
    pub field_names: Vec<&'static str>,
    /// `(field, one-line description)` for the marginalia hint shown next to
    /// a field name in the autocomplete popup. Fields absent here just show
    /// no description. Empty vec = no descriptions anywhere.
    pub field_descs: Vec<(&'static str, &'static str)>,
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
    listbox: &gtk::ListBox,
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
    // Mouse hover moves the actual selection (not just a separate CSS
    // `:hover` look) so there's exactly one highlighted row, wherever the
    // keyboard or the pointer last left it -- previously the theme's own
    // hover prelight and our keyboard-driven `:selected` row could show two
    // highlights at once when they landed on different rows.
    {
        let listbox = listbox.clone();
        row.connect_enter_notify_event(move |r, _| {
            listbox.select_row(Some(r));
            glib::Propagation::Proceed
        });
    }
    row
}

/// The first currently-visible (not filtered out) row, if any -- what
/// Enter activates and what the first Down/Tab-into-the-list navigation
/// lands on. `row_at_index(0)` alone can point at a row the current filter
/// has hidden, so every "pick a default row" call site goes through this
/// instead.
fn first_visible_row(listbox: &gtk::ListBox) -> Option<gtk::ListBoxRow> {
    let mut i = 0;
    while let Some(row) = listbox.row_at_index(i) {
        if row.is_child_visible() {
            return Some(row);
        }
        i += 1;
    }
    None
}

/// Highlights `idx` in the suggestions list (clamped, not wrapped) and
/// records it in `state` so `accept_suggestion` knows what Tab should
/// insert. Ported from winswitch's `ui.rs::select_suggestion`.
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

/// Populates `list` with one row per entry in `items` and reveals it.
///
/// `list` is constructed with `no-show-all` set (so the initial
/// `win.show_all()` doesn't prematurely reveal an empty popup), and that
/// flag guards the widget it's set on too, not just descendants reached by
/// an ancestor's recursive `show_all()` -- so each row/label is shown
/// explicitly here, and `list.show()` (a direct call, unlike `show_all()`,
/// always works regardless of `no-show-all`) is what actually reveals the
/// list. Ported from winswitch's `ui.rs::populate_suggestions`, which hit
/// this as a real bug (the popup silently never appeared) before landing
/// on this fix -- see that commit if this regresses again.
/// One rendered autocomplete row: the visible label, plus a greyed
/// long-form alias and a greyed one-line description (marginalia -- see
/// query-dsl.md's "Suggestion row anatomy"). `alias` / `desc` empty ->
/// that part is omitted.
struct SuggestRow {
    label: String,
    alias: String,
    desc: String,
}

fn dim_label(text: &str) -> gtk::Label {
    // Pango `alpha` is relative to the resolved text colour, so this stays
    // readable on both the normal and the selected-row background without
    // hard-coding a grey.
    let l = gtk::Label::new(None);
    l.set_markup(&format!(
        "<span alpha='55%'>{}</span>",
        gtk::glib::markup_escape_text(text)
    ));
    l.set_halign(gtk::Align::Start);
    l
}

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
        row.show();
    }
    list.show();
}

/// Re-derives the autocomplete popup from the query text on every
/// keystroke - one `completion_context` call picks the stage (verb name,
/// `/fv` field path, or that field's live values); this renders it.
/// Ported from winswitch's `ui.rs::update_suggestions`.
fn update_suggestions(query: &str, list: &gtk::ListBox, state: &Rc<State>) {
    for child in list.children() {
        list.remove(&child);
    }

    let Some(ctx) = completion_context(query, &state.field_names) else {
        hide_suggestions(list, state);
        return;
    };
    let (start, items, kind) = match ctx {
        Suggest::Verb { start, frag } => (start, verb_suggestions(&frag), SuggestionKind::Verb),
        Suggest::Field { start, frag } => (
            start,
            field_suggestions(&state.field_names, &frag).into_iter().map(str::to_string).collect(),
            SuggestionKind::Field,
        ),
        Suggest::Value { start, field, frag } => {
            (start, value_suggestions(&state.entries, field, &frag), SuggestionKind::Value(field))
        }
    };
    if items.is_empty() {
        hide_suggestions(list, state);
        return;
    }

    let rows: Vec<SuggestRow> = items
        .iter()
        .map(|item| match &kind {
            SuggestionKind::Verb => {
                let (alias, desc) = verb_meta(item);
                SuggestRow {
                    label: format!("/{item}"),
                    alias: alias.to_string(),
                    desc: desc.to_string(),
                }
            }
            SuggestionKind::Field => {
                let desc = state
                    .field_descs
                    .iter()
                    .find(|(f, _)| *f == item.as_str())
                    .map(|(_, d)| d.to_string())
                    .unwrap_or_default();
                SuggestRow { label: item.clone(), alias: String::new(), desc }
            }
            SuggestionKind::Value(_) => SuggestRow {
                label: item.clone(),
                alias: String::new(),
                desc: String::new(),
            },
        })
        .collect();

    populate_suggestions(list, &rows);
    *state.suggestions.borrow_mut() = items;
    *state.suggestion_start.borrow_mut() = start;
    *state.suggestion_kind.borrow_mut() = Some(kind);
    select_suggestion(list, state, 0);
}

/// Replaces the trailing fragment the suggestions were built from with the
/// chosen completion - `/<verb> ` for a verb, `<field>:` for a field name
/// (the `/fv ` prefix is already in `query[..start]`), or `<field>:<value>
/// ` for a value (re-quoted if it contains whitespace, trailing space
/// since a value is complete the instant it's chosen). Ported from
/// winswitch's `ui.rs::accept_suggestion`.
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
    let prefix = &query[..start];
    let new_query = match kind {
        SuggestionKind::Verb => format!("{prefix}/{chosen} "),
        SuggestionKind::Field => format!("{prefix}{chosen}:"),
        SuggestionKind::Value(field) => {
            let value = if chosen.contains(char::is_whitespace) {
                format!("\"{chosen}\"")
            } else {
                chosen
            };
            format!("{prefix}{field}:{value} ")
        }
    };
    hide_suggestions(list, state);
    search.set_text(&new_query);
    search.set_position(-1);
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

    let field_names = config.field_names.clone();
    let state = Rc::new(State {
        entries,
        query: RefCell::new(parse_query("", &field_names)),
        field_names,
        field_descs: config.field_descs.clone(),
        suggestions: RefCell::new(Vec::new()),
        suggestion_idx: RefCell::new(0),
        suggestion_start: RefCell::new(0),
        suggestion_kind: RefCell::new(None),
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

    if let Some(screen) = gdk::Screen::default() {
        let css = gtk::CssProvider::new();
        let _ = css.load_from_data(
            b".suggestions { border: 1px solid rgba(255,255,255,0.18); border-radius: 4px; } \
              .suggestions row { padding: 2px 6px; } \
              .suggestions row:selected, .suggestions row:hover, \
              .results row:selected, .results row:hover { \
                  background-color: rgba(255,255,255,0.18); background-image: none; \
                  box-shadow: none; border-radius: 0; }",
        );
        gtk::StyleContext::add_provider_for_screen(&screen, &css, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
    }

    let search = gtk::SearchEntry::new();
    search.set_placeholder_text(Some(config.placeholder.as_str()));
    let listbox = gtk::ListBox::new();
    listbox.set_selection_mode(gtk::SelectionMode::Browse);
    listbox.style_context().add_class("results");

    // Column-name/value autocomplete popup: an in-layout ListBox directly
    // under the search entry, shown/hidden via `update_suggestions` as
    // query text comes and goes. See winswitch's `ui.rs` for why this is a
    // plain ListBox and not a GtkPopover.
    let suggestions_list = gtk::ListBox::new();
    suggestions_list.set_selection_mode(gtk::SelectionMode::Browse);
    suggestions_list.set_no_show_all(true);
    suggestions_list.style_context().add_class("suggestions");
    suggestions_list.hide();

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
            if !q.field_terms.iter().all(|t| {
                t.fields.iter().any(|f| field_value(entry, f).map(|v| substr(&t.value, v)).unwrap_or(false))
            }) {
                return false;
            }
            q.text.is_empty() || entry.haystack.contains(q.text.as_str())
        })));
    }

    {
        let state = state.clone();
        let listbox = listbox.clone();
        let suggestions_list = suggestions_list.clone();
        let resize_to_content = resize_to_content.clone();
        // "changed", not "search-changed": GtkSearchEntry deliberately delays
        // search-changed by 150ms after the last keystroke, which reads as lag.
        // Filtering the whole list measures in single-digit ms.
        search.connect_changed(move |entry| {
            let text = entry.text();
            // Resolve the needle once per keystroke rather than once per row,
            // and drop the borrow before the filter func takes it.
            *state.query.borrow_mut() = parse_query(text.as_str(), &state.field_names);
            listbox.invalidate_filter();
            // No auto-selection here on purpose -- selecting the first
            // match on every keystroke was confusing (a highlight jumping
            // around while typing looks like something is about to
            // happen). Selection now only ever follows an explicit user
            // action (arrow keys, Tab-into-list, mouse), so a stale
            // selection that just got filtered out of view is cleared
            // rather than left dangling (Enter would otherwise silently
            // activate a hidden row) -- `first_visible_row` is what Enter
            // falls back to instead, see the key-press handler below.
            if let Some(sel) = listbox.selected_row() {
                if !sel.is_child_visible() {
                    listbox.select_row(None::<&gtk::ListBoxRow>);
                }
            }
            update_suggestions(text.as_str(), &suggestions_list, &state);
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
    vbox.pack_start(&suggestions_list, false, false, 0);
    vbox.pack_start(&scroll, true, true, 0);
    win.add(&vbox);

    // Only enough rows to fill the visible list before the first frame.
    let cursor = Rc::new(RefCell::new(0usize));
    {
        let mut c = cursor.borrow_mut();
        let end = config.initial_rows.min(state.entries.len());
        for i in *c..end {
            listbox.add(&make_row(&state, i, config.thumb_height, &pending, &listbox));
        }
        *c = end;
    }
    // Deliberately no initial selection -- see the no-auto-select comment
    // on `connect_changed` above. The list opens with nothing highlighted;
    // the first Down (or Tab into the list) is what selects
    // `first_visible_row`, and Enter with nothing selected falls back to
    // it too (see the key-press handler below).
    resize_to_content();

    {
        let listbox = listbox.clone();
        let search = search.clone();
        let suggestions_list = suggestions_list.clone();
        let state = state.clone();
        win.connect_key_press_event(move |_, ev| {
            use gdk::keys::constants as key;
            let k = ev.keyval();
            let ctrl = ev.state().contains(gdk::ModifierType::CONTROL_MASK);

            // Autocomplete popup takes over Ctrl+j/k, Tab, and Escape while
            // it's showing -- checked before any of those keys' normal
            // meaning below, and before Escape's own unconditional
            // quit-the-picker handling right after this block, since the
            // popup's own Escape only dismisses itself. Ported from
            // winswitch's `ui.rs` key-press handler.
            if !state.suggestions.borrow().is_empty() {
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
                // Nothing selected (the new default -- see the
                // no-auto-select comment on connect_changed) falls back to
                // the top visible result, same as pressing Enter in most
                // "spotlight"-style search boxes: no visual pre-highlight,
                // but Enter still commits to *something* sensible.
                let target = listbox.selected_row().or_else(|| first_visible_row(&listbox));
                if let Some(row) = target {
                    row.activate();
                }
                return glib::Propagation::Stop;
            }
            if k == key::Tab || k == key::ISO_Left_Tab {
                // Toggle instead of GTK's default focus-chain Tab, which
                // would walk into the list and then between individual rows.
                if search.is_focus() {
                    if listbox.selected_row().is_none() {
                        if let Some(row) = first_visible_row(&listbox) {
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
            // Ctrl+j/k are vim-style Down/Up here too, not just inside the
            // autocomplete popup (which already claims them above and
            // returns early, so this arm only ever runs once that popup
            // isn't showing).
            let step: i32 = if k == key::Up || (ctrl && k == key::k) {
                -1
            } else if k == key::Down || (ctrl && k == key::j) {
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
            // Nothing selected yet: *any* first navigation (not just Down,
            // though that's the one this was asked for) lands on the top
            // entry rather than applying `step` from an assumed index 0,
            // which used to skip straight to the second entry on first
            // Down. Once something is selected, step applies normally.
            let cur = listbox.selected_row().and_then(|s| visible.iter().position(|r| r == &s));
            let idx = match cur {
                Some(c) => (c as i32 + step).clamp(0, visible.len() as i32 - 1) as usize,
                None => 0,
            };
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
                listbox.add(&make_row(&state, i, thumb_height, &pending_rows, &listbox));
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

#[cfg(test)]
mod tests {
    use super::*;

    const FIELDS: [&str; 3] = ["type", "date", "app"];

    fn entry(id: &str, preview: &str, fields: Vec<(&'static str, &str)>) -> Entry {
        Entry {
            id: id.to_string(),
            haystack: preview.to_lowercase(),
            preview: preview.to_string(),
            fields: fields.into_iter().map(|(k, v)| (k, v.to_string())).collect(),
            thumb: false,
        }
    }

    fn matches(e: &Entry, query: &str) -> bool {
        let q = parse_query(query, &FIELDS);
        let field_ok = q.field_terms.iter().all(|t| {
            t.fields.iter().any(|f| field_value(e, f).map(|v| substr(&t.value, v)).unwrap_or(false))
        });
        field_ok && (q.text.is_empty() || e.haystack.contains(q.text.as_str()))
    }

    #[test]
    fn substr_is_containment() {
        assert!(substr("mag", "image"));
        assert!(!substr("mg", "image")); // not contiguous
        assert!(substr("", "anything"));
    }

    #[test]
    fn bare_words_join_into_one_literal_phrase() {
        let e = entry("1", "hello there world", vec![]);
        assert!(matches(&e, "hello there"));
        assert!(!matches(&e, "hello world")); // not contiguous in the haystack
    }

    #[test]
    fn fv_and_bare_text_are_identical() {
        let e = entry("1", "hello there world", vec![]);
        assert!(matches(&e, "/fv there"));
        assert!(matches(&e, "/filter-value there"));
        assert!(!matches(&e, "/fv nope"));
        // literal slash text still searchable (not a verb, not a prefix)
        let e2 = entry("2", "see /usr/bin/env", vec![]);
        assert!(matches(&e2, "/usr/bin"));
    }

    #[test]
    fn scoped_fv_filters_by_value_substring() {
        let e = entry("1", "a screenshot", vec![("type", "image")]);
        assert!(matches(&e, "/fv type:image"));
        assert!(matches(&e, "/fv type:mage")); // substring, not exact
        assert!(!matches(&e, "/fv type:text"));
    }

    #[test]
    fn field_name_is_substring_resolved() {
        let e = entry("1", "x", vec![("date", "5m")]);
        assert!(matches(&e, "/fv da:5m"));
        assert!(matches(&e, "/fv ate:5m")); // "ate" in "date"
        assert!(!matches(&e, "/fv dte:5m")); // not contiguous
    }

    #[test]
    fn unresolvable_field_narrows_to_nothing() {
        let e = entry("1", "x", vec![("type", "image")]);
        assert!(!matches(&e, "/fv zzz:image"));
    }

    #[test]
    fn missing_field_on_entry_never_matches() {
        let e = entry("1", "x", vec![("type", "image")]);
        assert!(!matches(&e, "/fv date:"));
        assert!(!matches(&e, "/fv date:5m"));
    }

    #[test]
    fn quoted_value_is_a_literal_substring() {
        let e = entry("1", "x", vec![("app", "Discord Canary")]);
        assert!(matches(&e, r#"/fv app:"discord can""#));
        assert!(!matches(&e, r#"/fv app:"can disc""#)); // not contiguous
    }

    #[test]
    fn multiple_field_terms_are_anded() {
        let e = entry("1", "x", vec![("type", "image"), ("date", "5m")]);
        assert!(matches(&e, "/fv type:image /fv date:5m"));
        assert!(!matches(&e, "/fv type:image /fv date:1h"));
    }

    #[test]
    fn field_term_and_free_text_combine() {
        let e = entry("1", "a cat photo", vec![("type", "image")]);
        assert!(matches(&e, "/fv type:image cat"));
        assert!(!matches(&e, "/fv type:image dog"));
    }

    #[test]
    fn inert_verbs_dont_leak_into_the_phrase() {
        let e = entry("1", "just some text", vec![("type", "image")]);
        // /ft /at /rt /s /rv are recognised but do nothing here, and must
        // not become literal phrase words.
        assert!(matches(&e, "/ft type /sort date /reverse text"));
        assert!(!matches(&e, "/ft type nope"));
    }

    #[test]
    fn half_typed_verb_is_inert_not_literal() {
        let e = entry("1", "some text", vec![]);
        assert!(matches(&e, "/f")); // could still be /fv or /ft
        assert!(matches(&e, "/rev"));
    }

    #[test]
    fn completion_verb_stage() {
        let Some(Suggest::Verb { frag, .. }) = completion_context("/f", &FIELDS) else { panic!() };
        assert_eq!(verb_suggestions(&frag), vec!["fv", "ft"]);
        let Some(Suggest::Verb { frag, .. }) = completion_context("/", &FIELDS) else { panic!() };
        assert_eq!(verb_suggestions(&frag), vec!["fv", "ft", "at", "rt", "s", "rv"]);
    }

    #[test]
    fn completion_field_stage_after_fv() {
        let Some(Suggest::Field { frag, start }) = completion_context("/fv da", &FIELDS) else { panic!() };
        assert_eq!((frag.as_str(), start), ("da", 4));
        let Some(Suggest::Field { .. }) = completion_context("/fv ", &FIELDS) else { panic!() };
        // no /fv -> no completion mid-phrase
        assert!(completion_context("plain text", &FIELDS).is_none());
        assert!(completion_context("cat ", &FIELDS).is_none());
    }

    #[test]
    fn completion_value_stage_needs_unambiguous_field() {
        let Some(Suggest::Value { field, frag, .. }) = completion_context("/fv type:im", &FIELDS) else {
            panic!()
        };
        assert_eq!((field, frag.as_str()), ("type", "im"));
        // "a" is in both "date" and "app" - ambiguous
        assert!(completion_context("/fv a:x", &FIELDS).is_none());
    }

    #[test]
    fn field_suggestions_narrow_by_substring_and_empty_lists_all() {
        assert_eq!(field_suggestions(&FIELDS, ""), vec!["type", "date", "app"]);
        assert_eq!(field_suggestions(&FIELDS, "ate"), vec!["date"]);
        assert!(field_suggestions(&FIELDS, "zzz").is_empty());
    }

    #[test]
    fn value_suggestions_are_deduped_sorted_and_substring_narrowed() {
        let entries = vec![
            entry("1", "a", vec![("type", "image")]),
            entry("2", "b", vec![("type", "text")]),
            entry("3", "c", vec![("type", "image")]),
            entry("4", "d", vec![]), // no type field - never suggested
        ];
        assert_eq!(value_suggestions(&entries, "type", ""), vec!["image", "text"]);
        assert_eq!(value_suggestions(&entries, "type", "im"), vec!["image"]);
        assert!(value_suggestions(&entries, "type", "zzz").is_empty());
    }

    #[test]
    fn humanize_ago_buckets() {
        assert_eq!(humanize_ago(100, 130), "30s");
        assert_eq!(humanize_ago(100, 100 + 5 * 60), "5m");
        assert_eq!(humanize_ago(100, 100 + 3 * 3600), "3h");
        assert_eq!(humanize_ago(100, 100 + 2 * 86400), "2d");
    }
}
