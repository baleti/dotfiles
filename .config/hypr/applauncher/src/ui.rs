//! The resident launcher window: a GTK3 + wlr-layer-shell card, built and
//! mapped once at daemon start and thereafter only shown/hidden by
//! flipping opacity, the input region and the keyboard mode -- never
//! rebuilt, never remapped. That's the whole point: by the time you press
//! mod+Super_l the surface already exists, the app list is already laid
//! out, and "open" costs a socket byte + an opacity flip, not a process
//! spawn racing the compositor.
//!
//! Layout mirrors `~/.config/quickshell/launcher/AppLauncher.qml`: a
//! centred card, 1px accent border, a search box over a scrolling list of
//! icon + name rows, plus the shared `/verb` DSL and its Tab-triggered
//! autocomplete popup.

use std::cell::{Cell, RefCell};
use std::io::Read;
use std::os::unix::io::AsRawFd;
use std::os::unix::net::UnixListener;
use std::process::Command;
use std::rc::Rc;

use gdk::prelude::*;
use gtk::prelude::*;
use gtk_layer_shell::LayerShell;

use crate::apps::{self, App, FIELD_DESCS, FIELD_NAMES};
use crate::dsl::{self, Query};
use crate::history::History;
use crate::theme::Theme;

/// Static &'static str view of FIELD_NAMES for the DSL (which wants
/// `&[&'static str]`).
fn field_names() -> Vec<&'static str> {
    FIELD_NAMES.to_vec()
}

struct State {
    apps: Vec<App>,
    history: RefCell<History>,
    query: RefCell<Query>,
    visible: Cell<bool>,
    // autocomplete
    suggestions: RefCell<Vec<String>>,
    suggestion_idx: Cell<usize>,
    suggestion_start: Cell<usize>,
    suggestion_kind: RefCell<Option<SuggestKind>>,
    cmd_valid: Option<(u16, u16, u16)>,
    cmd_invalid: Option<(u16, u16, u16)>,
}

#[derive(Clone, Copy)]
enum SuggestKind {
    Verb,
    Field,
    Value,
}

/// Match quality of `name` against the current first bare word: 0 exact,
/// 1 prefix, 2 substring, 3 none / no query. Mirrors QML `_rank`.
fn rank(name: &str, text: &str) -> u8 {
    if text.is_empty() {
        return 3;
    }
    let n = name.to_lowercase();
    if n == text {
        0
    } else if n.starts_with(text) {
        1
    } else if n.contains(text) {
        2
    } else {
        3
    }
}

fn app_matches(app: &App, q: &Query) -> bool {
    for t in &q.field_terms {
        let ok = t.fields.iter().any(|f| dsl::substr(&t.value, app.field(f)));
        if !ok {
            return false;
        }
    }
    q.text.is_empty() || app.haystack.contains(q.text.as_str())
}

/// The monitor Hyprland considers focused (not the one under the pointer --
/// focus-follows-mouse routinely splits them here). Copied from
/// clipboard-picker's `target_monitor`.
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

/// Widest of the frecency-top ~20 app names, clamped -- a one-shot measure
/// at startup, like QML's `_measure` but not re-run per keystroke (that
/// width animation was part of the jank).
fn card_width(state: &State) -> i32 {
    let mut ids: Vec<(&App, i64)> =
        state.apps.iter().map(|a| (a, state.history.borrow().score(&a.id))).collect();
    ids.sort_by(|a, b| b.1.cmp(&a.1));
    let ctx = gtk::Label::new(None).pango_context();
    let layout = gtk::pango::Layout::new(&ctx);
    let mut widest = 0;
    for (a, _) in ids.iter().take(20) {
        layout.set_text(&a.name);
        let (w, _) = layout.pixel_size();
        widest = widest.max(w);
    }
    (widest + 96).clamp(380, 560)
}

pub fn run_daemon(listener: UnixListener, show_now: bool) {
    if gtk::init().is_err() {
        eprintln!("applauncher: failed to initialise GTK");
        std::process::exit(1);
    }

    let theme = Theme::load();
    let state = Rc::new(State {
        apps: apps::load(),
        history: RefCell::new(History::load()),
        query: RefCell::new(dsl::parse_query("", &field_names())),
        visible: Cell::new(false),
        suggestions: RefCell::new(Vec::new()),
        suggestion_idx: Cell::new(0),
        suggestion_start: Cell::new(0),
        suggestion_kind: RefCell::new(None),
        cmd_valid: theme.cmd_valid,
        cmd_invalid: theme.cmd_invalid,
    });

    // ---- window ----------------------------------------------------
    let win = gtk::Window::new(gtk::WindowType::Toplevel);
    win.init_layer_shell();
    win.set_layer(gtk_layer_shell::Layer::Overlay);
    win.set_namespace("applauncher");
    win.set_keyboard_mode(gtk_layer_shell::KeyboardMode::None);
    win.set_exclusive_zone(0);
    // No edge anchors -> the compositor centres the surface on both axes,
    // matching the quickshell card.

    win.set_app_paintable(true);
    if let Some(screen) = gdk::Screen::default() {
        if let Some(vis) = screen.rgba_visual() {
            win.set_visual(Some(&vis));
        }
    }

    let (_mon_w, mon_h) = gdk::Display::default()
        .and_then(|d| target_monitor(&d))
        .map(|m| {
            win.set_monitor(&m);
            let g = m.geometry();
            (g.width(), g.height())
        })
        .unwrap_or((1920, 1080));

    let width_px = card_width(&state);
    let height_px = (mon_h as f64 * 0.6) as i32;
    win.set_size_request(width_px, height_px);

    // ---- css ------------------------------------------------------
    if let Some(screen) = gdk::Screen::default() {
        let css = gtk::CssProvider::new();
        let data = format!(
            "window {{ background: transparent; }}\n\
             .card {{ background-color: {bg}; border: 1px solid {accent}; border-radius: 12px; }}\n\
             .card entry {{ background: transparent; border: none; box-shadow: none; \
                 color: {text}; margin: 6px 10px; caret-color: {accent}; }}\n\
             .card entry image {{ color: {dim}; }}\n\
             .divider {{ background-color: {div}; min-height: 1px; }}\n\
             .results {{ background: transparent; }}\n\
             .results row {{ padding: 4px 10px; background: transparent; }}\n\
             .results row:selected, .results row:hover {{ \
                 background-color: alpha({accent}, 0.16); background-image: none; \
                 box-shadow: none; border-radius: 0; }}\n\
             .approw label {{ color: {text}; }}\n\
             .suggestions {{ background: transparent; }}\n\
             .suggestions row {{ padding: 2px 10px; }}\n\
             .suggestions row:selected {{ background-color: alpha({accent}, 0.18); border-radius: 4px; }}",
            bg = theme.background,
            accent = theme.accent,
            text = theme.text,
            dim = theme.text_dim,
            div = theme.divider,
        );
        let _ = css.load_from_data(data.as_bytes());
        gtk::StyleContext::add_provider_for_screen(
            &screen,
            &css,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }

    // ---- widgets -------------------------------------------------
    let card = gtk::Box::new(gtk::Orientation::Vertical, 0);
    card.style_context().add_class("card");

    let search = gtk::SearchEntry::new();
    search.set_placeholder_text(Some("search apps   \u{00b7}   /"));

    let divider = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    divider.style_context().add_class("divider");

    let suggestions = gtk::ListBox::new();
    suggestions.set_selection_mode(gtk::SelectionMode::Browse);
    suggestions.set_no_show_all(true);
    suggestions.style_context().add_class("suggestions");
    suggestions.hide();

    let listbox = gtk::ListBox::new();
    listbox.set_selection_mode(gtk::SelectionMode::Browse);
    listbox.style_context().add_class("results");

    let scroll = gtk::ScrolledWindow::new(gtk::Adjustment::NONE, gtk::Adjustment::NONE);
    scroll.set_policy(gtk::PolicyType::Never, gtk::PolicyType::Automatic);
    scroll.add(&listbox);

    card.pack_start(&search, false, false, 0);
    card.pack_start(&divider, false, false, 0);
    card.pack_start(&suggestions, false, false, 0);
    card.pack_start(&scroll, true, true, 0);
    win.add(&card);

    // ---- rows (built once) --------------------------------------
    for (i, app) in state.apps.iter().enumerate() {
        let row = gtk::ListBoxRow::new();
        let hb = gtk::Box::new(gtk::Orientation::Horizontal, 10);
        hb.style_context().add_class("approw");
        let img = match &app.icon {
            Some(icon) => gtk::Image::from_gicon(icon, gtk::IconSize::LargeToolbar),
            None => gtk::Image::from_icon_name(Some("application-x-executable"), gtk::IconSize::LargeToolbar),
        };
        img.set_pixel_size(20);
        let label = gtk::Label::new(Some(&app.name));
        label.set_xalign(0.0);
        label.set_ellipsize(gtk::pango::EllipsizeMode::End);
        label.set_max_width_chars(1);
        hb.pack_start(&img, false, false, 0);
        hb.pack_start(&label, true, true, 0);
        row.add(&hb);
        // row.index() maps straight back to state.apps[i] -- rows are never
        // added or removed after this.
        let _ = i;
        {
            let listbox = listbox.clone();
            row.connect_enter_notify_event(move |r, _| {
                listbox.select_row(Some(r));
                glib::Propagation::Proceed
            });
        }
        listbox.add(&row);
    }

    // ---- filter + sort -----------------------------------------
    {
        let state = state.clone();
        listbox.set_filter_func(Some(Box::new(move |row: &gtk::ListBoxRow| {
            let q = state.query.borrow();
            match state.apps.get(row.index() as usize) {
                Some(app) => app_matches(app, &q),
                None => true,
            }
        })));
    }
    {
        let state = state.clone();
        listbox.set_sort_func(Some(Box::new(move |a: &gtk::ListBoxRow, b: &gtk::ListBoxRow| -> i32 {
            let q = state.history.borrow();
            let query = state.query.borrow();
            let (ai, bi) = (a.index() as usize, b.index() as usize);
            let (Some(ax), Some(bx)) = (state.apps.get(ai), state.apps.get(bi)) else {
                return 0;
            };
            let ord = if let Some(s) = &query.sort {
                let c = ax.field(s.field).to_lowercase().cmp(&bx.field(s.field).to_lowercase());
                if s.descending {
                    c.reverse()
                } else {
                    c
                }
            } else {
                rank(&ax.name, &query.text)
                    .cmp(&rank(&bx.name, &query.text))
                    .then_with(|| q.score(&bx.id).cmp(&q.score(&ax.id)))
                    .then_with(|| ax.name.to_lowercase().cmp(&bx.name.to_lowercase()))
            };
            let ord = if query.reverse { ord.reverse() } else { ord };
            match ord {
                std::cmp::Ordering::Less => -1,
                std::cmp::Ordering::Greater => 1,
                std::cmp::Ordering::Equal => 0,
            }
        })));
    }

    let select_top = {
        let listbox = listbox.clone();
        Rc::new(move || {
            let mut i = 0;
            while let Some(row) = listbox.row_at_index(i) {
                if row.is_child_visible() {
                    listbox.select_row(Some(&row));
                    return;
                }
                i += 1;
            }
            listbox.select_row(None::<&gtk::ListBoxRow>);
        })
    };

    // ---- activate ----------------------------------------------
    let hide_win: Rc<dyn Fn()> = {
        let win = win.clone();
        let state = state.clone();
        let search = search.clone();
        let suggestions = suggestions.clone();
        Rc::new(move || {
            state.visible.set(false);
            win.set_keyboard_mode(gtk_layer_shell::KeyboardMode::None);
            win.set_opacity(0.0);
            if let Some(gw) = win.window() {
                gw.input_shape_combine_region(&gtk::cairo::Region::create(), 0, 0);
            }
            search.set_text("");
            suggestions.hide();
            state.suggestions.borrow_mut().clear();
        })
    };

    {
        let state = state.clone();
        let hide_win = hide_win.clone();
        listbox.connect_row_activated(move |_, row| {
            if let Some(app) = state.apps.get(row.index() as usize) {
                state.history.borrow_mut().bump(&app.id);
                app.launch();
            }
            hide_win();
        });
    }

    // ---- search changed ---------------------------------------
    {
        let state = state.clone();
        let listbox = listbox.clone();
        let suggestions = suggestions.clone();
        let select_top = select_top.clone();
        search.connect_changed(move |entry| {
            let text = entry.text().to_string();
            apply_command_colors(entry, &text, &state);
            *state.query.borrow_mut() = dsl::parse_query(&text, &field_names());
            listbox.invalidate_filter();
            listbox.invalidate_sort();
            select_top();
            // Tab-triggered popup only: any further typing closes it.
            suggestions.hide();
            state.suggestions.borrow_mut().clear();
            *state.suggestion_kind.borrow_mut() = None;
        });
    }

    // ---- keys -------------------------------------------------
    {
        let state = state.clone();
        let listbox = listbox.clone();
        let search = search.clone();
        let suggestions = suggestions.clone();
        let hide_win = hide_win.clone();
        win.connect_key_press_event(move |_, ev| {
            use gdk::keys::constants as key;
            let k = ev.keyval();
            let ctrl = ev.state().contains(gdk::ModifierType::CONTROL_MASK);

            // autocomplete popup owns these while it's up
            if !state.suggestions.borrow().is_empty() {
                if k == key::Escape {
                    close_suggestions(&suggestions, &state);
                    return glib::Propagation::Stop;
                }
                if k == key::Tab {
                    accept_suggestion(&search, &suggestions, &state);
                    return glib::Propagation::Stop;
                }
                if ctrl && (k == key::j || k == key::k) {
                    let n = state.suggestions.borrow().len();
                    let cur = state.suggestion_idx.get();
                    let next = if k == key::j {
                        (cur + 1).min(n - 1)
                    } else {
                        cur.saturating_sub(1)
                    };
                    select_suggestion(&suggestions, &state, next);
                    return glib::Propagation::Stop;
                }
            }

            if k == key::Escape {
                hide_win();
                return glib::Propagation::Stop;
            }
            if k == key::Return || k == key::KP_Enter {
                let target = listbox.selected_row().or_else(|| {
                    let mut i = 0;
                    loop {
                        match listbox.row_at_index(i) {
                            Some(r) if r.is_child_visible() => break Some(r),
                            Some(_) => i += 1,
                            None => break None,
                        }
                    }
                });
                if let Some(row) = target {
                    row.activate();
                }
                return glib::Propagation::Stop;
            }
            if k == key::Tab {
                if trigger_completion(&search.text(), &search, &suggestions, &state) {
                    return glib::Propagation::Stop;
                }
                return glib::Propagation::Stop;
            }

            let step: i32 = if k == key::Up || (ctrl && k == key::k) {
                -1
            } else if k == key::Down || (ctrl && k == key::j) {
                1
            } else if k == key::Page_Up {
                -8
            } else if k == key::Page_Down {
                8
            } else {
                return glib::Propagation::Proceed;
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
                .and_then(|s| visible.iter().position(|r| *r == s));
            let idx = match cur {
                Some(c) => (c as i32 + step).clamp(0, visible.len() as i32 - 1) as usize,
                None => 0,
            };
            listbox.select_row(Some(&visible[idx]));
            visible[idx].grab_focus();
            // keep typing focus in the search box
            search.grab_focus_without_selecting();
            glib::Propagation::Stop
        });
    }

    // ---- show / hide -----------------------------------------
    let show_win: Rc<dyn Fn()> = {
        let win = win.clone();
        let state = state.clone();
        let search = search.clone();
        let listbox = listbox.clone();
        let scroll = scroll.clone();
        let select_top = select_top.clone();
        Rc::new(move || {
            state.visible.set(true);
            if let Some(d) = gdk::Display::default() {
                if let Some(m) = target_monitor(&d) {
                    win.set_monitor(&m);
                }
            }
            search.set_text("");
            *state.query.borrow_mut() = dsl::parse_query("", &field_names());
            listbox.invalidate_filter();
            listbox.invalidate_sort();
            select_top();
            scroll.vadjustment().set_value(0.0);
            win.set_opacity(1.0);
            if let Some(gw) = win.window() {
                let (w, h) = (win.allocated_width().max(1), win.allocated_height().max(1));
                let rect = gtk::cairo::RectangleInt::new(0, 0, w, h);
                gw.input_shape_combine_region(&gtk::cairo::Region::create_rectangle(&rect), 0, 0);
            }
            win.set_keyboard_mode(gtk_layer_shell::KeyboardMode::Exclusive);
            search.grab_focus();
        })
    };

    win.connect_destroy(|_| gtk::main_quit());

    // Realize + map the surface now, then immediately fall back to the
    // hidden (transparent, click-through, no-keyboard) resting state --
    // unless this invocation is itself an open request.
    win.show_all();
    suggestions.hide();
    if show_now {
        show_win();
    } else {
        hide_win();
    }

    // ---- socket ---------------------------------------------
    {
        let show_win = show_win.clone();
        let hide_win = hide_win.clone();
        let state = state.clone();
        listener.set_nonblocking(true).ok();
        let fd = listener.as_raw_fd();
        glib::source::unix_fd_add_local(fd, glib::IOCondition::IN, move |_, _| {
            while let Ok((mut stream, _)) = listener.accept() {
                let mut buf = [0u8; 16];
                let cmd = match stream.read(&mut buf) {
                    Ok(n) => String::from_utf8_lossy(&buf[..n]).trim().to_string(),
                    Err(_) => break,
                };
                match cmd.as_str() {
                    "show" => show_win(),
                    "hide" => hide_win(),
                    "toggle" => {
                        if state.visible.get() {
                            hide_win()
                        } else {
                            show_win()
                        }
                    }
                    _ => {}
                }
            }
            glib::ControlFlow::Continue
        });
    }

    gtk::main();
}

// ---- inline /verb colouring ------------------------------------------
fn apply_command_colors(search: &gtk::SearchEntry, text: &str, state: &State) {
    let attrs = gtk::pango::AttrList::new();
    for (start, end, valid) in dsl::command_spans(text) {
        let rgb = if valid { state.cmd_valid } else { state.cmd_invalid };
        let Some((r, g, b)) = rgb else { continue };
        let mut attr = gtk::pango::AttrColor::new_foreground(r, g, b);
        attr.set_start_index(start as u32);
        attr.set_end_index(end as u32);
        attrs.insert(attr);
    }
    search.set_attributes(&attrs);
}

// ---- autocomplete ---------------------------------------------------
fn dim_label(text: &str) -> gtk::Label {
    let l = gtk::Label::new(None);
    l.set_markup(&format!("<span alpha='55%'>{}</span>", gtk::glib::markup_escape_text(text)));
    l.set_halign(gtk::Align::Start);
    l
}

fn close_suggestions(list: &gtk::ListBox, state: &State) {
    list.hide();
    state.suggestions.borrow_mut().clear();
    *state.suggestion_kind.borrow_mut() = None;
}

fn select_suggestion(list: &gtk::ListBox, state: &State, idx: usize) {
    let n = state.suggestions.borrow().len();
    if n == 0 {
        return;
    }
    let idx = idx.min(n - 1);
    state.suggestion_idx.set(idx);
    if let Some(row) = list.row_at_index(idx as i32) {
        list.select_row(Some(&row));
    }
}

fn compute_candidates(query: &str, state: &State) -> Option<(usize, Vec<String>, SuggestKind)> {
    let fields = field_names();
    let ctx = dsl::completion_context(query, &fields)?;
    let (start, items, kind) = match ctx {
        dsl::Suggest::Verb { start, frag } => (start, dsl::verb_suggestions(&frag), SuggestKind::Verb),
        dsl::Suggest::Field { start, frag } => (
            start,
            dsl::field_suggestions(&fields, &frag).into_iter().map(str::to_string).collect(),
            SuggestKind::Field,
        ),
        dsl::Suggest::Value { start, field, frag } => {
            let mut seen = std::collections::BTreeSet::new();
            for a in &state.apps {
                let v = a.field(field);
                if !v.is_empty() && dsl::substr(&frag, v) {
                    seen.insert(v.to_string());
                }
            }
            (start, seen.into_iter().collect(), SuggestKind::Value)
        }
    };
    if items.is_empty() {
        return None;
    }
    Some((start, items, kind))
}

fn populate_suggestions(list: &gtk::ListBox, state: &State) {
    for child in list.children() {
        list.remove(&child);
    }
    let items = state.suggestions.borrow().clone();
    let kind = *state.suggestion_kind.borrow();
    for item in &items {
        let row = gtk::ListBoxRow::new();
        let hb = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let (label_text, alias, desc) = match kind {
            Some(SuggestKind::Verb) => {
                let (a, d) = dsl::verb_meta(item);
                (format!("/{item}"), a.to_string(), d.to_string())
            }
            Some(SuggestKind::Field) => {
                let d = FIELD_DESCS
                    .iter()
                    .find(|(f, _)| f == item)
                    .map(|(_, d)| d.to_string())
                    .unwrap_or_default();
                (item.clone(), String::new(), d)
            }
            _ => (item.clone(), String::new(), String::new()),
        };
        let l = gtk::Label::new(Some(&label_text));
        l.set_halign(gtk::Align::Start);
        hb.pack_start(&l, false, false, 0);
        l.show();
        if !alias.is_empty() {
            let a = dim_label(&format!("({alias})"));
            hb.pack_start(&a, false, false, 0);
            a.show();
        }
        if !desc.is_empty() {
            let d = dim_label(&desc);
            hb.pack_start(&d, false, false, 0);
            d.show();
        }
        row.add(&hb);
        hb.show();
        list.add(&row);
        row.show();
    }
    list.show();
    select_suggestion(list, state, 0);
}

fn trigger_completion(
    query: &str,
    search: &gtk::SearchEntry,
    list: &gtk::ListBox,
    state: &State,
) -> bool {
    let Some((start, items, kind)) = compute_candidates(query, state) else {
        return false;
    };
    state.suggestion_start.set(start);
    *state.suggestion_kind.borrow_mut() = Some(kind);
    *state.suggestions.borrow_mut() = items.clone();
    if items.len() == 1 {
        accept_suggestion(search, list, state);
        return true;
    }
    populate_suggestions(list, state);
    true
}

fn accept_suggestion(search: &gtk::SearchEntry, list: &gtk::ListBox, state: &State) {
    let idx = state.suggestion_idx.get();
    let Some(chosen) = state.suggestions.borrow().get(idx).cloned() else {
        return;
    };
    let kind = *state.suggestion_kind.borrow();
    let start = state.suggestion_start.get();
    let query = search.text().to_string();
    let prefix = &query[..start.min(query.len())];
    let new_query = match kind {
        Some(SuggestKind::Verb) => format!("{prefix}/{chosen} "),
        Some(SuggestKind::Field) => format!("{prefix}{chosen}:"),
        Some(SuggestKind::Value) => {
            let v = if chosen.contains(char::is_whitespace) {
                format!("\"{chosen}\"")
            } else {
                chosen
            };
            format!("{prefix}{v} ")
        }
        None => return,
    };
    close_suggestions(list, state);
    search.set_text(&new_query);
    search.set_position(-1);
}
