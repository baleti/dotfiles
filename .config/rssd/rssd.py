#!/usr/bin/env python3
"""rssd - poll RSS/Atom feeds, notify on new items, archive them.

Timer-driven (see rssd.timer); not a long-running process.

  rssd            fetch all feeds, notify + archive new items
  rssd seed       mark everything currently in the feeds as seen, no notifications
  rssd dry-run    fetch and report what WOULD notify, without touching state
  rssd list       show what feeds/tags the config parses to, plus last status
  rssd add URL [tag ...]   append a feed line to the feeds file

Files:
  ~/.config/rssd/feeds                  feed list (newsboat-style: url  tag...  # comment)
  ~/.config/rssd/config                 behaviour (key = value)
  ~/.local/state/rssd/seen.json         per-feed seen-item ids + http validators
  ~/.local/state/rssd/items.jsonl       append-only archive of every new item
"""

from __future__ import annotations

import concurrent.futures
import hashlib
import html
import json
import os
import re
import socket
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import feedparser

CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "rssd"
STATE_DIR = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state")) / "rssd"
FEEDS_FILE = CONFIG_DIR / "feeds"
CONFIG_FILE = CONFIG_DIR / "config"
SEEN_FILE = STATE_DIR / "seen.json"
ARCHIVE_FILE = STATE_DIR / "items.jsonl"

feedparser.USER_AGENT = "rssd/1.0 (+https://localhost; feedparser)"

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
}

_TAG_RE = re.compile(r"<[^>]+>")
_WS_RE = re.compile(r"\s+")


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
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = SEEN_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, separators=(",", ":")))
    tmp.replace(SEEN_FILE)


def prune_seen(feed_state: dict, prune_days: int):
    cutoff = time.time() - prune_days * 86400
    seen = feed_state.get("seen", {})
    if len(seen) <= 50:
        return
    keep = {k: v for k, v in seen.items() if v >= cutoff}
    # always retain the 50 most-recent ids even if older than the cutoff
    if len(keep) < 50:
        for k, _ in sorted(seen.items(), key=lambda kv: kv[1], reverse=True)[:50]:
            keep[k] = seen[k]
    feed_state["seen"] = keep


# ---------------------------------------------------------------- item helpers

def entry_id(entry) -> str:
    for key in ("id", "guid", "link"):
        val = entry.get(key)
        if val:
            return str(val)
    basis = (entry.get("title", "") + entry.get("published", "") + entry.get("summary", ""))
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
    except Exception as e:  # feedparser is defensive but be safe
        return {"feed": feed, "error": f"{type(e).__name__}: {e}", "entries": []}

    status = parsed.get("status")
    if status == 304:
        return {"feed": feed, "not_modified": True, "entries": [], "status": status}

    bozo = parsed.get("bozo")
    if not parsed.entries and bozo:
        exc = parsed.get("bozo_exception")
        return {"feed": feed, "error": f"parse: {exc}", "entries": [], "status": status}

    return {
        "feed": feed,
        "entries": parsed.entries,
        "title": (parsed.feed.get("title") or url).strip(),
        "etag": parsed.get("etag"),
        "modified": parsed.get("modified"),
        "status": status,
    }


# ---------------------------------------------------------------- notify

def notify(title: str, body: str, urgency: str):
    try:
        subprocess.run(
            ["notify-send", "-a", "rssd", "-u", urgency,
             "-i", "application-rss+xml",
             "-h", "string:desktop-entry:rssd",
             title, body],
            check=False, timeout=10,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        log(f"notify-send failed: {e}")


def archive(records: list[dict]):
    if not records:
        return
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with ARCHIVE_FILE.open("a") as fh:
        for rec in records:
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")


# ---------------------------------------------------------------- commands

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
    timeout = cfg_int(cfg, "timeout")
    workers = max(1, cfg_int(cfg, "workers"))
    per_feed_cap = cfg_int(cfg, "max_notify_per_feed")
    total_cap = cfg_int(cfg, "max_notify_total")
    summary_chars = cfg_int(cfg, "summary_chars")
    urgency = cfg.get("urgency", "low").strip() or "low"
    prune_days = cfg_int(cfg, "prune_days")

    started = time.time()
    n_new = n_notified = n_err = n_304 = 0
    archive_records: list[dict] = []
    pending_notifications: list[tuple[str, str]] = []

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
            shown = 0
            for entry in fresh:
                title = clean_text(entry.get("title", "(untitled)"), 0)
                summary = clean_text(entry.get("summary", ""), summary_chars)
                link = entry.get("link", "")
                if do_archive:
                    archive_records.append({
                        "fetched_at": datetime.now(timezone.utc).isoformat(),
                        "published": entry_ts(entry),
                        "feed_url": url,
                        "feed_title": feed_title,
                        "tags": feed["tags"],
                        "title": title,
                        "link": link,
                        "summary": summary,
                    })
                if do_notify and shown < per_feed_cap:
                    body = summary or link
                    pending_notifications.append((f"{feed_title}: {title}", body))
                    shown += 1
            log(f"new  {feed_title}  (+{len(fresh)})")

    if do_archive:
        archive(archive_records)

    if do_notify:
        for ntitle, nbody in pending_notifications[:total_cap]:
            notify(ntitle, nbody, urgency)
            n_notified += 1

    for fs in fstates.values():
        prune_seen(fs, prune_days)

    if mode != "dry-run":
        state["last_run"] = int(started)
        save_seen(state)

    dur = time.time() - started
    log(f"done  {len(feeds)} feeds  {n_new} new  {n_notified} notified  "
        f"{n_304} unchanged  {n_err} errors  {dur:.1f}s"
        + ("   [dry-run: state not saved]" if mode == "dry-run" else "")
        + ("   [seed: no notifications]" if mode == "seed" else ""))
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
        seen_n = len(fs.get("seen", {}))
        last = fs.get("last_ok")
        when = datetime.fromtimestamp(last).strftime("%m-%d %H:%M") if last else "never"
        print(f"{mark} {f['url']}")
        print(f"     tags: {' '.join(f['tags']) or '-'}   seen:{seen_n}   last-ok:{when}")
        if fs.get("last_error"):
            print(f"     error: {fs['last_error']}")
    print("\ntags: " + "  ".join(f"{t}({n})" for t, n in sorted(tags.items())))
    lr = state.get("last_run")
    if lr:
        print("last run: " + datetime.fromtimestamp(lr).strftime("%Y-%m-%d %H:%M:%S"))
    return 0


def cmd_add(args: list[str]):
    if not args:
        log("usage: rssd add URL [tag ...]")
        return 2
    url, tags = args[0], args[1:]
    existing = {f["url"] for f in load_feeds()}
    if url in existing:
        log(f"already present: {url}")
        return 0
    with FEEDS_FILE.open("a") as fh:
        fh.write(f"{url}    {' '.join(tags)}\n".rstrip() + "\n")
    log(f"added {url}  {' '.join(tags)}")
    return 0


def main(argv: list[str]) -> int:
    cmd = argv[1] if len(argv) > 1 else "run"
    if cmd in ("run", "-h", "--help"):
        if cmd != "run":
            print(__doc__)
            return 0
        return cmd_run("run")
    if cmd == "seed":
        return cmd_run("seed")
    if cmd in ("dry-run", "dryrun", "--dry-run"):
        return cmd_run("dry-run")
    if cmd == "list":
        return cmd_list()
    if cmd == "add":
        return cmd_add(argv[2:])
    log(f"unknown command: {cmd}\n")
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
