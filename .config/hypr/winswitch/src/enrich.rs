//! Background enrichment of the open-window list with tmux and Claude Code
//! metadata, for the `$tmux.*`/`$claude.*` groups in query.rs (see
//! ~/.config/docs/query-dsl.md). Deliberately asynchronous end to end: alt-tab
//! must stay instant to open (including the existing tap fast-path in ui.rs,
//! which never even reaches this module), so nothing here may block the
//! grid's first paint. `start()` spawns one thread that does all the
//! subprocess/proc-tree work and streams results back as they're ready; a
//! genuinely expensive step (`$claude.contents`, reading a whole transcript)
//! is deferred further still, one thread per matched window, so a single
//! large conversation never delays the cheap fields on every other window.
//!
//! Two independent ways a window ends up correlated with a live Claude Code
//! session, because process ancestry alone doesn't cover tmux:
//!   - direct: the session's pid is a descendant of the window's own pid
//!     (claude run straight in a plain terminal, no tmux involved).
//!   - via tmux: the session was started inside a tmux pane (recorded in its
//!     own ~/.claude*/sessions/<pid>.json as a "tmux" field), and the window
//!     is a tmux client whose *tty* resolves to that same pane. tmux's own
//!     shell/pane processes are children of the detached `tmux: server`,
//!     never of the terminal emulator that merely attached to them, so pid
//!     ancestry can't see this case at all -- window-search.py and
//!     claude-history both solve the identical problem via #{client_tty},
//!     not process trees, for the same reason.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::mpsc;
use std::time::Duration;

use serde::Deserialize;
use serde_json::Value;

use crate::hyprctl::Window;

/// Same convention as claude-history's MAX_MSG_CHARS: a bound on how much
/// transcript text one window's `$claude.contents` carries, so one huge
/// pasted-file conversation can't blow up per-keystroke matching cost.
const CLAUDE_CONTENTS_BUDGET: usize = 20_000;

#[derive(Default, Clone)]
pub struct TmuxClaudeMeta {
    pub tmux_session: Option<String>,
    pub tmux_window: Option<String>,
    pub tmux_title: Option<String>,
    pub claude_title: Option<String>,
    pub claude_path: Option<String>,
    pub claude_session: Option<String>,
    /// Filled in last, by its own deferred thread -- see module doc.
    pub claude_contents: Option<String>,
}

impl TmuxClaudeMeta {
    /// Applies every field `other` actually set, leaving the rest of `self`
    /// alone -- results arrive as several independent partial updates (tmux
    /// fields, then claude metadata, then claude contents, each its own
    /// `send`), never as one complete record.
    pub fn merge(&mut self, other: TmuxClaudeMeta) {
        if other.tmux_session.is_some() { self.tmux_session = other.tmux_session; }
        if other.tmux_window.is_some() { self.tmux_window = other.tmux_window; }
        if other.tmux_title.is_some() { self.tmux_title = other.tmux_title; }
        if other.claude_title.is_some() { self.claude_title = other.claude_title; }
        if other.claude_path.is_some() { self.claude_path = other.claude_path; }
        if other.claude_session.is_some() { self.claude_session = other.claude_session; }
        if other.claude_contents.is_some() { self.claude_contents = other.claude_contents; }
    }
}

/// Kicks off background enrichment for `windows` (indices match the caller's
/// own window list) and delivers each partial result via `on_meta(index,
/// partial)` on the GTK main loop -- mirrors `wayland_capture::start`'s
/// `on_thumbnail(index, pixbuf)` shape, the same "fire and forget, results
/// land later into the running grid" pattern already used for thumbnails.
///
/// Polled on a 50ms timeout rather than an idle source: an idle source would
/// spin continuously (burning CPU) for as long as the channel might still
/// receive something, which for the Phase B contents threads can be however
/// long a transcript read takes. 50ms is imperceptible for a search-result
/// update and costs nothing between ticks.
pub fn start(windows: &[Window], on_meta: impl Fn(usize, TmuxClaudeMeta) + 'static) {
    let win_specs: Vec<(usize, i32)> = windows.iter().enumerate().map(|(i, w)| (i, w.pid)).collect();
    let (tx, rx) = mpsc::channel::<(usize, TmuxClaudeMeta)>();
    std::thread::spawn(move || run_enrichment(win_specs, tx));

    glib::source::timeout_add_local(Duration::from_millis(50), move || loop {
        match rx.try_recv() {
            Ok((idx, meta)) => on_meta(idx, meta),
            Err(mpsc::TryRecvError::Empty) => return glib::ControlFlow::Continue,
            Err(mpsc::TryRecvError::Disconnected) => return glib::ControlFlow::Break,
        }
    });
}

struct ProcInfo {
    ppid: i32,
    tty_nr: u64,
}

/// One pass over `/proc/*/stat` -- cheap (a few hundred processes on a
/// normal desktop), and shared by every window's descendant lookup below
/// instead of re-scanning `/proc` once per window.
fn read_all_proc() -> HashMap<i32, ProcInfo> {
    let mut map = HashMap::new();
    let Ok(entries) = fs::read_dir("/proc") else { return map };
    for entry in entries.flatten() {
        let Some(pid) = entry.file_name().to_str().and_then(|s| s.parse::<i32>().ok()) else { continue };
        if let Some(info) = read_proc_stat(pid) {
            map.insert(pid, info);
        }
    }
    map
}

/// `tty_nr` (field 7) and `ppid` (field 4) out of `/proc/<pid>/stat`. Parsed
/// after the last `)` rather than by naive whitespace-splitting from the
/// start, because `comm` (field 2, parenthesized) can itself contain spaces.
fn read_proc_stat(pid: i32) -> Option<ProcInfo> {
    let content = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let rparen = content.rfind(')')?;
    let rest: Vec<&str> = content[rparen + 2..].split_whitespace().collect();
    // `rest[0]` is field 3 (state) -- ppid is field 4 (rest[1]), tty_nr is
    // field 7 (rest[4]). (Confirmed by direct testing: an earlier version
    // of this used rest[0]/rest[3], one index too low, which silently
    // failed to parse *every* process's state character as ppid and
    // returned None for 100% of them -- caught by the manual_enrichment_
    // check test below reporting "procs seen: 0" against a real desktop
    // with hundreds of running processes.)
    Some(ProcInfo {
        ppid: rest.get(1)?.parse().ok()?,
        tty_nr: rest.get(4)?.parse::<i64>().ok()? as u64,
    })
}

/// `starttime` (field 22) compared verbatim against a claude session's own
/// recorded `procStart` -- the exact "still the same process, not a reused
/// pid" guard claude-history's own docstring describes for the same file.
fn proc_start_matches(pid: i32, expected: &str) -> bool {
    let Some(content) = fs::read_to_string(format!("/proc/{pid}/stat")).ok() else { return false };
    let Some(rparen) = content.rfind(')') else { return false };
    let rest: Vec<&str> = content[rparen + 2..].split_whitespace().collect();
    // starttime is field 22 -- rest[19], by the same rest[i] = field(i+3)
    // mapping documented in read_proc_stat above.
    rest.get(19).map(|s| *s == expected).unwrap_or(false)
}

/// Every pid in `root`'s subtree, `root` included -- built from one shared
/// `read_all_proc()` pass, not a fresh `/proc` scan per call.
fn descendants(procs: &HashMap<i32, ProcInfo>, root: i32) -> Vec<i32> {
    let mut children_of: HashMap<i32, Vec<i32>> = HashMap::new();
    for (&pid, info) in procs {
        children_of.entry(info.ppid).or_default().push(pid);
    }
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    let mut stack = vec![root];
    while let Some(pid) = stack.pop() {
        if !seen.insert(pid) {
            continue;
        }
        out.push(pid);
        if let Some(children) = children_of.get(&pid) {
            stack.extend(children);
        }
    }
    out
}

struct TmuxClient {
    tty: String,
    session: String,
    window_id: String,
}

fn tmux_clients() -> Vec<TmuxClient> {
    let Ok(out) = Command::new("tmux")
        .args(["list-clients", "-F", "#{client_tty}\t#{session_name}\t#{window_id}"])
        .output()
    else {
        return Vec::new();
    };
    if !out.status.success() {
        return Vec::new();
    }
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| {
            let mut p = l.splitn(3, '\t');
            Some(TmuxClient {
                tty: p.next()?.to_string(),
                session: p.next()?.to_string(),
                window_id: p.next()?.to_string(),
            })
        })
        .collect()
}

struct TmuxPane {
    window_id: String,
    pane_id: String,
    active: bool,
    pane_title: String,
    window_name: String,
}

fn tmux_panes() -> Vec<TmuxPane> {
    let Ok(out) = Command::new("tmux")
        .args(["list-panes", "-a", "-F", "#{window_id}\t#{pane_id}\t#{pane_active}\t#{pane_title}\t#{window_name}"])
        .output()
    else {
        return Vec::new();
    };
    if !out.status.success() {
        return Vec::new();
    }
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| {
            let mut p = l.splitn(5, '\t');
            Some(TmuxPane {
                window_id: p.next()?.to_string(),
                pane_id: p.next()?.to_string(),
                active: p.next()? == "1",
                pane_title: p.next()?.to_string(),
                window_name: p.next()?.to_string(),
            })
        })
        .collect()
}

/// `st_rdev` of a tty device node, for matching against `/proc/<pid>/stat`'s
/// `tty_nr` -- both are the kernel's packed major/minor `dev_t`, so a plain
/// equality check works without needing to unpack either side by hand.
fn pts_rdev(path: &str) -> Option<u64> {
    fs::metadata(path).ok().map(|m| m.rdev())
}

#[derive(Deserialize)]
struct SessionFile {
    pid: i32,
    #[serde(rename = "sessionId")]
    session_id: String,
    cwd: String,
    #[serde(rename = "procStart")]
    proc_start: String,
    name: Option<String>,
    tmux: Option<String>,
}

struct LiveClaudeSession {
    base_dir: PathBuf,
    pid: i32,
    session_id: String,
    cwd: String,
    name: Option<String>,
    /// `None` for a session that wasn't launched inside tmux -- only the
    /// direct pid-ancestry path in `run_enrichment` can ever match it.
    pane_id: Option<String>,
}

/// Every currently-live Claude Code session across every `~/.claude*` config
/// dir (bounded glob, same one claude-history's own `SESSIONS_GLOB` uses --
/// never an unbounded `$HOME` walk). Each `sessions/<pid>.json` is
/// re-verified against `/proc/<pid>/stat`'s own starttime before being
/// trusted, so a stale file left by a killed process (or a reused pid) is
/// never mistaken for a live one.
fn live_claude_sessions() -> Vec<LiveClaudeSession> {
    let mut out = Vec::new();
    let Some(home) = std::env::var_os("HOME") else { return out };
    let Ok(entries) = fs::read_dir(&home) else { return out };
    for entry in entries.flatten() {
        let Some(name) = entry.file_name().to_str().map(str::to_string) else { continue };
        if !name.starts_with(".claude") {
            continue;
        }
        let base_dir = entry.path();
        let Ok(files) = fs::read_dir(base_dir.join("sessions")) else { continue };
        for f in files.flatten() {
            if f.path().extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            let Ok(content) = fs::read_to_string(f.path()) else { continue };
            let Ok(sf) = serde_json::from_str::<SessionFile>(&content) else { continue };
            if !proc_start_matches(sf.pid, &sf.proc_start) {
                continue;
            }
            // "tmux" field format: "<session_name>:@<window_id>.%<pane_id>"
            // (confirmed against live ~/.claude*/sessions/*.json files) --
            // pane_id is globally unique, so pulling it out via the last '%'
            // needs no window/session lookup of its own.
            let pane_id = sf.tmux.as_deref().and_then(|t| t.rsplit_once('%')).map(|(_, id)| format!("%{id}"));
            out.push(LiveClaudeSession {
                base_dir: base_dir.clone(),
                pid: sf.pid,
                session_id: sf.session_id,
                cwd: sf.cwd,
                name: sf.name,
                pane_id,
            });
        }
    }
    out
}

/// Locates `<base_dir>/projects/*/<session_id>.jsonl` by scanning
/// `projects/`'s one level of subdirectories (not a recursive walk) rather
/// than deriving the project directory's own encoded name -- session_id is
/// a UUID, so an exact-filename match is unambiguous without needing to
/// know Claude Code's cwd-encoding scheme at all.
fn find_transcript(base_dir: &Path, session_id: &str) -> Option<PathBuf> {
    let entries = fs::read_dir(base_dir.join("projects")).ok()?;
    for entry in entries.flatten() {
        let candidate = entry.path().join(format!("{session_id}.jsonl"));
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

/// Recursively collects every string leaf in `v` into `out` (space
/// separated), stopping once `budget` bytes are collected. Walking the raw
/// JSON tree rather than binding to Claude Code's transcript schema (message
/// role/content shape) is deliberate: it can't be broken by that schema
/// changing, at the cost of also picking up incidental string fields (ids,
/// tool names) alongside real conversation text -- an acceptable trade for a
/// haystack that's only ever substring/subsequence-matched, never displayed.
fn collect_strings(v: &Value, out: &mut String, budget: usize) {
    if out.len() >= budget {
        return;
    }
    match v {
        Value::String(s) => {
            if s.len() > 2 {
                out.push(' ');
                out.push_str(s);
            }
        }
        Value::Array(items) => {
            for item in items {
                collect_strings(item, out, budget);
                if out.len() >= budget {
                    return;
                }
            }
        }
        Value::Object(map) => {
            for val in map.values() {
                collect_strings(val, out, budget);
                if out.len() >= budget {
                    return;
                }
            }
        }
        _ => {}
    }
}

/// The expensive step: reads and lowercases up to `CLAUDE_CONTENTS_BUDGET`
/// worth of text out of one transcript, read from the *end* of the file
/// backward -- same "recent wins" bias `window-search.py`'s recency
/// weighting and claude-history's own ranking already use, here applied as a
/// hard cutoff instead of a score since there's no corpus to rank against
/// (one document has no idf to speak of, so this stays a plain
/// subsequence-matched field like every other winswitch field rather than
/// reimplementing BM25 for n=1).
fn load_claude_contents(base_dir: &Path, session_id: &str) -> Option<String> {
    let path = find_transcript(base_dir, session_id)?;
    let content = fs::read_to_string(path).ok()?;
    let mut out = String::new();
    for line in content.lines().rev() {
        if out.len() >= CLAUDE_CONTENTS_BUDGET {
            break;
        }
        let Ok(v) = serde_json::from_str::<Value>(line) else { continue };
        collect_strings(&v, &mut out, CLAUDE_CONTENTS_BUDGET);
    }
    Some(out.to_lowercase())
}

fn run_enrichment(win_specs: Vec<(usize, i32)>, tx: mpsc::Sender<(usize, TmuxClaudeMeta)>) {
    let procs = read_all_proc();
    let sessions = live_claude_sessions();

    // Direct pid-ancestry match first -- covers "claude run straight in a
    // plain terminal," and costs nothing beyond the /proc pass already done.
    let mut claude_by_index: HashMap<usize, usize> = HashMap::new(); // window idx -> sessions[] idx
    for (idx, pid) in &win_specs {
        let desc = descendants(&procs, *pid);
        if let Some(si) = sessions.iter().position(|s| desc.contains(&s.pid)) {
            claude_by_index.insert(*idx, si);
        }
    }

    // tmux enrichment, and the tty-based path to a claude session for
    // windows the direct pid check above couldn't reach (tmux's actual
    // shell/claude process is a child of the detached tmux server, never of
    // the terminal emulator window -- see module doc).
    let clients = tmux_clients();
    if !clients.is_empty() {
        let panes = tmux_panes();
        let pts_cache: HashMap<&str, u64> =
            clients.iter().filter_map(|c| pts_rdev(&c.tty).map(|r| (c.tty.as_str(), r))).collect();

        for (idx, pid) in &win_specs {
            let desc_ttys: Vec<u64> = descendants(&procs, *pid)
                .iter()
                .filter_map(|p| procs.get(p))
                .map(|i| i.tty_nr)
                .filter(|&t| t != 0)
                .collect();
            if desc_ttys.is_empty() {
                continue;
            }
            let Some(client) = clients.iter().find(|c| pts_cache.get(c.tty.as_str()).is_some_and(|r| desc_ttys.contains(r))) else {
                continue;
            };
            // Every pane belonging to the window this client currently has
            // on screen -- not just the focused one. A split layout means a
            // pane running claude is genuinely visible even while some
            // *other* pane in the same window has keyboard focus, so
            // presence has to be checked across the whole visible window;
            // tmux_window/tmux_title stay tied to the active pane
            // specifically, since those describe what's focused, not
            // what's merely visible.
            let window_panes: Vec<&TmuxPane> = panes.iter().filter(|p| p.window_id == client.window_id).collect();
            let active_pane = window_panes.iter().find(|p| p.active).copied();
            let mut meta = TmuxClaudeMeta {
                tmux_session: Some(client.session.clone()),
                ..Default::default()
            };
            if let Some(p) = active_pane {
                meta.tmux_window = Some(p.window_name.clone());
                meta.tmux_title = Some(p.pane_title.clone());
            }
            let _ = tx.send((*idx, meta));

            if claude_by_index.contains_key(idx) {
                continue;
            }
            let si = window_panes
                .iter()
                .find_map(|p| sessions.iter().position(|s| s.pane_id.as_deref() == Some(p.pane_id.as_str())));
            if let Some(si) = si {
                claude_by_index.insert(*idx, si);
            }
        }
    }

    // Cheap claude metadata (no transcript read) for every match found
    // above, then hand the expensive contents read off to its own thread
    // per window -- bounded by "open windows only," so at most a handful.
    for (idx, si) in claude_by_index {
        let session = &sessions[si];
        let meta = TmuxClaudeMeta {
            claude_title: Some(session.name.clone().unwrap_or_else(|| session.session_id.clone())),
            claude_path: Some(session.cwd.clone()),
            claude_session: Some(session.session_id.clone()),
            ..Default::default()
        };
        let _ = tx.send((idx, meta));

        let base_dir = session.base_dir.clone();
        let session_id = session.session_id.clone();
        let tx = tx.clone();
        std::thread::spawn(move || {
            if let Some(contents) = load_claude_contents(&base_dir, &session_id) {
                let meta = TmuxClaudeMeta { claude_contents: Some(contents), ..Default::default() };
                let _ = tx.send((idx, meta));
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Not a unit test -- runs the real enrichment pipeline against this
    /// machine's actual open windows, live tmux server, and live
    /// ~/.claude*/sessions state, and prints what it found. `#[ignore]`d
    /// because its result depends entirely on what's running right now;
    /// this is how the tty/pid correlation logic was actually verified
    /// against real state (see the window-search-debugging-session memory
    /// for why that beats a simulated test here). Run with:
    ///   cargo test --release manual_enrichment_check -- --ignored --nocapture
    #[test]
    #[ignore]
    fn manual_enrichment_check() {
        let windows = crate::hyprctl::list_windows();
        eprintln!("open windows: {} ({} tmux clients, {} live claude sessions)", windows.len(), tmux_clients().len(), live_claude_sessions().len());

        let win_specs: Vec<(usize, i32)> = windows.iter().enumerate().map(|(i, w)| (i, w.pid)).collect();
        let (tx, rx) = mpsc::channel();
        run_enrichment(win_specs, tx);

        let mut results: HashMap<usize, TmuxClaudeMeta> = HashMap::new();
        while let Ok((idx, meta)) = rx.recv_timeout(Duration::from_secs(2)) {
            results.entry(idx).or_default().merge(meta);
        }

        for (idx, meta) in &results {
            let w = &windows[*idx];
            println!(
                "window[{idx}] pid={} class={:?} title={:?}\n  tmux_session={:?} tmux_window={:?} tmux_title={:?}\n  claude_title={:?} claude_path={:?} claude_session={:?} claude_contents_len={:?}",
                w.pid,
                w.class,
                w.title,
                meta.tmux_session,
                meta.tmux_window,
                meta.tmux_title,
                meta.claude_title,
                meta.claude_path,
                meta.claude_session,
                meta.claude_contents.as_ref().map(|c| c.len()),
            );
        }
        assert!(!results.is_empty(), "expected at least one open window to correlate with live tmux/claude state");
    }
}
