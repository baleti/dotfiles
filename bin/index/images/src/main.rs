//! images: live photo search picker (mod+v-style list) over the CLIP + face
//! indexes. The query engine runs in ~/.cache/indexes/photos/search_server.py
//! (127.0.0.1:8765, keeps models loaded); this window is only the UI.
//!
//! Opens on the newest photos. Typing narrows the list as you type (debounced).
//! Syntax: /face <name>   /clip brick   /face <name> /clip brick   or bare words.
//! Keys: type to search, Up/Down or Ctrl+j/k move, PgUp/PgDn jump, Enter opens
//! (photo is fetched from gdrive to /tmp and opened), Esc closes.

use eframe::egui::{self, Color32, FontData, FontDefinitions, FontFamily, Key, Margin, RichText, Stroke, TextureHandle};
use serde::Deserialize;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::time::{Duration, Instant};

/// Read from ~/.config/indexes/photos.json (IMAGES_CONFIG overrides), so no paths are compiled in.
struct Cfg { server: String, python: String, scheme: String, mount_root: String, data_dir: String }
fn cfg() -> &'static Cfg {
    static C: std::sync::OnceLock<Cfg> = std::sync::OnceLock::new();
    C.get_or_init(load_cfg)
}

fn load_cfg() -> Cfg {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/".into());
    let path = std::env::var("IMAGES_CONFIG").unwrap_or(format!("{home}/.config/indexes/photos.json"));
    let v: serde_json::Value = std::fs::read_to_string(&path).ok()
        .and_then(|t| serde_json::from_str(&t).ok()).unwrap_or(serde_json::Value::Null);
    let expand = |k: &str| {
        v.get(k).and_then(|x| x.as_str()).unwrap_or("")
            .replace("~", &home)
    };
    let port = v.pointer("/server/port").and_then(|x| x.as_u64()).unwrap_or(8765);
    let host = v.pointer("/server/host").and_then(|x| x.as_str()).unwrap_or("127.0.0.1").to_string();
    Cfg {
        server: format!("http://{host}:{port}"),
        python: expand("python"),
        scheme: expand("scheme_file"),
        mount_root: expand("mount_root"),
        data_dir: expand("data_dir"),
    }
}
const FONT_BOLD: &str = "/usr/share/fonts/TTF/JetBrainsMono-Bold.ttf";
const FONT: &str = "/usr/share/fonts/TTF/JetBrainsMono-Regular.ttf";
/// rows fetched per request; the list only asks for the pages that are on screen
const PAGE: usize = 200;
const GRID_ZOOM: f32 = 220.0;

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

/// 1997930 -> "1,997,930"
fn group_digits(n: usize) -> String {
    let d = n.to_string();
    let mut out = String::new();
    for (i, c) in d.chars().enumerate() {
        if i > 0 && (d.len() - i) % 3 == 0 { out.push(','); }
        out.push(c);
    }
    out
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


/// A local, regular file the picker may trash: under $HOME, outside the gdrive mount,
/// not a directory, not a symlink. Remote results (gdrive-crypt:...) are never eligible.
fn trashable(remote: &str) -> Option<(PathBuf, u64)> {
    if !remote.starts_with('/') { return None; }
    let home = PathBuf::from(std::env::var("HOME").ok()?);
    let p = PathBuf::from(remote);
    if !p.starts_with(&home) { return None; }
    if p.starts_with(PathBuf::from(&cfg().mount_root)) { return None; }
    let md = std::fs::symlink_metadata(&p).ok()?;
    if !md.is_file() { return None; }
    Some((p, md.len()))
}

fn human(b: u64) -> String { human_size(b) }


fn sort_path() -> PathBuf {
    PathBuf::from(&cfg().data_dir).join("search-files-sort.json")
}

/// Column proportions from the last session (defaults when missing or invalid).
fn load_cols() -> [f32; 5] {
    let v: serde_json::Value = std::fs::read_to_string(sort_path()).ok()
        .and_then(|t| serde_json::from_str(&t).ok()).unwrap_or(serde_json::Value::Null);
    let mut out = DEFAULT_COLS;
    if let Some(arr) = v.get("cols").and_then(|x| x.as_array()) {
        if arr.len() == 5 {
            let vals: Vec<f32> = arr.iter().filter_map(|x| x.as_f64().map(|f| f as f32)).collect();
            let sum: f32 = vals.iter().sum();
            if vals.len() == 5 && sum > 0.0 && vals.iter().all(|v| *v >= MIN_FRAC * 0.5) {
                for i in 0..5 { out[i] = vals[i] / sum; }
            }
        }
    }
    out
}

/// Search-box history file (one query per line), in the picker's data directory.
fn history_path() -> PathBuf {
    PathBuf::from(&cfg().data_dir).join("search-files-history.txt")
}

fn load_history() -> Vec<String> {
    std::fs::read_to_string(history_path())
        .map(|t| t.lines().map(|l| l.to_string()).filter(|l| !l.is_empty()).collect())
        .unwrap_or_default()
}

/// Collapse whitespace runs to single spaces (shell HIST_REDUCE_BLANKS).
fn normalize_query(q: &str) -> String {
    tokenize(q).join(" ")
}

/// Case-insensitive subsequence match (fzf-style fuzzy filter for the history popup).
fn fuzzy_match(hay: &str, needle: &str) -> bool {
    let mut it = hay.chars().flat_map(|c| c.to_lowercase());
    needle.chars().flat_map(|c| c.to_lowercase()).all(|n| it.any(|h| h == n))
}

/// Shortens `text` to fit `width` px in `font`, ending with an ellipsis when it had to be cut.
/// Plain words of a query (tags and the value after a tag are skipped), lowercased for matching.
/// Splits on whitespace, except inside double quotes (even mid-token, as in `name:"a b"`): a quoted
/// run is one entry. Quotes stay in the token; an unterminated quote runs to the end.
fn tokenize(q: &str) -> Vec<String> {
    let (mut out, mut cur, mut inq) = (Vec::new(), String::new(), false);
    for ch in q.chars() {
        if ch == '"' { inq = !inq; cur.push(ch); }
        else if ch.is_whitespace() && !inq {
            if !cur.is_empty() { out.push(std::mem::take(&mut cur)); }
        } else { cur.push(ch); }
    }
    if !cur.is_empty() { out.push(cur); }
    out
}

fn query_terms(q: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut skip_value = false;
    for tok in tokenize(q) {
        let tok = tok.as_str();
        if tok == "/fts" || tok == "/full-text-search" { continue; }
        // a negated term ("!word", "!//tag value") is something the results must NOT have: nothing to highlight
        if let Some(neg) = tok.strip_prefix('!') {
            if neg.starts_with("//") || neg == "/clip" || neg == "/face" { skip_value = true; }
            continue;
        }
        if tok == "/clip" || tok == "/face" || tok.starts_with("//") { skip_value = true; continue; }
        if skip_value { skip_value = false; continue; }
        let t = tok.replace('"', "").to_ascii_lowercase();
        if !t.is_empty() { out.push(t); }
    }
    out
}

/// The text with every case-insensitive occurrence of a term drawn on a highlight background.
fn name_job(text: &str, terms: &[String], font: &egui::FontId, color: Color32) -> egui::text::LayoutJob {
    let lower = text.to_ascii_lowercase();
    let mut ranges: Vec<(usize, usize)> = Vec::new();
    for t in terms.iter().filter(|t| !t.is_empty()) {
        let mut from = 0;
        while let Some(i) = lower[from..].find(t.as_str()) {
            let s = from + i;
            ranges.push((s, s + t.len()));
            from = s + t.len();
        }
    }
    ranges.sort();
    let mut merged: Vec<(usize, usize)> = Vec::new();
    for (s, e) in ranges {
        match merged.last_mut() {
            Some(last) if s <= last.1 => last.1 = last.1.max(e),
            _ => merged.push((s, e)),
        }
    }
    let mut job = egui::text::LayoutJob::default();
    let plain = egui::TextFormat::simple(font.clone(), color);
    // matched parts use the bold face (same advance width, so columns stay aligned)
    let hl = egui::TextFormat::simple(egui::FontId::new(font.size, FontFamily::Name("bold".into())), color);
    let mut pos = 0;
    for (s, e) in merged {
        job.append(&text[pos..s], 0.0, plain.clone());
        job.append(&text[s..e], 0.0, hl.clone());
        pos = e;
    }
    job.append(&text[pos..], 0.0, plain);
    job
}

fn fit_text(ui: &egui::Ui, text: &str, font: &egui::FontId, width: f32) -> String {
    let measure = |t: &str| ui.painter().layout_no_wrap(t.to_string(), font.clone(), egui::Color32::WHITE).size().x;
    if measure(text) <= width {
        return text.to_string();
    }
    let chars: Vec<char> = text.chars().collect();
    // binary search for the longest prefix that still fits with the ellipsis
    let (mut lo, mut hi) = (0usize, chars.len());
    while lo < hi {
        let mid = (lo + hi + 1) / 2;
        let cand: String = chars[..mid].iter().collect::<String>() + "…";
        if measure(&cand) <= width { lo = mid; } else { hi = mid - 1; }
    }
    chars[..lo].iter().collect::<String>() + "…"
}

/// Counts and consumes every queued press of `key` with `mods` this frame (repeats included).
fn take_count(ui: &mut egui::Ui, mods: egui::Modifiers, key: Key) -> usize {
    let mut c = 0;
    while c < 500 && ui.input_mut(|i| i.consume_key(mods, key)) {
        c += 1;
    }
    c
}

/// True when the query text field has a non-empty selection (then Ctrl+C/X belong to the text).
fn query_has_selection(ctx: &egui::Context) -> bool {
    egui::TextEdit::load_state(ctx, egui::Id::new("query"))
        .and_then(|st| st.cursor.char_range())
        .map(|r| r.primary.index != r.secondary.index)
        .unwrap_or(false)
}

/// Local path for a result: local rows are already paths; remote rows map through the gdrive mount.
fn local_path(remote: &str) -> PathBuf {
    if remote.starts_with('/') {
        PathBuf::from(remote)
    } else {
        PathBuf::from(format!("{}/{}", cfg().mount_root, short_name(remote)))
    }
}

/// Handlers for a mime type, from `gio mime`: (desktop id, display name).
fn handlers_for(mime: &str) -> Vec<(String, String)> {
    let out = std::process::Command::new("gio").arg("mime").arg(mime).output();
    let Ok(out) = out else { return Vec::new() };
    let mut v = Vec::new();
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        let t = line.trim();
        if let Some(id) = t.strip_suffix(".desktop") {
            let id = format!("{id}.desktop");
            let name = desktop_name(&id).unwrap_or_else(|| id.clone());
            if !v.iter().any(|(i, _): &(String, String)| i == &id) {
                v.push((id, name));
            }
        }
    }
    v
}

fn desktop_name(id: &str) -> Option<String> {
    for dir in ["/usr/share/applications", &format!("{}/.local/share/applications", std::env::var("HOME").unwrap_or_default())] {
        if let Ok(t) = std::fs::read_to_string(format!("{dir}/{id}")) {
            for line in t.lines() {
                if let Some(n) = line.strip_prefix("Name=") {
                    return Some(n.to_string());
                }
            }
        }
    }
    None
}

fn mime_of(path: &Path) -> String {
    std::process::Command::new("file").arg("--mime-type").arg("-b").arg(path).output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_else(|_| "application/octet-stream".into())
}

/// file:// URI for a local path (percent-encoding the characters that matter).
fn file_uri(p: &Path) -> String {
    let mut out = String::from("file://");
    for b in p.to_string_lossy().bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'/' | b'-' | b'_' | b'.' | b'~' => out.push(b as char),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// Put file URIs on the Wayland clipboard so a file manager can paste them.
fn clipboard_files(paths: &[PathBuf], cut: bool) {
    let uris: Vec<String> = paths.iter().map(|p| file_uri(p)).collect();
    let gnome = format!("{}\n{}", if cut { "cut" } else { "copy" }, uris.join("\n"));
    for (mime, body) in [
        ("x-special/gnome-copied-files", gnome),
        ("text/uri-list", uris.join("\r\n") + "\r\n"),
    ] {
        if let Ok(mut child) = std::process::Command::new("wl-copy").arg("--type").arg(mime)
            .stdin(std::process::Stdio::piped()).spawn()
        {
            if let Some(mut stdin) = child.stdin.take() {
                use std::io::Write;
                let _ = stdin.write_all(body.as_bytes());
            }
            let _ = child.wait();
        }
    }
}

/// Column x-positions for a row/header spanning [left, right]: name | path | size | modified | score.
/// Column x-positions for a row/header spanning [left, right]: name | path | size | modified | score.
/// `f` holds each column's share of the width (sums to 1), so the columns scale with the window.
struct Cols { name_x: f32, path_x: f32, path_r: f32, size_r: f32, date_x: f32, score_r: f32, right: f32 }
const MIN_FRAC: f32 = 0.04;
const DEFAULT_COLS: [f32; 5] = [0.30, 0.40, 0.10, 0.14, 0.06];
fn cols(left: f32, right: f32, f: &[f32; 5]) -> Cols {
    let w = (right - left).max(1.0);
    let x1 = left + f[0] * w;
    let x2 = x1 + f[1] * w;
    let x3 = x2 + f[2] * w;
    let x4 = x3 + f[3] * w;
    Cols { name_x: left, path_x: x1, path_r: x2, size_r: x2, date_x: x3, score_r: x4, right }
}

/// Totals over every match, computed by the server.
#[derive(Deserialize, Clone, Default)]
struct Stats {
    size: u64,
    #[serde(default)]
    dmin: Option<String>,
    #[serde(default)]
    dmax: Option<String>,
    #[serde(default)]
    kinds: Vec<(String, usize)>,
}

#[derive(Deserialize)]
struct Reply {
    #[serde(default)]
    stats: Option<Stats>,
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

fn load_palette(scheme: &str) -> Palette {
    let fallback = Palette {
        bg: Color32::from_rgb(0x1a, 0x1a, 0x1a),
        text: Color32::from_rgb(0xd8, 0xde, 0xe9),
        dim: Color32::from_rgb(0xa0, 0xa8, 0xb0),
        border: Color32::from_rgb(0x59, 0x59, 0x59),
        accent: Color32::from_rgb(0x33, 0xcc, 0xff),
        error: Color32::from_rgb(0xff, 0x55, 0x55),
    };
    let Ok(text) = std::fs::read_to_string(scheme) else { return fallback };
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

/// One page of results for a query, sorted on the server.
fn fetch_page(q: &str, sort: &str, desc: bool, page: usize) -> Result<Reply, String> {
    let url = format!("{}/query", cfg().server);
    ureq::get(&url)
        .query("q", q)
        .query("sort", sort)
        .query("desc", if desc { "1" } else { "0" })
        .query("offset", &(page * PAGE).to_string())
        .query("top", &PAGE.to_string())
        .timeout(Duration::from_secs(120))
        .call()
        .map_err(|e| format!("search server unreachable: {e}"))
        .and_then(|resp| resp.into_string().map_err(|e| e.to_string()))
        .and_then(|body| serde_json::from_str::<Reply>(&body).map_err(|e| e.to_string()))
}

/// background query results come back tagged with the request sequence number
/// One Recoll snippet of a file: page (when the format has pages), text, and match byte ranges.
#[derive(Deserialize, Clone)]
struct Snip {
    page: Option<i64>,
    text: String,
    ranges: Vec<(usize, usize)>,
}
#[derive(Deserialize)]
struct SnipReply {
    #[serde(default)]
    snippets: Vec<Snip>,
    #[serde(default)]
    error: Option<String>,
}
enum SnipState { Loading, Done(Vec<Snip>), Failed(String) }

fn fetch_snippets(remote: &str, q: &str) -> Result<Vec<Snip>, String> {
    let url = format!("{}/snippets", cfg().server);
    let r = ureq::get(&url).query("remote", remote).query("q", q)
        .timeout(Duration::from_secs(60)).call()
        .map_err(|e| format!("search server unreachable: {e}"))
        .and_then(|resp| resp.into_string().map_err(|e| e.to_string()))
        .and_then(|body| serde_json::from_str::<SnipReply>(&body).map_err(|e| e.to_string()))?;
    match r.error { Some(e) => Err(e), None => Ok(r.snippets) }
}

/// True for a `/fts` (full-text search) query: those results get a snippet preview pane.
fn is_fts(q: &str) -> bool {
    ["/fts", "/full-text-search"].iter().any(|v| {
        q.strip_prefix(v).map_or(false, |r| r.is_empty() || r.starts_with('/') || r.starts_with(char::is_whitespace))
    })
}

struct Fetch {
    seq: u64,
    page: usize,
    query: String,
    result: Result<Reply, String>,
}

struct App {
    pal: Palette,
    query: String,
    last_sent: String,
    last_change: Instant,
    cursor_end: bool,
    seq: u64,
    snip_tx: Sender<(String, String, Result<Vec<Snip>, String>)>,
    snip_rx: Receiver<(String, String, Result<Vec<Snip>, String>)>,
    /// preview pane: snippets per (file, query)
    snips: HashMap<(String, String), SnipState>,
    tx: Sender<Fetch>,
    /// sharp PDF first pages: remotes wanted (sent from the grid), and finished (remote, thumb path)
    hq_map: HashMap<String, String>,
    hq_asked: HashMap<String, Instant>,
    /// columns in the thumbnail grid as laid out last frame (arrow keys move by this many)
    grid_cols: usize,
    hq_tx: Sender<String>,
    hq_rx: Receiver<(String, String)>,
    rx: Receiver<Fetch>,
    /// total matches for the current query and the pages fetched so far (page index -> rows)
    total: usize,
    pages: HashMap<usize, Vec<Hit>>,
    pending: HashSet<usize>,
    req_q: String,
    req_sort: String,
    req_desc: bool,
    selected: usize,
    /// multi-selection: rows between `anchor` and `selected` (inclusive) are selected
    anchor: Option<usize>,
    /// delete confirmation: the exact local files that would be trashed, and the typed confirmation
    trash_pending: Option<Vec<(PathBuf, u64)>>,
    trash_typed: String,
    /// context menu: where it is shown and which hit it was opened for
    menu_at: Option<egui::Pos2>,
    menu_hit: Option<usize>,
    /// last drawn rectangle per hit (list view), used to place the menu for F10
    row_rects: HashMap<usize, egui::Rect>,
    menu_fresh: bool,
    /// search history (oldest first), persisted to the data dir, one query per line
    history: Vec<String>,
    /// Ctrl+R / F4 popup: open flag, highlighted row, and the query text last recorded
    hist_popup: bool,
    hist_sel: usize,
    last_recorded: String,
    /// mime type of the hit the menu / properties were opened for (computed once, on open)
    menu_mime: Option<String>,
    props_mime: String,
    /// true while keyboard focus is in the result list (query box is not auto-focused then)
    list_focus: bool,
    /// properties dialog for one hit
    props: Option<usize>,
    /// cached "Open with" handlers per mime type
    handlers: HashMap<String, Vec<(String, String)>>,
    status: String,
    busy: bool,
    textures: HashMap<String, TextureHandle>,
    missing: HashSet<String>,
    first_frame: bool,
    close_now: bool,
    people: Vec<String>,
    /// year-months present in the index (for //dm completion) and file kinds (for //mime)
    facets: FacetsReply,
    /// column widths as fractions of the row (drag the header boundaries to change)
    col_frac: [f32; 5],
    /// thumbnail size in px; Ctrl+wheel / pinch changes it; at GRID_ZOOM and above the results show as a grid
    thumb: f32,
    /// height of the results viewport last frame; sets how far PgUp/PgDn move
    results_h: f32,
    /// set by keyboard movement; the views scroll the cursor into sight once, then clear it
    scroll_pending: bool,
    /// totals for the status bar (size, dates, file types) from the page-0 reply
    stats: Option<Stats>,
    /// Ctrl+J/K/H/L chord currently held (its auto-repeats may lose the Ctrl modifier)
    chord_key: Option<Key>,
    /// grid scroll offset after the last frame (for keeping the grid still while the selection moves)
    grid_off: f32,
    popup: bool,
    /// /face pane: indexed faces as crops to pick from (no names involved)
    face_pane: Option<FacePane>,
    /// //path pane: folders matching the fragment being typed, listed virtually
    path_pane: Option<PathPane>,
    cands: Vec<(String, String)>, // (replacement text, label)
    cand_sel: usize,
    /// query text as of the last frame, so the popup only re-narrows when it really changed
    popup_q: String,
}

#[derive(Deserialize)]
struct PeopleReply {
    people: Vec<String>,
    /// year-months present in the index (for //dm completion) and file kinds (for //mime)
    facets: FacetsReply,
}

/// Completion candidates for the fragment at the end of `q`.
/// Returns (byte index where the fragment starts, candidates).
fn completions(q: &str, facets: &FacetsReply, history: &[String]) -> (usize, Vec<(String, String)>) {
    let start = q.rfind(char::is_whitespace).map(|i| i + q[i..].chars().next().unwrap().len_utf8()).unwrap_or(0);
    // a leading "!" negates the term being typed (query-dsl.md "Negation"): complete what follows it
    let start = if q[start..].starts_with('!') { start + 1 } else { start };
    let frag = &q[start..];
    let prev = q[..start].split_whitespace().last().unwrap_or("");
    let prev = prev.strip_prefix('!').unwrap_or(prev);
    let mut out = Vec::new();
    // values for a tag that takes one: (value, label)
    let values_for = |tag: &str| -> Vec<(String, String)> {
        match tag {
            "dm" => facets.dates.iter().map(|d| (d.clone(), "modified in this month".to_string())).collect(),
            "mime" => facets.mimes.iter().map(|m| (m.clone(), "file kind".to_string())).collect(),
            "size" => vec![
                ("<100K".into(), "smaller than 100 KiB".into()),
                (">100K".into(), "larger than 100 KiB".into()),
                (">1M".into(), "larger than 1 MiB".into()),
                (">10M".into(), "larger than 10 MiB".into()),
                (">100M".into(), "larger than 100 MiB".into()),
            ],
            _ => Vec::new(),
        }
    };
    const TAGS: [(&str, &str); 6] = [
        ("name", "file name contains"),
        ("path", "folder path contains"),
        ("size", "file size, e.g. >5M or <200K"),
        ("dm", "date modified, pick a month"),
        ("mime", "file kind: image, pdf, text, code, ..."),
        ("file", "file-name search mode"),
    ];
    if frag.starts_with('/') && !frag.starts_with("//") && !frag.contains(' ') && !prev.starts_with("//") {
        // a lone "/" lists every verb
        const VERBS: [(&str, &str); 5] = [
            ("/fts ", "full-text search over every content index: /fts dgcl design //mime pdf"),
            ("/clip ", "photos matching what they show (CLIP text): /clip brick"),
            ("/face ", "photos showing a registered person: /face daniel"),
            ("/sort ", "order the results by a field, e.g. /s size desc"),
            ("/reverse ", "flip the order"),
        ];
        for (v, label) in VERBS {
            if v.starts_with(frag) || (frag.len() >= 2 && "/s".starts_with(frag) && v == "/sort ") {
                out.push((v.to_string(), label.to_string()));
            }
        }
    }
    if matches!(prev, "/s" | "/sort") && !frag.starts_with('/') {
        // the field after /s, or a direction once a field is there
        let f = frag.to_lowercase();
        for (name, _) in SORT_FIELDS.iter() {
            if name.contains(f.as_str()) { out.push((format!("{name} "), "sort field".to_string())); }
        }
        return (start, out);
    } else if let Some(body) = frag.strip_prefix("//") {
        // exact tag with a value list: offer the values right away
        if let Some((tag, _)) = TAGS.iter().find(|(t, _)| *t == body) {
            let vals = values_for(tag);
            if !vals.is_empty() {
                for (v, label) in vals {
                    out.push((format!("//{tag} {v} "), label));
                }
                return (start, out);
            }
        }
        // stage 1: the tag name
        for (name, label) in TAGS.iter() {
            if name.starts_with(body) {
                out.push((format!("//{name} "), label.to_string()));
            }
        }
    } else if let Some(tag) = prev.strip_prefix("//").filter(|t| !values_for(t).is_empty()) {
        // stage 2: the value after a tag (substring filter on what the user typed)
        let f = frag.to_lowercase();
        for (v, label) in values_for(tag) {
            if v.to_lowercase().contains(&f) {
                out.push((format!("{v} "), label));
            }
        }
    } else if prev == "/clip" {
        // the text after /clip: earlier photo searches, newest first
        let f = frag.to_lowercase();
        let mut seen = std::collections::HashSet::new();
        for h in history.iter().rev() {
            if let Some(t) = h.trim().strip_prefix("/clip ") {
                let t = t.trim();
                if !t.is_empty() && t.to_lowercase().contains(&f) && seen.insert(t.to_string()) {
                    out.push((format!("{t} "), "earlier /clip search".to_string()));
                }
            }
        }
    }
    (start, out)
}

struct FacePane {
    items: Vec<(String, String)>,
    sel: usize,
    cols: usize,
    scroll_pending: bool,
    prefix: String,
    loading: bool,
    rx: Receiver<Vec<(String, String)>>,
}

fn fetch_faces(seed: u64) -> Vec<(String, String)> {
    let url = format!("{}/faces/pane?n=120&seed={seed}", cfg().server);
    ureq::get(&url)
        .timeout(Duration::from_secs(300))
        .call()
        .ok()
        .and_then(|r| r.into_string().ok())
        .and_then(|b| serde_json::from_str::<serde_json::Value>(&b).ok())
        .and_then(|v| v["faces"].as_array().cloned())
        .map(|fs| fs.iter().filter_map(|f| Some((f["id"].as_str()?.to_string(), f["thumb"].as_str()?.to_string()))).collect())
        .unwrap_or_default()
}

const PATH_PAGE: usize = 200;

struct PathPane {
    start: usize,
    frag: String,
    total: usize,
    pages: HashMap<usize, Vec<String>>,
    pending: HashSet<usize>,
    sel: usize,
    tx: Sender<PathPage>,
    rx: Receiver<PathPage>,
}

struct PathPage {
    frag: String,
    page: usize,
    total: usize,
    items: Vec<String>,
}

/// The //path fragment at the end of the query, and where it starts.
fn path_fragment(q: &str) -> Option<(usize, String)> {
    let idx = q.rfind("//path")?;
    let after = &q[idx + 6..];
    if !after.is_empty() && !after.starts_with(char::is_whitespace) {
        return None;
    }
    let start = idx + 6 + (after.len() - after.trim_start().len());
    let frag = &q[start..];
    if frag.contains("//") || frag.contains(char::is_whitespace) {
        return None;
    }
    Some((start, frag.to_string()))
}

fn request_path_page(p: &mut PathPane, page: usize) {
    if !p.pending.insert(page) {
        return;
    }
    let (tx, frag) = (p.tx.clone(), p.frag.clone());
    std::thread::spawn(move || {
        let (total, items) = ureq::get(&format!("{}/paths", cfg().server))
            .query("q", frag.trim_matches('"'))
            .query("offset", &(page * PATH_PAGE).to_string())
            .query("top", &PATH_PAGE.to_string())
            .timeout(Duration::from_secs(60))
            .call()
            .ok()
            .and_then(|r| r.into_string().ok())
            .and_then(|b| serde_json::from_str::<serde_json::Value>(&b).ok())
            .map(|v| {
                let items = v["items"].as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
                (v["total"].as_u64().unwrap_or(0) as usize, items)
            })
            .unwrap_or((0, Vec::new()));
        let _ = tx.send(PathPage { frag, page, total, items });
    });
}

/// Sortable fields: (name typed in `/s`, server key). The first four are the visible columns.
const SORT_FIELDS: [(&str, &str); 6] = [
    ("name", "name"), ("path", "path"), ("size", "size"), ("date-modified", "date"),
    ("extension", "ext"), ("depth", "depth"),
];

struct SortSpec {
    /// server keys, primary first; empty when the query has no /s (default: newest first)
    keys: Vec<String>,
    desc: bool,
    explicit: bool,
}

/// A `/s` path segment -> server key: exact name or alias first, else a unique substring.
fn resolve_sort_field(seg: &str) -> Option<&'static str> {
    let seg = seg.to_lowercase();
    if seg.is_empty() { return None; }
    if seg == "dm" || seg == "date" { return Some("date"); }
    if let Some(f) = SORT_FIELDS.iter().find(|f| f.0 == seg) { return Some(f.1); }
    let hits: Vec<_> = SORT_FIELDS.iter().filter(|f| f.0.contains(seg.as_str())).collect();
    if hits.len() == 1 { Some(hits[0].1) } else { None }
}

/// Direction word: only taken when it matches exactly one of ascending / descending.
fn sort_direction(tok: &str) -> Option<bool> {
    let t = tok.to_lowercase();
    if t.is_empty() { return None; }
    match ("ascending".contains(t.as_str()), "descending".contains(t.as_str())) {
        (true, false) => Some(false),
        (false, true) => Some(true),
        _ => None,
    }
}

/// Splits `/s`, `/sort` and `/rv` commands out of the query. Returns the rest (what the server
/// sees) and the requested order. Each `/s` adds keys (`/s a /s b` == `/s/a/b`: a, then b on ties);
/// a segment that resolves to nothing makes that whole `/s` inert. One direction for every key.
fn parse_sort(q: &str) -> (String, SortSpec) {
    let owned = tokenize(q);
    let toks: Vec<&str> = owned.iter().map(String::as_str).collect();
    let mut rest: Vec<&str> = Vec::new();
    let mut keys: Vec<String> = Vec::new();
    let mut desc = None;
    let mut reverse = false;
    let mut explicit = false;
    let mut i = 0;
    while i < toks.len() {
        let t = toks[i];
        i += 1;
        if t == "/rv" || t == "/reverse" { reverse = true; continue; }
        // a `//tag` owns the next token as its value, whatever it looks like (`//path /etc`, `//path /sort`)
        if t.starts_with("//") || t.starts_with("!//") {
            rest.push(t);
            if i < toks.len() { rest.push(toks[i]); i += 1; }
            continue;
        }
        let chain = if let Some(c) = t.strip_prefix("/sort") { c } else if let Some(c) = t.strip_prefix("/s") { c } else { rest.push(t); continue };
        let mut path = if chain.is_empty() { None } else if let Some(c) = chain.strip_prefix('/') { Some(c) } else { rest.push(t); continue };
        // direction may come before the field (`/s desc name`) or after it (`/s name desc`)
        let mut dir_first = None;
        if path.is_none() && i < toks.len() && !toks[i].starts_with('/') {
            if resolve_sort_field(toks[i]).is_none() {
                if let Some(d) = sort_direction(toks[i]) {
                    dir_first = Some(d);
                    i += 1;
                }
            }
            if i < toks.len() && !toks[i].starts_with('/') { path = Some(toks[i]); i += 1; }
        }
        let segs: Vec<Option<&str>> = path.map(|p| p.split('/').map(resolve_sort_field).collect()).unwrap_or_default();
        let mut dir = dir_first;
        if let Some(d) = toks.get(i).and_then(|d| sort_direction(d)) { i += 1; dir = Some(d); }
        if !segs.is_empty() && segs.iter().all(Option::is_some) {
            if dir.is_some() { desc = dir; }
            explicit = true;
            for k in segs.into_iter().flatten() {
                if !keys.iter().any(|x| x == k) { keys.push(k.to_string()); }
            }
        }
    }
    let mut desc_v = if keys.is_empty() { true } else { desc.unwrap_or(false) };
    if keys.is_empty() { keys.push("date".into()); }
    if reverse { desc_v = !desc_v; }
    (rest.join(" "), SortSpec { keys, desc: desc_v, explicit: explicit || reverse })
}

fn fts_subsequence(frag: &str, name: &str) -> bool {
    let mut it = name.chars();
    frag.chars().all(|c| it.any(|n| n == c))
}

fn apply(q: &str, start: usize, replacement: &str) -> String {
    format!("{}{}", &q[..start], replacement)
}

#[derive(Deserialize, Default)]
struct FacetsReply {
    #[serde(default)]
    dates: Vec<String>,
    #[serde(default)]
    mimes: Vec<String>,
    #[serde(default)]
    fts: Vec<String>,
}

fn fetch_facets() -> FacetsReply {
    ureq::get(&format!("{}/facets", cfg().server))
        .timeout(Duration::from_secs(5))
        .call()
        .ok()
        .and_then(|r| r.into_string().ok())
        .and_then(|b| serde_json::from_str::<FacetsReply>(&b).ok())
        .unwrap_or_default()
}

fn fetch_people() -> Vec<String> {
    ureq::get(&format!("{}/people", cfg().server))
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
        let bold = std::fs::read(FONT_BOLD).ok().map(|b| FontData::from_owned(b)).map(std::sync::Arc::new);
        // without the bold file the matches simply render in the regular face
        let mut bold_chain = fonts.families.get(&FontFamily::Monospace).cloned().unwrap_or_default();
        if let Some(b) = bold {
            fonts.font_data.insert("jbmono-bold".into(), b);
            bold_chain.insert(0, "jbmono-bold".to_string()); // regular chain stays behind it for fallback glyphs
        }
        fonts.families.insert(FontFamily::Name("bold".into()), bold_chain);
        cc.egui_ctx.set_fonts(fonts);
        let (tx, rx) = channel();
        let (hq_tx, hq_req) = channel::<String>();
        let (hq_done_tx, hq_rx) = channel::<(String, String)>();
        // one request per message; the server renders in the background and reports when the file is ready
        std::thread::spawn(move || {
            while let Ok(remote) = hq_req.recv() {
                let url = format!("{}/thumb_hq", cfg().server);
                let ready = ureq::get(&url).query("remote", &remote).timeout(Duration::from_secs(20)).call().ok()
                    .and_then(|r| r.into_string().ok())
                    .and_then(|b| serde_json::from_str::<serde_json::Value>(&b).ok())
                    .and_then(|v| if v["ready"].as_bool() == Some(true) { v["thumb"].as_str().map(String::from) } else { None });
                if let Some(path) = ready {
                    let _ = hq_done_tx.send((remote, path));
                }
            }
        });
        let (snip_tx, snip_rx) = channel();
        let mut app = Self {
            pal: load_palette(&cfg().scheme),
            query: String::new(),
            last_sent: "\u{0}".into(), // force the first browse request
            last_change: Instant::now() - Duration::from_secs(1),
            cursor_end: false,
            seq: 0,
            tx,
            hq_map: HashMap::new(),
            hq_asked: HashMap::new(),
            grid_cols: 1,
            hq_tx,
            hq_rx,
            rx,
            snip_tx,
            snip_rx,
            snips: HashMap::new(),
            total: 0,
            pages: HashMap::new(),
            pending: HashSet::new(),
            req_q: String::new(),
            req_sort: String::new(),
            req_desc: true,
            selected: 0,
            anchor: None,
            trash_pending: None,
            trash_typed: String::new(),
            menu_at: None,
            menu_hit: None,
            row_rects: HashMap::new(),
            props: None,
            menu_fresh: false,
            menu_mime: None,
            history: load_history(),
            hist_popup: false,
            hist_sel: 0,
            last_recorded: String::new(),
            props_mime: String::new(),
            list_focus: false,
            handlers: HashMap::new(),
            status: "connecting to search server…".into(),
            busy: false,
            textures: HashMap::new(),
            missing: HashSet::new(),
            first_frame: true,
            close_now: false,
            people: Vec::new(),
            facets: FacetsReply::default(),
            col_frac: load_cols(),
            thumb: 16.0, // same as Ctrl+0 (column list)
            results_h: 400.0,
            scroll_pending: false,
            stats: None,
            chord_key: None,
            grid_off: 0.0,
            popup: false,
            face_pane: None,
            path_pane: None,
            cands: Vec::new(),
            cand_sel: 0,
            popup_q: String::new(),
        };
        app.people = fetch_people();
        app.facets = fetch_facets();
        app.send_query();
        app
    }

    fn send_query(&mut self) {
        self.seq += 1;
        let (rest, sort) = parse_sort(&self.query);
        self.req_q = rest;
        self.req_sort = sort.keys.join(",");
        self.req_desc = sort.desc;
        self.last_sent = self.query.clone();
        self.pages.clear();
        self.pending.clear();
        self.busy = true;
        self.request_page(0);
    }

    fn request_page(&mut self, page: usize) {
        if !self.pending.insert(page) && page != 0 { return; }
        let tx: Sender<Fetch> = self.tx.clone();
        let (seq, q, sort, desc) = (self.seq, self.req_q.clone(), self.req_sort.clone(), self.req_desc);
        std::thread::spawn(move || {
            let r = fetch_page(&q, &sort, desc, page);
            let _ = tx.send(Fetch { seq, page, query: q, result: r });
        });
    }

    /// Requests the pages that cover rows lo..hi, skipping ones already fetched or in flight.
    fn ensure_rows(&mut self, lo: usize, hi: usize) {
        if self.total == 0 { return; }
        let hi = hi.min(self.total - 1);
        if lo > hi { return; }
        for page in lo / PAGE..=hi / PAGE {
            if !self.pages.contains_key(&page) && !self.pending.contains(&page) {
                self.request_page(page);
            }
        }
    }

    fn hit(&self, i: usize) -> Option<&Hit> {
        self.pages.get(&(i / PAGE)).and_then(|p| p.get(i % PAGE))
    }

    /// A row by index, fetching its page right away when it is not loaded yet.
    fn hit_now(&mut self, i: usize) -> Option<Hit> {
        if i >= self.total { return None; }
        if self.hit(i).is_none() {
            let page = i / PAGE;
            let rows = fetch_page(&self.req_q, &self.req_sort, self.req_desc, page).ok()?.results;
            self.pages.insert(page, rows);
        }
        self.hit(i).cloned()
    }

    fn drain(&mut self) {
        while let Ok((remote, path)) = self.hq_rx.try_recv() {
            self.hq_map.insert(remote, path);
        }
        while let Ok((remote, q, r)) = self.snip_rx.try_recv() {
            self.snips.insert((remote, q), match r { Ok(v) => SnipState::Done(v), Err(e) => SnipState::Failed(e) });
        }
        while let Ok(f) = self.rx.try_recv() {
            if f.seq != self.seq { continue; } // stale: a newer query was already sent
            self.pending.remove(&f.page);
            match f.result {
                Ok(r) => {
                    self.total = r.count;
                    if f.page == 0 { self.stats = r.stats.clone(); }
                    self.pages.insert(f.page, r.results);
                    self.selected = self.selected.min(self.total.saturating_sub(1));
                    if f.page == 0 {
                        self.busy = false;
                        self.missing.clear();
                        self.status = if !r.errors.is_empty() {
                            r.errors.join("; ")
                        } else if f.query.is_empty() {
                            format!("newest {} photos", self.total)
                        } else {
                            format!("{} matches", r.count)
                        };
                    }
                }
                Err(e) => {
                    if f.page == 0 { self.busy = false; self.status = e; }
                }
            }
        }
    }

    /// Indices of all selected rows (the cursor alone when there is no range).
    fn selection(&self) -> Vec<usize> {
        match self.anchor {
            Some(a) => {
                let (lo, hi) = (a.min(self.selected), a.max(self.selected));
                (lo..=hi).filter(|i| *i < self.total).collect()
            }
            None => vec![self.selected],
        }
    }

    fn in_selection(&self, idx: usize) -> bool {
        match self.anchor {
            Some(a) => idx >= a.min(self.selected) && idx <= a.max(self.selected),
            None => idx == self.selected,
        }
    }

    /// Move the cursor; with `extend` the range grows from the anchor, otherwise it collapses.
    fn move_cursor(&mut self, to: usize, extend: bool) {
        self.scroll_pending = true;
        if extend {
            if self.anchor.is_none() { self.anchor = Some(self.selected); }
        } else {
            self.anchor = None;
        }
        self.selected = to;
    }

    /// History entries matching the current search text, most recent first.
    fn hist_matches(&self) -> Vec<String> {
        let needle = normalize_query(&self.query);
        self.history.iter().rev()
            .filter(|h| needle.is_empty() || fuzzy_match(h, &needle))
            .take(10)
            .cloned()
            .collect()
    }

    /// Adds the current query to the history (see the DSL spec: recorded on accept / movement, not per keystroke).
    fn record_history(&mut self) {
        let q = normalize_query(&self.query);
        if q.is_empty() || q == self.last_recorded { return; }
        self.last_recorded = q.clone();
        self.history.retain(|h| h != &q);
        self.history.push(q);
        let _ = std::fs::create_dir_all(PathBuf::from(&cfg().data_dir));
        let _ = std::fs::write(history_path(), self.history.join("\n") + "\n");
    }

    /// Delete key: stage the selected trashable files for the confirmation dialog.
    fn request_trash(&mut self) {
        let mut files = Vec::new();
        let mut skipped = 0usize;
        for i in self.selection() {
            let Some(h) = self.hit_now(i) else { continue };
            match trashable(&h.remote) {
                Some(f) => files.push(f),
                None => skipped += 1,
            }
        }
        if files.is_empty() {
            self.status = format!("nothing to trash in the selection ({skipped} not eligible: remote or directory)");
            return;
        }
        self.trash_typed.clear();
        self.trash_pending = Some(files);
    }

    fn do_trash(&mut self, files: Vec<(PathBuf, u64)>) {
        let mut ok = 0usize;
        let mut failed = Vec::new();
        for (p, _) in &files {
            // re-check at the moment of deletion: the file may have changed since the dialog
            if trashable(&p.to_string_lossy()).is_none() {
                failed.push(p.display().to_string());
                continue;
            }
            let res = std::process::Command::new("gio").arg("trash").arg(p).status();
            match res {
                Ok(st) if st.success() => ok += 1,
                _ => failed.push(p.display().to_string()),
            }
        }
        self.anchor = None;
        self.send_query();
        self.status = if failed.is_empty() {
            format!("moved {ok} file(s) to the trash")
        } else {
            format!("moved {ok} file(s) to the trash; {} failed: {}", failed.len(), failed.join(", "))
        };
    }

    fn open_hit(&mut self, idx: usize) {
        let Some(h) = self.hit_now(idx) else { return };
        let local = local_path(&h.remote);
        if local.exists() {
            std::thread::spawn(move || {
                let _ = std::process::Command::new("xdg-open").arg(&local).status();
            });
        } else {
            // remote result that is not on the mount: fetch to /tmp first
            let name = h.remote.rsplit('/').next().unwrap_or("file").to_string();
            let dst = format!("/tmp/images-open-{name}");
            std::thread::spawn(move || {
                let _ = std::process::Command::new("sh").arg("-c")
                    .arg(format!("rclone cat '{}' > '{}' && xdg-open '{}'", h.remote, dst, dst)).status();
            });
        }
    }

    /// Opens the context menu for one hit; the mime type is looked up once here, not per frame.
    fn open_menu(&mut self, at: egui::Pos2, hit: usize) {
        self.menu_mime = self.hit_now(hit)
            .map(|h| local_path(&h.remote))
            .filter(|p| p.exists())
            .map(|p| mime_of(&p));
        if let Some(m) = self.menu_mime.clone() {
            self.handlers.entry(m.clone()).or_insert_with(|| handlers_for(&m));
        }
        self.menu_at = Some(at);
        self.menu_hit = Some(hit);
    }

    /// Opens the properties panel for one hit; the mime type is looked up once here.
    fn open_props(&mut self, idx: usize) {
        self.props_mime = self.hit_now(idx).map(|h| {
            let l = local_path(&h.remote);
            if l.exists() { mime_of(&l) } else { "not available locally".into() }
        }).unwrap_or_default();
        self.props = Some(idx);
    }

    fn open_selected(&mut self) {
        self.open_hit(self.selected);
    }

    /// Clicking a header writes `/s <field>` into the query (replacing any /s and /rv there):
    /// the same primary column flips the direction, another column sorts ascending.
    fn set_sort(&mut self, key: &str) {
        let (rest, cur) = parse_sort(&self.query);
        let desc = cur.explicit && cur.keys.first().map(String::as_str) == Some(key) && !cur.desc;
        let field = SORT_FIELDS.iter().find(|f| f.1 == key).map(|f| f.0).unwrap_or(key);
        let mut q = rest;
        if !q.is_empty() { q.push(' '); }
        q.push_str(&format!("/s {field}{}", if desc { " desc" } else { "" }));
        self.query = q;
        self.send_query();
        self.save_sort();
    }

    /// Writes the column proportions, so they come back next time the app opens.
    fn save_sort(&self) {
        let _ = std::fs::create_dir_all(PathBuf::from(&cfg().data_dir));
        let body = serde_json::json!({"cols": self.col_frac});
        let _ = std::fs::write(sort_path(), body.to_string());
    }

    /// Right-hand pane for /fts results: Recoll's snippets of the highlighted file, matches in bold.
    fn preview_pane(&mut self, ui: &mut egui::Ui) {
        let pal = self.pal;
        let Some(hit) = self.hit(self.selected).cloned() else { return };
        let key = (hit.remote.clone(), self.req_q.clone());
        if !self.snips.contains_key(&key) {
            self.snips.insert(key.clone(), SnipState::Loading);
            let tx = self.snip_tx.clone();
            let (remote, q) = key.clone();
            std::thread::spawn(move || {
                let r = fetch_snippets(&remote, &q);
                let _ = tx.send((remote, q, r));
            });
        }
        let bold = FontFamily::Name("bold".into());
        egui::Panel::right("preview")
            .resizable(true)
            .default_size(340.0)
            .size_range(200.0..=900.0)
            .frame(egui::Frame::new().fill(pal.bg).stroke(Stroke::new(1.0, pal.border)).inner_margin(Margin::same(12)))
            .show_inside(ui, |ui| {
                let name = hit.remote.rsplit('/').next().unwrap_or(&hit.remote);
                let dir = hit.remote.rsplit_once('/').map(|x| x.0).unwrap_or("");
                ui.add(egui::Label::new(RichText::new(name).color(pal.accent).size(13.0).family(bold.clone())).wrap());
                ui.add(egui::Label::new(RichText::new(dir).color(pal.dim).size(10.0)).wrap());
                ui.add_space(8.0);
                match self.snips.get(&key) {
                    None | Some(SnipState::Loading) => { ui.label(RichText::new("loading…").color(pal.dim).size(11.0)); }
                    Some(SnipState::Failed(e)) => { ui.label(RichText::new(e).color(pal.error).size(11.0)); }
                    Some(SnipState::Done(v)) if v.is_empty() => {
                        ui.label(RichText::new("no matching passages").color(pal.dim).size(11.0));
                    }
                    Some(SnipState::Done(v)) => {
                        egui::ScrollArea::vertical().auto_shrink([false, false]).show(ui, |ui| {
                            for sn in v {
                                if let Some(p) = sn.page {
                                    ui.label(RichText::new(format!("page {p}")).color(pal.dim).size(10.0));
                                }
                                let font = egui::FontId::proportional(12.0);
                                let plain = egui::TextFormat::simple(font.clone(), pal.text);
                                let hl = egui::TextFormat::simple(egui::FontId::new(12.0, bold.clone()), pal.accent);
                                let mut job = egui::text::LayoutJob::default();
                                job.wrap.max_width = ui.available_width();
                                let mut pos = 0;
                                for &(s, e) in &sn.ranges {
                                    if s < pos || e > sn.text.len() || !sn.text.is_char_boundary(s) || !sn.text.is_char_boundary(e) { continue; }
                                    job.append(&sn.text[pos..s], 0.0, plain.clone());
                                    job.append(&sn.text[s..e], 0.0, hl.clone());
                                    pos = e;
                                }
                                job.append(&sn.text[pos..], 0.0, plain);
                                ui.label(job);
                                ui.add_space(10.0);
                            }
                        });
                    }
                }
            });
    }

    /// Thumbnail grid for zoomed-in views: square cells with name, path, size and date under each.
    /// Only the rows on screen are laid out; the others are fetched as they come into view.
    fn grid_view(&mut self, ui: &mut egui::Ui, ctx: &egui::Context,
                 clicked: &mut Option<(usize, bool)>, dbl: &mut bool, right: &mut Option<(usize, egui::Pos2)>) {
        let pal = self.pal;
        let text_h = 58.0;
        // columns are as many as fit the thumbnail size, and the cells are stretched so they fill the whole width
        let gap = 10.0;
        let avail = ui.available_width();
        let cols = ((avail + gap) / (self.thumb + gap)).floor().max(1.0) as usize;
        self.grid_cols = cols;
        let t = ((avail - gap * (cols as f32 - 1.0)) / cols as f32).floor().max(16.0);
        let rows = self.total.div_ceil(cols);
        let view_h = ui.available_height() - 30.0;
        let mut area = egui::ScrollArea::vertical().max_height(view_h).auto_shrink([false, false]);
        // the spacing is set before show_rows so its row stride is exactly the one computed here
        ui.spacing_mut().item_spacing = egui::vec2(10.0, 10.0);
        let stride = t + text_h + 10.0;
        if self.scroll_pending {
            // keep the grid still while the selection moves inside the view; when it leaves, scroll by
            // whole rows so the rows stay aligned to the same screen positions
            let row = (self.selected / cols) as f32;
            let off = self.grid_off;
            let fits = row * stride >= off - 0.5 && (row + 1.0) * stride - 10.0 <= off + view_h + 0.5;
            if !fits {
                let visible = ((view_h + 10.0) / stride).floor().max(1.0);
                let first = (off / stride).round();
                let new_first = if row < first { row } else { row - visible + 1.0 };
                area = area.vertical_scroll_offset((new_first.max(0.0)) * stride);
            }
        }
        let out = area.show_rows(ui, t + text_h, rows, |ui, range| {
            self.ensure_rows(range.start * cols, range.end * cols);
            for row in range {
                ui.horizontal(|ui| {
                    for idx in row * cols..((row + 1) * cols).min(self.total) {
                        let (rect, resp) = ui.allocate_exact_size(egui::vec2(t, t + text_h), egui::Sense::click());
                        let Some(h) = self.hit(idx).cloned() else {
                            ui.painter().rect_filled(egui::Rect::from_min_size(rect.min, egui::vec2(t, t)), 4.0, pal.border.gamma_multiply(0.5));
                            continue;
                        };
                        let img = egui::Rect::from_min_size(rect.min, egui::vec2(t, t));
                        let selected = self.in_selection(idx);
                        // large PDF cells ask for a sharp first page in the background and switch to it when ready
                        let is_pdf = h.remote.to_lowercase().ends_with(".pdf") && h.remote.starts_with('/');
                        // ask again at most every 2 s while the cell stays on screen; the server drops requests that stop
                        let due = self.hq_asked.get(&h.remote).map_or(true, |t| t.elapsed() > Duration::from_secs(2));
                        if is_pdf && t >= 180.0 && !self.hq_map.contains_key(&h.remote) && due {
                            self.hq_asked.insert(h.remote.clone(), Instant::now());
                            let _ = self.hq_tx.send(h.remote.clone());
                        }
                        let thumb_path = self.hq_map.get(&h.remote).cloned().unwrap_or_else(|| h.thumb.clone());
                        match self.texture(ctx, &thumb_path) {
                            Some(tex) => { egui::Image::new(&tex).fit_to_exact_size(img.size()).paint_at(ui, img); }
                            None => { ui.painter().rect_filled(img, 4.0, pal.border.gamma_multiply(0.5)); }
                        }
                        if selected {
                            ui.painter().rect_stroke(img.expand(2.0), 4.0, Stroke::new(2.0, pal.accent), egui::StrokeKind::Outside);
                        }
                        let short = short_name(&h.remote);
                        let (dir, base) = match short.rsplit_once('/') {
                            Some((d, b)) => (d.to_string(), b.to_string()),
                            None => (String::new(), short.clone()),
                        };
                        let name_font = egui::FontId::monospace(12.0);
                        let small = egui::FontId::monospace(10.0);
                        let txt = if selected { pal.text } else { pal.text.gamma_multiply(0.85) };
                        let size_txt = h.size.map(human_size).unwrap_or_default();
                        let date_txt = h.mtime.as_deref().map(short_time).unwrap_or_default();
                        let name_text = fit_text(ui, &base, &name_font, t);
                        let terms = query_terms(&self.last_sent);
                        let lines = [
                            (fit_text(ui, &dir, &small, t), small.clone(), pal.dim),
                            (fit_text(ui, &size_txt, &small, t), small.clone(), pal.dim),
                            (fit_text(ui, &date_txt, &small, t), small.clone(), pal.dim),
                        ];
                        let painter = ui.painter();
                        let name_galley = painter.layout_job(name_job(&name_text, &terms, &name_font, txt));
                        painter.galley(egui::pos2(rect.left(), img.bottom() + 4.0), name_galley, txt);
                        let mut y = img.bottom() + 18.0;
                        for (text, font, color) in lines {
                            painter.text(egui::pos2(rect.left(), y), egui::Align2::LEFT_TOP, text, font, color);
                            y += 14.0;
                        }
                        if let Some(sc) = h.score {
                            painter.text(egui::pos2(rect.right() - 2.0, img.top() + 2.0), egui::Align2::RIGHT_TOP,
                                format!("{sc:.2}"), egui::FontId::monospace(10.0), pal.accent);
                        }
                        let shift = ui.input(|i| i.modifiers.shift);
                        if resp.clicked() { *clicked = Some((idx, shift)); }
                        if resp.double_clicked() { *dbl = true; *clicked = Some((idx, false)); }
                        if resp.secondary_clicked() {
                            *right = Some((idx, ui.input(|i| i.pointer.interact_pos()).unwrap_or(resp.rect.left_bottom())));
                        }
                    }
                });
            }
        });
        self.grid_off = out.state.offset.y;
    }

    /// Ctrl+Enter: show the photo selected in Dolphin, at its real folder on the gdrive mount.
    fn reveal_selected(&mut self) {
        let Some(h) = self.hit_now(self.selected) else { return };
        let local = local_path(&h.remote).to_string_lossy().into_owned();
        std::thread::spawn(move || {
            if let Some(dir) = Path::new(&local).parent() {
                let _ = std::process::Command::new("xdg-open").arg(dir).spawn();
            }
        });
    }

    fn copy_selection(&mut self, cut: bool) {
        let paths: Vec<PathBuf> = self.selection().into_iter()
            .filter_map(|i| self.hit_now(i)).map(|h| local_path(&h.remote))
            .filter(|p| p.exists()).collect();
        if paths.is_empty() {
            self.status = "nothing local to copy".into();
            return;
        }
        clipboard_files(&paths, cut);
        self.status = format!("{} {} file(s) on the clipboard", if cut { "cut" } else { "copied" }, paths.len());
    }

    fn accept_candidate(&mut self) {
        if let Some((rep, _)) = self.cands.get(self.cand_sel).cloned() {
            let (start, _) = completions(&self.query, &self.facets, &self.history);
            self.query = apply(&self.query, start, &rep);
            self.last_change = Instant::now() - Duration::from_millis(200);
            self.cursor_end = true;
        }
        self.popup = false;
    }

    fn texture(&mut self, ctx: &egui::Context, path: &str) -> Option<TextureHandle> {
        if let Some(t) = self.textures.get(path) { return Some(t.clone()); }
        if self.missing.contains(path) || !Path::new(path).exists() { return None; }
        let img = image::open(path).ok()?.to_rgba8();
        let (w, h) = img.dimensions();
        let ci = egui::ColorImage::from_rgba_unmultiplied([w as usize, h as usize], img.as_raw());
        let tex = ctx.load_texture(path, ci, egui::TextureOptions::LINEAR);
        self.textures.insert(path.to_string(), tex.clone());
        Some(tex)
    }
}

fn short_name(remote: &str) -> String {
    // "gdrive-crypt:photos/<folder>/<file>.jpg" -> "photos/<folder>/<file>.jpg"
    remote.split_once(':').map(|(_, p)| p.trim_start_matches('/')).unwrap_or(remote).to_string()
}

impl eframe::App for App {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        let pal = self.pal;
        ui.painter().rect_filled(ui.max_rect(), 0.0, pal.bg);
        // Ctrl+wheel and trackpad pinch: zoom the thumbnails, not the whole UI
        let zd = ui.input(|i| i.zoom_delta());
        if (zd - 1.0).abs() > 1e-4 {
            self.thumb = (self.thumb * zd).clamp(16.0, 800.0);
        }
        // Ctrl+- / Ctrl++ (Ctrl+= too): the same zoom as Ctrl+wheel, one step per press, repeating while held
        let mut preset: Option<f32> = None;
        let steps = ui.input_mut(|i| {
            let mut n = 0i32;
            i.events.retain(|e| {
                if let egui::Event::Key { key, pressed: true, modifiers, .. } = e {
                    if modifiers.ctrl && !modifiers.alt {
                        match key {
                            Key::Plus | Key::Equals => { n += 1; return false; }
                            Key::Minus => { n -= 1; return false; }
                            Key::Num0 => { preset = Some(16.0); return false; }  // most zoomed out: the column list
                            Key::Num9 => { preset = Some(320.0); return false; } // large thumbnails, short of the maximum
                            _ => {}
                        }
                    }
                }
                true
            });
            n
        });
        if let Some(p) = preset {
            self.thumb = p;
            self.scroll_pending = true;
        } else if steps != 0 {
            self.thumb = (self.thumb * 1.15f32.powi(steps)).clamp(16.0, 800.0);
        }
        ctx.set_zoom_factor(1.0);
        // wheel steps cover more when zoomed in (bigger rows); scaled on the scroll delta only,
        // because egui also derives the zoom step from the wheel delta
        let row_h = (self.thumb + 4.0).max(20.0);
        ctx.options_mut(|o| o.input_options.line_scroll_speed = 100.0);
        // ctrl+wheel zoom: half the default step, so zooming is gentler
        ctx.options_mut(|o| o.input_options.scroll_zoom_speed = 1.0 / 400.0);
        let scroll_boost = (row_h / 60.0).clamp(1.0, 6.0);
        ui.input_mut(|i| i.smooth_scroll_delta *= scroll_boost);
        let grid = self.thumb >= GRID_ZOOM;
        // the score column only exists for photo results
        let show_score = self.pages.values().flatten().any(|h| h.score.is_some());

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

        // holding Ctrl+J/K (or any Ctrl chord) repeats as key events plus stray text events: drop the text
        // so a held chord never types into the query box
        // Auto-repeat of a held Ctrl+J/K/H/L can arrive without the Ctrl modifier (and with the letter as
        // text), so remember the chord from its first press and treat repeats of that key as the chord
        let mut chord = self.chord_key;
        ui.input_mut(|i| {
            let ctrl_now = i.modifiers.ctrl || (i.modifiers.command && !i.modifiers.alt);
            for e in i.events.iter_mut() {
                if let egui::Event::Key { key, pressed, modifiers, .. } = e {
                    if !matches!(key, Key::J | Key::K | Key::H | Key::L) { continue; }
                    if !*pressed {
                        if chord == Some(*key) { chord = None; }
                    } else if modifiers.ctrl {
                        chord = Some(*key);
                    } else if chord == Some(*key) {
                        modifiers.ctrl = true;
                        modifiers.command = true;
                    }
                }
            }
            if ctrl_now || chord.is_some() {
                i.events.retain(|e| match e {
                    egui::Event::Text(t) => !(ctrl_now || (chord.is_some() && matches!(t.as_str(), "j" | "k" | "h" | "l" | "J" | "K" | "H" | "L"))),
                    _ => true,
                });
            }
        });
        self.chord_key = chord;

        // Delete: only when the confirmation dialog is closed
        let del = self.trash_pending.is_none() && ui.input(|i| i.key_pressed(Key::Delete));
        if del && !self.popup && self.total > 0 {
            self.request_trash();
        }

        // Shift+arrows extend the list selection; consume them before the query box sees them
        // (every queued press counts, so holding the key keeps extending; left/right only in the grid,
        // in the list they stay with the query box's own shift-selection)
        let shift_down_n = take_count(ui, egui::Modifiers::SHIFT, Key::ArrowDown);
        let shift_up_n = take_count(ui, egui::Modifiers::SHIFT, Key::ArrowUp);
        let (shift_left_n, shift_right_n) = if grid {
            (take_count(ui, egui::Modifiers::SHIFT, Key::ArrowLeft), take_count(ui, egui::Modifiers::SHIFT, Key::ArrowRight))
        } else { (0, 0) };

        // completion keys: consumed before the text edit sees them (so Tab does not move focus)
        let tab = ui.input_mut(|i| i.consume_key(egui::Modifiers::NONE, Key::Tab));
        // emacs-style Ctrl+E: caret to the end of the query (Ctrl+A keeps selecting everything)
        if ui.input_mut(|i| i.consume_key(egui::Modifiers::CTRL, Key::E)) {
            self.cursor_end = true;
        }
        let ctrl_space = ui.input_mut(|i| i.consume_key(egui::Modifiers::CTRL, Key::Space));
        if (tab || ctrl_space) && !self.popup && self.path_pane.is_none() && path_fragment(&self.query).is_some() {
            let (start, frag) = path_fragment(&self.query).unwrap_or((0, String::new()));
            let (tx, rx) = channel();
            let mut p = PathPane { start, frag, total: 0, pages: HashMap::new(), pending: HashSet::new(), sel: 0, tx, rx };
            request_path_page(&mut p, 0);
            self.path_pane = Some(p);
        } else if (tab || ctrl_space) && !self.popup && self.face_pane.is_none() && self.query.trim_end().ends_with("/face") {
            let q = self.query.trim_end().to_string();
            let seed = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
            let (tx, rx) = channel();
            std::thread::spawn(move || { let _ = tx.send(fetch_faces(seed)); });
            self.face_pane = Some(FacePane { items: Vec::new(), sel: 0, cols: 6, scroll_pending: false, prefix: q[..q.len() - "/face".len()].to_string(), loading: true, rx });
        } else if (tab || ctrl_space) && !self.popup {
            let (start, cands) = completions(&self.query, &self.facets, &self.history);
            match cands.len() {
                0 => {}
                1 => {
                    self.query = apply(&self.query, start, &cands[0].0);
                    self.last_change = Instant::now();
                    self.cursor_end = true;
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
        if let Some(p) = self.face_pane.as_mut() {
            if let Ok(items) = p.rx.try_recv() { p.items = items; p.loading = false; }
        }
        match (path_fragment(&self.query), self.path_pane.as_mut()) {
            (None, Some(_)) => self.path_pane = None,
            (Some((start, frag)), Some(p)) => {
                if frag != p.frag || start != p.start {
                    p.start = start;
                    p.frag = frag;
                    p.total = 0;
                    p.pages.clear();
                    p.pending.clear();
                    p.sel = 0;
                    request_path_page(p, 0);
                }
                while let Ok(pg) = p.rx.try_recv() {
                    if pg.frag == p.frag {
                        p.total = pg.total;
                        p.pending.remove(&pg.page);
                        p.pages.insert(pg.page, pg.items);
                    }
                }
            }
            _ => {}
        }
        if let Some(p) = self.path_pane.as_mut() {
            let (down, up, enter, esc) = ui.input_mut(|i| (
                i.consume_key(egui::Modifiers::NONE, Key::ArrowDown) | i.consume_key(egui::Modifiers::CTRL, Key::J),
                i.consume_key(egui::Modifiers::NONE, Key::ArrowUp) | i.consume_key(egui::Modifiers::CTRL, Key::K),
                i.consume_key(egui::Modifiers::NONE, Key::Enter) | i.consume_key(egui::Modifiers::NONE, Key::Tab),
                i.consume_key(egui::Modifiers::NONE, Key::Escape),
            ));
            if p.total > 0 {
                if down { p.sel = (p.sel + 1).min(p.total - 1); }
                if up { p.sel = p.sel.saturating_sub(1); }
            }
            if esc {
                self.path_pane = None;
            } else if enter {
                let chosen = p.pages.get(&(p.sel / PATH_PAGE)).and_then(|v| v.get(p.sel % PATH_PAGE)).cloned();
                if let Some(value) = chosen {
                    let shown = if value.contains(' ') { format!("\"{value}\"") } else { value };
                    self.query = format!("{}{} ", &self.query[..p.start], shown);
                    self.last_change = Instant::now() - Duration::from_millis(400);
                    self.cursor_end = true;
                    self.path_pane = None;
                }
            }
        }
        if self.face_pane.is_some() {
            let (l, r, u, d, enter, esc) = ui.input_mut(|i| (
                i.consume_key(egui::Modifiers::NONE, Key::ArrowLeft) | i.consume_key(egui::Modifiers::CTRL, Key::H),
                i.consume_key(egui::Modifiers::NONE, Key::ArrowRight) | i.consume_key(egui::Modifiers::CTRL, Key::L),
                i.consume_key(egui::Modifiers::NONE, Key::ArrowUp) | i.consume_key(egui::Modifiers::CTRL, Key::K),
                i.consume_key(egui::Modifiers::NONE, Key::ArrowDown) | i.consume_key(egui::Modifiers::CTRL, Key::J),
                i.consume_key(egui::Modifiers::NONE, Key::Enter),
                i.consume_key(egui::Modifiers::NONE, Key::Escape),
            ));
            if let Some(p) = self.face_pane.as_mut() {
                let n = p.items.len();
                let cols = p.cols.max(1);
                if n > 0 {
                    let before = p.sel;
                    if r { p.sel = (p.sel + 1).min(n - 1); }
                    if l { p.sel = p.sel.saturating_sub(1); }
                    if d { p.sel = (p.sel + cols).min(n - 1); }
                    if u { p.sel = p.sel.saturating_sub(cols); }
                    if p.sel != before { p.scroll_pending = true; }
                }
            }
            if esc { self.face_pane = None; }
            else if enter {
                if let Some(p) = self.face_pane.take() {
                    if let Some((id, _)) = p.items.get(p.sel) {
                        self.query = format!("{}/face \"@{}\" ", p.prefix, id);
                        self.last_change = Instant::now() - Duration::from_millis(400);
                        self.cursor_end = true;
                    }
                }
            }
        }
        if self.popup {
            // popup keys: Up/Down or Ctrl+J/K move, Enter accepts, Esc closes only the popup
            let (down, up, enter, esc, cj, ck) = ui.input_mut(|i| {
                (
                    i.key_pressed(Key::ArrowDown),
                    i.key_pressed(Key::ArrowUp),
                    i.key_pressed(Key::Enter) && !i.modifiers.ctrl,
                    i.key_pressed(Key::Escape),
                    false,
                    false,
                )
            });
            let (cj_n, ck_n) = (take_count(ui, egui::Modifiers::CTRL, Key::J), take_count(ui, egui::Modifiers::CTRL, Key::K));
            let n = self.cands.len();
            if esc { self.popup = false; }
            else if enter { self.accept_candidate(); }
            else if n > 0 {
                let _ = (cj, ck);
                if down { self.cand_sel = (self.cand_sel + 1) % n; }
                if up { self.cand_sel = (self.cand_sel + n - 1) % n; }
                self.cand_sel = (self.cand_sel + cj_n % n + n - ck_n % n) % n;
            }
        }
        // typing while the popup is open narrows it in place
        if self.popup && self.query != self.popup_q {
            let (_, cands) = completions(&self.query, &self.facets, &self.history);
            if cands.is_empty() { self.popup = false; } else { self.cands = cands; self.cand_sel = 0; }
        }
        self.popup_q = self.query.clone();

        // keys (only the ones the list owns; typing goes to the query box)
        let n = self.total;
        // Ctrl+R / F4: search history popup, seeded from the current text
        let hist_key = ui.input_mut(|i| i.consume_key(egui::Modifiers::CTRL, Key::R))
            | ui.input_mut(|i| i.consume_key(egui::Modifiers::NONE, Key::F4));
        if hist_key && !self.hist_popup && !self.popup && self.trash_pending.is_none() && self.props.is_none() {
            self.hist_popup = true;
            self.hist_sel = 0;
        }
        if self.hist_popup {
            let (down, up, enter, esc) = ui.input_mut(|i| (
                i.consume_key(egui::Modifiers::NONE, Key::ArrowDown) | i.consume_key(egui::Modifiers::CTRL, Key::J),
                i.consume_key(egui::Modifiers::NONE, Key::ArrowUp) | i.consume_key(egui::Modifiers::CTRL, Key::K),
                i.consume_key(egui::Modifiers::NONE, Key::Enter),
                i.consume_key(egui::Modifiers::NONE, Key::Escape),
            ));
            let matches = self.hist_matches();
            let m = matches.len();
            if esc { self.hist_popup = false; }
            else if enter {
                if let Some(q) = matches.get(self.hist_sel).cloned() {
                    self.query = q;
                    self.last_change = Instant::now() - Duration::from_millis(200);
                }
                self.hist_popup = false;
            } else if m > 0 {
                if down { self.hist_sel = (self.hist_sel + 1).min(m - 1); }
                if up { self.hist_sel = self.hist_sel.saturating_sub(1); }
            }
            self.hist_sel = self.hist_sel.min(m.saturating_sub(1));
        }

        // Ctrl+J / Ctrl+K from the query box: focus the list at the first / last entry
        // Ctrl+J/K/H/L: count every queued press (holding the key auto-repeats), so holding moves smoothly
        // while the completion popup is open, Ctrl+J/K belong to it (read further below), not the list
        let ctrl_j_n = if self.popup { 0 } else { take_count(ui, egui::Modifiers::CTRL, Key::J) };
        let ctrl_k_n = if self.popup { 0 } else { take_count(ui, egui::Modifiers::CTRL, Key::K) };
        let ctrl_j = ctrl_j_n > 0;
        let ctrl_k = ctrl_k_n > 0;
        let was_list = self.list_focus;
        if !was_list && n > 0 && !self.popup && self.trash_pending.is_none() && self.props.is_none() && (ctrl_j || ctrl_k) {
            self.list_focus = true;
            self.move_cursor(if ctrl_j { 0 } else { n - 1 }, false);
        }
        let (down, up, left, right, pgdn, pgup, home, end, enter, ctrl_enter, esc, _cj, _ck) = ui.input(|i| {
            (
                i.key_pressed(Key::ArrowDown),
                i.key_pressed(Key::ArrowUp),
                i.key_pressed(Key::ArrowLeft),
                i.key_pressed(Key::ArrowRight),
                i.key_pressed(Key::PageDown),
                i.key_pressed(Key::PageUp),
                i.key_pressed(Key::Home),
                i.key_pressed(Key::End),
                i.key_pressed(Key::Enter) && !i.modifiers.ctrl && !i.modifiers.alt,
                i.key_pressed(Key::Enter) && i.modifiers.ctrl,
                i.key_pressed(Key::Escape),
                false,
                false,
            )
        });
        // Esc closes the innermost thing first: menu, then properties, then the window
        if esc && !self.popup {
            if self.menu_at.is_some() { self.menu_at = None; self.menu_hit = None; }
            else if self.props.is_some() { self.props = None; }
            else { ctx.send_viewport_cmd(egui::ViewportCommand::Close); }
        }
        let alt_enter = ui.input(|i| i.key_pressed(Key::Enter) && i.modifiers.alt);
        if alt_enter && n > 0 && !self.popup && self.trash_pending.is_none() { self.open_props(self.selected); }
        let f10 = ui.input_mut(|i| i.consume_key(egui::Modifiers::NONE, Key::F10));
        if f10 && n > 0 && !self.popup && self.trash_pending.is_none() {
            let at = self.row_rects.get(&self.selected).map(|r| r.left_bottom()).unwrap_or(egui::pos2(40.0, 120.0));
            self.open_menu(at, self.selected);
        }
        let qsel = query_has_selection(&ctx);
        if !qsel && !self.popup && self.trash_pending.is_none() && self.props.is_none() && n > 0 {
            let key_c = ui.input_mut(|i| i.consume_key(egui::Modifiers::CTRL, Key::C));
            let key_x = ui.input_mut(|i| i.consume_key(egui::Modifiers::CTRL, Key::X));
            // egui-winit may report Ctrl+C / Ctrl+X as copy/cut events instead of key presses
            let ev_copy = ui.input_mut(|i| { let had = i.events.iter().any(|e| matches!(e, egui::Event::Copy)); i.events.retain(|e| !matches!(e, egui::Event::Copy)); had });
            let ev_cut = ui.input_mut(|i| { let had = i.events.iter().any(|e| matches!(e, egui::Event::Cut)); i.events.retain(|e| !matches!(e, egui::Event::Cut)); had });
            if key_c || ev_copy { self.copy_selection(false); }
            if key_x || ev_cut { self.copy_selection(true); }
        }
        if n > 0 && !self.popup {
            let cols = if grid { self.grid_cols.max(1) } else { 1 };
            let shift_any = ui.input(|i| i.modifiers.shift);
            // Ctrl+H / Ctrl+L: previous / next item, in grid and list alike (consumed before the query box)
            let h_n = take_count(ui, egui::Modifiers::CTRL, Key::H);
            let l_n = take_count(ui, egui::Modifiers::CTRL, Key::L);
            let j_n = if was_list { ctrl_j_n } else { 0 };
            let k_n = if was_list { ctrl_k_n } else { 0 };
            let cur = self.selected as i64;
            // all movement in this frame is summed, then applied once (clamped to the list)
            let mut delta: i64 = 0;
            let mut abs: Option<usize> = None;
            let mut extend = shift_any;
            let mut any = false;
            if grid && right { delta += 1; any = true; }
            if grid && left { delta -= 1; any = true; }
            delta += l_n as i64; delta -= h_n as i64;
            if h_n + l_n > 0 { any = true; }
            let down_steps = (down as i64) + j_n as i64;
            let up_steps = (up as i64) + k_n as i64;
            if down_steps + up_steps > 0 { any = true; }
            delta += cols as i64 * (down_steps - up_steps);
            if shift_down_n + shift_up_n + shift_left_n + shift_right_n > 0 {
                delta += cols as i64 * (shift_down_n as i64 - shift_up_n as i64) + shift_right_n as i64 - shift_left_n as i64;
                extend = true;
                any = true;
            }
            let row_h = if grid { self.thumb + 68.0 } else { (self.thumb + 4.0).max(20.0) };
            let rows = ((self.results_h / row_h).floor() as i64).max(1);
            let per_page = if grid { rows * cols as i64 } else { rows };
            let page = if ui.input(|i| i.modifiers.ctrl) { per_page * 2 } else { per_page };
            if pgdn { delta += page; any = true; }
            if pgup { delta -= page; any = true; }
            if home { abs = Some(0); any = true; }
            if end { abs = Some(n - 1); any = true; }
            if any {
                // browsing results after typing counts as use, once typing has paused
                if self.last_change.elapsed() >= Duration::from_millis(400) { self.record_history(); }
                let target = abs.unwrap_or_else(|| (cur + delta).clamp(0, n as i64 - 1) as usize);
                self.move_cursor(target, extend);
            }
        }
        if enter && n > 0 && !self.popup && !self.hist_popup {
            if self.last_change.elapsed() >= Duration::from_millis(400) { self.record_history(); }
            self.open_selected();
        }
        if ctrl_enter && n > 0 && !self.popup { self.reveal_selected(); }

        // confirmation dialog for moving files to the trash: modal, explicit, Esc cancels
        if let Some(files) = self.trash_pending.clone() {
            let total: u64 = files.iter().map(|(_, s)| *s).sum();
            let need = "DELETE";
            let mut confirm = false;
            let mut cancel = ui.input(|i| i.key_pressed(Key::Escape));
            egui::Window::new("Move to trash?")
                .collapsible(false)
                .resizable(true)
                .anchor(egui::Align2::CENTER_CENTER, egui::vec2(0.0, 0.0))
                .default_size([720.0, 520.0])
                .frame(egui::Frame::new().fill(pal.bg).stroke(Stroke::new(2.0, pal.error)).corner_radius(10.0).inner_margin(Margin::same(14)))
                .show(&ctx, |ui| {
                    ui.label(RichText::new(format!("{} file(s), {} total", files.len(), human(total)))
                        .color(pal.error).size(18.0).strong());
                    ui.label(RichText::new("Files are moved to the trash (recoverable), not erased. Only local files under your home folder are listed here.")
                        .color(pal.dim));
                    ui.add_space(8.0);
                    egui::ScrollArea::vertical().max_height(300.0).show(ui, |ui| {
                        for (p, sz) in &files {
                            ui.label(RichText::new(format!("{:>10}  {}", human(*sz), p.display())).monospace().size(12.0).color(pal.text));
                        }
                    });
                    ui.add_space(10.0);
                    ui.label(RichText::new(format!("Type {need} to confirm:")).color(pal.text));
                    let edit = ui.add(egui::TextEdit::singleline(&mut self.trash_typed).desired_width(200.0));
                    if !edit.has_focus() { edit.request_focus(); }
                    let ready = self.trash_typed.trim() == need;
                    ui.horizontal(|ui| {
                        if ui.add_enabled(ready, egui::Button::new(RichText::new("Move to trash").color(pal.error))).clicked() {
                            confirm = true;
                        }
                        if ui.button("Cancel").clicked() {
                            cancel = true;
                        }
                    });
                });
            if confirm {
                self.trash_pending = None;
                self.trash_typed.clear();
                self.do_trash(files);
            } else if cancel {
                self.trash_pending = None;
                self.trash_typed.clear();
                self.status = "delete cancelled".into();
            }
        }

        // context menu (right-click or F10): one entry, "Open with" submenu
        if let (Some(at), Some(hit)) = (self.menu_at, self.menu_hit) {
            let local = self.hit_now(hit).map(|h| local_path(&h.remote));
            let mime = self.menu_mime.clone();
            // photo results (they carry a score) can search for the face in them
            let face_remote = self.hit_now(hit).filter(|h| h.score.is_some()).map(|h| h.remote);
            let mut face_query: Option<String> = None;
            let mut chosen: Option<(String, PathBuf)> = None;
            let area = egui::Area::new(egui::Id::new("ctxmenu"))
                .order(egui::Order::Foreground)
                .fixed_pos(at)
                .show(&ctx, |ui| {
                    egui::Frame::popup(ui.style()).show(ui, |ui| {
                        if let Some(r) = &face_remote {
                            if ui.button("Search for this face").clicked() {
                                face_query = Some(format!("/face \"@{}\"", r));
                                ui.close();
                            }
                        }
                        ui.menu_button("Open with", |ui| {
                            match &mime {
                                None => { ui.label(RichText::new("not available locally").color(pal.dim)); }
                                Some(m) => {
                                    let apps = self.handlers.entry(m.clone()).or_insert_with(|| handlers_for(m)).clone();
                                    if apps.is_empty() { ui.label(RichText::new("no applications").color(pal.dim)); }
                                    for (id, name) in apps {
                                        if ui.button(name).clicked() {
                                            chosen = Some((id, local.clone().unwrap()));
                                            ui.close();
                                        }
                                    }
                                }
                            }
                        });
                    });
                });
            if let Some(q) = face_query {
                self.query = q;
                self.last_change = Instant::now() - Duration::from_millis(200);
                self.menu_at = None;
                self.menu_hit = None;
            } else if let Some((id, path)) = chosen {
                std::thread::spawn(move || {
                    let _ = std::process::Command::new("gtk-launch").arg(&id).arg(&path).status();
                });
                self.menu_at = None;
                self.menu_hit = None;
            } else if self.menu_fresh {
                self.menu_fresh = false;
            } else if area.response.clicked_elsewhere() {
                self.menu_at = None;
                self.menu_hit = None;
            }
        }

        // properties (Alt+Enter)
        if let Some(idx) = self.props {
            match self.hit_now(idx) {
                None => self.props = None,
                Some(h) => {
                    let local = local_path(&h.remote);
                    let mime = self.props_mime.clone();
                    let mut open = true;
                    egui::Window::new("Properties")
                        .open(&mut open)
                        .collapsible(false)
                        .anchor(egui::Align2::CENTER_CENTER, egui::vec2(0.0, 0.0))
                        .frame(egui::Frame::new().fill(pal.bg).stroke(Stroke::new(1.0, pal.border)).corner_radius(10.0).inner_margin(Margin::same(14)))
                        .show(&ctx, |ui| {
                            let row = |ui: &mut egui::Ui, k: &str, v: String| {
                                ui.horizontal(|ui| {
                                    ui.label(RichText::new(format!("{k:<10}")).monospace().color(pal.dim));
                                    ui.label(RichText::new(v).monospace().color(pal.text));
                                });
                            };
                            row(ui, "name", local.file_name().map(|x| x.to_string_lossy().into_owned()).unwrap_or_default());
                            row(ui, "folder", local.parent().map(|x| x.display().to_string()).unwrap_or_default());
                            row(ui, "size", h.size.map(human).unwrap_or_else(|| "-".into()));
                            row(ui, "modified", h.mtime.as_deref().map(short_time).unwrap_or_else(|| "-".into()));
                            row(ui, "type", mime);
                            row(ui, "source", h.remote.clone());
                        });
                    if !open { self.props = None; }
                }
            }
        }

        if self.list_focus && ui.input(|i| i.events.iter().any(|e| matches!(e, egui::Event::Text(_)))) {
            self.list_focus = false;
            ui.memory_mut(|m| m.request_focus(egui::Id::new("query")));
        }
        if is_fts(&self.req_q) && self.total > 0 && !grid {
            self.preview_pane(ui);
        }
        egui::Frame::new()
            .fill(pal.bg)
            .inner_margin(Margin::same(12))
            .show(ui, |ui| {
                // search row, closed off from the results by a single rule
                let row = egui::Frame::new()
                    .inner_margin(Margin::symmetric(4, 6))
                    .show(ui, |ui| {
                        ui.horizontal(|ui| {
                            if self.cursor_end {
                                // programmatic completion: park the caret after the inserted text
                                self.cursor_end = false;
                                let id = egui::Id::new("query");
                                if let Some(mut st) = egui::TextEdit::load_state(ui.ctx(), id) {
                                    let c = egui::text::CCursor::new(self.query.chars().count());
                                    st.cursor.set_char_range(Some(egui::text::CCursorRange::one(c)));
                                    st.store(ui.ctx(), id);
                                }
                            }
                            let edit = egui::TextEdit::singleline(&mut self.query)
                                .id(egui::Id::new("query"))
                                .frame(egui::Frame::NONE)
                                .text_color(pal.text)
                                .desired_width(f32::INFINITY)
                                .font(egui::TextStyle::Body);
                            let r = ui.add(edit);
                            if r.changed() { self.last_change = Instant::now(); }
                            if r.clicked() { self.list_focus = false; }
                            // keep focus here unless the list was focused on purpose
                            if !self.list_focus && !r.has_focus() { r.request_focus(); }
                        });
                    });
                let y = row.response.rect.bottom() + 2.0;
                ui.painter().hline(row.response.rect.left()..=row.response.rect.right(), y, Stroke::new(1.0, pal.border));
                ui.add_space(4.0);

                if self.hist_popup {
                    let items = self.hist_matches();
                    ui.add_space(4.0);
                    egui::Frame::new()
                        .fill(pal.bg)
                        .stroke(Stroke::new(1.0, pal.accent.gamma_multiply(0.6)))
                        .corner_radius(6.0)
                        .inner_margin(Margin::symmetric(6, 4))
                        .show(ui, |ui| {
                            if items.is_empty() {
                                ui.label(RichText::new("no matching searches").color(pal.dim).size(11.0));
                            }
                            for (i, q) in items.iter().enumerate() {
                                let sel = i == self.hist_sel;
                                ui.label(RichText::new(q).monospace().size(12.0)
                                    .color(if sel { pal.accent } else { pal.text }));
                            }
                        });
                }
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
                ui.add_space(4.0);

                if let Some(p) = self.path_pane.as_ref() {
                    let (total, sel, pages) = (p.total, p.sel, p.pages.clone());
                    let mut want: Vec<usize> = Vec::new();
                    let mut chosen: Option<usize> = None;
                    egui::Frame::new().fill(pal.bg).stroke(Stroke::new(1.0, pal.border)).corner_radius(6.0)
                        .inner_margin(Margin::same(6)).show(ui, |ui| {
                            if total == 0 {
                                ui.label(RichText::new("no folders match").color(pal.dim).size(11.0));
                            }
                            egui::ScrollArea::vertical().max_height(220.0).auto_shrink([false, false])
                                .show_rows(ui, 18.0, total, |ui, range| {
                                    for i in range {
                                        match pages.get(&(i / PATH_PAGE)).and_then(|v| v.get(i % PATH_PAGE)) {
                                            Some(s) => {
                                                if ui.selectable_label(i == sel, RichText::new(s).monospace().size(12.0)).clicked() {
                                                    chosen = Some(i);
                                                }
                                            }
                                            None => {
                                                want.push(i / PATH_PAGE);
                                                ui.label(RichText::new("…").color(pal.dim));
                                            }
                                        }
                                    }
                                });
                        });
                    want.sort();
                    want.dedup();
                    if let Some(p) = self.path_pane.as_mut() {
                        for page in want { request_path_page(p, page); }
                        if let Some(i) = chosen {
                            if let Some(value) = p.pages.get(&(i / PATH_PAGE)).and_then(|v| v.get(i % PATH_PAGE)).cloned() {
                                let shown = if value.contains(' ') { format!("\"{value}\"") } else { value };
                                let start = p.start;
                                self.query = format!("{}{} ", &self.query[..start], shown);
                                self.last_change = Instant::now() - Duration::from_millis(400);
                                self.cursor_end = true;
                                self.path_pane = None;
                            }
                        }
                    }
                    ui.add_space(4.0);
                }
                if let Some(p) = self.face_pane.as_ref() {
                    let (items, sel, loading, scroll) = (p.items.clone(), p.sel, p.loading, p.scroll_pending);
                    let mut chosen: Option<usize> = None;
                    let cell = 96.0;
                    let gap = 6.0;
                    let pitch = cell + gap;
                    let cols = ((ui.available_width() - 16.0) / pitch).floor().max(1.0) as usize;
                    let rows = items.len().div_ceil(cols);
                    egui::Frame::new().fill(pal.bg).stroke(Stroke::new(1.0, pal.border)).corner_radius(6.0)
                        .inner_margin(Margin::same(8)).show(ui, |ui| {
                            if loading {
                                ui.label(RichText::new("loading faces…").color(pal.dim).size(11.0));
                            } else if items.is_empty() {
                                ui.label(RichText::new("no faces indexed").color(pal.dim).size(11.0));
                            }
                            ui.spacing_mut().item_spacing = egui::vec2(gap, gap);
                            let mut area = egui::ScrollArea::vertical().max_height(300.0).auto_shrink([false, false]);
                            if scroll {
                                area = area.vertical_scroll_offset(((sel / cols) as f32 * pitch - 120.0).max(0.0));
                            }
                            area.show_rows(ui, pitch, rows, |ui, range| {
                                for row in range {
                                    ui.horizontal(|ui| {
                                        for c in 0..cols {
                                            let i = row * cols + c;
                                            let Some((_, thumb)) = items.get(i) else { break };
                                            let (rect, resp) = ui.allocate_exact_size(egui::vec2(cell, cell), egui::Sense::click());
                                            if let Some(tex) = self.texture(&ctx, thumb) {
                                                egui::Image::new(&tex).fit_to_exact_size(rect.size()).paint_at(ui, rect);
                                            }
                                            if i == sel {
                                                ui.painter().rect_stroke(rect.expand(2.0), 4.0, Stroke::new(2.0, pal.accent), egui::StrokeKind::Outside);
                                            }
                                            if resp.clicked() { chosen = Some(i); }
                                        }
                                    });
                                }
                            });
                        });
                    if let Some(p) = self.face_pane.as_mut() {
                        p.cols = cols;
                        p.scroll_pending = false;
                    }
                    if let Some(i) = chosen {
                        if let Some(p) = self.face_pane.take() {
                            if let Some((id, _)) = p.items.get(i) {
                                self.query = format!("{}/face \"@{}\" ", p.prefix, id);
                                self.last_change = Instant::now() - Duration::from_millis(400);
                                self.cursor_end = true;
                            }
                        }
                    }
                    ui.add_space(4.0);
                }
                // results list
                if self.total > 0 && !grid {
                    let (hr, _) = ui.allocate_exact_size(egui::vec2(ui.available_width(), 18.0), egui::Sense::hover());
                    // same left edge as the rows: thumbnail (6 px margin) + gap
                    let frac = self.col_frac;
                    let left = hr.left() + 6.0 + self.thumb + 12.0;
                    let c = cols(left, hr.right(), &frac);
                    let hf = egui::FontId::monospace(10.0);
                    let cur_sort = parse_sort(&self.query).1;
                    let mut columns: Vec<(&str, f32, &str)> = vec![
                        ("name", c.name_x, "NAME"),
                        ("path", c.path_x, "PATH"),
                        ("size", c.size_r, "SIZE"),
                        ("date", c.date_x, "MODIFIED"),
                    ];
                    if show_score { columns.push(("score", c.score_r, "SCORE")); }
                    for (key, x, label) in &columns {
                        let rect = egui::Rect::from_min_max(egui::pos2(*x, hr.top()), egui::pos2(*x + 40.0, hr.bottom()));
                        let resp = ui.interact(rect, egui::Id::new(("hdr", *key)), egui::Sense::click());
                        let primary = cur_sort.explicit && cur_sort.keys.first().map(String::as_str) == Some(*key);
                        let arrow = if primary { if cur_sort.desc { " ▼" } else { " ▲" } } else { "" };
                        ui.painter().text(egui::pos2(*x, hr.top() + 2.0), egui::Align2::LEFT_TOP,
                            format!("{label}{arrow}"), hf.clone(),
                            if primary { pal.accent } else { pal.dim });
                        if resp.clicked() && *key != "score" { self.set_sort(key); }
                    }
                    // drag handles on the boundaries between columns: move width from one column to its neighbour
                    let total = (hr.right() - left).max(1.0);
                    let bounds = [c.path_x, c.size_r, c.date_x, c.score_r];
                    for i in 0..4 {
                        let x = bounds[i];
                        let rect = egui::Rect::from_min_max(egui::pos2(x - 4.0, hr.top()), egui::pos2(x + 4.0, hr.bottom()));
                        let resp = ui.interact(rect, egui::Id::new(("colsep", i)), egui::Sense::drag());
                        if resp.hovered() || resp.dragged() {
                            ui.ctx().set_cursor_icon(egui::CursorIcon::ResizeHorizontal);
                        }
                        if resp.dragged() {
                            let d = resp.drag_delta().x / total;
                            let a = self.col_frac[i] + d;
                            let b = self.col_frac[i + 1] - d;
                            if a >= MIN_FRAC && b >= MIN_FRAC {
                                self.col_frac[i] = a;
                                self.col_frac[i + 1] = b;
                            }
                        }
                        if resp.drag_stopped() { self.save_sort(); }
                    }
                }
                let frac = self.col_frac;
                let mut clicked: Option<(usize, bool)> = None;
                let mut dbl = false;
                let mut right_at: Option<egui::Pos2> = None;
                let mut right_hit: Option<usize> = None;
                if grid {
                    let mut grid_right: Option<(usize, egui::Pos2)> = None;
                    self.grid_view(ui, &ctx, &mut clicked, &mut dbl, &mut grid_right);
                    if let Some((hit, at)) = grid_right {
                        right_hit = Some(hit);
                        right_at = Some(at);
                    }
                } else {
                self.results_h = ui.available_height() - 30.0;
                // one line per result: the row is just tall enough for the thumbnail and text
                let row_h = (self.thumb + 4.0).max(20.0);
                let mut area = egui::ScrollArea::vertical()
                    .max_height(ui.available_height() - 30.0)
                    .auto_shrink([false, false]);
                if self.scroll_pending {
                    let target = self.selected as f32 * row_h - (ui.available_height() - 30.0) * 0.4;
                    area = area.vertical_scroll_offset(target.max(0.0));
                }
                ui.spacing_mut().item_spacing.y = 0.0;
                area.show_rows(ui, row_h, self.total, |ui, range| {
                        self.ensure_rows(range.start, range.end.saturating_sub(1));
                        let thumb = self.thumb;
                        let terms = query_terms(&self.last_sent);
                        for idx in range {
                            let Some(h) = self.hit(idx).cloned() else {
                                ui.allocate_exact_size(egui::vec2(ui.available_width(), row_h), egui::Sense::hover());
                                continue;
                            };
                            let (rect, resp) = ui.allocate_exact_size(
                                egui::vec2(ui.available_width(), row_h),
                                egui::Sense::click(),
                            );
                            let selected = self.in_selection(idx);
                            if !selected && !ui.is_rect_visible(rect) { continue; }
                            if selected {
                                ui.painter().rect_filled(rect, 6.0, pal.accent.gamma_multiply(0.18));
                                ui.painter().rect_filled(
                                    egui::Rect::from_min_size(rect.min, egui::vec2(3.0, rect.height())),
                                    1.0,
                                    pal.accent,
                                );
                            }
                            let thumb_rect = egui::Rect::from_min_size(
                                rect.min + egui::vec2(6.0, (row_h - thumb) / 2.0),
                                egui::vec2(thumb, thumb),
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
                            let c = cols(thumb_rect.right() + 12.0, rect.right(), &frac);
                            let y = rect.center().y;
                            let short = short_name(&h.remote);
                            let (dir, base) = match short.rsplit_once('/') {
                                Some((d, b)) => (d.to_string(), b.to_string()),
                                None => (String::new(), short.clone()),
                            };
                            let txt = if selected { pal.text } else { pal.text.gamma_multiply(0.85) };
                            let dim = pal.dim;
                            let painter = ui.painter();
                            let name_font = egui::FontId::monospace(13.0);
                            let dir_font = egui::FontId::monospace(11.0);
                            let base = fit_text(ui, &base, &name_font, (c.path_x - c.name_x - 8.0).max(0.0));
                            let dir = fit_text(ui, &dir, &dir_font, (c.path_r - c.path_x - 8.0).max(0.0));
                            let name_clip = egui::Rect::from_min_max(egui::pos2(c.name_x, rect.top()), egui::pos2(c.path_x - 4.0, rect.bottom()));
                            let name_galley = painter.layout_job(name_job(&base, &terms, &egui::FontId::monospace(13.0), txt));
                            painter.with_clip_rect(name_clip).galley(egui::pos2(c.name_x, y - name_galley.size().y / 2.0), name_galley, txt);
                            let path_clip = egui::Rect::from_min_max(egui::pos2(c.path_x, rect.top()), egui::pos2(c.path_r - 4.0, rect.bottom()));
                            painter.with_clip_rect(path_clip).text(egui::pos2(c.path_x, y), egui::Align2::LEFT_CENTER, dir, egui::FontId::monospace(11.0), dim);
                            if let Some(sz) = h.size {
                                painter.text(egui::pos2(c.size_r, y), egui::Align2::LEFT_CENTER, human_size(sz), egui::FontId::monospace(11.0), dim);
                            }
                            if let Some(t) = &h.mtime {
                                painter.text(egui::pos2(c.date_x, y), egui::Align2::LEFT_CENTER, short_time(t), egui::FontId::monospace(11.0), dim);
                            }
                            if let (true, Some(s)) = (show_score, h.score) {
                                painter.text(egui::pos2(c.score_r, y), egui::Align2::LEFT_CENTER, format!("{s:.2}"), egui::FontId::monospace(12.0), pal.accent);
                            }
                            if selected {
                            }
                            let shift = ui.input(|i| i.modifiers.shift);
                            self.row_rects.insert(idx, rect);
                            if resp.clicked() { clicked = Some((idx, shift)); }
                            if resp.double_clicked() { dbl = true; clicked = Some((idx, false)); }
                            if resp.secondary_clicked() {
                                right_at = ui.input(|i| i.pointer.interact_pos());
                                right_hit = Some(idx);
                            }
                        }
                        if self.total == 0 && !self.busy {
                            ui.add_space(20.0);
                            ui.label(RichText::new("no matches").color(pal.dim));
                        }
                    });
                }
                if let (Some(hit), Some(at)) = (right_hit, right_at) {
                    // right-click on a row outside the selection selects just that row first
                    if !self.in_selection(hit) { self.anchor = None; self.selected = hit; }
                    self.open_menu(at, hit);
                    self.menu_fresh = true;
                    self.status = "context menu".into();
                }
                if let Some((i, extend)) = clicked { self.move_cursor(i, extend); self.list_focus = true; }
                if dbl { self.open_selected(); }

                ui.add_space(4.0);
                ui.label(
                    RichText::new({
                        let mut line = format!("{} shown", group_digits(self.total));
                        if let (Some(st), true) = (&self.stats, self.total > 0) {
                            line.push_str(&format!(" · {}", human_size(st.size)));
                            if let (Some(a), Some(b)) = (&st.dmin, &st.dmax) {
                                line.push_str(&if a == b { format!(" · {a}") } else { format!(" · {a} → {b}") });
                            }
                            if !st.kinds.is_empty() {
                                let k: Vec<String> = st.kinds.iter().filter(|(n, _)| n != "no ext").map(|(n, c)| format!("{n} {}", group_digits(*c))).collect();
                                if !k.is_empty() { line.push_str(&format!(" · {}", k.join(", "))); }
                            }
                        }
                        line
                    })
                        .color(pal.dim).size(11.0),
                );
            });

        self.scroll_pending = false;
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

#[cfg(test)]
mod sort_tests {
    use super::parse_sort;
    fn p(q: &str) -> (String, String, bool) { let (r, s) = parse_sort(q); (r, s.keys.join(","), s.desc) }
    #[test]
    fn grammar() {
        assert_eq!(p("cat"), ("cat".into(), "date".into(), true));
        assert_eq!(p("cat /s size desc"), ("cat".into(), "size".into(), true));
        assert_eq!(p("/s date-modified /s size"), ("".into(), "date,size".into(), false));
        assert_eq!(p("/sort/dm/size de x"), ("x".into(), "date,size".into(), true));
        assert_eq!(p("/s name blender"), ("blender".into(), "name".into(), false));
        assert_eq!(p("/s nonsense //name a"), ("//name a".into(), "date".into(), true));
        assert_eq!(p("/s size /rv"), ("".into(), "size".into(), true));
        assert_eq!(p("/s size \"a  /s name\" b"), ("\"a  /s name\" b".into(), "size".into(), false));
        assert_eq!(p("!//path /etc"), ("!//path /etc".into(), "date".into(), true));
        assert_eq!(p("!//path /sort /s size"), ("!//path /sort".into(), "size".into(), false));
        assert_eq!(p("//path /etc"), ("//path /etc".into(), "date".into(), true));
        assert_eq!(p("//path / /sort dm asc"), ("//path /".into(), "date".into(), false));
        assert_eq!(p("//path /sort /s size"), ("//path /sort".into(), "size".into(), false));
        assert_eq!(p("/s desc name"), ("".into(), "name".into(), true));
        assert_eq!(p("/s/size desc x"), ("x".into(), "size".into(), true));
        assert_eq!(p("/s d"), ("".into(), "date".into(), true)); // ambiguous (date-modified, depth) -> inert
    }
}
