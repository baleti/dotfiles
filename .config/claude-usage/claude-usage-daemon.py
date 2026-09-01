#!/usr/bin/env python3
"""Polls Anthropic's account-usage endpoint for this machine's Claude Code
accounts (~/.claude, ~/.claude2, ~/.claude3) and writes one combined
snapshot for the quickshell bar to read.

This is the same endpoint the `claude` CLI itself calls for `/usage` --
GET https://api.anthropic.com/api/oauth/usage, Bearer-authenticated with
the OAuth access token already sitting in each account's
.credentials.json. It is not a documented public API, just the client's
own account-info call, made with credentials the user already holds.

No OAuth refresh is implemented here on purpose: each account already has
live `claude` CLI sessions that keep .credentials.json refreshed on their
own (access tokens are short-lived, ~8h, refreshed continuously by normal
use). This daemon just re-reads the file fresh every cycle and skips an
account for that cycle on an auth failure, rather than reimplementing the
refresh flow and taking on new places to mishandle a refresh token.

Poll interval adapts to how likely anyone is to be watching the bar:
  - a monitor is DPMS-off, or the session is locked   -> hourly
  - a transcript under ~/.claude*/projects was written
    in the last ACTIVITY_WINDOW seconds                -> every 2 minutes
  - otherwise (screen on, nothing actively generating)  -> every 5 minutes

2026-08-31: the initial version used a 30s "active" interval and fired all
3 accounts back-to-back with no spacing. That tripped a 429 on this
endpoint within ~30 minutes of continuous "active" use, on all 3 accounts
simultaneously -- which points at an IP-wide limit, not a per-account one.
Fixed by widening ACTIVE to 2 minutes, staggering the 3 accounts'
requests, and adding real backoff below: a 429 now suspends ALL polling
(not just the account that got it) for a while, growing exponentially on
repeated 429s and respecting a Retry-After header when the response sends
one. A 429/other error also no longer blanks out that account's last-known
numbers in state.json -- it carries the last good reading forward, flagged
"stale", so the bar doesn't just go blank/red on every hiccup.

2026-08-31: also lists each account's live `claude` processes ("sessions"
in state.json), entirely from local files -- no network call, so it runs
on its own fixed 30s cadence regardless of the tier/backoff logic above.
Each account's `sessions/<pid>.json` (written by the CLI itself, keyed by
PID) gives pid/sessionId/cwd/status/tmux directly; a process only shows up
here if /proc/<pid> still exists, so an exited session's leftover json
doesn't linger. The "title" shown per session is tmux's own pane_title
(set by the CLI via terminal escape sequences, e.g. "Focused window
border accent color"), looked up once per cycle via one batched `tmux
list-panes -a` call (not one subprocess per session) and matched by the
globally-unique %pane-id embedded in that session's own "tmux" field --
NOT sessions/<pid>.json's own "name" field, which despite sounding like a
title is just an opaque auto-derived id (e.g. "user1-46") the CLI assigns
internally, unrelated to what the session is actually doing (confirmed by
comparing both against the same real pid 2026-08-31; name is kept as a
fallback for a session tmux can't find, e.g. one not running in a tmux
pane at all -- daemon/bg-pty-host processes). "Context tokens" per
session comes from the last
`type: "assistant"` message's `usage` field in that session's own
transcript (~/.claudeN/projects/<cwd-slug>/<sessionId>.jsonl, found by a
tail-window read, not a full-file parse -- see context_tokens_for) --
input + cache_creation + cache_read tokens, i.e. roughly how full that
session's context window currently is, not a lifetime total. Every alive
session is sent, sorted most-recently-active first -- deciding how many
actually fit on screen (there are routinely 20-40 alive per account here)
is the quickshell side's job, not this daemon's; it shows "+N more" using
the real count this sends rather than silently dropping data.

State is written atomically to ~/.cache/claude-usage/state.json.
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path

ACCOUNTS = [
    ("claude", Path.home() / ".claude"),
    ("claude2", Path.home() / ".claude2"),
    ("claude3", Path.home() / ".claude3"),
]

STATE_DIR = Path.home() / ".cache" / "claude-usage"
STATE_FILE = STATE_DIR / "state.json"

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"

INTERVAL_LOCKED = 3600
INTERVAL_ACTIVE = 120
INTERVAL_IDLE = 300
ACTIVITY_WINDOW = 90
# How often the main loop wakes to re-evaluate which tier it's in --
# independent of INTERVAL_ACTIVE so a screen-off transition mid-idle-wait is
# noticed promptly instead of only at the next scheduled fetch.
CHECK_GRANULARITY = 15
# Gap between each account's own request within one fetch cycle, so 3
# accounts never look like one 3-request burst to whatever's rate-limiting
# this endpoint.
ACCOUNT_STAGGER = 5

# Backoff after a 429: at least this long, or the response's own
# Retry-After if that's longer, doubling on each further 429 hit before the
# backoff has cleared (capped at MAX_BACKOFF).
BACKOFF_MIN = 600
BACKOFF_MAX = 3600

# Session/process listing: purely local (no network), so it runs on its
# own short cadence independent of the tiers above. SESSIONS_KEEP is a
# sanity ceiling, not a UI decision -- real counts here run 20-40 alive per
# account, so this is normally never hit; the quickshell side decides how
# many of the (sorted-most-recent-first) list actually fit on screen and
# shows "+N more" for the rest, using the real total this sends.
SESSIONS_INTERVAL = 30
SESSIONS_KEEP = 100
# Tail-window sizes tried in order (bytes) when hunting for the last
# assistant usage entry -- most files find it in the first, smallest pass;
# this only escalates for a session whose last turn had a huge tool result
# between it and EOF.
TOKEN_SEARCH_WINDOWS = (200_000, 1_500_000, None)  # None = whole file


def log(msg: str) -> None:
    print(f"[{datetime.now(timezone.utc).isoformat()}] {msg}", flush=True)


def is_screen_off_or_locked() -> bool:
    try:
        out = subprocess.run(
            ["hyprctl", "-j", "monitors"],
            capture_output=True, timeout=3, text=True, check=True,
        )
        mons = json.loads(out.stdout)
        if any(not m.get("dpmsStatus", True) for m in mons):
            return True
    except Exception:
        pass
    try:
        out = subprocess.run(
            ["loginctl", "show-session", "self", "-p", "LockedHint", "--value"],
            capture_output=True, timeout=3, text=True, check=True,
        )
        if out.stdout.strip() == "yes":
            return True
    except Exception:
        pass
    return False


def is_actively_using() -> bool:
    cutoff = time.time() - ACTIVITY_WINDOW
    for _, base in ACCOUNTS:
        projects = base / "projects"
        if not projects.is_dir():
            continue
        try:
            for jsonl in projects.glob("*/*.jsonl"):
                if jsonl.stat().st_mtime >= cutoff:
                    return True
        except OSError:
            continue
    return False


def current_tier() -> tuple[str, int]:
    if is_screen_off_or_locked():
        return "locked", INTERVAL_LOCKED
    if is_actively_using():
        return "active", INTERVAL_ACTIVE
    return "idle", INTERVAL_IDLE


def parse_retry_after(headers) -> float | None:
    raw = headers.get("Retry-After")
    if not raw:
        return None
    try:
        return float(raw)
    except ValueError:
        pass
    try:
        dt = parsedate_to_datetime(raw)
        return max(0.0, (dt - datetime.now(dt.tzinfo)).total_seconds())
    except Exception:
        return None


def fetch_usage(cred_path: Path) -> dict:
    try:
        creds = json.loads(cred_path.read_text())
        token = creds["claudeAiOauth"]["accessToken"]
    except Exception as e:
        return {"error": f"no credentials ({e.__class__.__name__})"}

    req = urllib.request.Request(
        USAGE_URL,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            data = json.load(r)
    except urllib.error.HTTPError as e:
        result = {"error": f"http {e.code}", "http_status": e.code}
        if e.code == 429:
            result["retry_after"] = parse_retry_after(e.headers)
        return result
    except Exception as e:
        return {"error": f"{e.__class__.__name__}: {e}"}

    limits = {item.get("kind"): item for item in (data.get("limits") or [])}
    session = limits.get("session")
    weekly = limits.get("weekly_all")
    return {
        "session_pct": session.get("percent") if session else None,
        "session_resets_at": session.get("resets_at") if session else None,
        "weekly_pct": weekly.get("percent") if weekly else None,
        "weekly_resets_at": weekly.get("resets_at") if weekly else None,
        "fetched_at": datetime.now(timezone.utc).isoformat(),
    }


def is_pid_alive(pid) -> bool:
    try:
        return Path(f"/proc/{int(pid)}").is_dir()
    except (TypeError, ValueError):
        return False


def cwd_to_slug(cwd: str) -> str:
    # ~/.claudeN/projects/<slug>/ naming: every '/' and '.' in the cwd
    # becomes '-' (confirmed against real project dirs, e.g.
    # "/home/user1/.claude" -> "-home-user1--claude").
    return cwd.replace(".", "-").replace("/", "-")


def context_tokens_for(transcript_path: Path):
    """(context_tokens, last_output_tokens) from the last assistant
    message's usage in transcript_path, or (None, None). context_tokens is
    input + cache_creation + cache_read -- roughly how full that session's
    context window currently is, not a lifetime running total."""
    try:
        size = transcript_path.stat().st_size
    except OSError:
        return None, None

    for window in TOKEN_SEARCH_WINDOWS:
        take = size if window is None else min(window, size)
        try:
            with transcript_path.open("rb") as fh:
                fh.seek(size - take)
                data = fh.read().decode("utf-8", errors="ignore")
        except OSError:
            return None, None

        for line in reversed(data.split("\n")):
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if rec.get("type") != "assistant":
                continue
            usage = (rec.get("message") or {}).get("usage")
            if usage:
                ctx = (
                    (usage.get("input_tokens") or 0)
                    + (usage.get("cache_creation_input_tokens") or 0)
                    + (usage.get("cache_read_input_tokens") or 0)
                )
                return ctx, usage.get("output_tokens")

        if take >= size:
            break
    return None, None


def get_tmux_pane_titles() -> dict:
    """{pane_id ("%1828"): pane_title} for every pane on the server, in one
    batched call -- not one `tmux display-message` subprocess per session
    (85+ of those every cycle would be wasteful). Empty dict (not an
    exception) if tmux isn't running or isn't on PATH."""
    try:
        out = subprocess.run(
            ["tmux", "list-panes", "-a", "-F", "#{pane_id}\t#{pane_title}"],
            capture_output=True, timeout=3, text=True, check=True,
        )
    except Exception:
        return {}
    titles = {}
    for line in out.stdout.splitlines():
        pane_id, _, title = line.partition("\t")
        if pane_id:
            titles[pane_id] = title
    return titles


def _read_proc_stat(pid: int):
    """(ppid, tty_nr) from /proc/<pid>/stat -- comm-safe (a process name can
    contain spaces/parens, so split after the last ')' rather than by
    field position from the start). Field layout after that point, per
    `man 5 proc`: state ppid pgrp session tty_nr ... -- ppid is index 1,
    tty_nr is index 4."""
    try:
        raw = Path(f"/proc/{pid}/stat").read_text()
    except OSError:
        return None
    paren = raw.rfind(")")
    if paren == -1:
        return None
    rest = raw[paren + 2:].split()
    if len(rest) < 5:
        return None
    try:
        return int(rest[1]), int(rest[4])
    except ValueError:
        return None


def _read_all_proc() -> dict:
    """pid -> (ppid, tty_nr) for every live process, one /proc sweep --
    the same shape winswitch's enrich.rs::read_all_proc() builds, used the
    same way: to walk from a window's own pid down to every descendant's
    controlling tty."""
    procs = {}
    try:
        pids = (p for p in os.listdir("/proc") if p.isdigit())
    except OSError:
        return procs
    for p in pids:
        info = _read_proc_stat(int(p))
        if info:
            procs[int(p)] = info
    return procs


def _descendant_ttys(procs: dict, root_pid: int) -> set:
    """tty_nr of root_pid and every process descended from it (BFS over
    ppid links built from _read_all_proc's sweep)."""
    children: dict = {}
    for pid, (ppid, _tty) in procs.items():
        children.setdefault(ppid, []).append(pid)
    ttys = set()
    seen = set()
    queue = [root_pid]
    while queue:
        pid = queue.pop()
        if pid in seen:
            continue
        seen.add(pid)
        info = procs.get(pid)
        if info:
            ttys.add(info[1])
        queue.extend(children.get(pid, ()))
    return ttys


def _tmux_clients() -> list:
    """[(client_tty, session_id_no_dollar)] -- which real terminal (tty) is
    currently attached to and looking at which tmux session, one batched
    call. tmux's own #{session_id} is "$"-prefixed ("$0"); stripped here
    since nothing else in this file carries that sigil."""
    try:
        out = subprocess.run(
            ["tmux", "list-clients", "-F", "#{client_tty}\t#{session_id}"],
            capture_output=True, timeout=3, text=True, check=True,
        )
    except Exception:
        return []
    clients = []
    for line in out.stdout.splitlines():
        tty, _, sess = line.partition("\t")
        if tty and sess:
            clients.append((tty, sess.lstrip("$")))
    return clients


def _monitor_names() -> dict:
    """hyprctl's numeric monitor id -> its name (e.g. "DP-1"), one call --
    `hyprctl clients` only gives the id, and "monitor 1" means nothing in
    the UI the way a real output name does."""
    try:
        raw = subprocess.run(
            ["hyprctl", "-j", "monitors"],
            capture_output=True, timeout=3, text=True, check=True,
        )
        return {m.get("id"): m.get("name") for m in json.loads(raw.stdout)}
    except Exception:
        return {}


def hyprland_windows_by_tmux_session() -> dict:
    """{tmux session id (no '$'): {"address", "class", "title",
    "workspace", "monitor"}} for every tmux session that currently has a
    client attached and displayed in some Hyprland window -- feeds the
    active-processes table's "hyprland" column group (workspace/monitor/
    window) and its hover-thumbnail/click-to-focus feature.

    "address" is what actually identifies the window unambiguously
    (thumb-capture and the focus dispatch both key off it) -- class/title
    are shown to the user but can't be used to pick a specific window
    themselves: this machine routinely has 30+ Alacritty windows all
    titled plain "Alacritty" (confirmed live 2026-09-01), which is
    exactly why the hover-thumbnail needed its own address-keyed capture
    helper (thumb-capture, see its own doc comment) instead of
    Quickshell's built-in ScreencopyView -- that one only exposes appId/
    title via the generic wlr-foreign-toplevel-list protocol, nowhere
    near enough to disambiguate this.

    Same tty/pid correlation winswitch's enrich.rs uses to match tmux
    clients to Hyprland windows (see that file's own doc comment): a
    tmux client's tty (`#{client_tty}`, the real terminal's pty) and a
    process's controlling tty (`tty_nr`, field 5 of /proc/<pid>/stat) are
    both the kernel's packed major/minor dev_t for the same device node,
    so `os.stat(client_tty).st_rdev == tty_nr` for the process actually
    sitting on that tty (or any of its descendants) is a solid identity
    check -- no tty is shared between two different pty devices. Walking
    every Hyprland window's full descendant-process tree for this is
    what read_all_proc/_descendant_ttys are for.

    Not every tmux session has an attached client (a detached session has
    nothing on screen to preview or focus), so this is best-effort and
    normally returns fewer entries than there are sessions -- callers
    should treat a missing key as "no window to show", not an error."""
    clients = _tmux_clients()
    if not clients:
        return {}
    try:
        raw = subprocess.run(
            ["hyprctl", "-j", "clients"],
            capture_output=True, timeout=3, text=True, check=True,
        )
        windows = json.loads(raw.stdout)
    except Exception:
        return {}

    client_rdevs = []
    for tty, sess in clients:
        try:
            client_rdevs.append((os.stat(tty).st_rdev, sess))
        except OSError:
            continue
    if not client_rdevs:
        return {}

    monitor_names = _monitor_names()
    procs = _read_all_proc()
    result: dict = {}
    for win in windows:
        pid = win.get("pid")
        if not pid or pid < 1:
            continue
        ttys = _descendant_ttys(procs, pid)
        if not ttys:
            continue
        for rdev, sess in client_rdevs:
            if sess not in result and rdev in ttys:
                ws = win.get("workspace") or {}
                result[sess] = {
                    "address": win.get("address") or "",
                    "class": win.get("class") or "",
                    "title": win.get("title") or "",
                    "workspace": ws.get("name") or "",
                    "monitor": monitor_names.get(win.get("monitor"), ""),
                }
    return result


PANE_ID_RE = re.compile(r"%\d+")
# sessions/<pid>.json's "tmux" field, e.g. "653:@1017.%1828" -- session id
# (no prefix), window id ("@"-prefixed), pane id ("%"-prefixed). Split out
# so quickshell can show them as their own sub-columns without the tmux
# object-type sigils (session 653, window 1017, pane 1828), not because
# they're wrong, but because they're tmux's own internal notation, not
# meaningful outside a tmux command.
TMUX_FIELD_RE = re.compile(r"^(\d+):@(\d+)\.%(\d+)$")


def list_sessions(base: Path, tmux_titles: dict, hypr_by_session: dict) -> list:
    sessions_dir = base / "sessions"
    if not sessions_dir.is_dir():
        return []

    rows = []
    for f in sessions_dir.glob("*.json"):
        try:
            data = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        pid = data.get("pid")
        if not is_pid_alive(pid):
            continue

        session_id = data.get("sessionId")
        cwd = data.get("cwd") or ""
        context_tokens = last_output_tokens = None
        if session_id and cwd:
            transcript = base / "projects" / cwd_to_slug(cwd) / f"{session_id}.jsonl"
            context_tokens, last_output_tokens = context_tokens_for(transcript)

        tmux_field = data.get("tmux")
        title = None
        tmux_session = tmux_window = tmux_pane = None
        if tmux_field:
            m = PANE_ID_RE.search(tmux_field)
            if m:
                title = tmux_titles.get(m.group(0))
            m2 = TMUX_FIELD_RE.match(tmux_field)
            if m2:
                tmux_session, tmux_window, tmux_pane = m2.group(1), m2.group(2), m2.group(3)
        if not title:
            # Not in tmux (or that pane's gone) -- fall back to the CLI's
            # own opaque auto-id rather than showing nothing.
            title = data.get("name")

        # The Hyprland window currently displaying this session's tmux
        # pane, if any (see hyprland_windows_by_tmux_session's own
        # comment) -- feeds the quickshell side's "hyprland" column group
        # and its hover-thumbnail/click-to-focus feature. All None for a
        # detached session (no window to preview) or a session not in
        # tmux at all.
        hypr = hypr_by_session.get(tmux_session) if tmux_session else None

        rows.append({
            "pid": pid,
            "status": data.get("status"),
            "title": title,
            "cwd": cwd,
            "tmux_session": tmux_session,
            "tmux_window": tmux_window,
            "tmux_pane": tmux_pane,
            "updated_at_ms": data.get("updatedAt"),
            "context_tokens": context_tokens,
            "last_output_tokens": last_output_tokens,
            "hypr_address": hypr["address"] if hypr else None,
            "hypr_class": hypr["class"] if hypr else None,
            "hypr_title": hypr["title"] if hypr else None,
            "hypr_workspace": hypr["workspace"] if hypr else None,
            "hypr_monitor": hypr["monitor"] if hypr else None,
        })

    rows.sort(key=lambda s: s.get("updated_at_ms") or 0, reverse=True)
    return rows[:SESSIONS_KEEP]


def write_state(accounts_data: list, sessions_data: dict, mode: str, interval: int) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    payload = {
        "accounts": accounts_data,
        "sessions": sessions_data,
        "poll_mode": mode,
        "poll_interval_s": interval,
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }
    tmp = STATE_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(payload, indent=2))
    tmp.replace(STATE_FILE)


def main() -> None:
    log("claude-usage-daemon starting")
    next_fetch = 0.0
    next_sessions = 0.0
    backoff_until = 0.0
    consecutive_429 = 0
    # account name -> last successful fetch_usage() result (no "account" key)
    last_good: dict[str, dict] = {}
    accounts_data = [{"account": name} for name, _ in ACCOUNTS]
    sessions_data = {name: [] for name, _ in ACCOUNTS}
    mode, interval = "idle", INTERVAL_IDLE

    while True:
        now = time.time()
        dirty = False

        # Session/process listing: local-only, its own cadence, runs even
        # during a network backoff window.
        if now >= next_sessions:
            tmux_titles = get_tmux_pane_titles()
            hypr_by_session = hyprland_windows_by_tmux_session()
            sessions_data = {name: list_sessions(base, tmux_titles, hypr_by_session) for name, base in ACCOUNTS}
            next_sessions = time.time() + SESSIONS_INTERVAL
            dirty = True

        if now < backoff_until:
            new_mode, new_interval = "backoff", int(backoff_until - now)
            if (mode, interval) != (new_mode, new_interval):
                mode, interval = new_mode, new_interval
                dirty = True
        elif now >= next_fetch:
            mode, interval = current_tier()
            accounts_data = []
            hit_429 = False
            retry_after_max = 0.0
            for i, (name, base) in enumerate(ACCOUNTS):
                if i > 0:
                    time.sleep(ACCOUNT_STAGGER)
                result = fetch_usage(base / ".credentials.json")

                if result.get("http_status") == 429:
                    hit_429 = True
                    retry_after_max = max(retry_after_max, result.get("retry_after") or 0.0)

                if "error" in result:
                    prev = last_good.get(name)
                    row = dict(prev) if prev else {}
                    row["account"] = name
                    row["error"] = result["error"]
                    row["stale"] = prev is not None
                    accounts_data.append(row)
                    if result["error"] != "http 429":
                        log(f"{name}: {result['error']}")
                else:
                    result["account"] = name
                    last_good[name] = {k: v for k, v in result.items() if k != "account"}
                    accounts_data.append(result)

            if hit_429:
                consecutive_429 += 1
                backoff_s = min(
                    BACKOFF_MAX,
                    max(BACKOFF_MIN, retry_after_max) * (2 ** (consecutive_429 - 1)),
                )
                backoff_until = time.time() + backoff_s
                mode = "backoff"
                interval = int(backoff_s)
                log(f"hit 429 (consecutive={consecutive_429}), backing off {backoff_s:.0f}s")
            else:
                consecutive_429 = 0

            next_fetch = time.time() + interval
            dirty = True

        if dirty:
            write_state(accounts_data, sessions_data, mode, interval)

        time.sleep(CHECK_GRANULARITY)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
