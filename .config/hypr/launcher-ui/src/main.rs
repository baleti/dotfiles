//! Proof of concept: the app launcher (bound to the Super key) as its own small native process
//! instead of a Quickshell component, built on the same pieces as ../winswitch-ui (sctk layer
//! shell, tiny-skia, fractional scaling, the shared DSL's tokenizer and substring rules).
//!
//! Scope of the PoC: text-only rows (no icons yet), bare-text search over name + generic name,
//! launch-frecency ranking from the Quickshell launcher's history file, launching, mouse.
//! Anything that needs the DSL engine (`/verbs`, Tab completion, history) is handed to the
//! Quickshell launcher (`qs ipc call launcher openWith <query>`), which opens with the query typed.
//! A launch is counted through Quickshell's IPC (`launcher bump`) so there is one writer for the file.
//!
//! The desktop entries are scanned on a worker thread, so the card and search box appear (and
//! accept typing) before the list is filled. Timings go to ~/.cache/launcher-ui.log.

use std::collections::{HashMap, HashSet};
use std::io::{BufRead, BufReader};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use ab_glyph::{point, Font, FontRef, PxScale, ScaleFont};
use smithay_client_toolkit::reexports::calloop::channel::{self, Event as ChanEvent, Sender};
use smithay_client_toolkit::reexports::calloop::timer::{TimeoutAction, Timer};
use smithay_client_toolkit::reexports::calloop::{EventLoop, LoopHandle};
use smithay_client_toolkit::reexports::calloop_wayland_source::WaylandSource;
use smithay_client_toolkit::reexports::client::globals::registry_queue_init;
use smithay_client_toolkit::reexports::client::protocol::{wl_keyboard, wl_output, wl_pointer, wl_seat, wl_shm, wl_surface};
use smithay_client_toolkit::reexports::client::{Connection, Dispatch, QueueHandle};
use smithay_client_toolkit::reexports::protocols::wp::fractional_scale::v1::client::{
    wp_fractional_scale_manager_v1::{self, WpFractionalScaleManagerV1},
    wp_fractional_scale_v1::{self, WpFractionalScaleV1},
};
use smithay_client_toolkit::reexports::protocols::wp::viewporter::client::{
    wp_viewport::{self, WpViewport},
    wp_viewporter::{self, WpViewporter},
};
use smithay_client_toolkit::{
    compositor::{CompositorHandler, CompositorState},
    delegate_compositor, delegate_keyboard, delegate_layer, delegate_output, delegate_pointer, delegate_registry,
    delegate_seat, delegate_shm,
    output::{OutputHandler, OutputState},
    registry::{ProvidesRegistryState, RegistryState},
    registry_handlers,
    seat::{
        keyboard::{KeyEvent, KeyboardHandler, Keysym, Modifiers, RawModifiers},
        pointer::{PointerEvent, PointerEventKind, PointerHandler},
        Capability, SeatHandler, SeatState,
    },
    shell::{
        wlr_layer::{Anchor, KeyboardInteractivity, Layer, LayerShell, LayerShellHandler, LayerSurface, LayerSurfaceConfigure},
        WaylandSurface,
    },
    shm::{slot::SlotPool, Shm, ShmHandler},
};
use tiny_skia::{Color, FillRule, Paint, PathBuilder, Pixmap, Rect, Stroke, Transform};

static FONT_DATA: &[u8] = include_bytes!("/usr/share/fonts/TTF/JetBrainsMono-Regular.ttf");

const FONT_PX: f32 = 13.0; // Theme.fontSize
const QUERY_PX: f32 = 14.0; // Theme.fontSize + 1
const CARD_W: i32 = 560;
const HEADER_H: i32 = 44;
const ROW_H: i32 = 30;
const HANDOFF_TIMEOUT: Duration = Duration::from_millis(2500);

struct DApp {
    id: String,
    name: String,
    generic: String,
    exec: String,
    terminal: bool,
    path: Option<String>,
    hay: String, // lowercase "name generic": what bare text is matched against
}

type Hist = HashMap<String, (u32, i64)>; // id -> (count, last unix seconds)

enum Msg {
    Apps { apps: Vec<DApp>, hist: Hist, ms: f64 },
    QsMapped,
    HandoffFailed,
}

type Rgb = [u8; 3];

struct Theme {
    primary: Rgb,
    text: Rgb,
    text_dim: Rgb,
}

fn hex(v: &serde_json::Value, fallback: Rgb) -> Rgb {
    let Some(s) = v.as_str() else { return fallback };
    let s = s.trim_start_matches('#');
    if s.len() < 6 {
        return fallback;
    }
    let p = |i: usize| u8::from_str_radix(&s[i..i + 2], 16).unwrap_or(0);
    [p(0), p(2), p(4)]
}

impl Theme {
    fn load() -> Theme {
        let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
        let v: serde_json::Value = std::fs::read_to_string(home.join(".local/state/quickshell/scheme.json"))
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or(serde_json::Value::Null);
        Theme {
            primary: hex(&v["primary"], [0x33, 0xcc, 0xff]),
            text: hex(&v["onSurface"], [0xd8, 0xde, 0xe9]),
            text_dim: hex(&v["onSurfaceVariant"], [0xa0, 0xa8, 0xb0]),
        }
    }
}

fn runtime_dir() -> PathBuf {
    std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/tmp"))
}

fn home() -> PathBuf {
    PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
}

// ---- the shared DSL's bare-text rules (quickshell/lib/dsl.js: tokenize, substrIdx) ----

struct Tok {
    text: String,
    lead_quote: bool,
    quoted: bool,
    neg: bool,
}

fn tokenize(q: &str) -> Vec<Tok> {
    let mut out = vec![];
    let (mut cur, mut started) = (String::new(), false);
    let (mut lead_quote, mut in_quotes, mut qc, mut quoted, mut neg) = (false, false, '\0', false, false);
    for c in q.chars() {
        if c == '!' && !started && !neg {
            neg = true;
            continue;
        }
        let opens = c == '"' || (c == '\'' && !started);
        if if in_quotes { c == qc } else { opens } {
            if !started {
                lead_quote = true;
            }
            if !in_quotes {
                qc = c;
            } else {
                quoted = true;
            }
            in_quotes = !in_quotes;
            started = true;
            continue;
        }
        if c.is_whitespace() && !in_quotes {
            if started {
                out.push(Tok { text: std::mem::take(&mut cur), lead_quote, quoted, neg });
                started = false;
                lead_quote = false;
                quoted = false;
            }
            neg = false;
            continue;
        }
        started = true;
        cur.push(c);
    }
    if started {
        out.push(Tok { text: cur, lead_quote, quoted, neg });
    }
    out
}

fn is_word(c: Option<&char>) -> bool {
    c.is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == '_')
}

fn substr(needle: &str, hay: &str, exact: bool) -> bool {
    let n: Vec<char> = needle.to_lowercase().chars().collect();
    let h: Vec<char> = hay.to_lowercase().chars().collect();
    if n.is_empty() {
        return true;
    }
    if n.len() > h.len() {
        return false;
    }
    let (lead, trail) = (is_word(n.first()), is_word(n.last()));
    (0..=h.len() - n.len()).any(|i| {
        h[i..i + n.len()] == n[..]
            && (!exact || (!(lead && i > 0 && is_word(h.get(i - 1))) && !(trail && is_word(h.get(i + n.len())))))
    })
}

fn needs_dsl(q: &str) -> bool {
    tokenize(q).iter().any(|t| !t.lead_quote && t.text.starts_with('/'))
}

// ---- desktop entries ----

fn parse_desktop(id: &str, text: &str) -> Option<DApp> {
    let mut in_entry = false;
    let (mut name, mut generic, mut exec, mut typ) = (String::new(), String::new(), String::new(), String::new());
    let (mut hidden, mut terminal, mut path) = (false, false, None);
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_entry = line == "[Desktop Entry]";
            continue;
        }
        if !in_entry {
            continue;
        }
        let Some((k, v)) = line.split_once('=') else { continue };
        match k.trim() {
            "Name" => name = v.trim().to_string(),
            "GenericName" => generic = v.trim().to_string(),
            "Exec" => exec = v.trim().to_string(),
            "Type" => typ = v.trim().to_string(),
            "NoDisplay" | "Hidden" => hidden |= v.trim() == "true",
            "Terminal" => terminal = v.trim() == "true",
            "Path" => path = Some(v.trim().to_string()),
            _ => {}
        }
    }
    if hidden || name.is_empty() || exec.is_empty() || (!typ.is_empty() && typ != "Application") {
        return None;
    }
    let hay = format!("{name} {generic}").to_lowercase();
    Some(DApp { id: id.to_string(), name, generic, exec, terminal, path, hay })
}

fn walk(dir: &Path, prefix: &str, seen: &mut HashSet<String>, out: &mut Vec<DApp>) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().to_string();
        let path = e.path();
        if path.is_dir() {
            walk(&path, &format!("{prefix}{name}-"), seen, out);
        } else if name.ends_with(".desktop") {
            let id = format!("{prefix}{name}");
            // an earlier directory wins, even when its entry is hidden
            if seen.insert(id.clone()) {
                if let Ok(text) = std::fs::read_to_string(&path) {
                    if let Some(app) = parse_desktop(&id, &text) {
                        out.push(app);
                    }
                }
            }
        }
    }
}

fn scan() -> Vec<DApp> {
    let mut dirs: Vec<PathBuf> = vec![];
    dirs.push(std::env::var_os("XDG_DATA_HOME").map(PathBuf::from).unwrap_or_else(|| home().join(".local/share")));
    let sys = std::env::var("XDG_DATA_DIRS").unwrap_or_default();
    let sys = if sys.is_empty() { "/usr/local/share:/usr/share".to_string() } else { sys };
    dirs.extend(sys.split(':').filter(|d| !d.is_empty()).map(PathBuf::from));
    let (mut seen, mut out) = (HashSet::new(), vec![]);
    for d in dirs {
        walk(&d.join("applications"), "", &mut seen, &mut out);
    }
    out
}

fn load_history() -> Hist {
    let v: serde_json::Value = std::fs::read_to_string(home().join(".cache/quickshell/launcher-history.json"))
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or(serde_json::Value::Null);
    v.as_object()
        .map(|o| o.iter().map(|(k, e)| (k.clone(), (e["count"].as_u64().unwrap_or(0) as u32, e["last"].as_i64().unwrap_or(0)))).collect())
        .unwrap_or_default()
}

/// LauncherHistory.score: launch count weighted heavily, a small recency bump.
fn score(hist: &Hist, id: &str) -> i64 {
    let Some(&(count, last)) = hist.get(id) else { return 0 };
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
    let age_days = if last > 0 { (now - last) as f64 / 86400.0 } else { 9999.0 };
    let recency = if age_days < 3.0 { 3 } else if age_days < 14.0 { 2 } else if age_days < 60.0 { 1 } else { 0 };
    count as i64 * 4 + recency
}

/// Exec= with the field codes (%f %U ...) dropped and %% unescaped.
fn clean_exec(exec: &str) -> String {
    let mut out = String::new();
    let mut it = exec.chars().peekable();
    while let Some(c) = it.next() {
        if c == '%' {
            match it.next() {
                Some('%') => out.push('%'),
                _ => {}
            }
        } else {
            out.push(c);
        }
    }
    out.trim().to_string()
}

// ---- drawing helpers (physical pixels; callers multiply logical coordinates by the scale) ----

/// Qt's `font.pixelSize` is the em size; ab_glyph's PxScale is the ascender-to-descender height.
fn px(font: &FontRef, size: f32) -> PxScale {
    PxScale::from(size * font.height_unscaled() / font.units_per_em().unwrap_or(1000.0))
}

fn text_width(font: &FontRef, size: f32, s: &str) -> f32 {
    let sf = font.as_scaled(px(font, size));
    s.chars().map(|c| sf.h_advance(sf.glyph_id(c))).sum()
}

/// (ascent, line height)
fn metrics(font: &FontRef, size: f32) -> (f32, f32) {
    let sf = font.as_scaled(px(font, size));
    (sf.ascent(), sf.ascent() - sf.descent() + sf.line_gap())
}

#[allow(clippy::too_many_arguments)]
fn draw_text(pm: &mut Pixmap, font: &FontRef, size: f32, x: f32, base: f32, rgb: Rgb, s: &str, max_w: f32) {
    let sf = font.as_scaled(px(font, size));
    let mut shown = String::new();
    if text_width(font, size, s) <= max_w {
        shown.push_str(s);
    } else {
        let ell = sf.h_advance(sf.glyph_id('…'));
        let mut w = 0.0;
        for c in s.chars() {
            let adv = sf.h_advance(sf.glyph_id(c));
            if w + adv + ell > max_w {
                break;
            }
            w += adv;
            shown.push(c);
        }
        shown.push('…');
    }
    let (pw, ph) = (pm.width() as i32, pm.height() as i32);
    let data = pm.data_mut();
    let mut cx = x;
    for ch in shown.chars() {
        let mut g = sf.scaled_glyph(ch);
        let adv = sf.h_advance(g.id);
        g.position = point(cx, base);
        if let Some(o) = font.outline_glyph(g) {
            let b = o.px_bounds();
            o.draw(|gx, gy, a| {
                let (px, py) = (b.min.x as i32 + gx as i32, b.min.y as i32 + gy as i32);
                if px < 0 || py < 0 || px >= pw || py >= ph {
                    return;
                }
                let i = ((py * pw + px) * 4) as usize;
                for k in 0..3 {
                    data[i + k] = (rgb[k] as f32 * a + data[i + k] as f32 * (1.0 - a)) as u8;
                }
                data[i + 3] = (a * 255.0 + data[i + 3] as f32 * (1.0 - a)) as u8;
            });
        }
        cx += adv;
    }
}

fn rrect(x: f32, y: f32, w: f32, h: f32, r: f32) -> tiny_skia::Path {
    let mut pb = PathBuilder::new();
    pb.move_to(x + r, y);
    pb.line_to(x + w - r, y);
    pb.quad_to(x + w, y, x + w, y + r);
    pb.line_to(x + w, y + h - r);
    pb.quad_to(x + w, y + h, x + w - r, y + h);
    pb.line_to(x + r, y + h);
    pb.quad_to(x, y + h, x, y + h - r);
    pb.line_to(x, y + r);
    pb.quad_to(x, y, x + r, y);
    pb.close();
    pb.finish().unwrap()
}

fn paint(rgb: Rgb, a: u8) -> Paint<'static> {
    let mut p = Paint::default();
    p.set_color(Color::from_rgba8(rgb[0], rgb[1], rgb[2], a));
    p.anti_alias = true;
    p
}

fn fill(pm: &mut Pixmap, path: &tiny_skia::Path, tf: Transform, rgb: Rgb, a: u8) {
    pm.fill_path(path, &paint(rgb, a), FillRule::Winding, tf, None);
}

fn stroke(pm: &mut Pixmap, path: &tiny_skia::Path, tf: Transform, rgb: Rgb, a: u8, width: f32) {
    let st = Stroke { width, ..Stroke::default() };
    pm.stroke_path(path, &paint(rgb, a), &st, tf, None);
}

struct App {
    registry_state: RegistryState,
    seat_state: SeatState,
    output_state: OutputState,
    shm: Shm,
    loop_handle: LoopHandle<'static, App>,
    layer: LayerSurface,
    viewport: Option<WpViewport>,
    _frac: Option<WpFractionalScaleV1>,
    scale_120: u32,
    pool: SlotPool,
    keyboard: Option<wl_keyboard::WlKeyboard>,
    pointer: Option<wl_pointer::WlPointer>,
    font: FontRef<'static>,
    theme: Theme,
    tx: Sender<Msg>,
    t0: Instant,
    log: Vec<String>,
    width: u32,
    height: u32,
    configured: bool,
    dirty: bool,
    exit: bool,
    first_frame: bool,
    first_key: bool,
    ctrl: bool,
    shift: bool,
    apps: Vec<DApp>,
    hist: Hist,
    query: String,
    cursor: usize, // in chars
    results: Vec<usize>,
    selected: usize,
    scroll: usize,
    handing_off: bool,
    pending_launch: Option<usize>,
    hover_origin: Option<(f64, f64)>,
    hover_armed: bool,
    hits: Vec<(i32, i32, i32, i32, usize)>, // logical row rects -> result position
    card_rect: (i32, i32, i32, i32),
}

impl App {
    fn note(&mut self, msg: &str) {
        let ms = self.t0.elapsed().as_secs_f64() * 1000.0;
        self.log.push(format!("+{ms:7.1}ms {msg}"));
    }

    fn scale(&self) -> f32 {
        self.scale_120 as f32 / 120.0
    }

    fn card_h(&self) -> i32 {
        (self.height as f32 * 0.6).round() as i32
    }

    fn vis_rows(&self) -> usize {
        (((self.card_h() - HEADER_H - 14) / ROW_H).max(1)) as usize
    }

    /// Filter by the query, rank (exact / prefix / substring of the first bare word), then
    /// launch frecency, then alphabetical -- AppLauncher.qml's order.
    fn refilter(&mut self) {
        let toks = tokenize(&self.query);
        let first = toks.iter().find(|t| !t.neg && !t.text.is_empty()).map(|t| t.text.to_lowercase()).unwrap_or_default();
        let rank = |a: &DApp| -> u8 {
            if first.is_empty() {
                return 3;
            }
            let n = a.name.to_lowercase();
            if n == first { 0 } else if n.starts_with(&first) { 1 } else if n.contains(&first) { 2 } else { 3 }
        };
        let mut rows: Vec<usize> = (0..self.apps.len())
            .filter(|&i| toks.iter().all(|t| substr(&t.text, &self.apps[i].hay, t.quoted) != t.neg))
            .collect();
        rows.sort_by(|&a, &b| {
            let (x, y) = (&self.apps[a], &self.apps[b]);
            rank(x)
                .cmp(&rank(y))
                .then(score(&self.hist, &y.id).cmp(&score(&self.hist, &x.id)))
                .then(x.name.to_lowercase().cmp(&y.name.to_lowercase()))
        });
        self.results = rows;
        self.selected = self.selected.min(self.results.len().saturating_sub(1));
        self.ensure_visible();
        self.dirty = true;
    }

    fn ensure_visible(&mut self) {
        if self.height == 0 {
            return;
        }
        let rows = self.vis_rows();
        if self.selected < self.scroll {
            self.scroll = self.selected;
        } else if self.selected >= self.scroll + rows {
            self.scroll = self.selected + 1 - rows;
        }
    }

    fn nav(&mut self, d: i32) {
        if self.results.is_empty() {
            return;
        }
        self.selected = (self.selected as i32 + d).clamp(0, self.results.len() as i32 - 1) as usize;
        self.ensure_visible();
        self.dirty = true;
    }

    fn launch(&mut self, pos: usize) {
        if self.results.get(pos).is_some() {
            // started only after the surface is gone (see main): while this layer holds the
            // exclusive keyboard grab the new window would not get focus
            self.pending_launch = Some(self.results[pos]);
        }
        self.exit = true;
    }

    fn handoff(&mut self) {
        if self.handing_off {
            return;
        }
        self.handing_off = true;
        self.note(&format!("handoff to quickshell (query {:?})", self.query));
        let query = self.query.clone();
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let ok = Command::new("qs")
                .args(["ipc", "call", "launcher", "openWith", &query])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .is_ok_and(|s| s.success());
            if !ok {
                let _ = tx.send(Msg::HandoffFailed);
            }
        });
        let _ = self.loop_handle.insert_source(Timer::from_duration(HANDOFF_TIMEOUT), |_, _, app: &mut App| {
            app.exit = true;
            TimeoutAction::Drop
        });
    }

    // ---- query editing ----

    fn byte_at(&self, chars: usize) -> usize {
        self.query.char_indices().nth(chars).map_or(self.query.len(), |(i, _)| i)
    }

    fn qlen(&self) -> usize {
        self.query.chars().count()
    }

    fn set_query(&mut self, q: String, cursor: usize) {
        self.query = q;
        self.cursor = cursor.min(self.qlen());
        self.selected = 0;
        self.scroll = 0;
        self.refilter();
        if needs_dsl(&self.query) {
            self.handoff();
        }
    }

    fn insert(&mut self, t: &str) {
        let at = self.byte_at(self.cursor);
        let mut q = self.query.clone();
        q.insert_str(at, t);
        let c = self.cursor + t.chars().count();
        self.set_query(q, c);
    }

    fn delete_range(&mut self, from: usize, to: usize) {
        if from >= to {
            return;
        }
        let (a, b) = (self.byte_at(from), self.byte_at(to));
        let mut q = self.query.clone();
        q.replace_range(a..b, "");
        self.set_query(q, from);
    }

    fn handle_key(&mut self, ev: KeyEvent) {
        if self.handing_off {
            return; // typed while Quickshell takes over: dropped, not leaked to a window
        }
        if !self.first_key {
            self.first_key = true;
            self.note("first key");
        }
        let ks = ev.keysym;
        let n = self.qlen();
        match ks {
            Keysym::Escape => self.exit = true,
            Keysym::Return | Keysym::KP_Enter => self.launch(self.selected),
            Keysym::Tab | Keysym::ISO_Left_Tab => self.handoff(), // completion
            Keysym::Down => self.nav(1),
            Keysym::Up => self.nav(-1),
            Keysym::Left => {
                self.cursor = self.cursor.saturating_sub(1);
                self.dirty = true;
            }
            Keysym::Right => {
                self.cursor = (self.cursor + 1).min(n);
                self.dirty = true;
            }
            Keysym::Home => {
                self.cursor = 0;
                self.dirty = true;
            }
            Keysym::End => {
                self.cursor = n;
                self.dirty = true;
            }
            Keysym::BackSpace => self.delete_range(self.cursor.saturating_sub(1), self.cursor),
            Keysym::Delete => self.delete_range(self.cursor, (self.cursor + 1).min(n)),
            _ if self.ctrl => match ks {
                Keysym::j | Keysym::n => self.nav(1),
                Keysym::k | Keysym::p => self.nav(-1),
                Keysym::r => self.handoff(), // history popup
                Keysym::a => {
                    self.cursor = 0;
                    self.dirty = true;
                }
                Keysym::e => {
                    self.cursor = n;
                    self.dirty = true;
                }
                Keysym::u => self.delete_range(0, self.cursor),
                Keysym::w => {
                    let chars: Vec<char> = self.query.chars().collect();
                    let mut i = self.cursor;
                    while i > 0 && chars[i - 1].is_whitespace() {
                        i -= 1;
                    }
                    while i > 0 && !chars[i - 1].is_whitespace() {
                        i -= 1;
                    }
                    self.delete_range(i, self.cursor);
                }
                _ => {}
            },
            _ => {
                if let Some(t) = ev.utf8.as_deref().filter(|t| !t.is_empty() && !t.chars().any(char::is_control)) {
                    self.insert(t);
                }
            }
        }
    }

    fn on_msg(&mut self, m: Msg) {
        match m {
            Msg::Apps { apps, hist, ms } => {
                self.note(&format!("{} desktop entries scanned in {ms:.1}ms", apps.len()));
                self.apps = apps;
                self.hist = hist;
                self.refilter();
            }
            Msg::QsMapped => {
                if self.handing_off {
                    self.note("quickshell launcher mapped");
                    self.exit = true;
                }
            }
            Msg::HandoffFailed => {
                self.note("handoff failed, staying native");
                self.handing_off = false;
            }
        }
    }

    fn draw(&mut self) {
        if !self.configured || self.width == 0 {
            return;
        }
        self.dirty = false;
        let sc = self.scale();
        let p = |v: i32| (v as f32 * sc).round() as i32;
        let (lw, lh_) = (self.width as i32, self.height as i32);
        let (w, h) = (p(lw), p(lh_));
        let mut pm = Pixmap::new(w as u32, h as u32).unwrap();
        let tf = Transform::from_scale(sc, sc);
        let th = &self.theme;
        let card_h = self.card_h();
        let (cx, cy) = ((lw - CARD_W) / 2, (lh_ as f32 * 0.2).round() as i32);
        self.card_rect = (cx, cy, CARD_W, card_h);

        fill(&mut pm, &rrect(cx as f32, cy as f32, CARD_W as f32, card_h as f32, 10.0), tf, [26, 26, 26], 230);
        stroke(&mut pm, &rrect(cx as f32 + 0.5, cy as f32 + 0.5, CARD_W as f32 - 1.0, card_h as f32 - 1.0, 9.5), tf, th.primary, 255, 1.0);

        // search row: magnifier, query, caret
        let (hx, hy) = ((cx + 16) as f32, cy as f32);
        let mut pb = PathBuilder::new();
        pb.push_circle(hx + 6.0, hy + 20.0, 4.5);
        pb.move_to(hx + 9.5, hy + 23.5);
        pb.line_to(hx + 13.0, hy + 27.0);
        if let Some(path) = pb.finish() {
            stroke(&mut pm, &path, tf, th.text_dim, 255, 1.5);
        }
        let size = QUERY_PX * sc;
        let (asc, lh) = metrics(&self.font, size);
        let top = (hy + (HEADER_H as f32 - lh / sc) / 2.0) * sc;
        let tx = (cx + 40) as f32 * sc;
        let max_w = (CARD_W - 56) as f32 * sc;
        draw_text(&mut pm, &self.font, size, tx, top + asc, th.text, &self.query, max_w);
        let before: String = self.query.chars().take(self.cursor).collect();
        let cxp = tx + text_width(&self.font, size, &before);
        if let Some(r) = Rect::from_xywh(cxp, top, (1.5 * sc).max(1.0), lh) {
            pm.fill_rect(r, &paint(th.primary, 255), Transform::identity(), None);
        }
        // separator
        if let Some(r) = Rect::from_xywh((cx + 8) as f32 * sc, (cy + HEADER_H) as f32 * sc, (CARD_W - 16) as f32 * sc, sc.max(1.0)) {
            pm.fill_rect(r, &paint(th.text_dim, 40), Transform::identity(), None);
        }

        // results
        let size = FONT_PX * sc;
        let (asc, lh) = metrics(&self.font, size);
        let rows = self.vis_rows();
        let list_y = cy + HEADER_H + 7;
        self.hits.clear();
        let mut hits = vec![];
        for (i, &ai) in self.results.iter().enumerate().skip(self.scroll).take(rows) {
            let y = list_y + (i - self.scroll) as i32 * ROW_H;
            hits.push((cx + 8, y, CARD_W - 16, ROW_H, i));
            if i == self.selected {
                fill(&mut pm, &rrect((cx + 8) as f32, y as f32 + 1.0, (CARD_W - 16) as f32, (ROW_H - 2) as f32, 6.0), tf, th.primary, 64);
            }
            let app = &self.apps[ai];
            // icon placeholder: a rounded chip with the initial (icons are not in the PoC)
            fill(&mut pm, &rrect((cx + 16) as f32, y as f32 + 5.0, 20.0, 20.0, 5.0), tf, th.text_dim, 40);
            let initial: String = app.name.chars().next().map(|c| c.to_uppercase().to_string()).unwrap_or_default();
            let iw = text_width(&self.font, size, &initial);
            draw_text(&mut pm, &self.font, size, (cx + 26) as f32 * sc - iw / 2.0, (y as f32 + (ROW_H as f32 - lh / sc) / 2.0) * sc + asc, th.text_dim, &initial, 30.0 * sc);
            let base = (y as f32 + (ROW_H as f32 - lh / sc) / 2.0) * sc + asc;
            draw_text(&mut pm, &self.font, size, (cx + 46) as f32 * sc, base, th.text, &app.name, (CARD_W - 64) as f32 * sc);
        }
        self.hits = hits;

        let stride = w * 4;
        let (buffer, canvas) = self.pool.create_buffer(w, h, stride, wl_shm::Format::Argb8888).expect("buffer");
        for (d, s) in canvas.chunks_exact_mut(4).zip(pm.data().chunks_exact(4)) {
            d[0] = s[2];
            d[1] = s[1];
            d[2] = s[0];
            d[3] = s[3];
        }
        if let Some(v) = &self.viewport {
            v.set_destination(lw, lh_);
        }
        self.layer.wl_surface().damage_buffer(0, 0, w, h);
        buffer.attach_to(self.layer.wl_surface()).expect("attach");
        self.layer.commit();
        if self.first_frame {
            self.first_frame = false;
            self.note(&format!("first frame committed (scale {sc})"));
        }
    }

    fn row_at(&self, x: f64, y: f64) -> Option<usize> {
        self.hits.iter().find(|(rx, ry, rw, rh, _)| x >= *rx as f64 && y >= *ry as f64 && x < (*rx + *rw) as f64 && y < (*ry + *rh) as f64).map(|h| h.4)
    }

    fn pointer_moved(&mut self, x: f64, y: f64) -> bool {
        if self.hover_armed {
            return true;
        }
        match self.hover_origin {
            None => {
                self.hover_origin = Some((x, y));
                false
            }
            Some((ox, oy)) => {
                if (x - ox).abs() + (y - oy).abs() > 8.0 {
                    self.hover_armed = true;
                }
                self.hover_armed
            }
        }
    }
}

impl CompositorHandler for App {
    fn scale_factor_changed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: i32) {}
    fn transform_changed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: wl_output::Transform) {}
    fn frame(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: u32) {}
    fn surface_enter(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: &wl_output::WlOutput) {}
    fn surface_leave(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: &wl_output::WlOutput) {}
}

impl OutputHandler for App {
    fn output_state(&mut self) -> &mut OutputState {
        &mut self.output_state
    }
    fn new_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
    fn update_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
    fn output_destroyed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
}

impl LayerShellHandler for App {
    fn closed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &LayerSurface) {
        self.exit = true;
    }
    fn configure(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &LayerSurface, cfg: LayerSurfaceConfigure, _: u32) {
        self.width = cfg.new_size.0.max(1);
        self.height = cfg.new_size.1.max(1);
        if !self.configured {
            self.configured = true;
            self.note(&format!("configured {}x{}", self.width, self.height));
        }
        self.dirty = true;
    }
}

impl SeatHandler for App {
    fn seat_state(&mut self) -> &mut SeatState {
        &mut self.seat_state
    }
    fn new_seat(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_seat::WlSeat) {}
    fn new_capability(&mut self, _: &Connection, qh: &QueueHandle<Self>, seat: wl_seat::WlSeat, cap: Capability) {
        if cap == Capability::Keyboard && self.keyboard.is_none() {
            let kb = self
                .seat_state
                .get_keyboard_with_repeat(qh, &seat, None, self.loop_handle.clone(), Box::new(|app, _kb, ev| app.handle_key(ev)))
                .expect("keyboard");
            self.keyboard = Some(kb);
        }
        if cap == Capability::Pointer && self.pointer.is_none() {
            self.pointer = self.seat_state.get_pointer(qh, &seat).ok();
        }
    }
    fn remove_capability(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_seat::WlSeat, cap: Capability) {
        if cap == Capability::Keyboard {
            self.keyboard = None;
        }
        if cap == Capability::Pointer {
            self.pointer = None;
        }
    }
    fn remove_seat(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_seat::WlSeat) {}
}

impl KeyboardHandler for App {
    fn enter(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard, _: &wl_surface::WlSurface, _: u32, _: &[u32], _: &[Keysym]) {
        self.note("keyboard focus");
    }
    fn leave(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard, _: &wl_surface::WlSurface, _: u32) {}
    fn press_key(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard, _: u32, ev: KeyEvent) {
        self.handle_key(ev);
    }
    fn release_key(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard, _: u32, _: KeyEvent) {}
    fn update_modifiers(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard, _: u32, m: Modifiers, _: RawModifiers, _: u32) {
        self.ctrl = m.ctrl;
        self.shift = m.shift;
    }
    fn repeat_key(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard, _: u32, _: KeyEvent) {}
}

impl PointerHandler for App {
    fn pointer_frame(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_pointer::WlPointer, events: &[PointerEvent]) {
        if self.handing_off {
            return;
        }
        for ev in events {
            let (x, y) = ev.position;
            match ev.kind {
                PointerEventKind::Enter { .. } | PointerEventKind::Motion { .. } => {
                    if self.pointer_moved(x, y) {
                        if let Some(pos) = self.row_at(x, y) {
                            if self.selected != pos {
                                self.selected = pos;
                                self.dirty = true;
                            }
                        }
                    }
                }
                PointerEventKind::Press { button, .. } if button == 0x110 => {
                    if let Some(pos) = self.row_at(x, y) {
                        self.launch(pos);
                    } else {
                        let (cx, cy, cw, ch) = self.card_rect;
                        if !(x >= cx as f64 && y >= cy as f64 && x < (cx + cw) as f64 && y < (cy + ch) as f64) {
                            self.exit = true; // click outside the card closes
                        }
                    }
                }
                PointerEventKind::Axis { vertical, .. } => {
                    let step = if vertical.discrete != 0 { vertical.discrete.signum() } else { vertical.absolute.signum() as i32 };
                    if step != 0 {
                        let max = self.results.len().saturating_sub(self.vis_rows());
                        self.scroll = (self.scroll as i32 + step).clamp(0, max as i32) as usize;
                        self.dirty = true;
                    }
                }
                _ => {}
            }
        }
    }
}

impl ShmHandler for App {
    fn shm_state(&mut self) -> &mut Shm {
        &mut self.shm
    }
}

impl Dispatch<WpFractionalScaleManagerV1, ()> for App {
    fn event(_: &mut Self, _: &WpFractionalScaleManagerV1, _: wp_fractional_scale_manager_v1::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<WpFractionalScaleV1, ()> for App {
    fn event(app: &mut Self, _: &WpFractionalScaleV1, event: wp_fractional_scale_v1::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        if let wp_fractional_scale_v1::Event::PreferredScale { scale } = event {
            app.scale_120 = scale;
            app.dirty = true;
        }
    }
}

impl Dispatch<WpViewporter, ()> for App {
    fn event(_: &mut Self, _: &WpViewporter, _: wp_viewporter::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<WpViewport, ()> for App {
    fn event(_: &mut Self, _: &WpViewport, _: wp_viewport::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

delegate_compositor!(App);
delegate_output!(App);
delegate_shm!(App);
delegate_seat!(App);
delegate_keyboard!(App);
delegate_pointer!(App);
delegate_layer!(App);
delegate_registry!(App);

impl ProvidesRegistryState for App {
    fn registry(&mut self) -> &mut RegistryState {
        &mut self.registry_state
    }
    registry_handlers![OutputState, SeatState];
}

fn write_log(log: &[String]) {
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(home().join(".cache/launcher-ui.log")) {
        let _ = writeln!(f, "--- run pid={}", std::process::id());
        for l in log {
            let _ = writeln!(f, "{l}");
        }
    }
}

fn pid_path() -> PathBuf {
    runtime_dir().join("launcher-ui.pid")
}

/// A second press toggles the launcher closed: if another instance is alive, stop it and exit.
fn already_open() -> bool {
    let Ok(text) = std::fs::read_to_string(pid_path()) else { return false };
    let Ok(pid) = text.trim().parse::<u32>() else { return false };
    let alive = std::fs::read_to_string(format!("/proc/{pid}/comm")).map(|c| c.trim() == "launcher-ui").unwrap_or(false);
    if alive && pid != std::process::id() {
        let _ = Command::new("kill").arg(pid.to_string()).status();
        let _ = std::fs::remove_file(pid_path());
        return true;
    }
    false
}

fn main() {
    let t0 = Instant::now();
    if already_open() {
        return;
    }
    let _ = std::fs::write(pid_path(), std::process::id().to_string());
    let mut pre: Vec<String> = vec![];

    // Hyprland socket2: know when the Quickshell launcher has mapped after a handoff
    let events = std::env::var("HYPRLAND_INSTANCE_SIGNATURE")
        .ok()
        .and_then(|sig| UnixStream::connect(runtime_dir().join("hypr").join(sig).join(".socket2.sock")).ok());

    let conn = Connection::connect_to_env().expect("wayland");
    let (globals, event_queue) = registry_queue_init(&conn).expect("registry");
    pre.push(format!("+{:7.1}ms wayland connected, globals listed", t0.elapsed().as_secs_f64() * 1000.0));
    let qh = event_queue.handle();
    let mut event_loop: EventLoop<App> = EventLoop::try_new().expect("loop");
    let loop_handle = event_loop.handle();
    WaylandSource::new(conn.clone(), event_queue).insert(loop_handle.clone()).expect("source");

    let compositor = CompositorState::bind(&globals, &qh).expect("compositor");
    let layer_shell = LayerShell::bind(&globals, &qh).expect("layer shell");
    let shm = Shm::bind(&globals, &qh).expect("shm");

    let surface = compositor.create_surface(&qh);
    let frac_mgr = globals.bind::<WpFractionalScaleManagerV1, _, _>(&qh, 1..=1, ()).ok();
    let viewporter = globals.bind::<WpViewporter, _, _>(&qh, 1..=1, ()).ok();
    let frac = frac_mgr.as_ref().map(|m| m.get_fractional_scale(&surface, &qh, ()));
    let viewport = viewporter.as_ref().map(|v| v.get_viewport(&surface, &qh, ()));
    let fractional = frac.is_some() && viewport.is_some();
    let layer = layer_shell.create_layer_surface(&qh, surface, Layer::Overlay, Some("launcher-ui"), None);
    layer.set_anchor(Anchor::TOP | Anchor::BOTTOM | Anchor::LEFT | Anchor::RIGHT);
    layer.set_keyboard_interactivity(KeyboardInteractivity::Exclusive);
    layer.set_exclusive_zone(-1);
    layer.set_size(0, 0);
    layer.commit();

    let pool = SlotPool::new(4 * 1024 * 1024, &shm).expect("pool");

    let (tx, rx) = channel::channel::<Msg>();
    loop_handle
        .insert_source(rx, |ev, _, app: &mut App| {
            if let ChanEvent::Msg(m) = ev {
                app.on_msg(m);
            }
        })
        .expect("channel");
    if let Some(stream) = events {
        let tx = tx.clone();
        std::thread::spawn(move || {
            for line in BufReader::new(stream).lines().map_while(Result::ok) {
                if line == "openlayer>>quickshell-launcher" && tx.send(Msg::QsMapped).is_err() {
                    break;
                }
            }
        });
    }
    // desktop entries + launch history, off the main thread: the card is usable before the list fills
    let tx_scan = tx.clone();
    std::thread::spawn(move || {
        let s = Instant::now();
        let apps = scan();
        let hist = load_history();
        let _ = tx_scan.send(Msg::Apps { apps, hist, ms: s.elapsed().as_secs_f64() * 1000.0 });
    });

    let mut app = App {
        registry_state: RegistryState::new(&globals),
        seat_state: SeatState::new(&globals, &qh),
        output_state: OutputState::new(&globals, &qh),
        shm,
        loop_handle: loop_handle.clone(),
        layer,
        viewport: if fractional { viewport } else { None },
        _frac: frac,
        scale_120: 120,
        pool,
        keyboard: None,
        pointer: None,
        font: FontRef::try_from_slice(FONT_DATA).unwrap(),
        theme: Theme::load(),
        tx,
        t0,
        log: pre,
        width: 0,
        height: 0,
        configured: false,
        dirty: false,
        exit: false,
        first_frame: true,
        first_key: false,
        ctrl: false,
        shift: false,
        apps: vec![],
        hist: HashMap::new(),
        query: String::new(),
        cursor: 0,
        results: vec![],
        selected: 0,
        scroll: 0,
        handing_off: false,
        pending_launch: None,
        hover_origin: None,
        hover_armed: false,
        hits: vec![],
        card_rect: (0, 0, 0, 0),
    };
    app.note("started");

    while !app.exit {
        event_loop.dispatch(None, &mut app).expect("dispatch");
        if app.dirty {
            app.draw();
        }
    }
    app.note("exit");
    let launch = app.pending_launch.take().map(|i| {
        let a = &app.apps[i];
        (a.id.clone(), a.name.clone(), clean_exec(&a.exec), a.terminal, a.path.clone())
    });
    let mut log = std::mem::take(&mut app.log);
    // destroy the layer surface and let the compositor process it before the new window maps
    drop(app);
    let _ = conn.roundtrip();
    let _ = std::fs::remove_file(pid_path());
    if let Some((id, name, exec, terminal, path)) = launch {
        let cmd = if terminal { format!("alacritty -e sh -c '{}'", exec.replace('\'', "'\\''")) } else { exec };
        let mut c = Command::new("sh");
        c.arg("-c").arg(&cmd).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).process_group(0);
        if let Some(p) = path.filter(|p| Path::new(p).is_dir()) {
            c.current_dir(p);
        }
        let ok = c.spawn().is_ok();
        // counted in Quickshell's frecency file through its IPC (one writer)
        let _ = Command::new("qs").args(["ipc", "call", "launcher", "bump", &id]).stdout(Stdio::null()).stderr(Stdio::null()).spawn();
        log.push(format!("+{:7.1}ms launched {name} ({id}) ok={ok}", t0.elapsed().as_secs_f64() * 1000.0));
    }
    write_log(&log);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scan_finds_real_apps() {
        let s = Instant::now();
        let apps = scan();
        eprintln!("{} apps in {:.1}ms; first: {:?}", apps.len(), s.elapsed().as_secs_f64() * 1000.0, apps.iter().take(3).map(|a| (&a.id, &a.name)).collect::<Vec<_>>());
        assert!(apps.len() > 20);
        assert!(apps.iter().all(|a| !a.name.is_empty() && !a.exec.is_empty()));
        let mut ids: Vec<&String> = apps.iter().map(|a| &a.id).collect();
        ids.sort();
        ids.dedup();
        assert_eq!(ids.len(), apps.len(), "ids are unique");
    }

    #[test]
    fn exec_field_codes() {
        assert_eq!(clean_exec("firefox %u"), "firefox");
        assert_eq!(clean_exec("env A=1 app --open %F --x 100%%"), "env A=1 app --open  --x 100%");
    }

    #[test]
    fn frecency_matches_the_qml_formula() {
        let mut h = Hist::new();
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64;
        h.insert("a.desktop".into(), (5, now));
        h.insert("b.desktop".into(), (5, 0));
        assert_eq!(score(&h, "a.desktop"), 5 * 4 + 3);
        assert_eq!(score(&h, "b.desktop"), 5 * 4);
        assert_eq!(score(&h, "none.desktop"), 0);
    }

    #[test]
    fn history_file_loads() {
        let h = load_history();
        eprintln!("{} history entries", h.len());
    }
}
