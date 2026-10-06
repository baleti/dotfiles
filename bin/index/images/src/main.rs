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
const FONT: &str = "/usr/share/fonts/TTF/JetBrainsMono-Regular.ttf";
const TOP: usize = 150;
const GRID_BELOW: f32 = 110.0;

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

/// (column key, descending) from the last session; ("", false) when there is none.
fn load_sort() -> (String, bool) {
    let v: serde_json::Value = std::fs::read_to_string(sort_path()).ok()
        .and_then(|t| serde_json::from_str(&t).ok()).unwrap_or(serde_json::Value::Null);
    let key = v.get("key").and_then(|x| x.as_str()).unwrap_or("").to_string();
    let desc = v.get("desc").and_then(|x| x.as_bool()).unwrap_or(false);
    (key, desc)
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
    q.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Case-insensitive subsequence match (fzf-style fuzzy filter for the history popup).
fn fuzzy_match(hay: &str, needle: &str) -> bool {
    let mut it = hay.chars().flat_map(|c| c.to_lowercase());
    needle.chars().flat_map(|c| c.to_lowercase()).all(|n| it.any(|h| h == n))
}

/// Shortens `text` to fit `width` px in `font`, ending with an ellipsis when it had to be cut.
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
struct Cols { name_x: f32, path_x: f32, path_r: f32, size_r: f32, date_x: f32, score_r: f32 }
const NAME_W: f32 = 210.0;
const SIZE_W: f32 = 84.0;
const DATE_W: f32 = 140.0;
const SCORE_W: f32 = 48.0;
fn cols(left: f32, right: f32) -> Cols {
    // columns are left-aligned: size_r / score_r hold the LEFT edge of those columns
    let score_r = right - SCORE_W;
    let date_x = score_r - 12.0 - DATE_W;
    let size_r = date_x - 12.0 - SIZE_W;
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
    cursor_end: bool,
    seq: u64,
    tx: Sender<Fetch>,
    rx: Receiver<Fetch>,
    hits: Vec<Hit>,
    count: usize,
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
    /// list sort: column key ("" = server order) and direction; remembered between runs
    sort_key: String,
    sort_desc: bool,
    /// thumbnail size in px; Ctrl+wheel / pinch changes it (rows grow and shrink with it)
    thumb: f32,
    /// thumbnail grid instead of the list; toggled with Ctrl+G
    grid_mode: bool,
    popup: bool,
    cands: Vec<(String, String)>, // (replacement text, label)
    cand_sel: usize,
}

#[derive(Deserialize)]
struct PeopleReply {
    people: Vec<String>,
    /// year-months present in the index (for //dm completion) and file kinds (for //mime)
    facets: FacetsReply,
}

/// Completion candidates for the fragment at the end of `q`.
/// Returns (byte index where the fragment starts, candidates).
fn completions(q: &str, people: &[String], facets: &FacetsReply) -> (usize, Vec<(String, String)>) {
    let start = q.rfind(char::is_whitespace).map(|i| i + q[i..].chars().next().unwrap().len_utf8()).unwrap_or(0);
    let frag = &q[start..];
    let prev = q[..start].split_whitespace().last().unwrap_or("");
    let mut out = Vec::new();
    // values for a tag that takes one: (value, label)
    let values_for = |tag: &str| -> Vec<(String, String)> {
        match tag {
            "dm" => facets.dates.iter().map(|d| (d.clone(), "modified in this month".to_string())).collect(),
            "mime" => facets.mimes.iter().map(|m| (m.clone(), "file kind".to_string())).collect(),
            "size" => vec![
                (">100K".into(), "larger than 100 KiB".into()),
                (">1M".into(), "larger than 1 MiB".into()),
                (">10M".into(), "larger than 10 MiB".into()),
                (">100M".into(), "larger than 100 MiB".into()),
                ("<100K".into(), "smaller than 100 KiB".into()),
            ],
            _ => Vec::new(),
        }
    };
    const TAGS: [(&str, &str); 8] = [
        ("face", "photos showing a registered person"),
        ("clip", "photos matching what they show (CLIP text)"),
        ("name", "file name contains"),
        ("path", "folder path contains"),
        ("size", "file size, e.g. >5M or <200K"),
        ("dm", "date modified, pick a month"),
        ("mime", "file kind: image, pdf, text, code, ..."),
        ("file", "file-name search mode"),
    ];
    if let Some(body) = frag.strip_prefix("//") {
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

#[derive(Deserialize, Default)]
struct FacetsReply {
    #[serde(default)]
    dates: Vec<String>,
    #[serde(default)]
    mimes: Vec<String>,
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
        cc.egui_ctx.set_fonts(fonts);
        let (tx, rx) = channel();
        let mut app = Self {
            pal: load_palette(&cfg().scheme),
            query: String::new(),
            last_sent: "\u{0}".into(), // force the first browse request
            last_change: Instant::now() - Duration::from_secs(1),
            cursor_end: false,
            seq: 0,
            tx,
            rx,
            hits: Vec::new(),
            count: 0,
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
            sort_key: load_sort().0,
            sort_desc: load_sort().1,
            thumb: 20.0,
            grid_mode: false,
            popup: false,
            cands: Vec::new(),
            cand_sel: 0,
        };
        app.people = fetch_people();
        app.facets = fetch_facets();
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
            let url = format!("{}/query", cfg().server);
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
                    self.apply_sort();
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

    /// Indices of all selected rows (the cursor alone when there is no range).
    fn selection(&self) -> Vec<usize> {
        match self.anchor {
            Some(a) => {
                let (lo, hi) = (a.min(self.selected), a.max(self.selected));
                (lo..=hi).filter(|i| *i < self.hits.len()).collect()
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
            let Some(h) = self.hits.get(i) else { continue };
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
        let gone: std::collections::HashSet<String> = files.iter().map(|(p, _)| p.display().to_string()).collect();
        self.hits.retain(|h| !(gone.contains(&h.remote) && !failed.contains(&h.remote)));
        self.anchor = None;
        self.selected = self.selected.min(self.hits.len().saturating_sub(1));
        self.status = if failed.is_empty() {
            format!("moved {ok} file(s) to the trash")
        } else {
            format!("moved {ok} file(s) to the trash; {} failed: {}", failed.len(), failed.join(", "))
        };
    }

    fn open_hit(&mut self, idx: usize) {
        let Some(h) = self.hits.get(idx).cloned() else { return };
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
        self.menu_mime = self.hits.get(hit)
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
        self.props_mime = self.hits.get(idx).map(|h| {
            let l = local_path(&h.remote);
            if l.exists() { mime_of(&l) } else { "not available locally".into() }
        }).unwrap_or_default();
        self.props = Some(idx);
    }

    fn open_selected(&mut self) {
        self.open_hit(self.selected);
    }

    /// Clicking a header: the same column flips the direction, another column sorts ascending.
    fn set_sort(&mut self, key: &str) {
        if self.sort_key == key {
            self.sort_desc = !self.sort_desc;
        } else {
            self.sort_key = key.to_string();
            self.sort_desc = false;
        }
        self.apply_sort();
        let _ = std::fs::create_dir_all(PathBuf::from(&cfg().data_dir));
        let _ = std::fs::write(sort_path(), serde_json::json!({"key": self.sort_key, "desc": self.sort_desc}).to_string());
    }

    fn apply_sort(&mut self) {
        if self.sort_key.is_empty() { return; }
        let key = self.sort_key.clone();
        let desc = self.sort_desc;
        self.hits.sort_by(|a, b| {
            let ord = match key.as_str() {
                "name" => short_name(&a.remote).rsplit('/').next().unwrap_or("").to_lowercase()
                    .cmp(&short_name(&b.remote).rsplit('/').next().unwrap_or("").to_lowercase()),
                "path" => short_name(&a.remote).to_lowercase().cmp(&short_name(&b.remote).to_lowercase()),
                "size" => a.size.unwrap_or(0).cmp(&b.size.unwrap_or(0)),
                "date" => a.mtime.clone().unwrap_or_default().cmp(&b.mtime.clone().unwrap_or_default()),
                "score" => a.score.unwrap_or(0.0).partial_cmp(&b.score.unwrap_or(0.0)).unwrap_or(std::cmp::Ordering::Equal),
                _ => std::cmp::Ordering::Equal,
            };
            if desc { ord.reverse() } else { ord }
        });
        self.selected = self.selected.min(self.hits.len().saturating_sub(1));
    }

    /// Thumbnail grid for zoomed-out views: square cells, score under each.
    fn grid_view(&mut self, ui: &mut egui::Ui, ctx: &egui::Context, hits: &[Hit], sel: &[usize],
                 clicked: &mut Option<(usize, bool)>, dbl: &mut bool, right: &mut Option<(usize, egui::Pos2)>) {
        let pal = self.pal;
        let t = self.thumb;
        egui::ScrollArea::vertical()
            .max_height(ui.available_height() - 28.0)
            .auto_shrink([false, false])
            .show(ui, |ui| {
                ui.spacing_mut().item_spacing = egui::vec2(8.0, 8.0);
                ui.horizontal_wrapped(|ui| {
                    for (idx, h) in hits.iter().enumerate() {
                        let (rect, resp) = ui.allocate_exact_size(egui::vec2(t, t + 14.0), egui::Sense::click());
                        let img = egui::Rect::from_min_size(rect.min, egui::vec2(t, t));
                        let selected = sel.contains(&idx);
                        match self.texture(ctx, &h.thumb) {
                            Some(tex) => { egui::Image::new(&tex).fit_to_exact_size(img.size()).paint_at(ui, img); }
                            None => { ui.painter().rect_filled(img, 4.0, pal.border.gamma_multiply(0.5)); }
                        }
                        if selected {
                            ui.painter().rect_stroke(img.expand(2.0), 4.0, Stroke::new(2.0, pal.accent), egui::StrokeKind::Outside);
                            ui.scroll_to_rect(rect, Some(egui::Align::Center));
                        }
                        if let Some(sc) = h.score {
                            ui.painter().text(egui::pos2(rect.left() + 2.0, img.bottom() + 1.0), egui::Align2::LEFT_TOP,
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
            });
    }

    /// Ctrl+Enter: show the photo selected in Dolphin, at its real folder on the gdrive mount.
    fn reveal_selected(&mut self) {
        let Some(h) = self.hits.get(self.selected).cloned() else { return };
        let rel = short_name(&h.remote);
        let local = format!("{}/{}", cfg().mount_root, rel);
        std::thread::spawn(move || {
            // dolphin --select opens the folder with the file highlighted; fall back to the folder alone
            let ok = std::process::Command::new("dolphin").arg("--select").arg(&local).spawn().is_ok();
            if !ok {
                if let Some(dir) = Path::new(&local).parent() {
                    let _ = std::process::Command::new("xdg-open").arg(dir).spawn();
                }
            }
        });
    }

    fn copy_selection(&mut self, cut: bool) {
        let paths: Vec<PathBuf> = self.selection().into_iter()
            .filter_map(|i| self.hits.get(i)).map(|h| local_path(&h.remote))
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
            let (start, _) = completions(&self.query, &self.people, &self.facets);
            self.query = apply(&self.query, start, &rep);
            self.last_change = Instant::now() - Duration::from_millis(200);
            self.cursor_end = true;
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
    // "gdrive-crypt:photos/<folder>/<file>.jpg" -> "photos/<folder>/<file>.jpg"
    remote.split_once(':').map(|(_, p)| p.trim_start_matches('/')).unwrap_or(remote).to_string()
}

impl eframe::App for App {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        let pal = self.pal;
        // Ctrl+wheel and trackpad pinch: zoom the thumbnails, not the whole UI
        let zd = ui.input(|i| i.zoom_delta());
        if (zd - 1.0).abs() > 1e-4 {
            self.thumb = (self.thumb * zd).clamp(16.0, 260.0);
        }
        ctx.set_zoom_factor(1.0);
        let grid = self.grid_mode;
        // Ctrl+G toggles the thumbnail grid (the list is the default at every zoom level)
        if ui.input_mut(|i| i.consume_key(egui::Modifiers::CTRL, Key::G)) {
            self.grid_mode = !self.grid_mode;
        }
        // the score column only exists for photo results
        let show_score = self.hits.iter().any(|h| h.score.is_some());

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

        // Delete: only when the confirmation dialog is closed
        let del = self.trash_pending.is_none() && ui.input(|i| i.key_pressed(Key::Delete));
        if del && !self.popup && !self.hits.is_empty() {
            self.request_trash();
        }

        // Shift+arrows extend the list selection; consume them before the query box sees them
        let shift_down = ui.input_mut(|i| i.consume_key(egui::Modifiers::SHIFT, Key::ArrowDown));
        let shift_up = ui.input_mut(|i| i.consume_key(egui::Modifiers::SHIFT, Key::ArrowUp));
        let _shift_left = ui.input_mut(|i| i.consume_key(egui::Modifiers::SHIFT, Key::ArrowLeft));
        let _shift_right = ui.input_mut(|i| i.consume_key(egui::Modifiers::SHIFT, Key::ArrowRight));

        // completion keys: consumed before the text edit sees them (so Tab does not move focus)
        let tab = ui.input_mut(|i| i.consume_key(egui::Modifiers::NONE, Key::Tab));
        let ctrl_space = ui.input_mut(|i| i.consume_key(egui::Modifiers::CTRL, Key::Space));
        if (tab || ctrl_space) && !self.popup {
            let (start, cands) = completions(&self.query, &self.people, &self.facets);
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
            let (_, cands) = completions(&self.query, &self.people, &self.facets);
            if cands.is_empty() { self.popup = false; } else { self.cands = cands; self.cand_sel = 0; }
        }

        // keys (only the ones the list owns; typing goes to the query box)
        let n = self.hits.len();
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
            let cols = if grid { ((ui.available_width() / (self.thumb + 10.0)).floor() as usize).max(1) } else { 1 };
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
            if shift_down { delta += cols as i64; extend = true; any = true; }
            if shift_up { delta -= cols as i64; extend = true; any = true; }
            if pgdn { delta += 8; any = true; }
            if pgup { delta -= 8; any = true; }
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
            let local = self.hits.get(hit).map(|h| local_path(&h.remote));
            let mime = self.menu_mime.clone();
            // photo results (they carry a score) can search for the face in them
            let face_remote = self.hits.get(hit).filter(|h| h.score.is_some()).map(|h| h.remote.clone());
            let mut face_query: Option<String> = None;
            let mut chosen: Option<(String, PathBuf)> = None;
            let area = egui::Area::new(egui::Id::new("ctxmenu"))
                .order(egui::Order::Foreground)
                .fixed_pos(at)
                .show(&ctx, |ui| {
                    egui::Frame::popup(ui.style()).show(ui, |ui| {
                        if let Some(r) = &face_remote {
                            if ui.button("Search for this face").clicked() {
                                face_query = Some(format!("//face \"@{}\"", r));
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
            match self.hits.get(idx).cloned() {
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
                            ui.label(RichText::new("history: enter replaces the search · esc closes").color(pal.dim).size(10.0));
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
                ui.add_space(6.0);
                ui.label(RichText::new(&self.status).color(if self.busy { pal.dim } else { pal.dim }).size(12.0));
                ui.add_space(4.0);

                // results list
                if !self.hits.is_empty() && !grid {
                    let (hr, _) = ui.allocate_exact_size(egui::vec2(ui.available_width(), 18.0), egui::Sense::hover());
                    // same left edge as the rows: thumbnail (6 px margin) + gap
                    let c = cols(hr.left() + 6.0 + self.thumb + 12.0, hr.right());
                    let hf = egui::FontId::monospace(10.0);
                    let mut columns: Vec<(&str, f32, f32, &str)> = vec![
                        ("name", c.name_x, NAME_W, "NAME"),
                        ("path", c.path_x, (c.path_r - c.path_x).max(0.0), "PATH"),
                        ("size", c.size_r, SIZE_W, "SIZE"),
                        ("date", c.date_x, DATE_W, "MODIFIED"),
                    ];
                    if show_score { columns.push(("score", c.score_r, SCORE_W, "SCORE")); }
                    for (key, x, w, label) in columns {
                        let rect = egui::Rect::from_min_size(egui::pos2(x, hr.top()), egui::vec2(w, 18.0));
                        let resp = ui.interact(rect, egui::Id::new(("hdr", key)), egui::Sense::click());
                        let arrow = if self.sort_key == key { if self.sort_desc { " ▼" } else { " ▲" } } else { "" };
                        ui.painter().text(egui::pos2(x, hr.top() + 2.0), egui::Align2::LEFT_TOP,
                            format!("{label}{arrow}"), hf.clone(),
                            if self.sort_key == key { pal.accent } else { pal.dim });
                        if resp.clicked() { self.set_sort(key); }
                    }
                }
                let hits = self.hits.clone();
                let sel_set: std::collections::HashSet<usize> = self.selection().into_iter().collect();
                let mut clicked: Option<(usize, bool)> = None;
                let mut dbl = false;
                let mut right_at: Option<egui::Pos2> = None;
                let mut right_hit: Option<usize> = None;
                if grid {
                    let sel_v: Vec<usize> = self.selection();
                    let mut grid_right: Option<(usize, egui::Pos2)> = None;
                    self.grid_view(ui, &ctx, &hits, &sel_v, &mut clicked, &mut dbl, &mut grid_right);
                    if let Some((hit, at)) = grid_right {
                        right_hit = Some(hit);
                        right_at = Some(at);
                    }
                } else {
                egui::ScrollArea::vertical()
                    .max_height(ui.available_height() - 28.0)
                    .auto_shrink([false, false])
                    .show(ui, |ui| {
                        // one line per result: the row is just tall enough for the thumbnail and text
                        let row_h = (self.thumb + 4.0).max(20.0);
                        let thumb = self.thumb;
                        for (idx, h) in hits.iter().enumerate() {
                            let (rect, resp) = ui.allocate_exact_size(
                                egui::vec2(ui.available_width(), row_h),
                                egui::Sense::click(),
                            );
                            let selected = sel_set.contains(&idx);
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
                            let c = cols(thumb_rect.right() + 12.0, rect.right());
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
                            let base = fit_text(ui, &base, &name_font, NAME_W - 4.0);
                            let dir = fit_text(ui, &dir, &dir_font, (c.path_r - c.path_x - 4.0).max(0.0));
                            let name_clip = egui::Rect::from_min_max(egui::pos2(c.name_x, rect.top()), egui::pos2(c.name_x + NAME_W, rect.bottom()));
                            painter.with_clip_rect(name_clip).text(egui::pos2(c.name_x, y), egui::Align2::LEFT_CENTER, base, egui::FontId::monospace(13.0), txt);
                            let path_clip = egui::Rect::from_min_max(egui::pos2(c.path_x, rect.top()), egui::pos2(c.path_r, rect.bottom()));
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
                                ui.scroll_to_rect(rect, Some(egui::Align::Center));
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
                        if hits.is_empty() && !self.busy {
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
