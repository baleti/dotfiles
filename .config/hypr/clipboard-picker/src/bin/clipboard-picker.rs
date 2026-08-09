//! cliphist picker on GTK3 + wlr-layer-shell, built on the shared `picker`
//! engine. Rust port of clipboard-picker.py: same behaviour, but without the
//! ~140ms the Python version spent on interpreter startup and
//! GObject-introspection typelib loading before it could draw anything.

use std::fs;
use std::io::Write;
use std::process::{Command, Stdio};
use std::rc::Rc;

use gdk_pixbuf::prelude::*;
use gdk_pixbuf::{InterpType, Pixbuf, PixbufLoader};

use clipboard_picker::picker::{self, Entry, PickerConfig};

const PROGRAM_NAME: &str = "clipboard-picker";
const THUMB_HEIGHT: i32 = 160;
const THUMB_MAX_WIDTH: i32 = 480;

/// Entry kinds selectable from the search box with `$name`.
///
/// cliphist itself only ever distinguishes images: it emits
/// "[[ binary data 50 KiB png 600x509 ]]" when the bytes decode as an image and
/// falls back to a text preview for everything else, discarding the MIME type
/// wl-paste saw. So kinds are derived here from the preview, and adding one is
/// a matter of extending this table plus `classify`.
const TYPE_NAMES: [&str; 2] = ["image", "text"];
const KIND_IMAGE: usize = 0;
const KIND_TEXT: usize = 1;

fn classify(preview: &str) -> usize {
    if looks_like_image(preview) {
        KIND_IMAGE
    } else {
        KIND_TEXT
    }
}

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

fn cliphist_list() -> Vec<Entry> {
    let out = match Command::new("cliphist").arg("list").output() {
        Ok(o) => o.stdout,
        Err(_) => return Vec::new(),
    };
    String::from_utf8_lossy(&out)
        .lines()
        .filter(|l| !l.is_empty())
        .map(|line| {
            let (id, preview) = match line.split_once('\t') {
                Some((a, b)) => (a.to_string(), b.to_string()),
                None => (line.to_string(), String::new()),
            };
            let kind = classify(&preview);
            Entry {
                haystack: preview.to_lowercase(),
                thumb: kind == KIND_IMAGE,
                kind,
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
        type_names: TYPE_NAMES.iter().map(|s| s.to_string()).collect(),
        placeholder: "search   ·   $image  $text".to_string(),
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
