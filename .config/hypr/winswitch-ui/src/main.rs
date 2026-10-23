//! Standalone alt-tab (ALT+Tab), its own small process instead of a Quickshell component.
//!
//! Looks and behaves like the Quickshell grid (quickshell/winswitch/WinSwitch.qml): same sizing
//! formulas, theme (scheme.json), cell layout and the same two modes -- unlocked (cycle;
//! releasing Alt confirms) and locked (typing opens the search box; Enter confirms, Escape
//! cancels). Bare-text search uses the shared DSL's tokenizer and substring rules.
//!
//! Anything that needs the DSL engine (a `/verb`, Tab completion, history popup / cycling) is
//! handed to the Quickshell grid over `qs ipc call winswitch handoff`, which opens the same
//! session locked with the query already typed -- so no feature is lost, it just isn't instant.
//!
//! The main thread only draws and handles input. Everything slow runs on worker threads and
//! arrives as messages over a calloop channel:
//!   * fresh captures, streamed by the `winswitch` capture worker (taken on every invocation)
//!   * Hyprland socket2 events from winswitch.lua (`altup`, `uitab`, `nav`, `openlayer`)
//! The window list is the file the Lua side already writes
//! ($XDG_RUNTIME_DIR/winswitch-windows.json), so the first frame needs no IPC.
//!
//! Timings of each stage are appended to ~/.cache/winswitch-ui.log on exit.

use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::os::unix::net::UnixStream;
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
use tiny_skia::{Color, FillRule, Paint, PathBuilder, Pixmap, PixmapPaint, Rect, Stroke, Transform};

static FONT_DATA: &[u8] = include_bytes!("/usr/share/fonts/TTF/JetBrainsMono-Regular.ttf");

const FONT_PX: f32 = 11.0; // Theme.fontSize - 2
const HEADER_FONT_PX: f32 = 13.0; // Theme.fontSize
const MIN_FRAME: i32 = 64;
const MAX_FRAME: i32 = 320;
const LABEL_ALLOWANCE: i32 = 54; // two default columns: title (<= 2 lines) + workspace
const CELL_H_OVERHEAD: i32 = 24;
const CELL_V_OVERHEAD: i32 = 24;
const SEARCH_H: i32 = 32;
/// An Alt release before this is a tap: switch without ever drawing the grid (WinSwitchState.showDelayMs).
const SHOW_DELAY: Duration = Duration::from_millis(70);
/// Give up waiting for the Quickshell grid to map after a handoff.
const HANDOFF_TIMEOUT: Duration = Duration::from_millis(2500);

struct Win {
    addr: String,
    class: String,
    title: String,
    ws: String,
    pid: String,
    meta: HashMap<String, String>, // tmux-* / claude-* values from the enrich stream
    w: i32,
    h: i32,
    active: bool,
}

enum Msg {
    Enrich { addr: String, meta: Vec<(String, String)> },
    Thumb { addr: String, w: u32, h: u32, data: Vec<u8>, cached: bool },
    CacheDone(usize),
    AltUp,
    Tab { dir: i32, seq: u32 },
    Nav(i32, i32),
    NavHistory,
    QsMapped,
    HandoffFailed,
    History(Vec<String>),
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

fn marker_path() -> PathBuf {
    runtime_dir().join("winswitch-ui-alt")
}

fn tabs_path() -> PathBuf {
    runtime_dir().join("winswitch-ui-tabs")
}

fn load_windows() -> Vec<Win> {
    let Ok(text) = std::fs::read_to_string(runtime_dir().join("winswitch-windows.json")) else { return vec![] };
    let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) else { return vec![] };
    let s = |x: &serde_json::Value, k: &str| x[k].as_str().unwrap_or("").to_string();
    v.as_array()
        .map(|a| {
            a.iter()
                .map(|w| {
                    let (class, title, ws) = (s(w, "class"), s(w, "title"), s(w, "workspace"));
                    Win {
                        addr: s(w, "address"),
                        class,
                        title,
                        ws,
                        pid: w["pid"].as_i64().map(|p| p.to_string()).unwrap_or_default(),
                        meta: HashMap::new(),
                        w: w["width"].as_i64().unwrap_or(0) as i32,
                        h: w["height"].as_i64().unwrap_or(0) as i32,
                        active: w["active"].as_bool().unwrap_or(false),
                    }
                })
                .collect()
        })
        .unwrap_or_default()
}

/// (seq, direction) pairs the Lua side recorded for presses that happened before this process
/// was listening on socket2.
fn load_tabs() -> Vec<(u32, i32)> {
    let Ok(text) = std::fs::read_to_string(tabs_path()) else { return vec![] };
    text.lines()
        .filter_map(|l| {
            let (seq, dir) = l.split_once(' ')?;
            Some((seq.parse().ok()?, if dir.trim() == "prev" { -1 } else { 1 }))
        })
        .collect()
}

// ---- the shared DSL's bare-text rules (quickshell/lib/dsl.js: tokenize, substrIdx) ----

/// The picker query DSL (~/.config/dsl/rs): winswitch's type vocabulary and verbs.
fn make_schema() -> pickerdsl::Schema {
    use pickerdsl::{VerbDef, VerbKind};
    let mut types = vec!["title", "workspace", "pid", "monitor", "windows"];
    for (g, subs) in [("tmux", &["session", "window", "title"][..]), ("claude", &["title", "path", "session", "age", "fts"][..])] {
        for s in subs {
            types.push(Box::leak(format!("{g}-{s}").into_boxed_str()));
        }
    }
    let mut sc = pickerdsl::Schema::new(&types, vec![
        VerbDef { short: "fts", long: "", kind: VerbKind::App { takes_arg: true }, max_parts: 2 },
        VerbDef { short: "sw", long: "switch-workspace", kind: VerbKind::App { takes_arg: false }, max_parts: 1 },
    ]);
    sc.exact_types = vec!["windows".into()];
    sc
}

const DEFAULT_COLUMNS: [&str; 2] = ["title", "workspace"];

/// Window rows as the DSL engine sees them.
struct WinSrc<'a>(&'a [Win]);

impl pickerdsl::Source for WinSrc<'_> {
    fn value(&self, row: usize, ty: &str) -> String {
        let w = &self.0[row];
        match ty {
            "title" => w.title.clone(),
            "workspace" => w.ws.clone(),
            "pid" => w.pid.clone(),
            _ => w.meta.get(ty).cloned().unwrap_or_default(),
        }
    }
    fn haystack(&self, row: usize) -> String {
        let w = &self.0[row];
        format!("{} {} {}", w.title, w.class, w.ws)
    }
}

/// Parts of the query the native UI cannot evaluate: app verbs (/fts, /sw), /g (needs the grouped
/// grid) and the full-text type. Those go to the Quickshell grid.
fn needs_qs(schema: &pickerdsl::Schema, q: &str) -> bool {
    let p = pickerdsl::parse(schema, q);
    !p.apps.is_empty()
        || p.group_raw.is_some()
        || p.terms.iter().any(|t| matches!(t, pickerdsl::Term::Scoped { keys, .. } if schema.resolve_keys(keys).iter().any(|k| k == "claude-fts")))
}

// ---- layout: ported from WinSwitch.qml (_typicalAspect/_gridDims/_cellSize/frameSize) ----

struct Layout {
    cols: i32,
    rows: i32,
    cell_w: i32,   // frame budget width
    max_h: i32,    // frame budget height
    cell_hgt: i32, // full cell height
    grid_w: i32,
    card_max_h: i32,
}

fn frame_size(ww: i32, wh: i32, bw: i32, bh: i32) -> (i32, i32) {
    if ww <= 0 || wh <= 0 {
        return (bw, bh);
    }
    let aspect = wh as f32 / ww as f32;
    let h_full = (bw as f32 * aspect).round() as i32;
    if h_full <= bh {
        return (bw, h_full.max(MIN_FRAME));
    }
    (((bh as f32 / aspect).round() as i32).max(MIN_FRAME), bh)
}

fn compute_layout(wins: &[Win], sw: i32, sh: i32) -> Layout {
    let mut ratios: Vec<f32> = wins.iter().filter(|w| w.w > 0 && w.h > 0).map(|w| (w.h as f32 / w.w as f32).clamp(0.3, 3.0)).collect();
    ratios.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let aspect = if ratios.is_empty() { 1.0 } else { ratios[ratios.len() / 2] };
    let avail_w = (sw as f32 * 0.7).round() as i32;
    let avail_h = (sh as f32 * 0.78).round() as i32;
    let n = wins.len().max(1) as i32;
    let (cols, rows) = if n == 1 {
        (1, 1)
    } else {
        let ideal = (aspect * n as f32 * avail_w as f32 / avail_h as f32).sqrt();
        let cols = (ideal.round() as i32).min(n.min(8)).max(2);
        (cols, (n + cols - 1) / cols)
    };
    let cell_w_budget = (avail_w / cols).max(MIN_FRAME + CELL_H_OVERHEAD);
    let cell_h_budget = ((cell_w_budget as f32 * aspect).round() as i32).min(avail_h / rows).max(MIN_FRAME + LABEL_ALLOWANCE + CELL_V_OVERHEAD);
    let grid_w = (cell_w_budget * cols).min(avail_w);
    let grid_h = (cell_h_budget * rows).min(avail_h);
    let cell_w = ((grid_w as f32 / cols as f32 - CELL_H_OVERHEAD as f32).floor() as i32).max(MIN_FRAME);
    let cell_h = (grid_h as f32 / rows as f32 - CELL_V_OVERHEAD as f32).floor() as i32;
    let cell_h = cell_h.max(MIN_FRAME + LABEL_ALLOWANCE);
    let max_h = MIN_FRAME.max(MAX_FRAME.min(cell_h - LABEL_ALLOWANCE));
    Layout {
        cols,
        rows,
        cell_w,
        max_h,
        cell_hgt: max_h + LABEL_ALLOWANCE + CELL_V_OVERHEAD,
        grid_w,
        card_max_h: (sh as f32 * 0.92).round() as i32,
    }
}

// ---- thumbnails ----

/// Decode a PNG and box-filter it down to fit `fw` x `fh` (aspect kept).
fn decode_scaled(path: &Path, fw: u32, fh: u32) -> Option<(u32, u32, Vec<u8>)> {
    let file = std::fs::File::open(path).ok()?;
    let mut reader = png::Decoder::new(BufReader::new(file)).read_info().ok()?;
    let mut buf = vec![0u8; reader.output_buffer_size()?];
    let info = reader.next_frame(&mut buf).ok()?;
    if info.color_type != png::ColorType::Rgba || info.bit_depth != png::BitDepth::Eight {
        return None;
    }
    let (sw, sh) = (info.width as usize, info.height as usize);
    if sw == 0 || sh == 0 {
        return None;
    }
    let scale = (fw as f32 / sw as f32).min(fh as f32 / sh as f32);
    let dw = ((sw as f32 * scale).round() as usize).clamp(1, fw as usize);
    let dh = ((sh as f32 * scale).round() as usize).clamp(1, fh as usize);
    let mut out = vec![0u8; dw * dh * 4];
    for dy in 0..dh {
        let (y0, y1) = (dy * sh / dh, ((dy + 1) * sh / dh).max(dy * sh / dh + 1).min(sh));
        for dx in 0..dw {
            let (x0, x1) = (dx * sw / dw, ((dx + 1) * sw / dw).max(dx * sw / dw + 1).min(sw));
            let (mut r, mut g, mut b, mut n) = (0u32, 0u32, 0u32, 0u32);
            // sample at most ~4x4 points per destination pixel
            let (sy, sx) = (((y1 - y0) / 4).max(1), ((x1 - x0) / 4).max(1));
            let mut y = y0;
            while y < y1 {
                let mut x = x0;
                while x < x1 {
                    let i = (y * sw + x) * 4;
                    r += buf[i] as u32;
                    g += buf[i + 1] as u32;
                    b += buf[i + 2] as u32;
                    n += 1;
                    x += sx;
                }
                y += sy;
            }
            let o = (dy * dw + dx) * 4;
            out[o] = (r / n) as u8;
            out[o + 1] = (g / n) as u8;
            out[o + 2] = (b / n) as u8;
            out[o + 3] = 255;
        }
    }
    Some((dw as u32, dh as u32, out))
}

/// Takes a fresh capture of every window now (nothing is cached between invocations): the
/// `winswitch` capture worker (it holds the screencopy grant) streams one PNG per window, each
/// decoded here to its frame size (`targets`: address -> physical frame size).
fn spawn_capture(targets: Vec<(String, u32, u32)>, tx: Sender<Msg>) {
    let sizes: HashMap<String, (u32, u32)> = targets.into_iter().map(|(a, w, h)| (a, (w, h))).collect();
    std::thread::spawn(move || {
        let bin = PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".config/hypr/winswitch/target/release/winswitch");
        let Ok(mut child) = Command::new(bin).stdout(Stdio::piped()).stderr(Stdio::null()).spawn() else { return };
        let Some(out) = child.stdout.take() else { return };
        for line in BufReader::new(out).lines().map_while(Result::ok) {
            let Ok(v) = serde_json::from_str::<serde_json::Value>(&line) else { continue };
            if v["type"] == "enrich" {
                if let (Some(addr), Some(m)) = (v["address"].as_str(), v["meta"].as_object()) {
                    // enrich keys are `group_sub`; the DSL's type names are `group-sub` (claude_time is claude-age)
                    let meta = m
                        .iter()
                        .filter_map(|(k, v)| {
                            let name = k.replacen('_', "-", 1).replace("claude-time", "claude-age");
                            v.as_str().map(|v| (name, v.to_string()))
                        })
                        .collect();
                    if tx.send(Msg::Enrich { addr: addr.to_string(), meta }).is_err() {
                        break;
                    }
                }
                continue;
            }
            if v["type"] != "thumbnail" {
                continue;
            }
            let (Some(addr), Some(path)) = (v["address"].as_str(), v["path"].as_str()) else { continue };
            let Some(&(fw, fh)) = sizes.get(addr) else { continue };
            if let Some((w, h, data)) = decode_scaled(Path::new(path.trim_start_matches("file://")), fw, fh) {
                if tx.send(Msg::Thumb { addr: addr.to_string(), w, h, data, cached: false }).is_err() {
                    break;
                }
            }
        }
        let _ = child.wait();
    });
}

/// The previous captures (the capture worker leaves the newest PNG per window in tmpfs), decoded
/// off the main thread as soon as the frame sizes are known and shown at once; a fresh capture
/// then replaces its picture in place, so nothing flickers between invocations (what
/// WinSwitchState.thumbnails did by living across sessions).
fn spawn_cache(targets_rx: std::sync::mpsc::Receiver<Vec<(String, u32, u32)>>, tx: Sender<Msg>) {
    std::thread::spawn(move || {
        let Ok(targets) = targets_rx.recv() else { return };
        let dir = runtime_dir().join("winswitch");
        let mut newest: HashMap<String, (u128, PathBuf)> = HashMap::new();
        if let Ok(rd) = std::fs::read_dir(&dir) {
            for e in rd.flatten() {
                let name = e.file_name().to_string_lossy().to_string();
                let Some(stem) = name.strip_suffix(".png") else { continue };
                let Some((addr, run)) = stem.split_once('-') else { continue };
                let Ok(run) = run.parse::<u128>() else { continue };
                if newest.get(addr).map_or(true, |(r, _)| run > *r) {
                    newest.insert(addr.to_string(), (run, e.path()));
                }
            }
        }
        let mut n = 0;
        for (addr, fw, fh) in targets {
            if let Some((_, p)) = newest.get(&addr) {
                if let Some((w, h, data)) = decode_scaled(p, fw, fh) {
                    n += 1;
                    let _ = tx.send(Msg::Thumb { addr, w, h, data, cached: true });
                }
            }
        }
        let _ = tx.send(Msg::CacheDone(n));
    });
}

/// Hyprland socket2 -> messages.
fn spawn_events(stream: UnixStream, tx: Sender<Msg>) {
    std::thread::spawn(move || {
        for line in BufReader::new(stream).lines().map_while(Result::ok) {
            if line == "openlayer>>quickshell-winswitch" {
                if tx.send(Msg::QsMapped).is_err() {
                    break;
                }
                continue;
            }
            let Some(ev) = line.strip_prefix("custom>>winswitch ") else { continue };
            let mut it = ev.split_whitespace();
            let msg = match (it.next(), it.next(), it.next()) {
                (Some("altup"), _, _) => Msg::AltUp,
                (Some("uitab"), Some(dir), seq) => Msg::Tab { dir: if dir == "prev" { -1 } else { 1 }, seq: seq.and_then(|s| s.parse().ok()).unwrap_or(0) },
                (Some("nav"), Some("left"), _) => Msg::Nav(-1, 0),
                (Some("nav"), Some("right"), _) => Msg::Nav(1, 0),
                (Some("nav"), Some("up"), _) => Msg::Nav(0, -1),
                (Some("nav"), Some("down"), _) => Msg::Nav(0, 1),
                (Some("nav"), Some("history"), _) => Msg::NavHistory,
                _ => continue,
            };
            if tx.send(msg).is_err() {
                break;
            }
        }
    });
}

fn socket2() -> Option<UnixStream> {
    let sig = std::env::var("HYPRLAND_INSTANCE_SIGNATURE").ok()?;
    UnixStream::connect(runtime_dir().join("hypr").join(sig).join(".socket2.sock")).ok()
}

fn focus(addr: &str) {
    let _ = Command::new("hyprctl").args(["eval", &format!("hl.dispatch(winswitch.focus(\"{addr}\"))")]).stdout(Stdio::null()).status();
}

fn history_path() -> PathBuf {
    PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".cache/quickshell/winswitch-query-history.json")
}

// ---- drawing helpers (all in physical pixels; callers multiply logical coordinates by the scale) ----

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

/// Greedy word wrap into at most `max_lines`; the last line keeps the remainder (draw_text elides it).
fn wrap_lines(font: &FontRef, size: f32, text: &str, max_w: f32, max_lines: usize) -> Vec<String> {
    let sf = font.as_scaled(px(font, size));
    let mut lines: Vec<String> = vec![];
    let mut rest: Vec<char> = text.chars().collect();
    while !rest.is_empty() {
        if lines.len() + 1 == max_lines {
            lines.push(rest.iter().collect());
            break;
        }
        let (mut w, mut cut, mut last_space) = (0.0, rest.len(), None);
        for (i, c) in rest.iter().enumerate() {
            let adv = sf.h_advance(sf.glyph_id(*c));
            if w + adv > max_w && i > 0 {
                cut = last_space.map(|s| s + 1).unwrap_or(i);
                break;
            }
            if *c == ' ' {
                last_space = Some(i);
            }
            w += adv;
        }
        let line: String = rest[..cut].iter().collect();
        lines.push(line.trim_end().to_string());
        rest = rest[cut..].iter().copied().skip_while(|c| *c == ' ').collect();
    }
    lines
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
    scale_ready: bool,
    pool: SlotPool,
    keyboard: Option<wl_keyboard::WlKeyboard>,
    pointer: Option<wl_pointer::WlPointer>,
    font: FontRef<'static>,
    theme: Theme,
    layout: Option<Layout>,
    tx: Sender<Msg>,
    t0: Instant,
    log: Vec<String>,
    width: u32,
    height: u32,
    configured: bool,
    blank_done: bool,
    shown: bool,
    dirty: bool,
    exit: bool,
    first_key_logged: bool,
    ctrl: bool,
    shift: bool,
    // session state (mirrors WinSwitchState / WinSwitch.qml)
    locked: bool,
    list_focused: bool,
    windows: Vec<Win>,
    thumbs: HashMap<String, Pixmap>,
    query: String,
    cursor: usize, // in chars
    history: Vec<String>,
    schema: pickerdsl::Schema,
    columns: Vec<String>, // the active columns for the current query (title first)
    filtered: Vec<usize>, // window indices passing the query, in list order (sorted by /s)
    selected: i32,        // window index, -1 = none
    applied_seq: u32,
    scroll: i32,
    handing_off: bool,
    hover_origin: Option<(f64, f64)>,
    hover_armed: bool,
    hits: Vec<(i32, i32, i32, i32, usize)>, // logical cell rects -> window index
    card_rect: (i32, i32, i32, i32),
    thumbs_count: usize,
    thumbs_cached: usize,
    pending_focus: Option<String>,
    cache_tx: Option<std::sync::mpsc::Sender<Vec<(String, u32, u32)>>>,
}

impl App {
    fn note(&mut self, msg: &str) {
        let ms = self.t0.elapsed().as_secs_f64() * 1000.0;
        self.log.push(format!("+{ms:7.1}ms {msg}"));
    }

    fn scale(&self) -> f32 {
        self.scale_120 as f32 / 120.0
    }

    fn cols(&self) -> usize {
        self.layout.as_ref().map_or(1, |l| l.cols as usize)
    }

    /// Cell height: the layout's, plus 14 px per active column past the default two (WinSwitch.qml's
    /// labelAllowance); the thumbnail frame keeps its size.
    fn cell_hgt(&self) -> i32 {
        self.layout.as_ref().map_or(0, |l| l.cell_hgt) + (self.columns.len() as i32 - 2).max(0) * 14
    }

    fn header_h(&self) -> i32 {
        if self.locked { SEARCH_H + 4 } else { 0 }
    }

    /// (card height, rows of cells that fit)
    fn card_dims(&self) -> (i32, i32) {
        let l = self.layout.as_ref().unwrap();
        let ch = self.cell_hgt();
        let h = (self.header_h() + l.rows * ch + 32).min(l.card_max_h);
        (h, ((h - 32 - self.header_h()) / ch).max(1))
    }

    fn visual(&self) -> i32 {
        self.filtered.iter().position(|&i| i as i32 == self.selected).map_or(-1, |p| p as i32)
    }

    fn select_visual(&mut self, v: usize) {
        if let Some(&i) = self.filtered.get(v) {
            self.selected = i as i32;
            self.ensure_visible();
            self.dirty = true;
        }
    }

    /// Re-apply the query: the selection stays if it still matches, else the first result.
    fn refilter(&mut self) {
        let parsed = pickerdsl::parse(&self.schema, &self.query);
        let src = WinSrc(&self.windows);
        self.filtered = pickerdsl::select_rows(&self.schema, &parsed, &src, self.windows.len());
        let defaults: Vec<String> = DEFAULT_COLUMNS.iter().map(|s| s.to_string()).collect();
        self.columns = pickerdsl::active_columns(&self.schema, &parsed, &defaults, &src, self.windows.len());
        if !self.query.is_empty() && !self.filtered.is_empty() && self.visual() < 0 {
            self.selected = self.filtered[0] as i32;
        }
        self.scroll = 0;
        self.ensure_visible();
    }

    fn ensure_visible(&mut self) {
        if self.layout.is_none() {
            return;
        }
        let rows = self.card_dims().1;
        let v = self.visual();
        if v < 0 {
            return;
        }
        let row = v / self.cols() as i32;
        if row < self.scroll {
            self.scroll = row;
        } else if row >= self.scroll + rows {
            self.scroll = row + 1 - rows;
        }
    }

    /// Cyclic over the results (WinSwitchState.advance / WinSwitch._advance).
    fn advance(&mut self, dir: i32) {
        let n = self.filtered.len() as i32;
        if n == 0 {
            return;
        }
        let cur = self.visual();
        let next = if cur < 0 {
            if dir < 0 { n - 1 } else { 0 }
        } else if dir < 0 {
            (cur - 1 + n) % n
        } else {
            (cur + 1) % n
        };
        self.select_visual(next as usize);
        self.record_query();
    }

    fn advance_row(&mut self, rows: i32) {
        let n = self.filtered.len() as i32;
        if n == 0 {
            return;
        }
        let cur = self.visual();
        let next = if cur < 0 { 0 } else { (cur + rows * self.cols() as i32).clamp(0, n - 1) };
        self.select_visual(next as usize);
        self.record_query();
    }

    /// An accepted (or acted-on) search goes into the Quickshell grid's history file via its IPC
    /// (one writer for that file).
    fn record_query(&self) {
        let q = self.query.trim();
        if self.locked && !q.is_empty() {
            let _ = Command::new("qs").args(["ipc", "call", "winswitch", "record", q]).stdout(Stdio::null()).stderr(Stdio::null()).spawn();
        }
    }

    fn confirm_window(&mut self, wi: Option<usize>) {
        self.record_query();
        // Focus only after the grid's surface is gone (see main): while this layer still holds the
        // exclusive keyboard grab, Hyprland gives focus back to the window it had before.
        if let Some(w) = wi.and_then(|i| self.windows.get(i)) {
            if !w.active {
                self.pending_focus = Some(w.addr.clone());
            }
        }
        self.exit = true;
    }

    fn confirm(&mut self) {
        let sel = if self.selected >= 0 { Some(self.selected as usize) } else { None };
        self.confirm_window(sel);
    }

    /// Hand the session to the Quickshell grid (DSL engine, completion, history popup).
    fn handoff(&mut self, history: bool) {
        if self.handing_off {
            return;
        }
        self.handing_off = true;
        self.note(&format!("handoff to quickshell (query {:?}, history {history})", self.query));
        let addr = if self.selected >= 0 { self.windows[self.selected as usize].addr.clone() } else { String::new() };
        let query = self.query.clone();
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let ok = Command::new("qs")
                .args(["ipc", "call", "winswitch", "handoff", &query, &addr, if history { "true" } else { "false" }])
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
        self.refilter();
        self.dirty = true;
        if needs_qs(&self.schema, &self.query) {
            self.handoff(false);
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

    /// zsh-autosuggestions style: the rest of the newest history entry starting with the query.
    fn ghost(&self) -> String {
        if !self.locked || self.cursor != self.qlen() || self.query.trim().is_empty() {
            return String::new();
        }
        for e in self.history.iter().rev() {
            if e.len() > self.query.len() && e.starts_with(&self.query) {
                return e[self.query.len()..].to_string();
            }
        }
        String::new()
    }

    fn handle_key(&mut self, ev: KeyEvent) {
        if self.handing_off {
            return; // keys typed while Quickshell takes over are dropped, not leaked to a window
        }
        if !self.first_key_logged {
            self.first_key_logged = true;
            self.note("first key");
        }
        let ks = ev.keysym;
        let printable = ev.utf8.as_deref().filter(|t| !t.is_empty() && !t.chars().any(char::is_control)).map(str::to_string);

        // keys that behave the same in every state
        match ks {
            Keysym::Escape => {
                self.exit = true;
                return;
            }
            Keysym::Return | Keysym::KP_Enter => {
                self.confirm();
                return;
            }
            _ => {}
        }
        if self.ctrl {
            match ks {
                Keysym::h => return self.advance(-1),
                Keysym::l => return self.advance(1),
                Keysym::j => return self.advance_row(1),
                Keysym::k => return self.advance_row(-1),
                Keysym::r => return self.handoff(true), // history popup
                _ => {}
            }
        }

        if !self.locked || self.list_focused {
            // unlocked grid, or search mode with focus moved down into the results
            match ks {
                Keysym::Tab | Keysym::ISO_Left_Tab if self.list_focused => {
                    self.list_focused = false;
                    self.cursor = self.qlen();
                    self.dirty = true;
                }
                Keysym::Tab => self.advance(1),
                Keysym::ISO_Left_Tab => self.advance(-1),
                Keysym::Right => self.advance(1),
                Keysym::Left => self.advance(-1),
                Keysym::Down => self.advance_row(1),
                Keysym::Up => self.advance_row(-1),
                _ => {
                    if let Some(t) = printable {
                        // any printable key locks into search; from list focus it appends
                        if !self.locked {
                            self.locked = true;
                            self.note("locked (search)");
                            self.set_query(t.clone(), t.chars().count());
                        } else {
                            self.list_focused = false;
                            self.insert(&t);
                        }
                        self.ensure_visible();
                    }
                }
            }
            return;
        }

        // locked, search box focused
        let n = self.qlen();
        match ks {
            Keysym::Tab | Keysym::ISO_Left_Tab => self.handoff(false), // completion
            Keysym::Up => self.handoff(true),                           // history
            Keysym::Down => {
                self.list_focused = true;
                self.dirty = true;
            }
            Keysym::Left => {
                self.cursor = self.cursor.saturating_sub(1);
                self.dirty = true;
            }
            Keysym::Right | Keysym::End if self.cursor == n && !self.ghost().is_empty() && !self.shift => {
                let q = format!("{}{}", self.query, self.ghost());
                let c = q.chars().count();
                self.set_query(q, c);
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
                Keysym::a => {
                    self.cursor = 0;
                    self.dirty = true;
                }
                Keysym::e => {
                    self.cursor = n;
                    self.dirty = true;
                }
                Keysym::f if self.cursor == n && !self.ghost().is_empty() => {
                    let q = format!("{}{}", self.query, self.ghost());
                    let c = q.chars().count();
                    self.set_query(q, c);
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
                if let Some(t) = printable {
                    self.insert(&t);
                }
            }
        }
    }

    fn on_msg(&mut self, m: Msg) {
        match m {
            Msg::AltUp => {
                if !self.locked && !self.handing_off {
                    self.note("alt released");
                    self.confirm();
                }
            }
            Msg::Tab { dir, seq } => {
                if seq != 0 && seq <= self.applied_seq {
                    return; // already applied from the tabs file
                }
                self.applied_seq = self.applied_seq.max(seq);
                if self.handing_off {
                    return;
                }
                if self.locked {
                    self.handoff(false); // Alt+Tab while locked cycles completion (DSL engine)
                } else {
                    self.advance(dir);
                }
            }
            Msg::Nav(dx, dy) => {
                if self.handing_off {
                    return;
                }
                match (dx, dy) {
                    (_, 0) => self.advance(dx),
                    _ => self.advance_row(dy),
                }
            }
            Msg::NavHistory => {
                if !self.handing_off {
                    self.handoff(true);
                }
            }
            Msg::QsMapped => {
                if self.handing_off {
                    self.note("quickshell grid mapped");
                    self.exit = true;
                }
            }
            Msg::HandoffFailed => {
                self.note("handoff failed, staying native");
                self.handing_off = false;
            }
            Msg::History(h) => {
                self.history = h;
                self.dirty = true;
            }
            Msg::Enrich { addr, meta } => {
                if let Some(w) = self.windows.iter_mut().find(|w| w.addr == addr) {
                    w.meta.extend(meta);
                    self.refilter();
                    self.dirty = true;
                }
            }
            Msg::CacheDone(n) => self.note(&format!("cached thumbnails decoded ({n})")),
            Msg::Thumb { addr, w, h, data, cached } => {
                if let Some(size) = tiny_skia::IntSize::from_wh(w, h) {
                    if let Some(pm) = Pixmap::from_vec(data, size) {
                        self.thumbs.insert(addr, pm);
                        if cached {
                            self.thumbs_cached += 1;
                            if self.thumbs_cached == 1 {
                                self.note("first cached thumbnail");
                            }
                        } else {
                            self.thumbs_count += 1;
                            if self.thumbs_count == 1 {
                                self.note("first fresh thumbnail");
                            }
                        }
                        self.dirty = true;
                    }
                }
            }
        }
    }

    fn commit_blank(&mut self) {
        // Mapped but transparent: keyboard focus is held from the first moment, the card only
        // appears once the hold delay passed (a quick tap never shows a grid).
        let (buffer, canvas) = self.pool.create_buffer(1, 1, 4, wl_shm::Format::Argb8888).expect("buffer");
        canvas.fill(0);
        if let Some(v) = &self.viewport {
            v.set_destination(self.width as i32, self.height as i32);
        }
        self.layer.wl_surface().damage_buffer(0, 0, 1, 1);
        buffer.attach_to(self.layer.wl_surface()).expect("attach");
        self.layer.commit();
        self.blank_done = true;
    }

    fn draw(&mut self) {
        if !self.configured || self.width == 0 || self.layout.is_none() {
            return;
        }
        self.dirty = false;
        if !(self.locked || self.shown || self.t0.elapsed() >= SHOW_DELAY) {
            if !self.blank_done {
                self.commit_blank();
            }
            return;
        }
        let first_card = !self.shown;
        self.shown = true;
        let draw_start = Instant::now();

        let sc = self.scale();
        let p = |v: i32| (v as f32 * sc).round() as i32;
        let (lw, lh_) = (self.width as i32, self.height as i32);
        let (w, h) = (p(lw), p(lh_));
        let mut pm = Pixmap::new(w as u32, h as u32).unwrap();
        let tf = Transform::from_scale(sc, sc);
        let l = self.layout.as_ref().unwrap();
        let (card_h, vis_rows) = self.card_dims();
        let card_w = l.grid_w + 32;
        let (cx, cy) = ((lw - card_w) / 2, (lh_ - card_h) / 2);
        let th = &self.theme;
        self.card_rect = (cx, cy, card_w, card_h);

        // card: Theme.bgAlpha, 1px primary border, rounding 10
        fill(&mut pm, &rrect(cx as f32, cy as f32, card_w as f32, card_h as f32, 10.0), tf, [26, 26, 26], 230);
        stroke(&mut pm, &rrect(cx as f32 + 0.5, cy as f32 + 0.5, card_w as f32 - 1.0, card_h as f32 - 1.0, 9.5), tf, th.primary, 255, 1.0);

        // search header (locked only)
        if self.locked {
            let (hx, hy) = ((cx + 16) as f32, (cy + 16) as f32);
            let mut pb = PathBuilder::new();
            pb.push_circle(hx + 6.0, hy + 14.0, 4.5);
            pb.move_to(hx + 9.5, hy + 17.5);
            pb.line_to(hx + 13.0, hy + 21.0);
            if let Some(path) = pb.finish() {
                stroke(&mut pm, &path, tf, th.text_dim, 255, 1.5);
            }
            let size = HEADER_FONT_PX * sc;
            let (asc, lh) = metrics(&self.font, size);
            let top = (hy + (SEARCH_H as f32 - lh / sc) / 2.0) * sc;
            let tx = (hx + 22.0) * sc;
            let max_w = (card_w - 32 - 22) as f32 * sc;
            draw_text(&mut pm, &self.font, size, tx, top + asc, th.text, &self.query, max_w);
            let before: String = self.query.chars().take(self.cursor).collect();
            let cxp = tx + text_width(&self.font, size, &before);
            let ghost = self.ghost();
            if !ghost.is_empty() {
                let full = text_width(&self.font, size, &self.query);
                draw_text(&mut pm, &self.font, size, tx + full, top + asc, [136, 136, 136], &ghost, max_w - full);
            }
            if let Some(r) = Rect::from_xywh(cxp, top, (1.5 * sc).max(1.0), lh) {
                pm.fill_rect(r, &paint(th.primary, 255), Transform::identity(), None);
            }
        }

        // grid
        let cell_hgt = self.cell_hgt();
        let (gx, gy) = (cx + 16, cy + 16 + self.header_h());
        let cell_full_w = l.cell_w + CELL_H_OVERHEAD;
        let size = FONT_PX * sc;
        let (asc, lh) = metrics(&self.font, size);
        let first = (self.scroll * l.cols) as usize;
        let sel = self.selected;
        self.hits.clear();
        let mut hits = vec![];
        for (slot, &wi) in self.filtered.iter().enumerate().skip(first).take((vis_rows * l.cols) as usize) {
            let local = (slot - first) as i32;
            let (col, row) = (local % l.cols, local / l.cols);
            let (x, y) = (gx + col * cell_full_w, gy + row * cell_hgt);
            hits.push((x, y, cell_full_w, cell_hgt, wi));
            let win = &self.windows[wi];
            // rectangle inset 4
            let (rx, ry, rw, rh) = (x + 4, y + 4, cell_full_w - 8, cell_hgt - 8);
            if wi as i32 == sel {
                let cell = rrect(rx as f32 + 0.5, ry as f32 + 0.5, rw as f32 - 1.0, rh as f32 - 1.0, 6.0);
                fill(&mut pm, &cell, tf, th.primary, 41);
                stroke(&mut pm, &cell, tf, th.primary, 255, 1.0);
            }
            // thumbnail frame
            let (fw, fh) = frame_size(win.w, win.h, l.cell_w, l.max_h);
            let (fx, fy) = (rx + (rw - fw) / 2, ry + 6);
            let frame = rrect(fx as f32 + 0.5, fy as f32 + 0.5, fw as f32 - 1.0, fh as f32 - 1.0, 4.0);
            fill(&mut pm, &frame, tf, [255, 255, 255], 5);
            if let Some(t) = self.thumbs.get(&win.addr) {
                let ox = p(fx) + (p(fw) - t.width() as i32) / 2;
                let oy = p(fy) + (p(fh) - t.height() as i32) / 2;
                pm.draw_pixmap(ox, oy, t.as_ref(), &PixmapPaint::default(), Transform::identity(), None);
            }
            stroke(&mut pm, &frame, tf, [255, 255, 255], 46, 1.0);
            // one line per active column: the first (title) centered and up to 2 lines, the rest left-aligned
            let text_w = (rw - 12) as f32 * sc;
            let mut ty = (fy + l.max_h + 4) as f32 * sc;
            let mut first = true;
            for col in &self.columns {
                let mut v = pickerdsl::Source::value(&WinSrc(&self.windows), wi, col);
                if col == "title" && v.is_empty() {
                    v = win.class.clone();
                }
                if v.is_empty() {
                    continue;
                }
                if v.chars().count() > 80 {
                    v = v.chars().take(80).collect::<String>() + "\u{2026}";
                }
                let prefix = match col.as_str() {
                    "title" => String::new(),
                    "workspace" => "#".to_string(),
                    "monitor" | "windows" => format!("{col}: "),
                    c => c.split_once('-').map_or(format!("{c}: "), |(_, sub)| format!("{sub}: ")),
                };
                if first {
                    first = false;
                    for line in wrap_lines(&self.font, size, &format!("{prefix}{v}"), text_w, 2) {
                        let lw_ = text_width(&self.font, size, &line).min(text_w);
                        draw_text(&mut pm, &self.font, size, (rx + 6) as f32 * sc + (text_w - lw_) / 2.0, ty + asc, th.text, &line, text_w);
                        ty += lh;
                    }
                } else {
                    draw_text(&mut pm, &self.font, size, (rx + 6) as f32 * sc, ty + asc, th.text, &format!("{prefix}{v}"), text_w);
                    ty += lh;
                }
            }
        }
        self.hits = hits;

        // blit to a shm buffer (tiny-skia RGBA premultiplied -> wl Argb8888 = B,G,R,A bytes)
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
        if first_card {
            // Fresh captures are taken on every invocation, after the first frame so it never waits.
            spawn_capture(self.targets(), self.tx.clone());
            let took = draw_start.elapsed().as_secs_f64() * 1000.0;
            self.note(&format!("first frame committed (scale {sc}, render+blit {took:.1}ms)"));
        }
    }

    /// (address, physical frame width, height) per window.
    fn targets(&self) -> Vec<(String, u32, u32)> {
        let Some(l) = self.layout.as_ref() else { return vec![] };
        let sc = self.scale();
        self.windows
            .iter()
            .map(|w| {
                let (fw, fh) = frame_size(w.w, w.h, l.cell_w, l.max_h);
                (w.addr.clone(), (fw as f32 * sc).round() as u32, (fh as f32 * sc).round() as u32)
            })
            .collect()
    }

    /// Once the layout and the scale are known, decode the previous captures (worker thread).
    fn start_cache(&mut self) {
        if self.configured && self.scale_ready {
            if let Some(tx) = self.cache_tx.take() {
                let _ = tx.send(self.targets());
                self.note("cache decode started");
            }
        }
    }

    // ---- pointer ----

    fn cell_at(&self, x: f64, y: f64) -> Option<usize> {
        self.hits.iter().find(|(cx, cy, cw, ch, _)| x >= *cx as f64 && y >= *cy as f64 && x < (*cx + *cw) as f64 && y < (*cy + *ch) as f64).map(|h| h.4)
    }

    fn pointer_moved(&mut self, x: f64, y: f64) -> bool {
        // The grid maps under a stationary pointer; hover only selects once it genuinely moved.
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
            self.layout = Some(compute_layout(&self.windows, self.width as i32, self.height as i32));
            self.refilter();
            self.start_cache();
            // schedule the first card draw for when the hold delay has passed
            let left = SHOW_DELAY.saturating_sub(self.t0.elapsed());
            let _ = self.loop_handle.insert_source(Timer::from_duration(left + Duration::from_millis(1)), |_, _, app: &mut App| {
                app.dirty = true;
                TimeoutAction::Drop
            });
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
        if self.handing_off || !self.shown {
            return;
        }
        for ev in events {
            let (x, y) = ev.position;
            match ev.kind {
                PointerEventKind::Enter { .. } | PointerEventKind::Motion { .. } => {
                    if self.pointer_moved(x, y) {
                        if let Some(wi) = self.cell_at(x, y) {
                            if self.selected != wi as i32 {
                                self.selected = wi as i32;
                                self.dirty = true;
                            }
                        }
                    }
                }
                PointerEventKind::Press { button, .. } if button == 0x110 => {
                    if let Some(wi) = self.cell_at(x, y) {
                        self.confirm_window(Some(wi));
                    } else {
                        let (cx, cy, cw, ch) = self.card_rect;
                        let inside = x >= cx as f64 && y >= cy as f64 && x < (cx + cw) as f64 && y < (cy + ch) as f64;
                        if !inside {
                            self.exit = true; // click on the backdrop closes
                        }
                    }
                }
                PointerEventKind::Axis { vertical, .. } => {
                    let step = if vertical.discrete != 0 { vertical.discrete.signum() } else { vertical.absolute.signum() as i32 };
                    if step != 0 && self.layout.is_some() {
                        let total = (self.filtered.len() as i32 + self.cols() as i32 - 1) / self.cols() as i32;
                        let max = (total - self.card_dims().1).max(0);
                        self.scroll = (self.scroll + step).clamp(0, max);
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
            app.scale_ready = true;
            app.dirty = true;
            app.start_cache();
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
    let Some(home) = std::env::var_os("HOME") else { return };
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(PathBuf::from(home).join(".cache/winswitch-ui.log")) {
        let _ = writeln!(f, "--- run pid={}", std::process::id());
        for l in log {
            let _ = writeln!(f, "{l}");
        }
    }
}

/// WinSwitchState.advance over the whole list.
fn step(cur: i32, n: i32, dir: i32) -> i32 {
    if dir < 0 { if cur <= 0 { n - 1 } else { cur - 1 } } else { (cur + 1) % n }
}

fn main() {
    let t0 = Instant::now();
    let mut pre: Vec<String> = vec![];
    // how long after Lua wrote the press (tabs file) this process got to main()
    if let Ok(m) = std::fs::metadata(tabs_path()).and_then(|m| m.modified()) {
        if let Ok(d) = std::time::SystemTime::now().duration_since(m) {
            pre.push(format!("  lua press -> main(): {:.1}ms", d.as_secs_f64() * 1000.0));
        }
    }
    let windows = load_windows();
    if windows.is_empty() {
        return;
    }
    let n = windows.len() as i32;
    // the session starts on the focused window; every recorded press advances from there
    let mut selected = windows.iter().position(|w| w.active).map_or(-1, |i| i as i32);
    let mut applied_seq = 0;
    for (seq, dir) in load_tabs() {
        selected = step(selected, n, dir);
        applied_seq = applied_seq.max(seq);
    }

    // Subscribe to Alt-release events BEFORE checking whether Alt is still down, so a release
    // between the two cannot be lost. The Lua side keeps a marker file while its Alt poll runs.
    let events = socket2();
    if events.is_some() && !marker_path().exists() {
        // Alt already released: a tap, which switches without a grid.
        if let Some(w) = windows.get(selected.max(0) as usize) {
            if !w.active {
                focus(&w.addr);
            }
        }
        write_log(&[format!("+{:7.1}ms quick tap -> focused window {selected}", t0.elapsed().as_secs_f64() * 1000.0)]);
        return;
    }

    pre.push(format!("+{:7.1}ms window list + tabs read", t0.elapsed().as_secs_f64() * 1000.0));
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
    // fractional scaling: the compositor tells the preferred scale (1/120 units); the buffer is
    // rendered at that scale and the viewport maps it back to the logical size
    let frac_mgr = globals.bind::<WpFractionalScaleManagerV1, _, _>(&qh, 1..=1, ()).ok();
    let viewporter = globals.bind::<WpViewporter, _, _>(&qh, 1..=1, ()).ok();
    let frac = frac_mgr.as_ref().map(|m| m.get_fractional_scale(&surface, &qh, ()));
    let viewport = viewporter.as_ref().map(|v| v.get_viewport(&surface, &qh, ()));
    let fractional = frac.is_some() && viewport.is_some();
    let layer = layer_shell.create_layer_surface(&qh, surface, Layer::Overlay, Some("winswitch-ui"), None);
    layer.set_anchor(Anchor::TOP | Anchor::BOTTOM | Anchor::LEFT | Anchor::RIGHT);
    layer.set_keyboard_interactivity(KeyboardInteractivity::Exclusive);
    layer.set_exclusive_zone(-1);
    layer.set_size(0, 0);
    layer.commit();

    let pool = SlotPool::new(4 * 1024 * 1024, &shm).expect("pool");
    let (cache_tx, cache_rx) = std::sync::mpsc::channel();

    let (tx, rx) = channel::channel::<Msg>();
    loop_handle
        .insert_source(rx, |ev, _, app: &mut App| {
            if let ChanEvent::Msg(m) = ev {
                app.on_msg(m);
            }
        })
        .expect("channel");
    if let Some(stream) = events {
        spawn_events(stream, tx.clone());
    }
    spawn_cache(cache_rx, tx.clone());
    // search history for the ghost suggestion (read-only; the Quickshell grid owns the file)
    let tx_hist = tx.clone();
    std::thread::spawn(move || {
        let h: Vec<String> = std::fs::read_to_string(history_path()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default();
        let _ = tx_hist.send(Msg::History(h));
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
        scale_ready: !fractional,
        pool,
        keyboard: None,
        pointer: None,
        font: FontRef::try_from_slice(FONT_DATA).unwrap(),
        theme: Theme::load(),
        layout: None,
        tx,
        t0,
        log: pre,
        width: 0,
        height: 0,
        configured: false,
        blank_done: false,
        shown: false,
        dirty: false,
        exit: false,
        first_key_logged: false,
        ctrl: false,
        shift: false,
        locked: false,
        list_focused: false,
        schema: make_schema(),
        columns: vec![],
        filtered: vec![],
        windows,
        thumbs: HashMap::new(),
        query: String::new(),
        cursor: 0,
        history: vec![],
        selected,
        applied_seq,
        scroll: 0,
        handing_off: false,
        hover_origin: None,
        hover_armed: false,
        hits: vec![],
        card_rect: (0, 0, 0, 0),
        thumbs_count: 0,
        thumbs_cached: 0,
        pending_focus: None,
        cache_tx: Some(cache_tx),
    };
    app.note(&format!("started, {} windows, selected {}", app.windows.len(), app.selected));

    while !app.exit {
        event_loop.dispatch(None, &mut app).expect("dispatch");
        if app.dirty {
            app.draw();
        }
    }
    app.note(&format!("exit ({} cached + {} fresh thumbnails)", app.thumbs_cached, app.thumbs_count));
    let (pending, mut log) = (app.pending_focus.take(), std::mem::take(&mut app.log));
    // destroy the layer surface and make sure the compositor has processed it before switching focus
    drop(app);
    let _ = conn.roundtrip();
    if let Some(addr) = pending {
        focus(&addr);
        log.push(format!("+{:7.1}ms focused {addr} after the grid closed", t0.elapsed().as_secs_f64() * 1000.0));
    }
    write_log(&log);
}

#[cfg(test)]
mod dsl_engine {
    //! The tokenizer / substring vectors live in the pickerdsl crate now; here only what is local:
    //! which queries the native UI hands to Quickshell.
    use super::*;

    #[test]
    fn only_unported_features_hand_off() {
        let sc = make_schema();
        for q in ["/fv/title foo", "brave /s/title", "/rt/workspace", "/at/tmux", "!brave", "\"/etc\"", "/", "/f"] {
            assert!(!needs_qs(&sc, q), "{q}");
        }
        for q in ["/g/workspace", "/fts/claude-live foo", "/sw", "/fv/claude-fts word"] {
            assert!(needs_qs(&sc, q), "{q}");
        }
    }
}
