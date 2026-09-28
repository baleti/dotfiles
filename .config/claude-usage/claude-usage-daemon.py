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
import ctypes
import json
import os
import select
import signal
import subprocess
import sys
import threading
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

# ---- turn-done desktop notification (replaces ~/.claude/hooks/
# claude-stop-notify.py's Stop hook, disabled 2026-09-20) -----------------
# That hook ran synchronously inside Claude Code's own turn-completion
# path, forked 3 subprocesses, and was subject to a 5s hook timeout -- all
# things that get worse, not better, exactly when the system is already
# under the kind of memory pressure that motivated moving this out. This
# daemon already recomputes every session's live status/tmux/hyprland/
# token state every SESSIONS_INTERVAL; inotify (below) just makes that
# recompute happen right after a session's status file actually changes
# instead of waiting up to SESSIONS_INTERVAL, and the transition-detect
# step here (main()'s prev_status dict) fires the notification.
ICON_PATH = Path.home() / ".config/quickshell/bar/assets/claude-logo.png"
NOTIFY_BODY_BUDGET = 200
# Floor between two inotify-triggered session recomputes, regardless of how
# many events arrive in between (they're drained and coalesced into one).
# Without this, a burst of near-simultaneous status-file writes across many
# live sessions -- e.g. the exact "many active sessions at once" scenario
# that caused the original CPU incident -- would fire the full (tmux +
# hyprland + per-session transcript tail-read) recompute back-to-back with
# no rate limit, reintroducing the same class of problem this replaces.
# Still far below SESSIONS_INTERVAL's 30s, so a real status change is
# noticed within a couple of seconds instead of up to 30.
SESSIONS_MIN_GAP = 3


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


def last_message_ts_ms(transcript_path: Path):
    """Epoch-ms of the transcript's last record with a "timestamp" field -
    the real "when was this conversation last actually active" signal,
    straight from message content. Deliberately NOT the same thing as the
    CLI's own self-reported sessions/<pid>.json "updatedAt": that field
    tracks the current PROCESS's lifetime, so a `claude --resume` of a
    week-old conversation makes updatedAt say "just now" even though
    nothing in the conversation itself is new - confirmed the hard way
    2026-09-06, when resuming ~100 crashed sessions in one batch made the
    usage panel show every single one as freshly started regardless of how
    old the actual conversation was. Reading the transcript's own last
    timestamp instead survives any number of resumes/restarts: it only
    moves forward when a real message is appended, exactly matching what
    the panel is supposed to mean by "last used"."""
    try:
        size = transcript_path.stat().st_size
    except OSError:
        return None

    for window in TOKEN_SEARCH_WINDOWS:
        take = size if window is None else min(window, size)
        try:
            with transcript_path.open("rb") as fh:
                fh.seek(size - take)
                data = fh.read().decode("utf-8", errors="ignore")
        except OSError:
            return None

        for line in reversed(data.split("\n")):
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            ts = rec.get("timestamp")
            if not ts:
                continue
            try:
                return int(datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp() * 1000)
            except ValueError:
                continue

        if take >= size:
            break
    return None


def _tmux_panes_by_tty() -> dict:
    """Controlling-tty rdev -> {"session", "window", "pane", "title"} for
    every pane on the server, live, in one batched call -- not one `tmux
    display-message` subprocess per session (85+ of those every cycle
    would be wasteful).

    This is list_sessions' *live* source for tmux_session/window/pane and
    title, matched against each Claude process's own controlling tty (see
    _read_proc_stat). It replaces trusting sessions/<pid>.json's own
    self-reported "tmux" field (e.g. "653:@1017.%1828"), which the CLI
    writes once at process start and never updates again: the moment that
    pane's tmux session gets killed (or killed and recreated under a new
    id -- tmux reuses low ids), the cached field silently goes stale while
    the process itself keeps running in the background. Confirmed live
    2026-09-10: 51 of 106 live Claude sessions here had a cached "tmux"
    field pointing at a session id that no longer existed at all, and a
    further 6 pointed at a session that existed but had no attached
    client -- both read as "no window to show" once resolved live instead
    of quietly carrying a wrong-looking number forever. A pid whose live
    tty has no match here (process not currently sitting in any tmux pane,
    or no controlling terminal at all) gets None for all of tmux_session/
    window/pane/title, which is the honest answer rather than a stale one.

    Empty dict (not an exception) if tmux isn't running or isn't on
    PATH."""
    try:
        out = subprocess.run(
            ["tmux", "list-panes", "-a", "-F",
             "#{pane_tty}\t#{session_id}\t#{window_id}\t#{pane_id}\t#{pane_title}"],
            capture_output=True, timeout=3, text=True, check=True,
        )
    except Exception:
        return {}
    result = {}
    for line in out.stdout.splitlines():
        parts = line.split("\t", 4)
        if len(parts) != 5:
            continue
        tty, session_id, window_id, pane_id, title = parts
        try:
            rdev = os.stat(tty).st_rdev
        except OSError:
            continue
        # tmux's own sigils ("$"/"@"/"%") stripped here, same convention
        # the rest of this file and the quickshell side already use for
        # these ids.
        result[rdev] = {
            "session": session_id.lstrip("$"),
            "window": window_id.lstrip("@"),
            "pane": pane_id.lstrip("%"),
            "title": title,
        }
    return result


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


def _read_proc_state(pid: int):
    """Single-char /proc/<pid>/stat state ('R' running, 'S' sleeping, 'T'
    stopped by a job-control signal (Ctrl+Z / SIGTSTP) or SIGSTOP, 'Z'
    zombie, ...). A stopped process can't update its own sessions/<pid>.json
    "status" field - reading this directly is the only way to tell a
    deliberately job-control-backgrounded session apart from one that's
    merely idle, confirmed live: CPU time is provably frozen (checked via
    `ps time` across a 5s window) while state is 'T', and a plain `fg` in
    its pane fully restores it - no different from any other shell
    background job."""
    try:
        raw = Path(f"/proc/{pid}/stat").read_text()
    except OSError:
        return None
    paren = raw.rfind(")")
    if paren == -1:
        return None
    rest = raw[paren + 2:].split()
    return rest[0] if rest else None


def _is_cgroup_frozen(pid: int) -> bool:
    """True if this pid was suspended via ~/.config/tmux/scripts/
    freeze-process-cgroup-toggle.sh (prefix+Ctrl-f / :freeze-process-cgroup-toggle),
    i.e. it currently lives in a "tmux-freeze-<pid>" cgroup v2 directory
    with cgroup.freeze == 1. Unlike _read_proc_state's 'T' check, this
    process is NOT stopped from the kernel scheduler's point of view (no
    signal was ever sent) -- /proc/<pid>/stat still reports 'S', so this
    is the only way to detect it."""
    try:
        line = Path(f"/proc/{pid}/cgroup").read_text().splitlines()[0]
    except (OSError, IndexError):
        return False
    if not line.startswith("0::"):
        return False
    relpath = line[3:]
    if Path(relpath).name != f"tmux-freeze-{pid}":
        return False
    try:
        return Path(f"/sys/fs/cgroup{relpath}/cgroup.freeze").read_text().strip() == "1"
    except OSError:
        return False


def _reap_if_orphaned(pid: int) -> bool:
    """A pid frozen via freeze-process-cgroup-toggle.sh is a child of the
    pane's shell, not the pane's own process tree root - the shell itself
    is deliberately left unfrozen (see that script's header comment for
    why: only the foreground job is suspended). If that shell exits - its
    tmux pane/session gets killed - while its child is still frozen, the
    child is orphaned: reparented to systemd --user (this host's
    subreaper), but being frozen, it is not scheduled at all and can never
    notice its parent is gone or exit on its own. Nothing left in the
    process tree could ever thaw or kill it again - it would sit there
    forever, still fully resident (see ~/frozen-claude-orphan-bug.md,
    found live: 13 such orphans had accumulated from this feature's own
    development, each with a tmux_self_session name for a session no
    longer in `tmux list-sessions`).

    Detected by ppid: a pid whose parent is systemd --user itself, not a
    real shell, has unambiguously been reparented to the subreaper - a
    live pane's frozen process always has the pane's actual shell as its
    parent. Only called on a pid already confirmed cgroup-frozen (see
    call site) - checking ppid for every live session pid on every cycle
    would be wasted work for the overwhelmingly common non-frozen case.

    Thaws first (a frozen task may not process a signal at all until
    unfrozen) then kills it. True if this pid was reaped - caller should
    not add a row for it, it no longer exists."""
    try:
        rest = Path(f"/proc/{pid}/stat").read_text()
        ppid = int(rest[rest.rfind(")") + 2:].split()[1])
        pcomm = Path(f"/proc/{ppid}/comm").read_text().strip()
    except (OSError, IndexError, ValueError):
        return False
    if pcomm != "systemd":
        return False

    try:
        line = Path(f"/proc/{pid}/cgroup").read_text().splitlines()[0]
        relpath = line[3:] if line.startswith("0::") else None
    except (OSError, IndexError):
        relpath = None
    if relpath and Path(relpath).name == f"tmux-freeze-{pid}":
        try:
            Path(f"/sys/fs/cgroup{relpath}/cgroup.freeze").write_text("0")
        except OSError:
            pass

    try:
        os.kill(pid, signal.SIGKILL)
        log(f"reaped orphaned frozen pid {pid} (parent was systemd --user, pid {ppid})")
    except ProcessLookupError:
        pass
    return True


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


def hyprland_windows_by_tmux_session(procs: dict = None) -> dict:
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
    # Shared with list_sessions' own live tty resolution when main() passes
    # one in (one /proc sweep per cycle instead of two) -- still usable
    # standalone (module-level testing, the earlier ad-hoc checks run
    # against this file) since a fresh sweep happens when procs is None.
    if procs is None:
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


def list_sessions(base: Path, tty_panes: dict, procs: dict, hypr_by_session: dict) -> list:
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
        if _is_cgroup_frozen(pid) and _reap_if_orphaned(pid):
            continue

        session_id = data.get("sessionId")
        cwd = data.get("cwd") or ""
        context_tokens = last_output_tokens = None
        transcript_ts = None
        if session_id and cwd:
            transcript = base / "projects" / cwd_to_slug(cwd) / f"{session_id}.jsonl"
            context_tokens, last_output_tokens = context_tokens_for(transcript)
            transcript_ts = last_message_ts_ms(transcript)

        # Live tty match (see _tmux_panes_by_tty's own comment for why this
        # replaced trusting the CLI's self-reported "tmux" field in this
        # file) -- info[1] is this pid's own tty_nr (_read_proc_stat's
        # (ppid, tty_nr) pair), already known for every live pid from
        # main()'s one /proc sweep.
        info = procs.get(pid)
        pane = tty_panes.get(info[1]) if info else None
        title = None
        tmux_session = tmux_window = tmux_pane = None
        if pane:
            tmux_session, tmux_window, tmux_pane = pane["session"], pane["window"], pane["pane"]
            title = pane["title"]
        if not title:
            # Not currently in any tmux pane -- fall back to the CLI's own
            # opaque auto-id rather than showing nothing.
            title = data.get("name")

        # The Hyprland window currently displaying this session's tmux
        # pane, if any (see hyprland_windows_by_tmux_session's own
        # comment) -- feeds the quickshell side's "hyprland" column group
        # and its hover-thumbnail/click-to-focus feature. All None for a
        # detached session (no window to preview) or a session not in
        # tmux at all.
        hypr = hypr_by_session.get(tmux_session) if tmux_session else None

        # Live process state takes precedence over the CLI's own
        # self-reported "status" - a stopped/frozen process can't write to
        # its own session file to say so (see _read_proc_state's and
        # _is_cgroup_frozen's docstrings). Checked in this order since a
        # cgroup-frozen process still reports proc state 'S', not 'T'.
        if _is_cgroup_frozen(pid):
            status = "frozen"
        elif _read_proc_state(pid) == "T":
            status = "stopped"
        else:
            status = data.get("status")

        rows.append({
            "pid": pid,
            "status": status,
            "title": title,
            "cwd": cwd,
            # Both only for notify_turn_done() below, not consumed by the
            # quickshell panel: session_id to rebuild the transcript path
            # without re-reading this registry file a second time, and the
            # self-reported "tmux" name (not tmux_session below, which is
            # the live #{session_id} -- notify-summon.sh's "claude-stop:"
            # click-to-focus branch matches by session *name*).
            "session_id": session_id,
            "tmux_self_session": (data.get("tmux") or "").split(":", 1)[0] or None,
            "tmux_session": tmux_session,
            "tmux_window": tmux_window,
            "tmux_pane": tmux_pane,
            # Transcript's own last-message timestamp, not the self-reported
            # per-process updatedAt (see last_message_ts_ms's docstring for
            # why: the latter reads "just now" for any --resume regardless
            # of the conversation's actual age). Falls back to updatedAt
            # only when the transcript has no parseable timestamp at all.
            "updated_at_ms": transcript_ts or data.get("updatedAt"),
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


def notify_fields_for(transcript_path: Path):
    """(ai_title, last_assistant_text) for the desktop notification --
    same growing-tail-window approach as context_tokens_for/
    last_message_ts_ms above (most recent record of each type is always
    near EOF), so this never loads a multi-MB transcript fully into
    memory. (None, "") if neither is found."""
    try:
        size = transcript_path.stat().st_size
    except OSError:
        return None, ""

    for window in TOKEN_SEARCH_WINDOWS:
        take = size if window is None else min(window, size)
        try:
            with transcript_path.open("rb") as fh:
                fh.seek(size - take)
                data = fh.read().decode("utf-8", errors="ignore")
        except OSError:
            return None, ""

        title = None
        body = ""
        for line in reversed(data.split("\n")):
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            rtype = rec.get("type")
            if title is None and rtype == "ai-title":
                title = rec.get("aiTitle")
            elif not body and rtype == "assistant":
                content = (rec.get("message") or {}).get("content")
                if isinstance(content, str):
                    body = content
                elif isinstance(content, list):
                    parts = [c.get("text", "") for c in content
                             if isinstance(c, dict) and c.get("type") == "text"]
                    body = " ".join(p for p in parts if p)
            if title is not None and body:
                return title, body

        if take >= size:
            return title, body
    return None, ""


def fmt_tokens(n):
    """274308 -> '274k', 850 -> '850' -- same rule as
    ClaudeUsageExpanded.qml's fmtTokens, for consistency with the panel."""
    if not isinstance(n, (int, float)):
        return None
    if n < 1000:
        return str(int(n))
    return f"{n / 1000:.1f}k" if n < 10000 else f"{int(n / 1000)}k"


def notify_footer(account: str, row: dict) -> str:
    """'146k tok · win 103 pane 111 · wks 16 · claude' -- same fields as
    the ctrl+alt+c panel's tokens/tmux/wks/acct columns, only the parts
    that actually resolved for this row."""
    parts = []
    tokens = fmt_tokens(row.get("context_tokens"))
    if tokens:
        parts.append(f"{tokens} tok")
    if row.get("tmux_window") and row.get("tmux_pane"):
        parts.append(f"win {row['tmux_window']} pane {row['tmux_pane']}")
    if row.get("hypr_workspace"):
        parts.append(f"wks {row['hypr_workspace']}")
    if account:
        parts.append(account)
    return " · ".join(parts)


def active_window_address():
    try:
        out = subprocess.run(
            ["hyprctl", "activewindow", "-j"],
            capture_output=True, text=True, timeout=2,
        )
        return json.loads(out.stdout).get("address")
    except Exception:
        return None


def notify_turn_done(account: str, base: Path, row: dict) -> None:
    """Fire the desktop notification for a session that just went from
    busy to waiting/idle (main()'s prev_status transition check) -- same
    icon/footer/skip-if-focused shape as the old Stop hook, just driven by
    this daemon's own already-fresh per-row data instead of a hook
    subprocess forked from inside Claude Code's turn-completion path."""
    try:
        if row.get("hypr_address") and row["hypr_address"] == active_window_address():
            return  # already looking at that window -- no point interrupting

        session_id, cwd = row.get("session_id"), row.get("cwd")
        transcript = base / "projects" / cwd_to_slug(cwd) / f"{session_id}.jsonl" if session_id and cwd else None
        ai_title, body = notify_fields_for(transcript) if transcript else (None, "")

        title = ai_title or row.get("title") or (Path(cwd).name if cwd else None) or "Claude Code"
        body = body.strip()
        if len(body) > NOTIFY_BODY_BUDGET:
            body = body[:NOTIFY_BODY_BUDGET].rstrip() + "…"
        footer = notify_footer(account, row)
        if footer:
            body = f"{body}\n\n{footer}" if body else footer

        app_name = f"claude-stop:{row['tmux_self_session']}" if row.get("tmux_self_session") else "claude-stop:"
        subprocess.run(
            ["notify-send", "-i", str(ICON_PATH), "-a", app_name, title, body],
            timeout=3,
        )
    except Exception as e:
        log(f"notify_turn_done: pid={row.get('pid')}: {e!r}")


# ---- inotify (ctypes, no third-party dependency) -------------------------
# Watches each account's sessions/ dir for CLOSE_WRITE/MOVED_TO so a status
# change (Claude Code rewriting its own sessions/<pid>.json, see
# list_sessions' docstring) triggers a session recompute promptly instead
# of waiting up to SESSIONS_INTERVAL. Deliberately doesn't parse individual
# inotify_event payloads -- every consumer here just wants to know
# "something changed", not which file, so a raw drain is enough.
_libc = ctypes.CDLL("libc.so.6", use_errno=True)
_libc.inotify_init1.restype = ctypes.c_int
_libc.inotify_add_watch.restype = ctypes.c_int
_INOTIFY_MASK = 0x00000008 | 0x00000080  # IN_CLOSE_WRITE | IN_MOVED_TO


def setup_inotify() -> tuple[int, int]:
    """(fd, watch_count). fd is -1 if inotify_init1 itself failed (caller
    falls back to plain polling); watch_count is how many of the 3
    accounts' sessions/ dirs actually got a watch (0 also means "fall back
    to polling for freshness", but the fd may still be valid)."""
    fd = _libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
    if fd < 0:
        errno = ctypes.get_errno()
        log(f"inotify_init1 failed ({os.strerror(errno)}), falling back to {SESSIONS_INTERVAL}s polling")
        return -1, 0
    watched = 0
    for _name, base in ACCOUNTS:
        sessions_dir = base / "sessions"
        if not sessions_dir.is_dir():
            continue
        wd = _libc.inotify_add_watch(fd, str(sessions_dir).encode(), _INOTIFY_MASK)
        if wd < 0:
            errno = ctypes.get_errno()
            log(f"inotify_add_watch({sessions_dir}) failed: {os.strerror(errno)}")
            continue
        watched += 1
    return fd, watched


def drain_inotify(fd: int) -> bool:
    """True if at least one event was read. Reads until EAGAIN so a burst
    of events (many sessions' files changing near-simultaneously) collapses
    into a single wake rather than one per event."""
    saw_any = False
    while True:
        try:
            data = os.read(fd, 64 * 1024)
        except BlockingIOError:
            return saw_any
        except OSError:
            return saw_any
        if not data:
            return saw_any
        saw_any = True


# ---- network usage-% fetch, on its own thread -----------------------------
# fetch_usage()'s urlopen(timeout=8) and the 2 * ACCOUNT_STAGGER (5s) pacing
# sleeps between the 3 accounts are both genuinely blocking - up to ~34s
# worst case per fetch cycle, which used to run on the same thread/loop as
# session recompute and inotify handling. A freeze/thaw notification (see
# freeze-process-cgroup-toggle.sh's nudge_claude_usage_panel) landing
# anywhere in that window sat queued, unread, until the fetch cycle
# finished and the loop came back around to select()-ing the inotify fd -
# confirmed live: a status stuck stale for over 15s despite the actual
# cgroup state having flipped immediately, with the delay traced to a
# fetch_usage() call itself (an interruptible wait around just the stagger
# sleeps closed part of the gap, but not that). Running the fetch
# independently removes the main loop's session/inotify responsiveness
# from this entirely - communicated back purely through _fetch_shared
# under _fetch_lock, a plain dict rather than anything fancier since it's
# one writer (this thread) and one reader (main()'s loop).
_fetch_lock = threading.Lock()
_fetch_shared = {
    "accounts_data": [{"account": name} for name, _ in ACCOUNTS],
    "mode": "idle",
    "interval": INTERVAL_IDLE,
    "dirty": False,
}


def fetch_loop() -> None:
    next_fetch = 0.0
    backoff_until = 0.0
    consecutive_429 = 0
    # account name -> last successful fetch_usage() result (no "account" key)
    last_good: dict[str, dict] = {}
    mode, interval = "idle", INTERVAL_IDLE

    while True:
        now = time.time()

        if now < backoff_until:
            new_mode, new_interval = "backoff", int(backoff_until - now)
            if (mode, interval) != (new_mode, new_interval):
                mode, interval = new_mode, new_interval
                with _fetch_lock:
                    _fetch_shared["mode"] = mode
                    _fetch_shared["interval"] = interval
                    _fetch_shared["dirty"] = True
            time.sleep(min(1.0, backoff_until - now))
            continue

        if now < next_fetch:
            time.sleep(min(1.0, next_fetch - now))
            continue

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

        with _fetch_lock:
            _fetch_shared["accounts_data"] = accounts_data
            _fetch_shared["mode"] = mode
            _fetch_shared["interval"] = interval
            _fetch_shared["dirty"] = True


def main() -> None:
    log("claude-usage-daemon starting")
    next_sessions = 0.0
    last_sessions_run = 0.0
    accounts_data = [{"account": name} for name, _ in ACCOUNTS]
    sessions_data = {name: [] for name, _ in ACCOUNTS}
    mode, interval = "idle", INTERVAL_IDLE
    # pid -> last-seen status, for the busy->waiting/idle transition that
    # means "a turn just finished" (notify_turn_done below). Deliberately
    # in-memory only -- a daemon restart just means the next real
    # transition after restart is the first one noticed, same cold-start
    # behavior the old Stop hook had (nothing to resume mid-turn either).
    prev_status: dict[int, str] = {}

    inotify_fd, watched = setup_inotify()
    if inotify_fd >= 0 and watched == 0:
        log("no sessions/ dirs to watch yet, falling back to polling")

    # See fetch_loop's own docstring/comment for why this runs independently
    # rather than sharing this loop: its blocking network calls must never
    # delay this loop's own session-recompute/inotify responsiveness.
    threading.Thread(target=fetch_loop, daemon=True).start()

    while True:
        now = time.time()
        dirty = False

        # Session/process listing: local-only, its own cadence, runs even
        # during a network backoff window. Also the trigger point for
        # turn-done notifications (see prev_status above) since this is
        # where each row's current status is known.
        if now >= next_sessions:
            procs = _read_all_proc()
            tty_panes = _tmux_panes_by_tty()
            hypr_by_session = hyprland_windows_by_tmux_session(procs)
            sessions_data = {name: list_sessions(base, tty_panes, procs, hypr_by_session) for name, base in ACCOUNTS}
            last_sessions_run = time.time()
            next_sessions = last_sessions_run + SESSIONS_INTERVAL
            dirty = True

            base_by_name = dict(ACCOUNTS)
            seen_pids = set()
            for name, rows in sessions_data.items():
                for row in rows:
                    pid = row.get("pid")
                    if pid is None:
                        continue
                    seen_pids.add(pid)
                    was, status = prev_status.get(pid), row.get("status")
                    if was == "busy" and status in ("waiting", "idle"):
                        notify_turn_done(name, base_by_name[name], row)
                    prev_status[pid] = status
            # Drop exited pids rather than let this grow forever across a
            # long-running daemon -- a reused pid getting treated as a
            # continuation of an unrelated old session is already an
            # accepted (and here, harmless-worst-case: a missed or
            # spurious notification) edge case elsewhere in this file.
            for pid in list(prev_status):
                if pid not in seen_pids:
                    del prev_status[pid]

        # Just picks up whatever fetch_loop most recently produced -- never
        # blocks, never does any network I/O on this thread.
        with _fetch_lock:
            if _fetch_shared["dirty"]:
                accounts_data = _fetch_shared["accounts_data"]
                mode = _fetch_shared["mode"]
                interval = _fetch_shared["interval"]
                _fetch_shared["dirty"] = False
                dirty = True

        if dirty:
            write_state(accounts_data, sessions_data, mode, interval)

        if inotify_fd >= 0:
            # Bounded by next_sessions, not just CHECK_GRANULARITY: a nudge
            # (see nudge_claude_usage_panel) pulls next_sessions forward
            # (below) to respect SESSIONS_MIN_GAP after the *previous*
            # recompute, but that pulled-forward value only mattered before
            # if a further inotify event happened to arrive and wake this
            # select() early - otherwise the loop blocked here for the
            # full, fixed CHECK_GRANULARITY (15s) regardless of how soon
            # next_sessions actually was, then only noticed it was already
            # due once that timeout finally elapsed on its own. Confirmed
            # live: two toggles inside SESSIONS_MIN_GAP of each other (e.g.
            # thaw immediately followed by freeze) - the first's recompute
            # landed fast, but the second's own pulled-forward
            # next_sessions (~3s away) got stranded behind a fresh, blind
            # 15s wait with nothing else to interrupt it, landing at
            # extremely close to next_sessions + CHECK_GRANULARITY instead
            # of next_sessions itself.
            timeout = max(0.0, min(CHECK_GRANULARITY, next_sessions - time.time()))
            ready, _, _ = select.select([inotify_fd], [], [], timeout)
            if ready and drain_inotify(inotify_fd):
                # A session's status file changed -- recompute soon, but
                # never sooner than SESSIONS_MIN_GAP after the last real
                # recompute (see that constant's comment: this is the
                # guard against a recompute storm under many simultaneously
                # active sessions).
                next_sessions = min(next_sessions, max(time.time(), last_sessions_run + SESSIONS_MIN_GAP))
        else:
            time.sleep(CHECK_GRANULARITY)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
