//! cliphist picker on GTK3 + wlr-layer-shell, built on the shared `picker`
//! engine. Rust port of clipboard-picker.py: same behaviour, but without the
//! ~140ms the Python version spent on interpreter startup and
//! GObject-introspection typelib loading before it could draw anything.

use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::rc::Rc;
use std::time::{SystemTime, UNIX_EPOCH};

use gdk_pixbuf::prelude::*;
use gdk_pixbuf::{InterpType, Pixbuf, PixbufLoader};

use clipboard_picker::picker::{self, Entry, PickerConfig};

const PROGRAM_NAME: &str = "clipboard-picker";
const THUMB_HEIGHT: i32 = 160;
const THUMB_MAX_WIDTH: i32 = 480;
/// `/fv field:value`-selectable fields, offered by the autocomplete popup.
const FIELD_NAMES: [&str; 2] = ["type", "date"];

/// cliphist renders non-text entries as "[[ binary data 50 KiB png 600x509 ]]".
fn looks_like_image(preview: &str) -> bool {
    let p = preview.trim_start();
    if !p.starts_with("[[") {
        return false;
    }
    let lower = p.to_ascii_lowercase();
    lower.contains("binary data")
        && ["png", "jpg", "jpeg", "gif", "bmp", "webp"]
            .iter()
            .any(|ext| lower.contains(ext))
}

/// `cliphist-expire.sh`'s own state directory -- shared with
/// `cliphist-store-logged.sh` (wired into hyprland.lua's wl-paste --watch),
/// which is what actually writes the id-to-timestamp log this reads from.
/// Kept alongside that script's own watermarks rather than a new directory,
/// since both are "cliphist-adjacent state cliphist itself doesn't keep."
fn cliphist_state_dir() -> PathBuf {
    let base = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".local/state"));
    base.join("cliphist-expire")
}

/// id -> exact copy-time (Unix seconds), from `cliphist-store-logged.sh`'s
/// log. An id with no line here was copied before that wrapper existed (or
/// its log line has since been pruned by cliphist-expire.sh once the entry
/// itself expired) -- such entries just have no `date` field at all (see
/// `cliphist_list`), same "absent, not empty" contract `Entry::fields` uses
/// throughout.
fn read_timestamps() -> HashMap<String, u64> {
    let path = cliphist_state_dir().join("timestamps");
    let Ok(text) = fs::read_to_string(&path) else {
        return HashMap::new();
    };
    text.lines()
        .filter_map(|line| {
            let (ts, id) = line.split_once('\t')?;
            Some((id.to_string(), ts.parse().ok()?))
        })
        .collect()
}

fn cliphist_list() -> Vec<Entry> {
    let out = match Command::new("cliphist").arg("list").output() {
        Ok(o) => o.stdout,
        Err(_) => return Vec::new(),
    };
    let timestamps = read_timestamps();
    let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    String::from_utf8_lossy(&out)
        .lines()
        .filter(|l| !l.is_empty())
        .map(|line| {
            let (id, preview) = match line.split_once('\t') {
                Some((a, b)) => (a.to_string(), b.to_string()),
                None => (line.to_string(), String::new()),
            };
            let is_image = looks_like_image(&preview);
            let mut fields = vec![("type", (if is_image { "image" } else { "text" }).to_string())];
            if let Some(&ts) = timestamps.get(&id) {
                fields.push(("date", picker::humanize_ago(ts, now)));
            }
            Entry {
                haystack: preview.to_lowercase(),
                thumb: is_image,
                fields,
                id,
                preview,
            }
        })
        .collect()
}

fn decode(id: &str) -> Vec<u8> {
    Command::new("cliphist")
        .args(["decode", id])
        .output()
        .map(|o| o.stdout)
        .unwrap_or_default()
}

/// Scaled pixbuf for an image entry, cached on disk. None if undecodable.
fn load_thumb(id: &str) -> Option<Pixbuf> {
    let cached = picker::cache_dir(PROGRAM_NAME).join(format!("{id}.png"));
    if cached.metadata().map(|m| m.len() > 0).unwrap_or(false) {
        if let Ok(pb) = Pixbuf::from_file(&cached) {
            return Some(pb);
        }
        let _ = fs::remove_file(&cached);
    }

    let raw = decode(id);
    if raw.is_empty() {
        return None;
    }
    let loader = PixbufLoader::new();
    if loader.write(&raw).is_err() || loader.close().is_err() {
        return None;
    }
    let pb = loader.pixbuf()?;

    // Scale on height, then clamp very wide images. Unlike wofi we don't fit a
    // square, so panoramic screenshots don't shrink to nothing.
    let (w, h) = (pb.width(), pb.height());
    let pb = if h > 0 {
        let mut tw = ((w as f64) * (THUMB_HEIGHT as f64) / (h as f64)).round() as i32;
        let mut th = THUMB_HEIGHT;
        if tw > THUMB_MAX_WIDTH {
            th = ((h as f64) * (THUMB_MAX_WIDTH as f64) / (w as f64)).round() as i32;
            tw = THUMB_MAX_WIDTH;
        }
        pb.scale_simple(tw.max(1), th.max(1), InterpType::Bilinear)?
    } else {
        pb
    };

    let dir = picker::cache_dir(PROGRAM_NAME);
    let _ = fs::create_dir_all(&dir);
    let _ = pb.savev(&cached, "png", &[]);
    Some(pb)
}

fn copy_entry(id: &str) {
    let data = decode(id);
    if data.is_empty() {
        return;
    }
    if let Ok(mut child) = Command::new("wl-copy").stdin(Stdio::piped()).spawn() {
        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(&data);
        }
        let _ = child.wait();
    }
}

fn main() {
    let entries = cliphist_list();

    let config = PickerConfig {
        program_name: PROGRAM_NAME,
        field_names: FIELD_NAMES.to_vec(),
        field_descs: vec![
            ("type", "text or image"),
            ("date", "how long ago it was copied"),
        ],
        placeholder: "search   ·   $type:  $date:".to_string(),
        width_fraction: 0.5,
        height_fraction: 0.8,
        thumb_height: THUMB_HEIGHT,
        initial_rows: 60,
        chunk_rows: 120,
    };

    picker::run(
        entries,
        config,
        Some(Rc::new(load_thumb)),
        Box::new(|entry: &Entry| copy_entry(&entry.id)),
    );
}
