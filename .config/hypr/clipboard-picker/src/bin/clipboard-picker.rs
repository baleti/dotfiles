//! cliphist picker headless backend. UI moved to Quickshell/QML
//! (~/.config/quickshell/clipboard/ClipboardPicker.qml, mirroring winswitch's
//! GTK->Quickshell move) on 2026-09-11; this binary now just talks to
//! cliphist/wl-copy and prints NDJSON, the same split winswitch's
//! output.rs/main.rs settled on. `notification-picker` (this crate's other
//! bin) is untouched and still the GTK+layer-shell `picker::run` engine --
//! only mod+v moved.
//!
//! Subcommands:
//!   list             one NDJSON line per cliphist entry, then exit
//!   thumb <id>       ensure `<id>.png`'s scaled thumbnail is cached, print
//!                    its path (nothing if the entry isn't a decodable image)
//!   thumbs <id>...   same as `thumb`, batched -- one `{id,path,width,height}`
//!                    NDJSON line per successfully decoded id, streamed as
//!                    each one finishes rather than held until the last
//!                    (same streaming-output reasoning as winswitch's
//!                    output.rs)
//!   texts <id>...    full decoded text for ids whose `list` preview
//!                    cliphist itself truncated -- one `{id,text}` NDJSON
//!                    line per id, streamed
//!   activate <id>    decode `<id>` and push it to the clipboard (wl-copy)

use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use gdk_pixbuf::prelude::*;
use gdk_pixbuf::{InterpType, Pixbuf, PixbufLoader};
use serde_json::json;

use clipboard_picker::picker::{self, Entry};

const PROGRAM_NAME: &str = "clipboard-picker";
const THUMB_HEIGHT: i32 = 160;
const THUMB_MAX_WIDTH: i32 = 480;

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

/// id -> (chars, lines), from `cliphist-store-logged.sh`'s `sizes` log
/// (written at copy time) plus anything `stats` has since backfilled. An id
/// with no line just gets no badge until `stats` fills it in.
fn read_sizes() -> HashMap<String, (u64, u64)> {
    let Ok(text) = fs::read_to_string(cliphist_state_dir().join("sizes")) else {
        return HashMap::new();
    };
    text.lines()
        .filter_map(|line| {
            let mut it = line.split('\t');
            let id = it.next()?;
            Some((id.to_string(), (it.next()?.parse().ok()?, it.next()?.parse().ok()?)))
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
            let (id, mut preview) = match line.split_once('\t') {
                Some((a, b)) => (a.to_string(), b.to_string()),
                None => (line.to_string(), String::new()),
            };
            // Overflow placeholder (see resolve_overflow): hide the hash line.
            let mut overflow = false;
            if let Some(i) = preview.find(" overflow:") {
                preview.truncate(i);
                overflow = true;
            }
            let is_image = looks_like_image(&preview);
            // A non-image binary overflow (pdf, video, office doc...) is
            // offered a thumbnail optimistically; `thumbs` answers `nothumb`
            // if no thumbnailer can make one and the row reverts to text.
            let is_file = overflow && !is_image && preview.starts_with("[[");
            let kind = if is_image { "image" } else if is_file { "file" } else { "text" };
            let mut fields = vec![("type", kind.to_string())];
            if let Some(&ts) = timestamps.get(&id) {
                fields.push(("date", picker::humanize_ago(ts, now)));
            }
            Entry {
                haystack: preview.to_lowercase(),
                thumb: is_image || is_file,
                fields,
                id,
                preview,
            }
        })
        .collect()
}

/// cliphist silently drops entries above ~5 MB, so cliphist-store-logged.sh
/// keeps bigger ones as private files under `large/` and stores a small
/// placeholder whose last line is `overflow:<sha256>`. Resolve that back to
/// the real bytes; anything else passes through untouched.
fn resolve_overflow(raw: Vec<u8>) -> Vec<u8> {
    if raw.len() > 4096 {
        return raw;
    }
    let text = String::from_utf8_lossy(&raw);
    let hash = match text.lines().last().and_then(|l| l.strip_prefix("overflow:")) {
        Some(h) => h.trim(),
        None => return raw,
    };
    if hash.len() != 64 || !hash.bytes().all(|b| b.is_ascii_hexdigit()) {
        return raw;
    }
    fs::read(cliphist_state_dir().join("large").join(hash)).unwrap_or_default()
}

fn decode(id: &str) -> Vec<u8> {
    let raw = Command::new("cliphist")
        .args(["decode", id])
        .output()
        .map(|o| o.stdout)
        .unwrap_or_default();
    resolve_overflow(raw)
}

fn pixbuf_from(bytes: &[u8]) -> Option<Pixbuf> {
    let loader = PixbufLoader::new();
    if loader.write(bytes).is_err() || loader.close().is_err() {
        return None;
    }
    loader.pixbuf()
}

/// Exec line of the first freedesktop `.thumbnailer` that claims `mime`.
fn find_thumbnailer(mime: &str) -> Option<String> {
    let home = std::env::var("HOME").unwrap_or_default();
    let dirs = [format!("{home}/.local/share/thumbnailers"), "/usr/share/thumbnailers".to_string()];
    for d in dirs {
        let Ok(rd) = fs::read_dir(&d) else { continue };
        let mut files: Vec<_> = rd.flatten().map(|e| e.path()).collect();
        files.sort();
        for f in files {
            if f.extension().and_then(|e| e.to_str()) != Some("thumbnailer") {
                continue;
            }
            let Ok(text) = fs::read_to_string(&f) else { continue };
            let (mut exec, mut mimes) = (None, false);
            for l in text.lines() {
                if let Some(v) = l.strip_prefix("Exec=") {
                    exec = Some(v.trim().to_string());
                } else if let Some(v) = l.strip_prefix("MimeType=") {
                    mimes = v.split(';').any(|m| m.trim() == mime);
                }
            }
            if let (Some(e), true) = (exec, mimes) {
                return Some(e);
            }
        }
    }
    None
}

/// PNG thumbnail for non-image data (PDF, office docs, video, audio...) via
/// the system's freedesktop thumbnailers. These are big decoders (poppler,
/// ffmpeg, libgsf), so each runs inside bubblewrap with no network, no
/// access to $HOME, only the one input file (read-only) and a scratch output
/// dir, under a hard timeout and address-space/CPU limits.
fn external_thumb(id: &str, raw: &[u8]) -> Option<Vec<u8>> {
    if raw.is_empty() || raw.len() > 512 * 1024 * 1024 {
        return None;
    }
    let dir = picker::cache_dir(PROGRAM_NAME);
    let work = dir.join(format!("{id}.tw"));
    let _ = fs::remove_dir_all(&work);
    fs::create_dir_all(work.join("out")).ok()?;
    let cleanup = |r: Option<Vec<u8>>| {
        let _ = fs::remove_dir_all(&work);
        r
    };
    let src = work.join("in");
    let wrote = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&src)
        .and_then(|mut f| f.write_all(raw));
    if wrote.is_err() {
        return cleanup(None);
    }
    let mime = Command::new("file")
        .args(["-b", "--mime-type"])
        .arg(&src)
        .stdin(Stdio::null())
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default();
    let Some(exec) = find_thumbnailer(&mime) else { return cleanup(None) };

    let size = THUMB_HEIGHT.to_string();
    let argv: Vec<String> = exec
        .split_whitespace()
        .map(|t| {
            t.trim_matches('"')
                .replace("%%", "\0")
                .replace("%i", "/w/in")
                .replace("%u", "file:///w/in")
                .replace("%o", "/w/out/thumb.png")
                .replace("%s", &size)
                .replace('\0', "%")
        })
        .collect();
    if argv.is_empty() {
        return cleanup(None);
    }
    let status = Command::new("timeout")
        .args(["25", "prlimit", "--as=4294967296", "--cpu=20", "bwrap"])
        .args([
            "--unshare-all", "--die-with-parent", "--new-session", "--cap-drop", "ALL", "--clearenv",
            "--setenv", "HOME", "/tmp", "--setenv", "PATH", "/usr/bin", "--setenv", "XDG_CACHE_HOME", "/tmp",
            "--ro-bind", "/usr", "/usr", "--ro-bind", "/etc", "/etc",
            "--symlink", "usr/lib", "/lib", "--symlink", "usr/lib", "/lib64",
            "--symlink", "usr/bin", "/bin", "--symlink", "usr/bin", "/sbin",
            "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp",
        ])
        .arg("--ro-bind")
        .arg(&src)
        .arg("/w/in")
        .arg("--bind")
        .arg(work.join("out"))
        .arg("/w/out")
        .arg("--")
        .args(&argv)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    let png = if status.map(|s| s.success()).unwrap_or(false) {
        fs::read(work.join("out/thumb.png")).ok().filter(|b| !b.is_empty() && b.len() < 32 * 1024 * 1024)
    } else {
        None
    };
    cleanup(png)
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
    let pb = pixbuf_from(&raw)
        .or_else(|| external_thumb(id, &raw).and_then(|png| pixbuf_from(&png)))?;

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
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&dir, fs::Permissions::from_mode(0o700));
        let _ = fs::set_permissions(&cached, fs::Permissions::from_mode(0o600));
    }
    Some(pb)
}

/// Small looping preview for animated GIFs, cached as `<id>.anim.gif`; None
/// for anything that isn't a multi-frame GIF. The quickshell process never
/// decodes the original: ImageMagick re-encodes it in a throwaway subprocess
/// (explicit `gif:` coder so it can't be talked into another format, resource
/// limits, hard timeout, frame cap) and QML only loads that clean output, so a
/// malformed clipboard GIF can at worst kill a short-lived child. A
/// `<id>.noanim` marker records "checked, not animated" so opening the picker
/// never re-decodes the same entry.
fn ensure_anim(id: &str) -> Option<PathBuf> {
    let dir = picker::cache_dir(PROGRAM_NAME);
    let out = dir.join(format!("{id}.anim.gif"));
    if out.metadata().map(|m| m.len() > 0).unwrap_or(false) {
        return Some(out);
    }
    let marker = dir.join(format!("{id}.noanim"));
    if marker.exists() {
        return None;
    }
    let _ = fs::create_dir_all(&dir);
    let mark_none = || {
        let _ = fs::write(&marker, b"");
        None
    };

    let raw = decode(id);
    if !(raw.starts_with(b"GIF87a") || raw.starts_with(b"GIF89a")) {
        return mark_none();
    }
    let src = dir.join(format!("{id}.src.gif"));
    let written = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&src)
        .and_then(|mut f| f.write_all(&raw));
    if written.is_err() {
        let _ = fs::remove_file(&src);
        return None;
    }
    let tmp_out = dir.join(format!("{id}.anim.tmp.gif"));
    let status = Command::new("timeout")
        .args(["15", "magick"])
        .args([
            "-limit", "memory", "256MiB", "-limit", "map", "256MiB", "-limit", "disk", "512MiB",
            "-limit", "area", "200MP", "-limit", "width", "16KP", "-limit", "height", "16KP",
            "-limit", "time", "10", "-limit", "thread", "2",
        ])
        .arg(format!("gif:{}[0-59]", src.display()))
        .args(["-coalesce", "-resize", "360x120>", "-layers", "OptimizePlus", "-loop", "0"])
        .arg(format!("gif:{}", tmp_out.display()))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    let _ = fs::remove_file(&src);
    let ok = status.map(|s| s.success()).unwrap_or(false);
    let frames = if ok {
        Command::new("identify")
            .args(["-format", "%n\n"])
            .arg(format!("gif:{}", tmp_out.display()))
            .stdin(Stdio::null())
            .output()
            .ok()
            .and_then(|o| String::from_utf8_lossy(&o.stdout).lines().next().and_then(|l| l.trim().parse::<u32>().ok()))
            .unwrap_or(0)
    } else {
        0
    };
    if frames < 2 {
        let _ = fs::remove_file(&tmp_out);
        return if ok { mark_none() } else { None };
    }
    use std::os::unix::fs::PermissionsExt;
    let _ = fs::set_permissions(&tmp_out, fs::Permissions::from_mode(0o600));
    if fs::rename(&tmp_out, &out).is_err() {
        let _ = fs::remove_file(&tmp_out);
        return None;
    }
    Some(out)
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

/// One NDJSON line per entry: `{id, preview, haystack, thumb, fields}`,
/// `fields` an object keyed by field name (`type`, optionally `date`) --
/// same field set `cliphist_list` always built, just serialized instead of
/// stuffed into a GTK row. QML's ClipboardQueryDsl.qml is the field-name
/// registry now (was `FIELD_NAMES`/`field_descs` here).
fn print_list(entries: &[Entry]) {
    let mut out = std::io::stdout().lock();
    let sizes = read_sizes();
    for e in entries {
        let size = sizes.get(&e.id);
        let fields: serde_json::Map<String, serde_json::Value> =
            e.fields.iter().map(|(k, v)| ((*k).to_string(), json!(v))).collect();
        let line = json!({
            "id": e.id,
            "preview": e.preview,
            "haystack": e.haystack,
            "thumb": e.thumb,
            "fields": fields,
            "chars": size.map(|s| s.0),
            "lines": size.map(|s| s.1),
        });
        let _ = writeln!(out, "{line}");
    }
}

fn main() {
    let mut args = std::env::args().skip(1);
    match args.next().as_deref() {
        Some("thumb") => {
            let Some(id) = args.next() else {
                eprintln!("usage: {PROGRAM_NAME} thumb <id>");
                std::process::exit(1);
            };
            if load_thumb(&id).is_some() {
                let path = picker::cache_dir(PROGRAM_NAME).join(format!("{id}.png"));
                println!("{}", path.display());
            }
        }
        Some("thumbs") => {
            // Reports the cached PNG's own pixel dimensions alongside its
            // path -- QML computes its own further downscale (this file's
            // THUMB_HEIGHT/THUMB_MAX_WIDTH are a first, coarser cap; the
            // frontend's own, usually smaller, target is applied from these
            // real numbers) rather than guessing at how Image's `sourceSize`
            // reflects into `implicitWidth`/`implicitHeight`, the same
            // "report real numbers, don't make the frontend guess" reasoning
            // as winswitch's own `output.rs::thumbnail`.
            let mut out = std::io::stdout().lock();
            for id in args {
                if let Some(pb) = load_thumb(&id) {
                    let path = picker::cache_dir(PROGRAM_NAME).join(format!("{id}.png"));
                    let _ = writeln!(
                        out,
                        "{}",
                        json!({"id": id, "path": path.display().to_string(), "width": pb.width(), "height": pb.height()})
                    );
                    let _ = out.flush();
                    // Second line, after the still is already on screen.
                    if let Some(a) = ensure_anim(&id) {
                        let _ = writeln!(out, "{}", json!({"id": id, "anim": a.display().to_string()}));
                        let _ = out.flush();
                    }
                } else {
                    let _ = writeln!(out, "{}", json!({"id": id, "nothumb": true}));
                    let _ = out.flush();
                }
            }
        }
        Some("texts") => {
            // Full decoded text for entries whose `list` preview cliphist
            // itself truncated (fixed ~100-rune cap plus its own "…",
            // regardless of how wide the picker's search box actually is --
            // reported as text eliding "too early" when it was really just
            // short data, not a layout bug). One `{id,text}` NDJSON line per
            // id that actually decodes to something.
            let mut out = std::io::stdout().lock();
            for id in args {
                let raw = decode(&id);
                if raw.is_empty() {
                    continue;
                }
                let text = String::from_utf8_lossy(&raw).into_owned();
                let _ = writeln!(out, "{}", json!({"id": id, "text": text}));
                let _ = out.flush();
            }
        }
        Some("stats") => {
            // `{id,chars,lines}` of the full decoded text per id, streamed as
            // each decodes -- for the row's size badge (cliphist's preview
            // flattens newlines and caps at ~100 runes, so neither is
            // recoverable from `list`). Kept out of `list` on purpose:
            // decoding every entry there delayed the picker's first paint
            // (reported 2026-09-19); the frontend fires this after `list`
            // and merges results in as they arrive. Ids that don't decode to
            // text (images, empty) are simply skipped.
            let mut out = std::io::stdout().lock();
            // Also persisted to the `sizes` log so this only ever runs once
            // per pre-existing entry (new ones are logged at copy time).
            let mut log = fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(cliphist_state_dir().join("sizes"))
                .ok();
            for id in args {
                let raw = decode(&id);
                if raw.is_empty() || raw.starts_with(b"\x89PNG") || raw.starts_with(b"\xff\xd8") {
                    continue;
                }
                let text = String::from_utf8_lossy(&raw);
                let trimmed = text.trim_end_matches(['\n', '\r']);
                let (chars, lines) = (trimmed.chars().count(), trimmed.lines().count().max(1));
                if let Some(f) = log.as_mut() {
                    let _ = writeln!(f, "{id}\t{chars}\t{lines}");
                }
                let _ = writeln!(out, "{}", json!({"id": id, "chars": chars, "lines": lines}));
                let _ = out.flush();
            }
        }
        Some("activate") => {
            let Some(id) = args.next() else {
                eprintln!("usage: {PROGRAM_NAME} activate <id>");
                std::process::exit(1);
            };
            copy_entry(&id);
        }
        None | Some("list") => print_list(&cliphist_list()),
        Some(other) => {
            eprintln!("{PROGRAM_NAME}: unknown subcommand {other:?}");
            std::process::exit(1);
        }
    }
}
