//! The app launcher (bound to the Super key) as its own small native process: sctk layer shell,
//! tiny-skia, fractional scaling, desktop entries with icons, launch-frecency ranking from the
//! Quickshell launcher's history file, and the shared picker DSL (../../dsl/rs): `/fv /s /g`
//! filters, sort and sections, completion, search-box history, plus the workspace actions
//! (`/move-to-workspace`, `/move-workspace`, `/add-workspace`).
//! Launches and accepted queries are written straight to ~/.cache/quickshell/launcher-history.json
//! and launcher-query-history.json (this process is their only writer now).
//!
//! The desktop entries are scanned on a worker thread, so the card and search box appear (and
//! accept typing) before the list is filled. Timings go to ~/.cache/launcher-ui.log.

use std::collections::{HashMap, HashSet};
use std::io::BufReader;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Instant;

use ab_glyph::{point, Font, FontRef, PxScale, ScaleFont};
use smithay_client_toolkit::reexports::calloop::channel::{self, Event as ChanEvent, Sender};
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

const FONT_PX: f32 = 12.0; // Theme.fontSize - 1 (the name text)
const ICON_PX: u32 = 48; // icons are rasterized once at this size and scaled down when drawn
const QUERY_PX: f32 = 14.0; // Theme.fontSize + 1
const HEADER_H: i32 = 44;
const ROW_H: i32 = 30;

struct DApp {
    id: String,
    name: String,
    generic: String,
    comment: String,
    categories: Vec<String>,
    keywords: Vec<String>,
    icon: String,
    exec: String,
    terminal: bool,
    path: Option<String>,
}

type Hist = HashMap<String, (u32, i64)>; // id -> (count, last unix seconds)

enum Msg {
    Apps { apps: Vec<DApp>, hist: Hist, ms: f64 },
    Icon { name: String, w: u32, h: u32, data: Vec<u8> },
    Icons(Vec<(String, Vec<u8>)>),
    QHistory(Vec<String>),
    Hypr(HyprInfo),
}

/// What the workspace actions need from Hyprland, fetched off the main thread at start.
#[derive(Default, Clone)]
struct HyprInfo {
    workspaces: Vec<HWorkspace>,
    active_addr: String,
    active_ws: i64,
}

#[derive(Clone)]
struct HWorkspace {
    id: i64,
    name: String,
    monitor: String,
    windows: usize,
    classes: Vec<String>,
}

#[derive(Clone, Copy, PartialEq)]
enum ActionKind {
    /// move the window that was focused when the launcher opened
    Window,
    /// move the current workspace after another
    Workspace,
}

/// A row of the workspace list.
#[derive(Clone)]
struct WsRow {
    name: String,
    target: String,
    id: Option<i64>,
    cnt: i64, // -1 = no count (the "new workspace" row)
    mon: String,
    apps: String,
    create: bool,
}

/// Typing the full verb swaps the results for the workspace list; whatever follows it filters / names.
fn action_match(q: &str) -> Option<(ActionKind, String)> {
    let t = q.trim_start();
    for (verb, kind) in [("/move-to-workspace", ActionKind::Window), ("/move-workspace", ActionKind::Workspace)] {
        if let Some(rest) = t.strip_prefix(verb) {
            if rest.is_empty() {
                return Some((kind, String::new()));
            }
            if rest.starts_with(char::is_whitespace) {
                return Some((kind, rest.trim().to_string()));
            }
        }
    }
    None
}

const ACTION_VERBS: [&str; 3] = ["/move-to-workspace", "/move-workspace", "/add-workspace"];

/// What to run once the surface is gone.
enum Pending {
    Launch(usize),
    MoveToWorkspace(WsRow, String),
    MoveWorkspaceAfter(WsRow, i64),
    AddWorkspace(String, i64),
}

fn hypr_json(args: &[&str]) -> serde_json::Value {
    Command::new("hyprctl")
        .arg("-j")
        .args(args)
        .stderr(Stdio::null())
        .output()
        .ok()
        .and_then(|o| serde_json::from_slice(&o.stdout).ok())
        .unwrap_or(serde_json::Value::Null)
}

fn fetch_hypr() -> HyprInfo {
    let clients = hypr_json(&["clients"]);
    let mut by_ws: HashMap<i64, Vec<String>> = HashMap::new();
    for c in clients.as_array().into_iter().flatten() {
        let (id, class) = (c["workspace"]["id"].as_i64().unwrap_or(-1), c["class"].as_str().unwrap_or(""));
        let v = by_ws.entry(id).or_default();
        if !class.is_empty() && !v.iter().any(|x| x == class) {
            v.push(class.to_string());
        }
    }
    let workspaces = hypr_json(&["workspaces"])
        .as_array()
        .into_iter()
        .flatten()
        .map(|w| {
            let id = w["id"].as_i64().unwrap_or(-1);
            HWorkspace {
                id,
                name: w["name"].as_str().unwrap_or("").to_string(),
                monitor: w["monitor"].as_str().unwrap_or("").to_string(),
                windows: w["windows"].as_u64().unwrap_or(0) as usize,
                classes: by_ws.get(&id).cloned().unwrap_or_default(),
            }
        })
        .collect();
    let aw = hypr_json(&["activewindow"]);
    HyprInfo { workspaces, active_addr: aw["address"].as_str().unwrap_or("").to_string(), active_ws: aw["workspace"]["id"].as_i64().unwrap_or(-1) }
}

fn lua_str(s: &str) -> String {
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
}

fn run_repl(lua: &str) {
    let _ = Command::new("hyprctl").args(["repl", lua]).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).status();
    // workspaces created/renamed through repl can leave Quickshell's workspace model stale
    let _ = Command::new("hyprctl").args(["dispatch", "exec", "true"]).stdout(Stdio::null()).stderr(Stdio::null()).status();
}

fn move_to_workspace_lua(addr: &str, row: &WsRow) -> String {
    let addr = addr.trim_start_matches("0x");
    let find = format!(
        "for _, w in ipairs(hl.get_windows()) do if tostring(w.address):gsub('^0x', '') == {} then ",
        lua_str(addr)
    );
    let t = &row.target;
    if row.create {
        // Hyprland orders workspaces by integer id and can't renumber: the smallest unused id above the
        // window's workspace, then named via rename
        format!(
            "{find}local used = {{}} for _, x in ipairs(hl.get_workspaces()) do used[x.id] = true end \
             local id = w.workspace.id + 1 while used[id] do id = id + 1 end \
             hl.dispatch(hl.dsp.window.move({{ workspace = id, window = w }})) \
             hl.dispatch(hl.dsp.workspace.rename({{ workspace = id, name = {} }})) break end end",
            lua_str(t)
        )
    } else {
        let ws = match row.id {
            Some(id) => id.to_string(),
            None if t.chars().all(|c| c.is_ascii_digit()) && !t.is_empty() => t.clone(),
            None => lua_str(&format!("name:{t}")),
        };
        format!("{find}hl.dispatch(hl.dsp.window.move({{ workspace = {ws}, window = w }})) break end end")
    }
}

fn move_workspace_after_lua(row: &WsRow, cur: i64) -> String {
    let id = row.id.unwrap_or(0);
    format!(
        "local cur = hl.get_workspace({cur}) local name = cur and cur.name or '' \
         local used = {{}} for _, x in ipairs(hl.get_workspaces()) do used[x.id] = true end \
         local id = {id} + 1 while used[id] and id ~= {cur} do id = id + 1 end \
         if id == {cur} then return end \
         for _, w in ipairs(hl.get_windows()) do if w.workspace.id == {cur} then hl.dispatch(hl.dsp.window.move({{ workspace = id, window = w, follow = false }})) end end \
         hl.dispatch(hl.dsp.workspace.rename({{ workspace = id, name = name }})) \
         hl.dispatch(hl.dsp.focus({{ workspace = id }}))"
    )
}

fn add_workspace_lua(target: &str, cur: i64) -> String {
    format!(
        "local cur = hl.get_workspace({cur}) \
         local used, names = {{}}, {{}} for _, x in ipairs(hl.get_workspaces()) do used[x.id] = true names[tostring(x.name)] = true end \
         local name = {} \
         if name == '' then local base = cur and tonumber(cur.name) or 0 \
         local n = math.floor(base) + 1 while names[tostring(n)] or used[n] do n = n + 1 end name = tostring(n) end \
         if names[name] then return end \
         local anchor = cur and cur.id or 0 \
         local id = anchor + 1 \
         if used[id] then local k = id while used[k + 1] do k = k + 1 end local ok = true \
         local by = {{}} for _, w in ipairs(hl.get_windows()) do local wid = w.workspace.id \
         if wid >= id and wid <= k then if w.group then ok = false end by[wid] = by[wid] or {{}} table.insert(by[wid], w) end end \
         for _, m in ipairs(hl.get_monitors()) do local a = m.active_workspace if a and a.id >= id and a.id <= k and not m.focused then ok = false end end \
         if ok then local nm = {{}} for _, x in ipairs(hl.get_workspaces()) do nm[x.id] = x.name end \
         for i = k, id, -1 do if by[i] then for _, w in ipairs(by[i]) do hl.dispatch(hl.dsp.window.move({{ workspace = i + 1, window = w, follow = false }})) end \
         hl.dispatch(hl.dsp.workspace.rename({{ workspace = i + 1, name = nm[i] }})) end end \
         else while used[id] do id = id + 1 end end end \
         hl.dispatch(hl.dsp.focus({{ workspace = id }})) \
         hl.dispatch(hl.dsp.workspace.rename({{ workspace = id, name = name }}))",
        lua_str(target)
    )
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

/// The picker query DSL (~/.config/dsl/rs): this launcher's type vocabulary. The column verbs stay
/// parseable (inert here, as in the Quickshell launcher) but are not offered in completion.
fn make_schema() -> pickerdsl::Schema {
    let mut sc = pickerdsl::Schema::new(&["name", "generic", "comment", "exec", "categories", "keywords"], vec![]);
    sc.hidden_verbs = ["ft", "at", "rt"].map(String::from).to_vec();
    sc.extra_universe = ACTION_VERBS.iter().map(|v| v[1..].to_string()).collect();
    sc.type_descs = [
        ("name", "the application name"),
        ("generic", "the generic name (\"Web Browser\")"),
        ("comment", "the freedesktop Comment= description"),
        ("exec", "the launch command"),
        ("categories", "freedesktop Categories= entries"),
        ("keywords", "freedesktop Keywords= entries"),
        ("move-to-workspace", "move focused window to a workspace"),
        ("move-workspace", "move this workspace after another"),
        ("add-workspace", "add an empty workspace after this one"),
    ]
    .map(|(a, b)| (a.to_string(), b.to_string()))
    .to_vec();
    sc
}

/// Desktop entries as rows for the DSL engine. `name` and `generic` are also the free-text
/// haystack; the other types are scoped-only (prose Comment= made `ala` hit "scalable").
struct AppSrc<'a>(&'a [DApp]);

impl pickerdsl::Source for AppSrc<'_> {
    fn value(&self, row: usize, ty: &str) -> String {
        self.values(row, ty).into_iter().next().unwrap_or_default()
    }
    fn values(&self, row: usize, ty: &str) -> Vec<String> {
        let a = &self.0[row];
        match ty {
            "name" => vec![a.name.clone()],
            "generic" => vec![a.generic.clone()],
            "comment" => vec![a.comment.clone()],
            "exec" => vec![a.exec.clone()],
            "categories" => a.categories.clone(),
            "keywords" => a.keywords.clone(),
            _ => vec![],
        }
    }
    fn haystack(&self, row: usize) -> String {
        format!("{} {}", self.0[row].name, self.0[row].generic)
    }
}

// ---- desktop entries ----

fn parse_desktop(id: &str, text: &str) -> Option<DApp> {
    let mut in_entry = false;
    let (mut name, mut generic, mut exec, mut typ) = (String::new(), String::new(), String::new(), String::new());
    let mut icon = String::new();
    let (mut comment, mut categories, mut keywords) = (String::new(), vec![], vec![]);
    let split = |v: &str| v.split(';').map(str::trim).filter(|x| !x.is_empty()).map(String::from).collect::<Vec<_>>();
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
            "Icon" => icon = v.trim().to_string(),
            "Comment" => comment = v.trim().to_string(),
            "Categories" => categories = split(v),
            "Keywords" => keywords = split(v),
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
    Some(DApp { id: id.to_string(), name, generic, comment, categories, keywords, icon, exec, terminal, path })
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
/// Atomic JSON write (tmp + rename), as the Quickshell singletons' FileView did.
fn write_json_atomic(path: &Path, v: &serde_json::Value) {
    let tmp = path.with_extension("json.tmp");
    if std::fs::write(&tmp, serde_json::to_string(v).unwrap_or_default()).is_ok() {
        let _ = std::fs::rename(&tmp, path);
    }
}

/// A launch counts toward the frecency file: { id: {count, last} }.
fn bump_launch(id: &str) {
    if id.is_empty() {
        return;
    }
    let path = home().join(".cache/quickshell/launcher-history.json");
    let mut v: serde_json::Value = std::fs::read_to_string(&path).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_else(|| serde_json::json!({}));
    let Some(map) = v.as_object_mut() else { return };
    let count = map.get(id).and_then(|e| e["count"].as_u64()).unwrap_or(0) + 1;
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs());
    map.insert(id.to_string(), serde_json::json!({ "count": count, "last": now }));
    let _ = std::fs::create_dir_all(path.parent().unwrap());
    write_json_atomic(&path, &v);
}

/// An accepted query joins the search-box history (whitespace reduced, earlier duplicate dropped,
/// re-appended as the most recent).
fn record_query(q: &str) {
    let q = q.split_whitespace().collect::<Vec<_>>().join(" ");
    if q.is_empty() {
        return;
    }
    let path = home().join(".cache/quickshell/launcher-query-history.json");
    let mut h: Vec<String> = std::fs::read_to_string(&path).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default();
    h.retain(|e| *e != q);
    h.push(q);
    let _ = std::fs::create_dir_all(path.parent().unwrap());
    write_json_atomic(&path, &serde_json::json!(h));
}

fn score(hist: &Hist, id: &str) -> i64 {
    let Some(&(count, last)) = hist.get(id) else { return 0 };
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
    let age_days = if last > 0 { (now - last) as f64 / 86400.0 } else { 9999.0 };
    let recency = if age_days < 3.0 { 3 } else if age_days < 14.0 { 2 } else if age_days < 60.0 { 1 } else { 0 };
    count as i64 * 4 + recency
}

// ---- icons ----
// Names resolve to files through the Quickshell launcher's existing script (its theme priority
// list is the policy: Papirus, Tela, breeze, Adwaita, hicolor); the answers are cached on disk,
// so only names not seen before ever reach the script.

fn icon_cache_path() -> PathBuf {
    home().join(".cache/launcher-ui/icons.json")
}

fn resolve_icons(names: &[String]) -> HashMap<String, String> {
    let mut cache: HashMap<String, String> =
        std::fs::read_to_string(icon_cache_path()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default();
    let missing: Vec<&String> = names
        .iter()
        .filter(|n| !n.starts_with('/') && !cache.get(*n).is_some_and(|p| p.is_empty() || Path::new(p).exists()))
        .collect();
    if !missing.is_empty() {
        let out = Command::new("python3").arg(home().join(".config/quickshell/scripts/resolve-icons.py")).args(&missing).stderr(Stdio::null()).output();
        if let Ok(o) = out {
            if let Ok(found) = serde_json::from_slice::<HashMap<String, String>>(&o.stdout) {
                // names that resolve to nothing are remembered too (""), so they never respawn the script
                for n in &missing {
                    cache.entry((*n).clone()).or_default();
                }
                cache.extend(found);
                let _ = std::fs::create_dir_all(home().join(".cache/launcher-ui"));
                let _ = std::fs::write(icon_cache_path(), serde_json::to_string(&cache).unwrap_or_default());
            }
        }
    }
    for n in names {
        if n.starts_with('/') {
            cache.insert(n.clone(), n.clone());
        }
    }
    cache
}

/// load_icon() through an on-disk raster cache: raw premultiplied RGBA per icon, reused while it is
/// newer than the source file, so a launch reads ~9 KB per icon instead of decoding PNG/SVG again.
fn icon_key(name: &str) -> String {
    name.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '.' { c } else { '_' }).collect()
}

fn raster_dir() -> PathBuf {
    home().join(".cache/launcher-ui/raster")
}

/// Every cached raster, read in one go at start (before the desktop entries are even scanned), so
/// the first frame that shows rows already has their icons.
fn preload_rasters() -> Vec<(String, Vec<u8>)> {
    let suffix = format!(".{ICON_PX}.rgba");
    let Ok(rd) = std::fs::read_dir(raster_dir()) else { return vec![] };
    rd.filter_map(|e| {
        let e = e.ok()?;
        let name = e.file_name().to_string_lossy().to_string();
        let key = name.strip_suffix(&suffix)?.to_string();
        let d = std::fs::read(e.path()).ok().filter(|d| d.len() == (ICON_PX * ICON_PX * 4) as usize)?;
        Some((key, d))
    })
    .collect()
}

/// load_icon() through an on-disk raster cache: raw premultiplied RGBA per icon, reused while it is
/// newer than the source file. Returns the pixels only when they were (re)decoded just now; an
/// up-to-date raster was already delivered by preload_rasters().
fn cached_icon(name: &str, path: &str) -> Option<(u32, u32, Vec<u8>)> {
    let file = raster_dir().join(format!("{}.{ICON_PX}.rgba", icon_key(name)));
    let src_m = std::fs::metadata(path).and_then(|m| m.modified()).ok()?;
    if std::fs::metadata(&file).and_then(|m| m.modified()).is_ok_and(|m| m >= src_m) {
        return None;
    }
    let (w, h, data) = load_icon(path)?;
    let _ = std::fs::create_dir_all(file.parent()?);
    let _ = std::fs::write(&file, &data);
    Some((w, h, data))
}

/// An icon file as premultiplied RGBA at ICON_PX x ICON_PX (aspect kept, centered).
fn load_icon(path: &str) -> Option<(u32, u32, Vec<u8>)> {
    let sz = ICON_PX;
    if path.ends_with(".svg") {
        let data = std::fs::read(path).ok()?;
        let tree = resvg::usvg::Tree::from_data(&data, &resvg::usvg::Options::default()).ok()?;
        let size = tree.size();
        let k = (sz as f32 / size.width()).min(sz as f32 / size.height());
        let mut pm = resvg::tiny_skia::Pixmap::new(sz, sz)?;
        let tf = resvg::tiny_skia::Transform::from_row(k, 0.0, 0.0, k, (sz as f32 - size.width() * k) / 2.0, (sz as f32 - size.height() * k) / 2.0);
        resvg::render(&tree, tf, &mut pm.as_mut());
        return Some((sz, sz, pm.take()));
    }
    if !path.ends_with(".png") {
        return None; // xpm: not supported
    }
    let file = std::fs::File::open(path).ok()?;
    let mut dec = png::Decoder::new(BufReader::new(file));
    dec.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    let mut reader = dec.read_info().ok()?;
    let mut buf = vec![0u8; reader.output_buffer_size()?];
    let info = reader.next_frame(&mut buf).ok()?;
    let (sw, sh) = (info.width as usize, info.height as usize);
    let ch = match info.color_type {
        png::ColorType::Rgba => 4,
        png::ColorType::Rgb => 3,
        png::ColorType::GrayscaleAlpha => 2,
        png::ColorType::Grayscale => 1,
        _ => return None,
    };
    if sw == 0 || sh == 0 {
        return None;
    }
    let px = |x: usize, y: usize| -> [u32; 4] {
        let i = (y * sw + x) * ch;
        match ch {
            4 => [buf[i] as u32, buf[i + 1] as u32, buf[i + 2] as u32, buf[i + 3] as u32],
            3 => [buf[i] as u32, buf[i + 1] as u32, buf[i + 2] as u32, 255],
            2 => [buf[i] as u32, buf[i] as u32, buf[i] as u32, buf[i + 1] as u32],
            _ => [buf[i] as u32, buf[i] as u32, buf[i] as u32, 255],
        }
    };
    let k = (sz as f32 / sw as f32).min(sz as f32 / sh as f32);
    let (dw, dh) = (((sw as f32 * k).round() as usize).clamp(1, sz as usize), ((sh as f32 * k).round() as usize).clamp(1, sz as usize));
    let (ox, oy) = ((sz as usize - dw) / 2, (sz as usize - dh) / 2);
    let mut out = vec![0u8; (sz * sz * 4) as usize];
    for dy in 0..dh {
        let (y0, y1) = (dy * sh / dh, ((dy + 1) * sh / dh).max(dy * sh / dh + 1).min(sh));
        for dx in 0..dw {
            let (x0, x1) = (dx * sw / dw, ((dx + 1) * sw / dw).max(dx * sw / dw + 1).min(sw));
            let (mut r, mut g, mut b, mut a, mut n) = (0u32, 0u32, 0u32, 0u32, 0u32);
            for y in y0..y1 {
                for x in x0..x1 {
                    let v = px(x, y);
                    // premultiplied accumulation
                    r += v[0] * v[3] / 255;
                    g += v[1] * v[3] / 255;
                    b += v[2] * v[3] / 255;
                    a += v[3];
                    n += 1;
                }
            }
            let o = ((oy + dy) * sz as usize + ox + dx) * 4;
            out[o] = (r / n) as u8;
            out[o + 1] = (g / n) as u8;
            out[o + 2] = (b / n) as u8;
            out[o + 3] = (a / n) as u8;
        }
    }
    Some((sz, sz, out))
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

struct Ac {
    comp: pickerdsl::Completion,
    items: Vec<String>,
    sel: usize,
}

const AC_ROW_H: i32 = 24;
const WS_HEAD_H: i32 = 18;
const WS_CARD_W: i32 = 780;
const WS_COL_ID: f32 = 56.0;
const WS_COL_WIN: f32 = 64.0;
const WS_COL_MON: f32 = 96.0;
const WS_COL_APPS: f32 = 260.0;

/// One entry of the grouped display.
#[derive(Clone)]
enum Disp {
    Head { depth: usize, id: String, label: String, count: usize, folded: bool },
    Row(usize), // position in `results`
}

/// What a list row shows.
enum Entry {
    App(usize), // position in `results`
    Head(usize), // index in `disp`
    Ws(usize),
}

enum Hit {
    Item(usize),
    Head(String),
    Pop(usize),
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
    icons: HashMap<String, Pixmap>,
    qhist: Vec<String>, // search-box history, oldest first (the Quickshell launcher owns the file)
    hist_idx: i32,      // -1 = on the draft, not cycling
    hist_draft: String,
    walked: bool,       // Down walked the results: Up walks them back before it recalls history
    schema: pickerdsl::Schema,
    ac: Option<Ac>,
    ac_multi: Option<pickerdsl::Completion>, // Ctrl+Space AND-narrowing: the completion it began on
    ac_active: bool,
    ac_scroll: usize,
    recalling: bool,
    group: Option<pickerdsl::group::Parsed>,
    group_raw: String,
    collapsed: HashSet<String>,
    disp: Vec<Disp>,
    today: String,
    action: Option<(ActionKind, String)>,
    ws_rows: Vec<WsRow>,
    hypr: HyprInfo,
    query: String,
    cursor: usize, // in chars
    sel_all: bool, // Ctrl+A: whole query selected
    results: Vec<usize>,
    selected: usize,
    scroll: usize,
    pending: Option<Pending>,
    hover_origin: Option<(f64, f64)>,
    hover_armed: bool,
    hits: Vec<(i32, i32, i32, i32, Hit)>, // logical row rects
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

    /// AppLauncher.qml: icon gutter (40) + the widest of the first 13 names + right padding (28),
    /// floored at 360 and capped at 560; the workspace list is a fixed 780.
    fn card_w(&self) -> i32 {
        if self.action.is_some() {
            return WS_CARD_W;
        }
        let widest = self.results.iter().take(13).map(|&i| text_width(&self.font, FONT_PX, &self.apps[i].name)).fold(0.0f32, f32::max);
        ((widest + 68.0).round() as i32).clamp(360, 560)
    }

    fn card_h(&self) -> i32 {
        (self.height as f32 * 0.6).round() as i32
    }

    fn list_top(&self) -> i32 {
        HEADER_H + 7 + if self.action.is_some() { WS_HEAD_H } else { 0 }
    }

    fn vis_rows(&self) -> usize {
        (((self.card_h() - self.list_top() - 7) / ROW_H).max(1)) as usize
    }

    /// How many selectable things there are (apps, or workspace rows).
    fn sel_count(&self) -> usize {
        if self.action.is_some() { self.ws_rows.len() } else { self.results.len() }
    }

    fn entries(&self) -> Vec<Entry> {
        if self.action.is_some() {
            return (0..self.ws_rows.len()).map(Entry::Ws).collect();
        }
        if self.group.is_some() {
            return self.disp.iter().enumerate().map(|(i, d)| match d {
                Disp::Head { .. } => Entry::Head(i),
                Disp::Row(p) => Entry::App(*p),
            }).collect();
        }
        (0..self.results.len()).map(Entry::App).collect()
    }

    /// Filter by the query (the DSL engine), order by /s or else AppLauncher.qml's rank (exact / prefix /
    /// substring of the first bare word), launch frecency, alphabetical; fold into /g sections.
    fn refilter(&mut self) {
        let parsed = pickerdsl::parse(&self.schema, &self.query);
        self.action = action_match(&self.query);
        self.disp.clear();
        self.group = None;
        if let Some((kind, arg)) = self.action.clone() {
            self.results.clear();
            self.build_ws_rows(kind, &arg);
            self.selected = self.selected.min(self.ws_rows.len().saturating_sub(1));
            self.ensure_visible();
            self.dirty = true;
            return;
        }
        self.ws_rows.clear();
        let src = AppSrc(&self.apps);
        let mut rows: Vec<usize> = (0..self.apps.len()).filter(|&i| pickerdsl::row_matches(&self.schema, &parsed, &src, i)).collect();
        if let Some(sort) = &parsed.sort {
            pickerdsl::sort_rows(&mut rows, sort, &src);
        } else {
            let first = parsed
                .terms
                .iter()
                .find_map(|t| match t {
                    pickerdsl::Term::Free { text, neg: false, .. } => Some(text.to_lowercase()),
                    _ => None,
                })
                .unwrap_or_default();
            let rank = |a: &DApp| -> u8 {
                if first.is_empty() {
                    return 3;
                }
                let n = a.name.to_lowercase();
                if n == first { 0 } else if n.starts_with(&first) { 1 } else if n.contains(&first) { 2 } else { 3 }
            };
            rows.sort_by(|&a, &b| {
                let (x, y) = (&self.apps[a], &self.apps[b]);
                rank(x)
                    .cmp(&rank(y))
                    .then(score(&self.hist, &y.id).cmp(&score(&self.hist, &x.id)))
                    .then(x.name.to_lowercase().cmp(&y.name.to_lowercase()))
            });
        }
        let raw = parsed.group_raw.clone().unwrap_or_default();
        let known: Vec<&str> = self.schema.types.iter().map(|s| s.as_str()).collect();
        let grouped = if raw.is_empty() { None } else { pickerdsl::group::parse_group(&raw, &known, &[]) };
        if raw != self.group_raw {
            self.collapsed.clear();
            self.group_raw = raw;
        }
        if let Some(g) = &grouped {
            if self.today.is_empty() {
                self.today = Command::new("date").arg("+%F").output().ok().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).unwrap_or_default();
            }
            let layout = pickerdsl::group::group_layout(rows.len(), g, &|i, name| pickerdsl::Source::value(&src, rows[i], name), &self.today, &|_, _| None);
            let mut order = vec![];
            for e in pickerdsl::group::group_visible(&layout, &self.collapsed) {
                match e {
                    pickerdsl::group::Entry::Header { depth, id, label, count } => {
                        let folded = self.collapsed.contains(&id);
                        self.disp.push(Disp::Head { depth, id, label, count, folded });
                    }
                    pickerdsl::group::Entry::Row(i) => {
                        self.disp.push(Disp::Row(order.len()));
                        order.push(rows[i]);
                    }
                }
            }
            rows = order;
        }
        self.group = grouped;
        self.results = rows;
        self.selected = self.selected.min(self.results.len().saturating_sub(1));
        self.ensure_visible();
        self.dirty = true;
    }

    fn build_ws_rows(&mut self, kind: ActionKind, arg: &str) {
        let arg_l = arg.to_lowercase();
        let mut list: Vec<&HWorkspace> = self
            .hypr
            .workspaces
            .iter()
            .filter(|w| w.id >= 0 && !w.name.starts_with("special:") && !(kind == ActionKind::Workspace && w.id == self.hypr.active_ws))
            .collect();
        list.sort_by_key(|w| w.id);
        let (mut out, mut exact) = (vec![], false);
        for w in list {
            let n = w.name.to_lowercase();
            if !arg_l.is_empty() && !n.contains(&arg_l) {
                continue;
            }
            if n == arg_l {
                exact = true;
            }
            let row = WsRow { name: w.name.clone(), target: w.name.clone(), id: Some(w.id), cnt: w.windows as i64, mon: w.monitor.clone(), apps: w.classes.join(", "), create: false };
            if n == arg_l { out.insert(0, row) } else { out.push(row) }
        }
        if !arg.is_empty() && !exact && kind == ActionKind::Window {
            out.push(WsRow { name: format!("+ new workspace \"{arg}\""), target: arg.to_string(), id: None, cnt: -1, mon: String::new(), apps: "created after the current workspace".into(), create: true });
        }
        self.ws_rows = out;
    }

    fn ensure_visible(&mut self) {
        if self.height == 0 {
            return;
        }
        let rows = self.vis_rows();
        let entries = self.entries();
        let Some(mut at) = entries.iter().position(|e| match e {
            Entry::App(p) => self.action.is_none() && *p == self.selected,
            Entry::Ws(i) => *i == self.selected,
            Entry::Head(_) => false,
        }) else {
            self.scroll = 0;
            return;
        };
        if at > 0 && matches!(entries[at - 1], Entry::Head(_)) {
            at -= 1; // keep the section header above the first row visible
        }
        let sel_at = at;
        if sel_at < self.scroll {
            self.scroll = sel_at;
        } else if sel_at >= self.scroll + rows {
            self.scroll = sel_at + 1 - rows;
        }
    }

    fn nav(&mut self, d: i32) {
        let n = self.sel_count();
        if n == 0 {
            return;
        }
        self.selected = (self.selected as i32 + d).clamp(0, n as i32 - 1) as usize;
        self.ensure_visible();
        self.dirty = true;
    }

    fn launch(&mut self, pos: usize) {
        if self.ac.is_some() {
            return;
        }
        if let Some((kind, _)) = &self.action {
            if let Some(row) = self.ws_rows.get(pos).cloned() {
                self.pending = Some(match kind {
                    ActionKind::Window => Pending::MoveToWorkspace(row, self.hypr.active_addr.clone()),
                    ActionKind::Workspace => Pending::MoveWorkspaceAfter(row, self.hypr.active_ws),
                });
            }
        } else if self.results.get(pos).is_some() {
            // started only after the surface is gone (see main): while this layer holds the
            // exclusive keyboard grab the new window would not get focus
            self.pending = Some(Pending::Launch(self.results[pos]));
        } else {
            return;
        }
        self.exit = true;
    }

    // ---- completion / history popup (same behaviour as winswitch-ui) ----

    fn hide_ac(&mut self) {
        self.ac_multi = None;
        self.ac = None;
        self.ac_active = false;
        self.ac_scroll = 0;
        self.dirty = true;
    }

    fn ac_candidates(&self, comp: &pickerdsl::Completion) -> Vec<String> {
        pickerdsl::candidates(&self.schema, comp, &AppSrc(&self.apps), self.apps.len())
    }

    fn ac_recompute(&mut self) {
        let Some(ac) = &self.ac else { return };
        if ac.comp.kind == pickerdsl::CompKind::History {
            let items = pickerdsl::history_candidates(&self.qhist, &self.query);
            self.ac = Some(Ac { comp: ac.comp.clone(), items, sel: 0 });
        } else if let Some(base) = self.ac_multi.clone() {
            match pickerdsl::multi_candidates(&self.schema, &self.query, &base, &AppSrc(&self.apps), self.apps.len()) {
                Some((comp, items)) => self.ac = if items.is_empty() { None } else { Some(Ac { comp, items, sel: 0 }) },
                None => {
                    self.ac_multi = None; // edited back past the frozen start: ordinary completion again
                    return self.ac_recompute();
                }
            }
        } else if let Some(comp) = pickerdsl::completion_context(&self.schema, &self.query) {
            let items = self.ac_candidates(&comp);
            self.ac = if items.is_empty() { None } else { Some(Ac { comp, items, sel: 0 }) };
        } else {
            self.ac = None;
        }
        self.ac_scroll = 0;
        self.dirty = true;
    }

    fn trigger_completion(&mut self) {
        let Some(comp) = pickerdsl::completion_context(&self.schema, &self.query) else { return };
        self.ac_active = true;
        let items = self.ac_candidates(&comp);
        if items.is_empty() {
            return;
        }
        let single = items.len() == 1;
        self.ac = Some(Ac { comp, items, sel: 0 });
        self.ac_scroll = 0;
        self.dirty = true;
        if single {
            self.ac_accept();
        }
    }

    fn ac_rows(&self) -> usize {
        let cap = if self.ac.as_ref().is_some_and(|a| a.comp.kind == pickerdsl::CompKind::History) { self.card_h() / 2 } else { self.card_h() - HEADER_H };
        (((cap - 8) / AC_ROW_H).max(1) as usize).min(self.ac.as_ref().map_or(1, |a| a.items.len()).max(1))
    }

    fn ac_move(&mut self, d: i32, wrap: bool) {
        let Some(ac) = self.ac.as_mut() else { return };
        let n = ac.items.len() as i32;
        if n == 0 {
            return;
        }
        let t = ac.sel as i32 + d;
        ac.sel = if wrap { t.rem_euclid(n) } else { t.clamp(0, n - 1) } as usize;
        let (rows, sel) = (self.ac_rows(), self.ac.as_ref().unwrap().sel);
        if sel < self.ac_scroll {
            self.ac_scroll = sel;
        } else if sel >= self.ac_scroll + rows {
            self.ac_scroll = sel + 1 - rows;
        }
        self.dirty = true;
    }

    fn ac_accept(&mut self) {
        let Some(ac) = self.ac.take() else { return };
        let Some(chosen) = ac.items.get(ac.sel) else { return };
        let q = pickerdsl::accept(&self.query, &ac.comp, chosen);
        self.ac_multi = None;
        self.ac_active = false;
        self.ac_scroll = 0;
        let c = q.chars().count();
        self.recalling = true;
        self.set_query(q, c);
        self.recalling = false;
        // /add-workspace has no prompt: accepting it runs it
        if self.query.trim_end().ends_with("/add-workspace") {
            self.pending = Some(Pending::AddWorkspace(String::new(), self.hypr.active_ws));
            self.exit = true;
        }
    }

    fn open_history(&mut self) {
        let comp = pickerdsl::Completion { kind: pickerdsl::CompKind::History, start: 0, fragment: String::new(), verb: None, fields: None };
        let items = pickerdsl::history_candidates(&self.qhist, &self.query);
        self.ac = Some(Ac { comp, items, sel: 0 });
        self.ac_active = true;
        self.ac_scroll = 0;
        self.dirty = true;
    }

    fn toggle_fold(&mut self, id: &str) {
        if !self.collapsed.remove(id) {
            self.collapsed.insert(id.to_string());
        }
        self.refilter();
        self.dirty = true;
    }

    /// Ctrl+G: fold / unfold the section of the selected row.
    fn toggle_selected_group(&mut self) {
        let mut cur: Option<String> = None;
        for d in &self.disp {
            match d {
                Disp::Head { id, .. } => cur = Some(id.clone()),
                Disp::Row(p) if *p == self.selected => break,
                _ => {}
            }
        }
        if let Some(id) = cur {
            self.toggle_fold(&id);
        }
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
        if !self.recalling {
            self.hist_idx = -1;
        }
        self.walked = false;
        self.refilter();
        if self.ac_active {
            self.ac_recompute();
        } else {
            self.ac = None;
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
        if self.ac.is_some() || self.cursor != self.qlen() || self.query.trim().is_empty() {
            return String::new();
        }
        for e in self.qhist.iter().rev() {
            if e.len() > self.query.len() && e.starts_with(&self.query) {
                return e[self.query.len()..].to_string();
            }
        }
        String::new()
    }

    /// Recall text without it counting as an edit (it must not end the history cycle).
    fn recall(&mut self, text: String) {
        self.hide_ac();
        let c = text.chars().count();
        self.recalling = true;
        self.set_query(text, c);
        self.recalling = false;
    }

    fn history_prev(&mut self) {
        if self.qhist.is_empty() {
            return;
        }
        if self.hist_idx < 0 {
            self.hist_draft = self.query.clone();
            self.hist_idx = self.qhist.len() as i32;
        }
        if self.hist_idx > 0 {
            self.hist_idx -= 1;
            let t = self.qhist[self.hist_idx as usize].clone();
            self.recall(t);
        }
    }

    fn history_next(&mut self) {
        if self.hist_idx < 0 {
            return;
        }
        self.hist_idx += 1;
        if self.hist_idx as usize >= self.qhist.len() {
            self.hist_idx = -1;
            let t = std::mem::take(&mut self.hist_draft);
            self.recall(t);
        } else {
            let t = self.qhist[self.hist_idx as usize].clone();
            self.recall(t);
        }
    }

    /// Down / Ctrl+J: forward through history once Up has started cycling, else walk the results.
    fn down_key(&mut self) {
        if self.hist_idx >= 0 {
            self.history_next();
        } else {
            self.nav(1);
            self.walked = true;
        }
    }

    /// Up / Ctrl+K: walk the results back once Down walked them, else recall history.
    fn up_key(&mut self) {
        if self.walked && self.selected > 0 {
            self.nav(-1);
        } else {
            self.walked = false;
            self.history_prev();
        }
    }

    fn handle_key(&mut self, ev: KeyEvent) {
        if !self.first_key {
            self.first_key = true;
            self.note("first key");
        }
        let ks = ev.keysym;
        let n = self.qlen();
        let popup = self.ac.is_some();
        if std::mem::take(&mut self.sel_all) && n > 0 {
            let typed = ev.utf8.as_deref().filter(|t| !t.is_empty() && !t.chars().any(char::is_control));
            match ks {
                Keysym::BackSpace | Keysym::Delete => {
                    self.set_query(String::new(), 0);
                    return;
                }
                Keysym::Left | Keysym::Home => {
                    self.cursor = 0;
                    self.dirty = true;
                    return;
                }
                Keysym::Right | Keysym::End => {
                    self.cursor = n;
                    self.dirty = true;
                    return;
                }
                _ if !self.ctrl && typed.is_some() => {
                    self.set_query(typed.unwrap_or_default().to_string(), typed.map_or(0, |t| t.chars().count()));
                    return;
                }
                _ => self.dirty = true,
            }
        }
        match ks {
            Keysym::Escape => {
                if popup {
                    self.hide_ac();
                } else {
                    self.exit = true;
                }
            }
            Keysym::Return | Keysym::KP_Enter => {
                if popup {
                    self.ac_accept();
                } else {
                    self.launch(self.selected);
                }
            }
            Keysym::Tab | Keysym::ISO_Left_Tab => {
                let back = ks == Keysym::ISO_Left_Tab || self.shift;
                if popup && !back {
                    self.ac_accept();
                } else if popup {
                    self.ac_move(-1, true);
                } else {
                    self.trigger_completion();
                }
            }
            Keysym::space if popup && self.ctrl => {
                // AND-narrow instead of accept: the space starts a further substring
                let comp = self.ac.as_ref().map(|a| a.comp.clone());
                if let Some(c) = comp.filter(|c| c.kind != pickerdsl::CompKind::History) {
                    if self.ac_multi.is_none() {
                        self.ac_multi = Some(c);
                    }
                    self.insert(" ");
                }
            }
            Keysym::space if popup && !self.ctrl => self.ac_accept(),
            Keysym::space if self.ctrl && !popup => self.trigger_completion(),
            Keysym::Page_Down if popup => self.ac_move(self.ac_rows() as i32, false),
            Keysym::Page_Up if popup => self.ac_move(-(self.ac_rows() as i32), false),
            Keysym::Down if popup => self.ac_move(1, false),
            Keysym::Up if popup => self.ac_move(-1, false),
            Keysym::Down => self.down_key(),
            Keysym::Up => self.up_key(),
            Keysym::Right | Keysym::End if self.cursor == n && !self.ghost().is_empty() && !self.shift => {
                let q = format!("{}{}", self.query, self.ghost());
                let c = q.chars().count();
                self.set_query(q, c);
            }
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
                Keysym::j | Keysym::n if popup => self.ac_move(1, false),
                Keysym::k | Keysym::p if popup => self.ac_move(-1, false),
                Keysym::j | Keysym::n => self.down_key(),
                Keysym::k | Keysym::p => self.up_key(),
                Keysym::g if self.group.is_some() => self.toggle_selected_group(),
                Keysym::f if self.cursor == n && !self.ghost().is_empty() => {
                    let q = format!("{}{}", self.query, self.ghost());
                    let c = q.chars().count();
                    self.set_query(q, c);
                }
                Keysym::r => self.open_history(),
                Keysym::a => {
                    self.sel_all = n > 0;
                    self.cursor = n;
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
            Msg::Icons(list) => {
                if let Some(size) = tiny_skia::IntSize::from_wh(ICON_PX, ICON_PX) {
                    for (key, data) in list {
                        if let Some(pm) = Pixmap::from_vec(data, size) {
                            self.icons.insert(key, pm);
                        }
                    }
                }
                self.dirty = true;
            }
            Msg::Icon { name, w, h, data } => {
                if let Some(size) = tiny_skia::IntSize::from_wh(w, h) {
                    if let Some(pm) = Pixmap::from_vec(data, size) {
                        self.icons.insert(icon_key(&name), pm);
                        self.dirty = true;
                    }
                }
            }
            Msg::QHistory(h) => {
                self.qhist = h;
                self.dirty = true;
            }
            Msg::Hypr(h) => {
                self.hypr = h;
                if self.action.is_some() {
                    self.refilter();
                }
                self.dirty = true;
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
        let card_w = self.card_w();
        let (cx, cy) = ((lw - card_w) / 2, (lh_ as f32 * 0.2).round() as i32);
        self.card_rect = (cx, cy, card_w, card_h);

        fill(&mut pm, &rrect(cx as f32, cy as f32, card_w as f32, card_h as f32, 10.0), tf, [26, 26, 26], 230);
        stroke(&mut pm, &rrect(cx as f32 + 0.5, cy as f32 + 0.5, card_w as f32 - 1.0, card_h as f32 - 1.0, 9.5), tf, th.primary, 255, 1.0);

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
        let max_w = (card_w - 56) as f32 * sc;
        // recognised /commands (and the workspace actions) in the accent colour, the rest normal
        let mut spans: Vec<(usize, usize)> = pickerdsl::command_spans(&self.schema, &self.query).into_iter().filter(|s| s.2).map(|s| (s.0, s.1)).collect();
        for t in pickerdsl::tokenize(&self.query) {
            if !t.lead_quote && ACTION_VERBS.contains(&t.text.as_str()) {
                spans.push((t.start, t.start + t.text.chars().count()));
            }
        }
        spans.sort();
        let qc: Vec<char> = self.query.chars().collect();
        let (mut at, mut x) = (0usize, tx);
        let seg = |pm: &mut Pixmap, from: usize, to: usize, col: Rgb, x: &mut f32| {
            if to > from {
                let t: String = qc[from..to].iter().collect();
                draw_text(pm, &self.font, size, *x, top + asc, col, &t, max_w - (*x - tx));
                *x += text_width(&self.font, size, &t);
            }
        };
        for (a, b) in spans {
            let (a, b) = (a.max(at).min(qc.len()), b.min(qc.len()));
            seg(&mut pm, at, a, th.text, &mut x);
            seg(&mut pm, a, b, th.primary, &mut x);
            at = b.max(at);
        }
        seg(&mut pm, at, qc.len(), th.text, &mut x);
        if self.sel_all {
            let w = text_width(&self.font, size, &self.query).min(max_w);
            if let Some(r) = Rect::from_xywh(tx, top, w, lh) {
                pm.fill_rect(r, &paint(th.primary, 70), Transform::identity(), None);
            }
        }
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
        // separator
        if let Some(r) = Rect::from_xywh((cx + 8) as f32 * sc, (cy + HEADER_H) as f32 * sc, (card_w - 16) as f32 * sc, sc.max(1.0)) {
            pm.fill_rect(r, &paint(th.text_dim, 40), Transform::identity(), None);
        }

        // results / workspace list / completion popup
        let size = FONT_PX * sc;
        let (asc, lh) = metrics(&self.font, size);
        let rows = self.vis_rows();
        let list_y = cy + self.list_top();
        self.hits.clear();
        let mut hits: Vec<(i32, i32, i32, i32, Hit)> = vec![];
        let dim = [th.text_dim[0] / 2 + 13, th.text_dim[1] / 2 + 13, th.text_dim[2] / 2 + 13];
        if let Some(ac) = &self.ac {
            let history = ac.comp.kind == pickerdsl::CompKind::History;
            let py0 = cy + HEADER_H + 4;
            let prow = self.ac_rows();
            let (pasc, plh) = metrics(&self.font, 12.0 * sc);
            if ac.items.is_empty() && history {
                draw_text(&mut pm, &self.font, 11.0 * sc, (cx + 24) as f32 * sc, py0 as f32 * sc + pasc + 4.0 * sc, th.text_dim, "no matching history", (card_w - 52) as f32 * sc);
            }
            for (i, item) in ac.items.iter().enumerate().skip(self.ac_scroll).take(prow) {
                let y = py0 + (i - self.ac_scroll) as i32 * AC_ROW_H;
                hits.push((cx + 8, y, card_w - 16, AC_ROW_H, Hit::Pop(i)));
                let cur = i == ac.sel;
                if cur {
                    fill(&mut pm, &rrect((cx + 12) as f32, y as f32, (card_w - 24) as f32, AC_ROW_H as f32, 5.0), tf, th.primary, 46);
                }
                let (label, alias, desc) = if history { (item.clone(), String::new(), String::new()) } else { pickerdsl::row_info(&self.schema, ac.comp.kind, item) };
                let base = (y as f32 + (AC_ROW_H as f32 - plh / sc) / 2.0) * sc + pasc;
                let mut x = (cx + 22) as f32 * sc;
                let room = (cx + card_w - 12) as f32 * sc;
                draw_text(&mut pm, &self.font, 12.0 * sc, x, base, if cur { th.primary } else { th.text }, &label, room - x);
                x += text_width(&self.font, 12.0 * sc, &label) + 8.0 * sc;
                for t in [if alias.is_empty() { String::new() } else { format!("({alias})") }, desc] {
                    if !t.is_empty() && x < room {
                        draw_text(&mut pm, &self.font, 11.0 * sc, x, base, dim, &t, room - x);
                        x += text_width(&self.font, 11.0 * sc, &t) + 8.0 * sc;
                    }
                }
            }
        } else {
            if self.action.is_some() {
                // column titles of the workspace table
                let name_w = (card_w - 24) as f32 - WS_COL_ID - WS_COL_WIN - WS_COL_MON - WS_COL_APPS - 40.0;
                let (hasc, hlh) = metrics(&self.font, 10.0 * sc);
                let hb = ((cy + HEADER_H + 4) as f32 + (WS_HEAD_H as f32 - hlh / sc) / 2.0) * sc + hasc;
                let mut x = (cx + 12) as f32;
                for (t, w, right) in [("workspace", name_w, false), ("id", WS_COL_ID, true), ("windows", WS_COL_WIN, true), ("monitor", WS_COL_MON, false), ("apps", WS_COL_APPS, false)] {
                    let tw = text_width(&self.font, 10.0 * sc, t) / sc;
                    draw_text(&mut pm, &self.font, 10.0 * sc, (x + if right { (w - tw).max(0.0) } else { 0.0 }) * sc, hb, dim, t, w * sc);
                    x += w + 10.0;
                }
            }
            let entries = self.entries();
            for (n, e) in entries.iter().enumerate().skip(self.scroll).take(rows) {
                let y = list_y + (n - self.scroll) as i32 * ROW_H;
                let base = (y as f32 + (ROW_H as f32 - lh / sc) / 2.0) * sc + asc;
                match e {
                    Entry::Head(di) => {
                        let Disp::Head { depth, id, label, count, folded } = &self.disp[*di] else { continue };
                        hits.push((cx + 8, y, card_w - 16, ROW_H, Hit::Head(id.clone())));
                        let dx = 8 + *depth as i32 * 14;
                        fill(&mut pm, &rrect((cx + dx) as f32, (y + ROW_H - 1) as f32, (card_w - dx - 8) as f32, 1.0, 0.0), tf, th.text_dim, 90);
                        let text = format!("{} {}   {}{}", if *folded { "\u{25b8}" } else { "\u{25be}" }, label, count, if *folded { " (folded)" } else { "" });
                        draw_text(&mut pm, &self.font, size, (cx + dx + 2) as f32 * sc, base + 3.0 * sc, th.text, &text, (card_w - dx - 12) as f32 * sc);
                    }
                    Entry::Ws(i) => {
                        hits.push((cx + 8, y, card_w - 16, ROW_H, Hit::Item(*i)));
                        if *i == self.selected {
                            fill(&mut pm, &rrect((cx + 8) as f32, y as f32 + 1.0, (card_w - 16) as f32, (ROW_H - 2) as f32, 6.0), tf, th.primary, 64);
                        }
                        let r = &self.ws_rows[*i];
                        let name_w = (card_w - 24) as f32 - WS_COL_ID - WS_COL_WIN - WS_COL_MON - WS_COL_APPS - 40.0;
                        let mut x = (cx + 12) as f32;
                        let cols = [
                            (r.name.clone(), name_w, false, true),
                            (if r.create { String::new() } else { r.id.map(|v| v.to_string()).unwrap_or_default() }, WS_COL_ID, true, false),
                            (if r.cnt < 0 { String::new() } else { r.cnt.to_string() }, WS_COL_WIN, true, false),
                            (r.mon.clone(), WS_COL_MON, false, false),
                            (r.apps.clone(), WS_COL_APPS, false, false),
                        ];
                        for (t, w, right, hi) in cols {
                            let tw = text_width(&self.font, size, &t) / sc;
                            draw_text(&mut pm, &self.font, size, (x + if right { (w - tw).max(0.0) } else { 0.0 }) * sc, base, if hi { th.text } else { th.text_dim }, &t, w * sc);
                            x += w + 10.0;
                        }
                    }
                    Entry::App(pos) => {
                        hits.push((cx + 8, y, card_w - 16, ROW_H, Hit::Item(*pos)));
                        if *pos == self.selected {
                            fill(&mut pm, &rrect((cx + 8) as f32, y as f32 + 1.0, (card_w - 16) as f32, (ROW_H - 2) as f32, 6.0), tf, th.primary, 64);
                        }
                        let app = &self.apps[self.results[*pos]];
                        if let Some(ic) = self.icons.get(&icon_key(&app.icon)) {
                            // rasterized at ICON_PX, drawn 20 logical px wide
                            let k = (20.0 * sc) / ICON_PX as f32;
                            let tf_i = Transform::from_row(k, 0.0, 0.0, k, (cx + 12) as f32 * sc, (y as f32 + 5.0) * sc);
                            let pp = tiny_skia::PixmapPaint { quality: tiny_skia::FilterQuality::Bilinear, ..Default::default() };
                            pm.draw_pixmap(0, 0, ic.as_ref(), &pp, tf_i, None);
                        } else {
                            // not loaded (yet): a rounded chip with the initial
                            fill(&mut pm, &rrect((cx + 12) as f32, y as f32 + 5.0, 20.0, 20.0, 5.0), tf, th.text_dim, 40);
                            let initial: String = app.name.chars().next().map(|c| c.to_uppercase().to_string()).unwrap_or_default();
                            let iw = text_width(&self.font, size, &initial);
                            draw_text(&mut pm, &self.font, size, (cx + 22) as f32 * sc - iw / 2.0, base, th.text_dim, &initial, 30.0 * sc);
                        }
                        draw_text(&mut pm, &self.font, size, (cx + 40) as f32 * sc, base, th.text, &app.name, (card_w - 56) as f32 * sc);
                    }
                }
            }
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

    fn hit_at(&self, x: f64, y: f64) -> Option<&Hit> {
        self.hits.iter().find(|(rx, ry, rw, rh, _)| x >= *rx as f64 && y >= *ry as f64 && x < (*rx + *rw) as f64 && y < (*ry + *rh) as f64).map(|h| &h.4)
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
        for ev in events {
            let (x, y) = ev.position;
            match ev.kind {
                PointerEventKind::Enter { .. } | PointerEventKind::Motion { .. } => {
                    if self.pointer_moved(x, y) {
                        match self.hit_at(x, y) {
                            Some(Hit::Item(pos)) => {
                                let pos = *pos;
                                if self.selected != pos {
                                    self.selected = pos;
                                    self.dirty = true;
                                }
                            }
                            Some(Hit::Pop(i)) => {
                                let i = *i;
                                if let Some(ac) = self.ac.as_mut() {
                                    if ac.sel != i {
                                        ac.sel = i;
                                        self.dirty = true;
                                    }
                                }
                            }
                            _ => {}
                        }
                    }
                }
                PointerEventKind::Press { button, .. } if button == 0x110 => match self.hit_at(x, y) {
                    Some(Hit::Item(pos)) => {
                        let pos = *pos;
                        self.launch(pos);
                    }
                    Some(Hit::Head(id)) => {
                        let id = id.clone();
                        self.toggle_fold(&id);
                    }
                    Some(Hit::Pop(i)) => {
                        let i = *i;
                        if let Some(ac) = self.ac.as_mut() {
                            ac.sel = i;
                        }
                        self.ac_accept();
                    }
                    None => {
                        let (cx, cy, cw, ch) = self.card_rect;
                        if !(x >= cx as f64 && y >= cy as f64 && x < (cx + cw) as f64 && y < (cy + ch) as f64) {
                            self.exit = true; // click outside the card closes
                        }
                    }
                },
                PointerEventKind::Axis { vertical, .. } => {
                    let step = if vertical.discrete != 0 { vertical.discrete.signum() } else { vertical.absolute.signum() as i32 };
                    if step != 0 {
                        if self.ac.is_some() {
                            let max = self.ac.as_ref().map_or(0, |a| a.items.len()).saturating_sub(self.ac_rows());
                            self.ac_scroll = (self.ac_scroll as i32 + step).clamp(0, max as i32) as usize;
                        } else {
                            let max = self.entries().len().saturating_sub(self.vis_rows());
                            self.scroll = (self.scroll as i32 + step).clamp(0, max as i32) as usize;
                        }
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
    // Hyprland state for the workspace actions, off the main thread
    let tx_h = tx.clone();
    std::thread::spawn(move || {
        let _ = tx_h.send(Msg::Hypr(fetch_hypr()));
    });
    // desktop entries + launch history, off the main thread: the card is usable before the list fills
    let tx_scan = tx.clone();
    std::thread::spawn(move || {
        let s = Instant::now();
        let _ = tx_scan.send(Msg::Icons(preload_rasters()));
        let apps = scan();
        let hist = load_history();
        // most-used apps first, so the icons you see first arrive first
        let mut order: Vec<usize> = (0..apps.len()).collect();
        order.sort_by_key(|&i| std::cmp::Reverse(score(&hist, &apps[i].id)));
        let names: Vec<String> = {
            let mut seen = HashSet::new();
            order.iter().map(|&i| apps[i].icon.clone()).filter(|n| !n.is_empty() && seen.insert(n.clone())).collect()
        };
        let _ = tx_scan.send(Msg::Apps { apps, hist, ms: s.elapsed().as_secs_f64() * 1000.0 });
        let paths = resolve_icons(&names);
        for n in names {
            if let Some((w, h, data)) = paths.get(&n).and_then(|p| cached_icon(&n, p)) {
                if tx_scan.send(Msg::Icon { name: n, w, h, data }).is_err() {
                    break;
                }
            }
        }
    });

    let tx_q = tx.clone();
    std::thread::spawn(move || {
        let h: Vec<String> = std::fs::read_to_string(home().join(".cache/quickshell/launcher-query-history.json")).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default();
        let _ = tx_q.send(Msg::QHistory(h));
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
        icons: HashMap::new(),
        qhist: vec![],
        hist_idx: -1,
        hist_draft: String::new(),
        walked: false,
        query: String::new(),
        cursor: 0,
        sel_all: false,
        results: vec![],
        selected: 0,
        scroll: 0,
        schema: make_schema(),
        ac: None,
        ac_multi: None,
        ac_active: false,
        ac_scroll: 0,
        recalling: false,
        group: None,
        group_raw: String::new(),
        collapsed: HashSet::new(),
        disp: vec![],
        today: String::new(),
        action: None,
        ws_rows: vec![],
        hypr: HyprInfo::default(),
        pending: None,
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
    let query = app.query.clone();
    let pending = app.pending.take().map(|p| match p {
        Pending::Launch(i) => {
            let a = &app.apps[i];
            (Some((a.id.clone(), a.name.clone(), clean_exec(&a.exec), a.terminal, a.path.clone())), None)
        }
        other => (None, Some(other)),
    });
    let mut log = std::mem::take(&mut app.log);
    // destroy the layer surface and let the compositor process it before the new window maps
    drop(app);
    let _ = conn.roundtrip();
    let _ = std::fs::remove_file(pid_path());
    if let Some((Some((id, name, exec, terminal, path)), _)) = &pending {
        let cmd = if *terminal { format!("alacritty -e sh -c '{}'", exec.replace('\'', "'\\''")) } else { exec.clone() };
        let mut c = Command::new("sh");
        c.arg("-c").arg(&cmd).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).process_group(0);
        if let Some(p) = path.as_ref().filter(|p| Path::new(p.as_str()).is_dir()) {
            c.current_dir(p);
        }
        let ok = c.spawn().is_ok();
        bump_launch(id);
        record_query(&query);
        log.push(format!("+{:7.1}ms launched {name} ({id}) ok={ok}", t0.elapsed().as_secs_f64() * 1000.0));
    }
    if let Some((_, Some(action))) = pending {
        record_query(&query);
        match action {
            Pending::MoveToWorkspace(row, addr) if !addr.is_empty() => run_repl(&move_to_workspace_lua(&addr, &row)),
            Pending::MoveWorkspaceAfter(row, cur) if cur >= 0 => run_repl(&move_workspace_after_lua(&row, cur)),
            Pending::AddWorkspace(target, cur) => run_repl(&add_workspace_lua(&target, cur)),
            _ => {}
        }
        log.push(format!("+{:7.1}ms workspace action done", t0.elapsed().as_secs_f64() * 1000.0));
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

    #[test]
    fn workspace_actions_parse() {
        assert!(matches!(action_match("/move-to-workspace"), Some((ActionKind::Window, a)) if a.is_empty()));
        assert!(matches!(action_match("  /move-workspace  3"), Some((ActionKind::Workspace, a)) if a == "3"));
        assert!(action_match("/move-to-workspaces").is_none());
        assert!(action_match("firefox /move-workspace").is_none());
    }

    #[test]
    fn lua_builders_embed_user_text_safely() {
        let row = WsRow { name: "x".into(), target: "a\"b".into(), id: None, cnt: -1, mon: String::new(), apps: String::new(), create: true };
        let lua = move_to_workspace_lua("0xabc", &row);
        assert!(lua.contains("name = \"a\\\"b\"") && lua.contains("== \"abc\""), "{lua}");
        assert!(!lua.contains('\n'));
        assert!(add_workspace_lua("", 5).contains("hl.get_workspace(5)"));
        assert!(move_workspace_after_lua(&WsRow { id: Some(7), ..row }, 5).contains("local id = 7 + 1"));
    }

    #[test]
    fn dsl_filters_desktop_entries() {
        let sc = make_schema();
        let mk = |name: &str, cats: &[&str]| DApp {
            id: name.into(), name: name.into(), generic: String::new(), comment: String::new(),
            categories: cats.iter().map(|s| s.to_string()).collect(), keywords: vec![], icon: String::new(),
            exec: name.to_lowercase(), terminal: false, path: None,
        };
        let apps = vec![mk("Blender", &["Graphics", "3DGraphics"]), mk("Firefox", &["Network"]), mk("Gimp", &["Graphics"])];
        let src = AppSrc(&apps);
        let rows = |q: &str| pickerdsl::select_rows(&sc, &pickerdsl::parse(&sc, q), &src, apps.len());
        assert_eq!(rows("//cat graphics"), vec![0, 2]);
        assert_eq!(rows("//cat 3dgraphics"), vec![0]);
        assert_eq!(rows("!//cat graphics"), vec![1]);
        assert_eq!(rows("/s/name/asc //cat graphics"), vec![0, 2]);
        assert_eq!(rows("/ft/name blender"), vec![0]); // column verbs are inert here
    }

    #[test]
    fn query_history_record_semantics() {
        // same normalisation as LauncherQueryHistory.record: whitespace reduced, duplicate floats to the end
        let norm = |q: &str| q.split_whitespace().collect::<Vec<_>>().join(" ");
        assert_eq!(norm("  /s/name   asc "), "/s/name asc");
    }
}
