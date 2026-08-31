#!/usr/bin/env python3
"""rssd - poll RSS/Atom feeds, notify on new items, archive them.

Timer-driven (see rssd.timer); not a long-running process.

  rssd            fetch all feeds, notify + archive new items
  rssd seed       mark everything currently in the feeds as seen, no notifications
  rssd dry-run    fetch and report what WOULD notify, without touching state
  rssd list       show what feeds/tags the config parses to, plus last status
  rssd icons      (re)resolve every feed's site icon into the cache
  rssd opml       write the feed list as OPML to stdout (import into any reader)
  rssd add URL [tag ...]   append a feed line to the feeds file

Files (everything lives under ~/.cache so it stays out of backup snapshots):
  ~/.config/rssd/feeds                  feed list (newsboat-style: url  tag...  # comment)
  ~/.config/rssd/config                 behaviour (key = value)
  ~/.cache/rssd/seen.json               per-feed seen-item ids + http validators + icon
  ~/.cache/rssd/items.jsonl             append-only archive of every new item
  ~/.cache/rssd/icons/<host>.<ext>      resolved per-source favicons
  ~/.cache/rssd/media/<hash>.<ext>      downloaded article lead images
"""

from __future__ import annotations

import concurrent.futures
import hashlib
import html
import io
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urljoin, urlsplit

import feedparser

CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "rssd"
CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "rssd"
FEEDS_FILE = CONFIG_DIR / "feeds"
CONFIG_FILE = CONFIG_DIR / "config"
SEEN_FILE = CACHE_DIR / "seen.json"
ARCHIVE_FILE = CACHE_DIR / "items.jsonl"
ICON_DIR = CACHE_DIR / "icons"
MEDIA_DIR = CACHE_DIR / "media"

UA = "rssd/1.1 (feed reader; +https://localhost)"
feedparser.USER_AGENT = UA

DEFAULTS = {
    "notify": "true",
    "archive": "true",
    "max_notify_per_feed": "4",
    "max_notify_total": "20",
    "urgency": "low",
    "summary_chars": "220",
    "workers": "8",
    "timeout": "20",
    "prune_days": "90",
    "archive_days": "30",
    # source icons shown as the notification icon (falls back to a generic
    # rss glyph when a feed has no resolvable favicon)
    "fetch_favicons": "true",
    "favicon_refresh_days": "30",
    # article lead images: download + cache them, and/or show them in the card
    "fetch_images": "true",
    "notify_images": "true",
    "image_max_bytes": "3000000",
}

# magic-byte signatures for the image types Qt's loader handles
_IMAGE_SIGS = {
    b"\x89PNG\r\n\x1a\n": "png",
    b"\xff\xd8\xff": "jpg",
    b"GIF87a": "gif",
    b"GIF89a": "gif",
    b"RIFF": "webp",  # RIFF....WEBP, checked further below
    b"\x00\x00\x01\x00": "ico",
    b"<?xml": "svg",
    b"<svg": "svg",
}

_TAG_RE = re.compile(r"<[^>]+>")
_WS_RE = re.compile(r"\s+")
_IMG_RE = re.compile(r"<img[^>]+src=[\"']([^\"']+)[\"']", re.I)
_LINK_ICON_RE = re.compile(
    r"<link\b[^>]*rel=[\"'][^\"']*icon[^\"']*[\"'][^>]*>", re.I)
_HREF_RE = re.compile(r"href=[\"']([^\"']+)[\"']", re.I)


def log(*a):
    print(*a, file=sys.stderr, flush=True)


# ---------------------------------------------------------------- config / feeds

def load_config() -> dict:
    cfg = dict(DEFAULTS)
    if CONFIG_FILE.exists():
        for raw in CONFIG_FILE.read_text().splitlines():
            line = raw.split("#", 1)[0].strip()
            if not line or "=" not in line:
                continue
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip()
    return cfg


def cfg_bool(cfg, key):
    return cfg.get(key, "").strip().lower() in ("1", "true", "yes", "on")


def cfg_int(cfg, key):
    try:
        return int(cfg[key])
    except (KeyError, ValueError):
        return int(DEFAULTS[key])


def load_feeds() -> list[dict]:
    if not FEEDS_FILE.exists():
        log(f"no feeds file at {FEEDS_FILE}")
        return []
    feeds = []
    for raw in FEEDS_FILE.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        feeds.append({"url": parts[0], "tags": parts[1:]})
    return feeds


# ---------------------------------------------------------------- state

def load_seen() -> dict:
    if SEEN_FILE.exists():
        try:
            data = json.loads(SEEN_FILE.read_text())
            data.setdefault("feeds", {})
            return data
        except (json.JSONDecodeError, OSError) as e:
            log(f"seen.json unreadable ({e}); starting fresh")
    return {"feeds": {}}


def save_seen(state: dict):
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = SEEN_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, separators=(",", ":")))
    tmp.replace(SEEN_FILE)


def prune_seen(feed_state: dict, prune_days: int):
    cutoff = time.time() - prune_days * 86400
    seen = feed_state.get("seen", {})
    if len(seen) <= 50:
        return
    keep = {k: v for k, v in seen.items() if v >= cutoff}
    if len(keep) < 50:
        for k, _ in sorted(seen.items(), key=lambda kv: kv[1], reverse=True)[:50]:
            keep[k] = seen[k]
    feed_state["seen"] = keep


# ---------------------------------------------------------------- http

def http_get(url: str, timeout: int, max_bytes: int = 0) -> tuple[bytes, str]:
    """GET url, returning (body, content_type). Raises on error / over-size."""
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        ctype = resp.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
        if max_bytes:
            data = resp.read(max_bytes + 1)
            if len(data) > max_bytes:
                raise ValueError(f"over {max_bytes} bytes")
        else:
            data = resp.read()
    return data, ctype


def sniff_image_ext(data: bytes) -> str | None:
    for sig, ext in _IMAGE_SIGS.items():
        if data.startswith(sig):
            if ext == "webp" and data[8:12] != b"WEBP":
                continue
            return ext
    return None


# ---------------------------------------------------------------- favicons

def _slug(host: str) -> str:
    return re.sub(r"[^a-z0-9.-]", "_", host.lower().removeprefix("www."))


def cached_icon(host: str) -> Path | None:
    for p in sorted(ICON_DIR.glob(_slug(host) + ".*")):
        return p
    return None


# favicon extensions Qt renders well and that make sense at 32px (SVG skipped:
# some are huge and the feedburner one is a generic bird)
_FAVICON_CTYPES = {
    "image/x-icon": "ico", "image/vnd.microsoft.icon": "ico",
    "image/jpeg": "jpg", "image/png": "png", "image/gif": "gif",
    "image/webp": "webp",
}


def favicon_host(feed_url: str, site_url: str | None) -> str:
    """Host to hang the icon off: the publication's own site if the feed
    advertised one (feedburner/substack proxies), else the feed url's host."""
    for u in (site_url, feed_url):
        if u:
            h = urlsplit(u).netloc
            if h and "feedburner" not in h and "feedproxy" not in h:
                return h
    return urlsplit(feed_url).netloc


def resolve_favicon(host: str, feed_image_href: str | None, timeout: int) -> Path | None:
    """Find a usable site icon for `host` and cache it. Returns its path.

    Only URL parsing here touches feed-controlled data; the download is
    size-capped, content-type checked and magic-byte sniffed, and the file is
    stored under a host-derived name (never a feed-supplied path)."""
    if not host:
        return None
    base = f"https://{host}"
    candidates: list[str] = []
    if feed_image_href:
        candidates.append(urljoin(base + "/", feed_image_href))
    try:
        homepage, _ = http_get(base + "/", timeout, max_bytes=1_000_000)
        htext = homepage.decode("utf-8", "replace")
        for tag in _LINK_ICON_RE.findall(htext)[:6]:
            m = _HREF_RE.search(tag)
            if m:
                candidates.append(urljoin(base + "/", m.group(1)))
    except Exception:
        pass
    candidates.append(base + "/favicon.ico")

    tried = set()
    for url in candidates:
        if url in tried or urlsplit(url).scheme not in ("http", "https"):
            continue
        tried.add(url)
        try:
            data, ctype = http_get(url, timeout, max_bytes=512_000)
        except Exception:
            continue
        if len(data) < 64:  # 200-OK empty / stub favicon
            continue
        ext = sniff_image_ext(data)
        if ext == "svg":
            continue
        if not ext:
            ext = _FAVICON_CTYPES.get(ctype)
        if not ext:
            continue
        ICON_DIR.mkdir(parents=True, exist_ok=True)
        for old in ICON_DIR.glob(_slug(host) + ".*"):
            old.unlink()
        path = ICON_DIR / f"{_slug(host)}.{ext}"
        path.write_bytes(data)
        return path
    return None


def ensure_favicons(feeds, state, timeout, refresh_days, workers, force=False):
    fstates = state["feeds"]
    cutoff = time.time() - refresh_days * 86400
    todo = []
    for f in feeds:
        fs = fstates.setdefault(f["url"], {})
        host = favicon_host(f["url"], fs.get("site_url"))
        fs["_ichost"] = host
        have = cached_icon(host)
        if have and not fs.get("icon"):
            fs["icon"] = str(have)
        if fs.get("icon") and not Path(fs["icon"]).exists():
            fs["icon"] = ""  # cache file was swept
        # icon_at is the last resolution *attempt* (success or not): a feed with
        # no findable favicon is retried at most every refresh_days
        if force or fs.get("icon_at", 0) < cutoff:
            todo.append(f)
    if not todo:
        return 0
    resolved = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(workers, len(todo))) as pool:
        futs = {
            pool.submit(resolve_favicon, fstates[f["url"]]["_ichost"],
                        fstates[f["url"]].get("image_href"), timeout): f
            for f in todo
        }
        for fut in concurrent.futures.as_completed(futs):
            fs = fstates[futs[fut]["url"]]
            try:
                path = fut.result()
            except Exception as e:
                path = None
                log(f"icon ERR {futs[fut]['url']}: {e}")
            fs["icon_at"] = int(time.time())
            if path:
                fs["icon"] = str(path)
                resolved += 1
            else:
                fs.setdefault("icon", "")
    for fs in fstates.values():
        fs.pop("_ichost", None)
    return resolved


# ---------------------------------------------------------------- article images

def entry_image_url(entry) -> str | None:
    for mc in entry.get("media_content", []) or []:
        t = (mc.get("type") or "").lower()
        if mc.get("url") and (mc.get("medium") == "image" or t.startswith("image")):
            return mc["url"]
    for mt in entry.get("media_thumbnail", []) or []:
        if mt.get("url"):
            return mt["url"]
    for enc in entry.get("enclosures", []) or []:
        if (enc.get("type") or "").lower().startswith("image") and enc.get("href"):
            return enc["href"]
    blob = ""
    if entry.get("content"):
        blob = entry["content"][0].get("value", "")
    blob = blob or entry.get("summary", "")
    m = _IMG_RE.search(blob)
    return m.group(1) if m else None


def fetch_image(url: str, timeout: int, max_bytes: int) -> str | None:
    if not url or urlsplit(url).scheme not in ("http", "https"):
        return None
    digest = hashlib.sha1(url.encode()).hexdigest()[:16]
    for p in MEDIA_DIR.glob(digest + ".*"):
        return str(p)
    try:
        data, ctype = http_get(url, timeout, max_bytes=max_bytes)
    except Exception:
        return None
    ext = sniff_image_ext(data)
    if not ext or ext == "svg":  # don't render remote SVG in notifications
        return None
    MEDIA_DIR.mkdir(parents=True, exist_ok=True)
    path = MEDIA_DIR / f"{digest}.{ext}"
    path.write_bytes(data)
    return str(path)


# ---------------------------------------------------------------- item helpers

def entry_id(entry) -> str:
    for key in ("id", "guid", "link"):
        val = entry.get(key)
        if val:
            return str(val)
    basis = entry.get("title", "") + entry.get("published", "") + entry.get("summary", "")
    return "sha1:" + hashlib.sha1(basis.encode("utf-8", "replace")).hexdigest()


def clean_text(s: str, limit: int) -> str:
    s = html.unescape(_TAG_RE.sub(" ", s or ""))
    s = _WS_RE.sub(" ", s).strip()
    if limit and len(s) > limit:
        s = s[: limit - 1].rstrip() + "…"
    return s


def entry_ts(entry) -> str:
    for key in ("published_parsed", "updated_parsed"):
        tm = entry.get(key)
        if tm:
            try:
                return datetime(*tm[:6], tzinfo=timezone.utc).isoformat()
            except (TypeError, ValueError):
                pass
    return ""


# ---------------------------------------------------------------- archive

def append_archive(records: list[dict]):
    if not records:
        return
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    with ARCHIVE_FILE.open("a") as fh:
        for rec in records:
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")


def prune_archive(archive_days: int):
    if not ARCHIVE_FILE.exists() or archive_days <= 0:
        return
    cutoff = datetime.now(timezone.utc).timestamp() - archive_days * 86400
    kept, dropped = [], 0
    for line in ARCHIVE_FILE.read_text().splitlines():
        if not line.strip():
            continue
        try:
            rec = json.loads(line)
            ts = datetime.fromisoformat(rec.get("fetched_at", "")).timestamp()
        except (json.JSONDecodeError, ValueError):
            kept.append(line)
            continue
        if ts >= cutoff:
            kept.append(line)
        else:
            dropped += 1
    if dropped:
        tmp = ARCHIVE_FILE.with_suffix(".jsonl.tmp")
        tmp.write_text("\n".join(kept) + "\n")
        tmp.replace(ARCHIVE_FILE)
        # sweep now-orphaned media
        refs = {rec for line in kept for rec in [json.loads(line).get("image", "")] if rec}
        for m in MEDIA_DIR.glob("*"):
            if str(m) not in refs:
                m.unlink()


# ---------------------------------------------------------------- notify

def notify(title: str, body: str, urgency: str, icon: str, image: str | None,
           feed_title: str, link: str):
    args = ["notify-send", "-a", "rssd", "-u", urgency, "-i", icon,
            "-h", "string:desktop-entry:rssd",
            "-h", f"string:x-rssd-feed:{feed_title}"]
    if link:
        args += ["-h", f"string:x-rssd-link:{link}"]
    if image:
        args += ["-h", f"string:x-rssd-image-path:{image}"]
    args += [title, body]
    try:
        subprocess.run(args, check=False, timeout=10)
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        log(f"notify-send failed: {e}")


# ---------------------------------------------------------------- fetch

def fetch(feed: dict, feed_state: dict, timeout: int) -> dict:
    socket.setdefaulttimeout(timeout)
    url = feed["url"]
    try:
        parsed = feedparser.parse(
            url,
            etag=feed_state.get("etag"),
            modified=feed_state.get("modified"),
        )
    except Exception as e:
        return {"feed": feed, "error": f"{type(e).__name__}: {e}", "entries": []}

    status = parsed.get("status")
    if status == 304:
        return {"feed": feed, "not_modified": True, "entries": [], "status": status}

    if not parsed.entries and parsed.get("bozo"):
        return {"feed": feed, "error": f"parse: {parsed.get('bozo_exception')}",
                "entries": [], "status": status}

    image_href = None
    img = parsed.feed.get("image")
    if isinstance(img, dict):
        image_href = img.get("href") or img.get("url")

    return {
        "feed": feed,
        "entries": parsed.entries,
        "title": (parsed.feed.get("title") or url).strip(),
        "etag": parsed.get("etag"),
        "modified": parsed.get("modified"),
        "image_href": image_href,
        # the publication's own site (feedburner/substack proxies point here);
        # its host is a better basis for the favicon than the feed url's host
        "site_url": (parsed.feed.get("link") or "").strip(),
        "status": status,
    }


# ---------------------------------------------------------------- run

def cmd_run(mode: str):
    """mode: 'run' | 'seed' | 'dry-run'"""
    cfg = load_config()
    feeds = load_feeds()
    if not feeds:
        return 1
    state = load_seen()
    fstates = state["feeds"]

    do_notify = cfg_bool(cfg, "notify") and mode == "run"
    do_archive = cfg_bool(cfg, "archive") and mode == "run"
    do_images = cfg_bool(cfg, "fetch_images")
    notify_images = cfg_bool(cfg, "notify_images")
    timeout = cfg_int(cfg, "timeout")
    workers = max(1, cfg_int(cfg, "workers"))
    per_feed_cap = cfg_int(cfg, "max_notify_per_feed")
    total_cap = cfg_int(cfg, "max_notify_total")
    summary_chars = cfg_int(cfg, "summary_chars")
    urgency = cfg.get("urgency", "low").strip() or "low"
    image_max = cfg_int(cfg, "image_max_bytes")

    started = time.time()
    n_new = n_notified = n_err = n_304 = 0
    archive_records: list[dict] = []
    # (title, body, icon, image, feed_title, link)
    pending: list[tuple] = []

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futs = {
            pool.submit(fetch, f, fstates.get(f["url"], {}), timeout): f
            for f in feeds
        }
        for fut in concurrent.futures.as_completed(futs):
            res = fut.result()
            feed = res["feed"]
            url = feed["url"]
            fs = fstates.setdefault(url, {})

            if res.get("error"):
                n_err += 1
                fs["last_error"] = res["error"]
                fs["last_error_at"] = int(time.time())
                log(f"ERR  {url}\n     {res['error']}")
                continue
            if res.get("not_modified"):
                n_304 += 1
                fs["last_ok"] = int(time.time())
                continue

            fs.pop("last_error", None)
            fs.pop("last_error_at", None)
            fs["last_ok"] = int(time.time())
            fs["title"] = res["title"]
            if res.get("image_href"):
                fs["image_href"] = res["image_href"]
            if res.get("site_url"):
                fs["site_url"] = res["site_url"]
            if res.get("etag"):
                fs["etag"] = res["etag"]
            if res.get("modified"):
                fs["modified"] = res["modified"]

            seen = fs.setdefault("seen", {})
            first_time = not seen and "seeded" not in fs
            now = time.time()
            fresh = []
            for entry in res["entries"]:
                eid = entry_id(entry)
                if eid in seen:
                    continue
                seen[eid] = now
                fresh.append(entry)

            if first_time or mode == "seed":
                fs["seeded"] = int(now)
                if fresh:
                    log(f"seed {url}  ({len(fresh)} items)")
                continue
            if not fresh:
                continue

            n_new += len(fresh)
            feed_title = res["title"]
            feed_icon = fs.get("icon") or ""
            host = urlsplit(url).netloc
            shown = 0
            fresh_meta = []  # (title, body, image) rows for deferred notify
            for entry in fresh:
                title = clean_text(entry.get("title", "(untitled)"), 0)
                summary = clean_text(entry.get("summary", ""), summary_chars)
                link = entry.get("link", "")
                img_path = None
                if do_images:
                    img_path = fetch_image(entry_image_url(entry), timeout, image_max)
                if do_archive:
                    archive_records.append({
                        "id": entry_id(entry),
                        "fetched_at": datetime.now(timezone.utc).isoformat(),
                        "published": entry_ts(entry),
                        "feed_url": url,
                        "feed_title": feed_title,
                        "tags": feed["tags"],
                        "title": title,
                        "link": link,
                        "summary": summary,
                        "image": img_path or "",
                        "icon": feed_icon,
                    })
                if do_notify and shown < per_feed_cap:
                    body = html.escape(summary) if summary else ""
                    if link:
                        anchor = f'<a href="{html.escape(link, quote=True)}">{html.escape(host)} ↗</a>'
                        body = f"{body}\n\n{anchor}" if body else anchor
                    fresh_meta.append((f"{feed_title}: {title}", body,
                                       img_path if notify_images else None, link))
                    shown += 1
            for mt, mb, mi, ml in fresh_meta:
                pending.append((url, mt, mb, mi, feed_title, ml))
            log(f"new  {feed_title}  (+{len(fresh)})")

    if do_archive:
        append_archive(archive_records)
        prune_archive(cfg_int(cfg, "archive_days"))

    # resolve any missing source icons before dispatching, so first-seen
    # feeds still notify with their favicon rather than the generic glyph
    if cfg_bool(cfg, "fetch_favicons") and mode != "dry-run":
        got = ensure_favicons(feeds, state, timeout,
                              cfg_int(cfg, "favicon_refresh_days"), workers)
        if got:
            log(f"icons  resolved {got} new source icon(s)")

    if do_notify:
        for feed_url, title, body, image, feed_title, link in pending[:total_cap]:
            icon = fstates.get(feed_url, {}).get("icon") or "application-rss+xml"
            notify(urgency=urgency, title=title, body=body, icon=icon,
                   image=image, feed_title=feed_title, link=link)
            n_notified += 1

    for fs in fstates.values():
        prune_seen(fs, cfg_int(cfg, "prune_days"))

    if mode != "dry-run":
        state["last_run"] = int(started)
        save_seen(state)

    dur = time.time() - started
    log(f"done  {len(feeds)} feeds  {n_new} new  {n_notified} notified  "
        f"{n_304} unchanged  {n_err} errors  {dur:.1f}s"
        + ("   [dry-run: state not saved]" if mode == "dry-run" else "")
        + ("   [seed: no notifications]" if mode == "seed" else ""))
    return 0


# ---------------------------------------------------------------- other commands

def cmd_icons():
    cfg = load_config()
    feeds = load_feeds()
    state = load_seen()
    # need feed <image> hrefs: a light fetch first
    with concurrent.futures.ThreadPoolExecutor(max_workers=cfg_int(cfg, "workers")) as pool:
        for fut in concurrent.futures.as_completed(
                {pool.submit(fetch, f, {}, cfg_int(cfg, "timeout")): f for f in feeds}):
            r = fut.result()
            fe = state["feeds"].setdefault(r["feed"]["url"], {})
            if r.get("image_href"):
                fe["image_href"] = r["image_href"]
            if r.get("site_url"):
                fe["site_url"] = r["site_url"]
    got = ensure_favicons(feeds, state, cfg_int(cfg, "timeout"),
                          cfg_int(cfg, "favicon_refresh_days"),
                          cfg_int(cfg, "workers"), force=True)
    save_seen(state)
    have = sum(1 for f in feeds if state["feeds"].get(f["url"], {}).get("icon"))
    print(f"resolved {got} icon(s); {have}/{len(feeds)} feeds now have one  ({ICON_DIR})")
    return 0


def cmd_list():
    feeds = load_feeds()
    state = load_seen()
    fstates = state.get("feeds", {})
    tags: dict[str, int] = {}
    print(f"{len(feeds)} feeds  ({FEEDS_FILE})\n")
    for f in feeds:
        fs = fstates.get(f["url"], {})
        for t in f["tags"]:
            tags[t] = tags.get(t, 0) + 1
        mark = "  "
        if fs.get("last_error"):
            mark = "!!"
        elif not fs:
            mark = " ?"
        icon = "icon" if fs.get("icon") else "----"
        last = fs.get("last_ok")
        when = datetime.fromtimestamp(last).strftime("%m-%d %H:%M") if last else "never"
        print(f"{mark} {f['url']}")
        print(f"     tags:{' '.join(f['tags']) or '-'}  {icon}  "
              f"seen:{len(fs.get('seen', {}))}  last-ok:{when}")
        if fs.get("last_error"):
            print(f"     error: {fs['last_error']}")
    print("\ntags: " + "  ".join(f"{t}({n})" for t, n in sorted(tags.items())))
    lr = state.get("last_run")
    if lr:
        print("last run: " + datetime.fromtimestamp(lr).strftime("%Y-%m-%d %H:%M:%S"))
    return 0


def cmd_opml():
    feeds = load_feeds()
    now = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S %z")
    out = ['<?xml version="1.0" encoding="UTF-8"?>',
           '<opml version="2.0">', '  <head>', '    <title>rssd feeds</title>',
           f'    <dateCreated>{now}</dateCreated>', '  </head>', '  <body>']
    for f in feeds:
        cat = html.escape(",".join(f["tags"]), quote=True)
        u = html.escape(f["url"], quote=True)
        out.append(f'    <outline type="rss" text="{u}" title="{u}" '
                   f'xmlUrl="{u}" category="{cat}"/>')
    out += ['  </body>', '</opml>']
    print("\n".join(out))
    return 0


def cmd_add(args: list[str]):
    if not args:
        log("usage: rssd add URL [tag ...]")
        return 2
    url, tags = args[0], args[1:]
    if url in {f["url"] for f in load_feeds()}:
        log(f"already present: {url}")
        return 0
    with FEEDS_FILE.open("a") as fh:
        fh.write(f"{url}    {' '.join(tags)}".rstrip() + "\n")
    log(f"added {url}  {' '.join(tags)}")
    return 0


def main(argv: list[str]) -> int:
    cmd = argv[1] if len(argv) > 1 else "run"
    if cmd in ("-h", "--help"):
        print(__doc__)
        return 0
    if cmd == "run":
        return cmd_run("run")
    if cmd == "seed":
        return cmd_run("seed")
    if cmd in ("dry-run", "dryrun", "--dry-run"):
        return cmd_run("dry-run")
    if cmd == "icons":
        return cmd_icons()
    if cmd == "list":
        return cmd_list()
    if cmd == "opml":
        return cmd_opml()
    if cmd == "add":
        return cmd_add(argv[2:])
    log(f"unknown command: {cmd}\n")
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
