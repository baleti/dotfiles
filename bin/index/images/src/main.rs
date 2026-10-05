//! images: live photo search picker (mod+v-style list) over the CLIP + face
//! indexes. The query engine runs in ~/.cache/indexes/photos/search_server.py
//! (127.0.0.1:8765, keeps models loaded); this window is only the UI.
//!
//! Opens on the newest photos. Typing narrows the list as you type (debounced).
//! Syntax: //face <name>   //clip brick   //face <name> //clip brick   or bare words.
//! Keys: type to search, Up/Down or Ctrl+j/k move, PgUp/PgDn jump, Enter opens
//! (photo is fetched from gdrive to /tmp and opened), Esc closes.

use eframe::egui::{self, Color32, FontData, FontDefinitions, FontFamily, Key, Margin, RichText, Stroke, TextureHandle};
use serde::Deserialize;
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::time::{Duration, Instant};

const SERVER: &str = "http://127.0.0.1:8765";
const SCHEME: &str = "/home/user1/.local/state/quickshell/scheme.json";
const FONT: &str = "/usr/share/fonts/TTF/JetBrainsMono-Regular.ttf";
const TOP: usize = 150;
const ROW_H: f32 = 64.0;
const THUMB: f32 = 52.0;

#[derive(Deserialize, Clone)]
struct Hit {
    remote: String,
    score: Option<f32>,
    thumb: String,
    #[serde(default)]
    size: Option<u64>,
    #[serde(default)]
    mtime: Option<String>,
}

fn human_size(b: u64) -> String {
    const U: [&str; 5] = ["B", "KiB", "MiB", "GiB", "TiB"];
    let (mut v, mut i) = (b as f64, 0);
    while v >= 1024.0 && i < U.len() - 1 { v /= 1024.0; i += 1; }
    if i == 0 { format!("{b} B") } else { format!("{v:.1} {}", U[i]) }
}

/// "2015-06-05T20:49:06.000Z" -> "2015-06-05 20:49"
fn short_time(t: &str) -> String {
    t.replace('T', " ").chars().take(16).collect()
}

/// Column x-positions for a row/header spanning [left, right]: name | path | size | modified | score.
struct Cols { name_x: f32, path_x: f32, path_r: f32, size_r: f32, date_x: f32, score_r: f32 }
const NAME_W: f32 = 210.0;
const SIZE_W: f32 = 84.0;
const DATE_W: f32 = 140.0;
const SCORE_W: f32 = 48.0;
fn cols(left: f32, right: f32) -> Cols {
    let score_r = right - 12.0;
    let date_x = score_r - SCORE_W - 12.0 - DATE_W;
    let size_r = date_x - 12.0;
    let name_x = left;
    let path_x = name_x + NAME_W + 12.0;
    Cols { name_x, path_x, path_r: size_r - SIZE_W - 12.0, size_r, date_x, score_r }
}

#[derive(Deserialize)]
struct Reply {
    count: usize,
    results: Vec<Hit>,
    #[serde(default)]
    errors: Vec<String>,
}

/// Colours from the live Material You scheme (same file the quickshell pickers read).
#[derive(Clone, Copy)]
struct Palette {
    bg: Color32,
    text: Color32,
    dim: Color32,
    border: Color32,
    accent: Color32,
    error: Color32,
}

fn hex(s: &str) -> Option<Color32> {
    let s = s.strip_prefix('#')?;
    if s.len() != 6 { return None; }
    let v = u32::from_str_radix(s, 16).ok()?;
    Some(Color32::from_rgb((v >> 16) as u8, (v >> 8) as u8, v as u8))
}

fn load_palette() -> Palette {
    let fallback = Palette {
        bg: Color32::from_rgb(0x1a, 0x1a, 0x1a),
        text: Color32::from_rgb(0xd8, 0xde, 0xe9),
        dim: Color32::from_rgb(0xa0, 0xa8, 0xb0),
        border: Color32::from_rgb(0x59, 0x59, 0x59),
        accent: Color32::from_rgb(0x33, 0xcc, 0xff),
        error: Color32::from_rgb(0xff, 0x55, 0x55),
    };
    let Ok(text) = std::fs::read_to_string(SCHEME) else { return fallback };
    let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) else { return fallback };
    let g = |k: &str, d: Color32| v.get(k).and_then(|x| x.as_str()).and_then(hex).unwrap_or(d);
    Palette {
        bg: g("surface", fallback.bg),
        text: g("onSurface", fallback.text),
        dim: g("onSurfaceVariant", fallback.dim),
        border: g("outlineVariant", fallback.border),
        accent: g("primary", fallback.accent),
        error: g("error", fallback.error),
    }
}

/// background query results come back tagged with the request sequence number
struct Fetch {
    seq: u64,
    query: String,
    result: Result<Reply, String>,
}

struct App {
    pal: Palette,
    query: String,
    last_sent: String,
    last_change: Instant,
    seq: u64,
    tx: Sender<Fetch>,
    rx: Receiver<Fetch>,
    hits: Vec<Hit>,
    count: usize,
    selected: usize,
    status: String,
    busy: bool,
    textures: HashMap<String, TextureHandle>,
    missing: HashSet<String>,
    first_frame: bool,
    close_now: bool,
    people: Vec<String>,
    popup: bool,
    cands: Vec<(String, String)>, // (replacement text, label)
    cand_sel: usize,
}

#[derive(Deserialize)]
struct PeopleReply {
    people: Vec<String>,
}

/// Completion candidates for the fragment at the end of `q`.
/// Returns (byte index where the fragment starts, candidates).
fn completions(q: &str, people: &[String]) -> (usize, Vec<(String, String)>) {
    let start = q.rfind(char::is_whitespace).map(|i| i + q[i..].chars().next().unwrap().len_utf8()).unwrap_or(0);
    let frag = &q[start..];
    let prev = q[..start].split_whitespace().last().unwrap_or("");
    let mut out = Vec::new();
    if let Some(body) = frag.strip_prefix("//") {
        // stage 1: the path (//face, //clip)
        for (name, label) in [("face", "match a registered person's face"), ("clip", "match what the photo shows (CLIP text)")] {
            if name.starts_with(body) {
                out.push((format!("//{name} "), label.to_string()));
            }
        }
    } else if prev == "//face" || (prev.is_empty() && !frag.is_empty() && q[..start].trim().is_empty()) {
        // stage 2 after //face (or a bare word that could name a person)
        if !frag.is_empty() || prev == "//face" {
            for n in people {
                if n.to_lowercase().contains(&frag.to_lowercase()) {
                    out.push((format!("{n} "), "registered person".to_string()));
                }
            }
        }
    }
    (start, out)
}

fn apply(q: &str, start: usize, replacement: &str) -> String {
    format!("{}{}", &q[..start], replacement)
}

fn fetch_people() -> Vec<String> {
    ureq::get(&format!("{SERVER}/people"))
        .timeout(Duration::from_secs(3))
        .call()
        .ok()
        .and_then(|r| r.into_string().ok())
        .and_then(|b| serde_json::from_str::<PeopleReply>(&b).ok())
        .map(|p| p.people)
        .unwrap_or_default()
}

impl App {
    fn new(cc: &eframe::CreationContext<'_>) -> Self {
        let mut fonts = FontDefinitions::default();
        if let Ok(bytes) = std::fs::read(FONT) {
            fonts.font_data.insert("jbmono".into(), std::sync::Arc::new(FontData::from_owned(bytes)));
            for fam in [FontFamily::Proportional, FontFamily::Monospace] {
                fonts.families.entry(fam).or_default().insert(0, "jbmono".into());
            }
        }
        cc.egui_ctx.set_fonts(fonts);
        let (tx, rx) = channel();
        let mut app = Self {
            pal: load_palette(),
            query: String::new(),
            last_sent: "\u{0}".into(), // force the first browse request
            last_change: Instant::now() - Duration::from_secs(1),
            seq: 0,
            tx,
            rx,
            hits: Vec::new(),
            count: 0,
            selected: 0,
            status: "connecting to search server…".into(),
            busy: false,
            textures: HashMap::new(),
            missing: HashSet::new(),
            first_frame: true,
            close_now: false,
            people: Vec::new(),
            popup: false,
            cands: Vec::new(),
            cand_sel: 0,
        };
        app.people = fetch_people();
        app.send_query();
        app
    }

    fn send_query(&mut self) {
        self.seq += 1;
        let seq = self.seq;
        let q = self.query.trim().to_string();
        self.last_sent = self.query.clone();
        self.busy = true;
        let tx: Sender<Fetch> = self.tx.clone();
        std::thread::spawn(move || {
            let url = format!("{SERVER}/query");
            let r = ureq::get(&url)
                .query("q", &q)
                .query("top", &TOP.to_string())
                .timeout(Duration::from_secs(120))
                .call()
                .map_err(|e| format!("search server unreachable: {e}"))
                .and_then(|resp| resp.into_string().map_err(|e| e.to_string()))
                .and_then(|body| serde_json::from_str::<Reply>(&body).map_err(|e| e.to_string()));
            let _ = tx.send(Fetch { seq, query: q, result: r });
        });
    }

    fn drain(&mut self) {
        while let Ok(f) = self.rx.try_recv() {
            if f.seq != self.seq { continue; } // stale: a newer query was already sent
            self.busy = false;
            match f.result {
                Ok(r) => {
                    self.count = r.count;
                    self.hits = r.results;
                    self.selected = self.selected.min(self.hits.len().saturating_sub(1));
                    self.missing.clear();
                    self.status = if !r.errors.is_empty() {
                        r.errors.join("; ")
                    } else if f.query.is_empty() {
                        format!("newest {} photos", self.hits.len())
                    } else {
                        format!("{} matches", r.count)
                    };
                }
                Err(e) => self.status = e,
            }
        }
    }

    fn open_selected(&mut self) {
        let Some(h) = self.hits.get(self.selected).cloned() else { return };
        let name = h.remote.rsplit('/').next().unwrap_or("photo.jpg").to_string();
        let dst = format!("/tmp/images-open-{name}");
        // fetch the full photo in the background, then hand it to xdg-open
        std::thread::spawn(move || {
            let ok = std::process::Command::new("sh")
                .arg("-c")
                .arg(format!("rclone cat '{}' > '{}' && xdg-open '{}'", h.remote, dst, dst))
                .status()
                .map(|s| s.success())
                .unwrap_or(false);
            let _ = ok;
        });
        self.close_now = true;
    }

    fn accept_candidate(&mut self) {
        if let Some((rep, _)) = self.cands.get(self.cand_sel).cloned() {
            let (start, _) = completions(&self.query, &self.people);
            self.query = apply(&self.query, start, &rep);
            self.last_change = Instant::now() - Duration::from_millis(200);
        }
        self.popup = false;
    }

    fn texture(&mut self, ctx: &egui::Context, path: &str) -> Option<TextureHandle> {
        if let Some(t) = self.textures.get(path) { return Some(t.clone()); }
        if self.missing.contains(path) || !Path::new(path).exists() { return None; }
        let img = image::open(path).ok()?.to_rgb8();
        let (w, h) = img.dimensions();
        let ci = egui::ColorImage::from_rgb([w as usize, h as usize], img.as_raw());
        let tex = ctx.load_texture(path, ci, egui::TextureOptions::LINEAR);
        self.textures.insert(path.to_string(), tex.clone());
        Some(tex)
    }
}

fn short_name(remote: &str) -> String {
    // "gdrive-crypt:photos/2015-07_Phone/20150605_204906.jpg" -> "photos/2015-07_Phone/20150605_204906.jpg"
    remote.split_once(':').map(|(_, p)| p.trim_start_matches('/')).unwrap_or(remote).to_string()
}

impl eframe::App for App {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        let pal = self.pal;

        if self.close_now {
            ctx.send_viewport_cmd(egui::ViewportCommand::Close);
        }
        self.drain();

        // debounced live search: fire once typing pauses
        if self.query != self.last_sent && self.last_change.elapsed() >= Duration::from_millis(160) {
            self.send_query();
        }
        if self.first_frame {
            self.first_frame = false;
            ui.memory_mut(|m| m.request_focus(egui::Id::new("query")));
        }

        // completion keys: consumed before the text edit sees them (so Tab does not move focus)
        let tab = ui.input_mut(|i| i.consume_key(egui::Modifiers::NONE, Key::Tab));
        let ctrl_space = ui.input_mut(|i| i.consume_key(egui::Modifiers::CTRL, Key::Space));
        if (tab || ctrl_space) && !self.popup {
            let (start, cands) = completions(&self.query, &self.people);
            match cands.len() {
                0 => {}
                1 => {
                    self.query = apply(&self.query, start, &cands[0].0);
                    self.last_change = Instant::now();
                }
                _ => {
                    self.cands = cands;
                    self.cand_sel = 0;
                    self.popup = true;
                }
            }
        } else if tab && self.popup {
            self.accept_candidate();
        }
        if self.popup {
            // popup keys: Up/Down or Ctrl+J/K move, Enter accepts, Esc closes only the popup
            let (down, up, enter, esc, cj, ck) = ui.input(|i| {
                (
                    i.key_pressed(Key::ArrowDown),
                    i.key_pressed(Key::ArrowUp),
                    i.key_pressed(Key::Enter),
                    i.key_pressed(Key::Escape),
                    i.modifiers.ctrl && i.key_pressed(Key::J),
                    i.modifiers.ctrl && i.key_pressed(Key::K),
                )
            });
            let n = self.cands.len();
            if esc { self.popup = false; }
            else if enter { self.accept_candidate(); }
            else if n > 0 {
                if down || cj { self.cand_sel = (self.cand_sel + 1) % n; }
                if up || ck { self.cand_sel = (self.cand_sel + n - 1) % n; }
            }
        }
        // typing while the popup is open narrows it in place
        if self.popup && self.query != self.last_sent {
            let (_, cands) = completions(&self.query, &self.people);
            if cands.is_empty() { self.popup = false; } else { self.cands = cands; self.cand_sel = 0; }
        }

        // keys (only the ones the list owns; typing goes to the query box)
        let n = self.hits.len();
        let (down, up, pgdn, pgup, home, end, enter, esc, cj, ck) = ui.input(|i| {
            (
                i.key_pressed(Key::ArrowDown),
                i.key_pressed(Key::ArrowUp),
                i.key_pressed(Key::PageDown),
                i.key_pressed(Key::PageUp),
                i.key_pressed(Key::Home),
                i.key_pressed(Key::End),
                i.key_pressed(Key::Enter),
                i.key_pressed(Key::Escape),
                i.modifiers.ctrl && i.key_pressed(Key::J),
                i.modifiers.ctrl && i.key_pressed(Key::K),
            )
        });
        if esc && !self.popup { ctx.send_viewport_cmd(egui::ViewportCommand::Close); }
        if n > 0 && !self.popup {
            if down || cj { self.selected = (self.selected + 1).min(n - 1); }
            if up || ck { self.selected = self.selected.saturating_sub(1); }
            if pgdn { self.selected = (self.selected + 8).min(n - 1); }
            if pgup { self.selected = self.selected.saturating_sub(8); }
            if home { self.selected = 0; }
            if end { self.selected = n - 1; }
        }
        if enter && n > 0 && !self.popup { self.open_selected(); }

        egui::Frame::new()
            .fill(pal.bg)
            .stroke(Stroke::new(1.0, pal.border))
            .corner_radius(10.0)
            .inner_margin(Margin::same(12))
            .show(ui, |ui| {
                // search row
                egui::Frame::new()
                    .stroke(Stroke::new(1.0, pal.border))
                    .corner_radius(6.0)
                    .inner_margin(Margin::symmetric(10, 6))
                    .show(ui, |ui| {
                        ui.horizontal(|ui| {
                            ui.label(RichText::new("󰍉").color(pal.accent).size(16.0));
                            let edit = egui::TextEdit::singleline(&mut self.query)
                                .id(egui::Id::new("query"))
                                .frame(egui::Frame::NONE)
                                .hint_text(RichText::new("//face <name>   //clip brick   //face <name> //clip brick").color(pal.dim))
                                .text_color(pal.text)
                                .desired_width(f32::INFINITY)
                                .font(egui::TextStyle::Body);
                            let r = ui.add(edit);
                            if r.changed() { self.last_change = Instant::now(); }
                            // keep focus here even after a click elsewhere in the picker
                            if !r.has_focus() { r.request_focus(); }
                        });
                    });

                if self.popup && !self.cands.is_empty() {
                    ui.add_space(4.0);
                    egui::Frame::new()
                        .fill(pal.bg)
                        .stroke(Stroke::new(1.0, pal.accent.gamma_multiply(0.6)))
                        .corner_radius(6.0)
                        .inner_margin(Margin::symmetric(6, 4))
                        .show(ui, |ui| {
                            for (i, (rep, label)) in self.cands.iter().enumerate().take(8) {
                                let sel = i == self.cand_sel;
                                ui.horizontal(|ui| {
                                    ui.label(RichText::new(rep.trim_end()).monospace().color(if sel { pal.accent } else { pal.text }));
                                    ui.label(RichText::new(label).color(pal.dim).size(11.0));
                                });
                            }
                        });
                }
                ui.add_space(6.0);
                ui.label(RichText::new(&self.status).color(if self.busy { pal.dim } else { pal.dim }).size(12.0));
                ui.add_space(4.0);

                // results list
                if !self.hits.is_empty() {
                    let (hr, _) = ui.allocate_exact_size(egui::vec2(ui.available_width(), 18.0), egui::Sense::hover());
                    let c = cols(hr.left() + 52.0 + 22.0, hr.right());
                    let hp = ui.painter();
                    let hf = egui::FontId::monospace(10.0);
                    hp.text(egui::pos2(c.name_x, hr.top()), egui::Align2::LEFT_TOP, "NAME", hf.clone(), pal.dim);
                    hp.text(egui::pos2(c.path_x, hr.top()), egui::Align2::LEFT_TOP, "PATH", hf.clone(), pal.dim);
                    hp.text(egui::pos2(c.size_r, hr.top()), egui::Align2::RIGHT_TOP, "SIZE", hf.clone(), pal.dim);
                    hp.text(egui::pos2(c.date_x, hr.top()), egui::Align2::LEFT_TOP, "MODIFIED", hf.clone(), pal.dim);
                    hp.text(egui::pos2(c.score_r, hr.top()), egui::Align2::RIGHT_TOP, "SCORE", hf, pal.dim);
                }
                let hits = self.hits.clone();
                let sel = self.selected;
                let mut clicked: Option<usize> = None;
                let mut dbl = false;
                egui::ScrollArea::vertical()
                    .max_height(ui.available_height() - 28.0)
                    .auto_shrink([false, false])
                    .show(ui, |ui| {
                        for (idx, h) in hits.iter().enumerate() {
                            let (rect, resp) = ui.allocate_exact_size(
                                egui::vec2(ui.available_width(), ROW_H),
                                egui::Sense::click(),
                            );
                            let selected = idx == sel;
                            if selected {
                                ui.painter().rect_filled(rect, 6.0, pal.accent.gamma_multiply(0.18));
                                ui.painter().rect_filled(
                                    egui::Rect::from_min_size(rect.min, egui::vec2(3.0, rect.height())),
                                    1.0,
                                    pal.accent,
                                );
                            }
                            let thumb_rect = egui::Rect::from_min_size(
                                rect.min + egui::vec2(10.0, (ROW_H - THUMB) / 2.0),
                                egui::vec2(THUMB, THUMB),
                            );
                            match self.texture(&ctx, &h.thumb) {
                                Some(t) => {
                                    egui::Image::new(&t).fit_to_exact_size(thumb_rect.size())
                                        .paint_at(ui, thumb_rect);
                                }
                                None => {
                                    ui.painter().rect_filled(thumb_rect, 4.0, pal.border.gamma_multiply(0.5));
                                }
                            }
                            let c = cols(thumb_rect.right() + 12.0, rect.right());
                            let y = rect.top() + 12.0;
                            let short = short_name(&h.remote);
                            let (dir, base) = match short.rsplit_once('/') {
                                Some((d, b)) => (d.to_string(), b.to_string()),
                                None => (String::new(), short.clone()),
                            };
                            let txt = if selected { pal.text } else { pal.text.gamma_multiply(0.85) };
                            let dim = pal.dim;
                            let painter = ui.painter();
                            let name_clip = egui::Rect::from_min_max(egui::pos2(c.name_x, rect.top()), egui::pos2(c.name_x + NAME_W, rect.bottom()));
                            painter.with_clip_rect(name_clip).text(egui::pos2(c.name_x, y), egui::Align2::LEFT_TOP, base, egui::FontId::monospace(13.0), txt);
                            let path_clip = egui::Rect::from_min_max(egui::pos2(c.path_x, rect.top()), egui::pos2(c.path_r, rect.bottom()));
                            painter.with_clip_rect(path_clip).text(egui::pos2(c.path_x, y + 2.0), egui::Align2::LEFT_TOP, dir, egui::FontId::monospace(11.0), dim);
                            if let Some(sz) = h.size {
                                painter.text(egui::pos2(c.size_r, y), egui::Align2::RIGHT_TOP, human_size(sz), egui::FontId::monospace(11.0), dim);
                            }
                            if let Some(t) = &h.mtime {
                                painter.text(egui::pos2(c.date_x, y), egui::Align2::LEFT_TOP, short_time(t), egui::FontId::monospace(11.0), dim);
                            }
                            if let Some(s) = h.score {
                                painter.text(egui::pos2(c.score_r, y), egui::Align2::RIGHT_TOP, format!("{s:.2}"), egui::FontId::monospace(12.0), pal.accent);
                            }
                            if selected {
                                ui.scroll_to_rect(rect, Some(egui::Align::Center));
                            }
                            if resp.clicked() { clicked = Some(idx); }
                            if resp.double_clicked() { dbl = true; clicked = Some(idx); }
                        }
                        if hits.is_empty() && !self.busy {
                            ui.add_space(20.0);
                            ui.label(RichText::new("no matches").color(pal.dim));
                        }
                    });
                if let Some(i) = clicked { self.selected = i; }
                if dbl { self.open_selected(); }

                ui.add_space(4.0);
                ui.label(
                    RichText::new(format!("{} shown · ↑↓ / ^j^k move · PgUp/PgDn · Home/End · ⏎ open · esc close", self.hits.len()))
                        .color(pal.dim).size(11.0),
                );
            });

        // keep polling so thumbnails and results appear without input
        ctx.request_repaint_after(Duration::from_millis(120));
    }
}

fn main() -> eframe::Result {
    let opts = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("images")
            .with_inner_size([760.0, 620.0])
            .with_decorations(false)
            .with_transparent(true)
            .with_always_on_top(),
        ..Default::default()
    };
    eframe::run_native("images", opts, Box::new(|cc| Ok(Box::new(App::new(cc)))))
}
