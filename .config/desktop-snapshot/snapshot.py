#!/usr/bin/env python3
"""Desktop session/window state snapshot daemon.

Captures, on an interval, everything needed to reconstruct "what was running
and where" on this desktop:

1. A metadata snapshot (JSON, in ~/.cache/desktop-snapshot/): Hyprland window
   positions/workspaces for every app, tmux sessions/windows/panes, and which
   Claude account (CLAUDE_CONFIG_DIR) each claude pane runs under -- plus an
   explicit cross-reference tying each terminal window to the tmux
   session/window it shows, resolved the same way
   claude-account-window-rename-hook.sh does (pgrep -x -P <pane_pid> claude,
   then /proc/<pid>/environ) rather than trusting the (rename-stale) window
   name. This part is pure reads: hyprctl -j, tmux list-*, /proc.

2. The tmux-resurrect save (pane layout + scrollback into ~/.tmux/resurrect/).
   This used to be driven by the tmux-continuum plugin, dropped 2026-09-06:
   continuum has no timer of its own, it just wedges `#(continuum_save.sh)`
   into status-right, so tmux re-ran it once per attached client per status
   redraw -- ~48 clients here meant a burst of 15-20 bash+tmux subprocesses
   every ~10s just to check "time to save yet?" (almost always no). This
   daemon calls tmux-resurrect's save.sh directly on a clean timer instead
   (see save_tmux_resurrect / --resurrect-interval). tmux-resurrect itself
   stays -- it still owns save.sh/restore.sh and the prefix+C-r restore
   binding; only continuum's scheduler is gone.

The resurrect save runs `tmux capture-pane` under the hood but never mutates
live tmux/Hyprland state (no new windows, no kills, no relaunches) -- exactly
the same safe path continuum exercised every 10 minutes.
"""
import argparse
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

CACHE_DIR = Path.home() / ".cache" / "desktop-snapshot"
SNAP_DIR = CACHE_DIR / "snapshots"
LATEST = CACHE_DIR / "latest.json"
US = "\x1f"  # field separator, matches claude-account-window-rename-hook.sh's convention

# Matches resurrect-rotate-pane-contents.sh's own default
# (@resurrect-delete-backup-after, unset here so it's 30) - see rotate()'s
# docstring for why these two schedules need to agree.
RETENTION_DAYS = 30

# tmux-resurrect's save script (see the module docstring for why this daemon
# drives it now instead of tmux-continuum). Path is where resurrect.tmux's
# self-healing checkout in ~/.tmux.conf clones it.
RESURRECT_SAVE_SCRIPT = (
    Path.home() / ".config" / "tmux" / "plugins" / "tmux-resurrect" / "scripts" / "save.sh"
)
# save.sh with @resurrect-capture-pane-contents on + ~150 panes takes ~10s
# wall; give it generous headroom before treating it as wedged.
RESURRECT_SAVE_TIMEOUT = 180
# Default seconds between resurrect saves. Independent of the metadata
# snapshot interval: the metadata capture is ~0.5s and fine to run often,
# the resurrect save is ~10s wall and there's little point doing it more
# than every few minutes. 0 (or --no-resurrect) disables it entirely.
DEFAULT_RESURRECT_INTERVAL = 300


def run(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return ""


def hyprctl_json(*args):
    out = run(["hyprctl", "-j", *args])
    try:
        return json.loads(out) if out else None
    except json.JSONDecodeError:
        return None


def read_proc_cmdline(pid):
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            raw = f.read()
        return [p for p in raw.decode(errors="replace").split("\0") if p]
    except OSError:
        return None


def read_proc_cwd(pid):
    try:
        return os.readlink(f"/proc/{pid}/cwd")
    except OSError:
        return None


def read_proc_environ(pid):
    try:
        with open(f"/proc/{pid}/environ", "rb") as f:
            raw = f.read()
    except OSError:
        return {}
    env = {}
    for kv in raw.decode(errors="replace").split("\0"):
        if "=" in kv:
            k, _, v = kv.partition("=")
            env[k] = v
    return env


def get_ps_tree():
    """One global `ps` call -> (pid_info, children). Avoids a pgrep/ps
    subprocess per window/pane - same "sweep once, not per-target" approach
    already used elsewhere in this config (claude-account-focused-pane-watch.sh)."""
    out = run(["ps", "-eo", "pid,ppid,tty,comm", "--no-headers"])
    pid_info = {}
    children = {}
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        try:
            pid, ppid = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        tty, comm = parts[2], parts[3]
        pid_info[pid] = {"ppid": ppid, "tty": tty, "comm": comm}
        children.setdefault(ppid, []).append(pid)
    return pid_info, children


def descendants(pid, children, limit=200):
    seen = []
    stack = [pid]
    while stack and len(seen) < limit:
        p = stack.pop()
        seen.append(p)
        stack.extend(children.get(p, []))
    return seen


def account_for_config_dir(cfg_dir):
    if cfg_dir.endswith("/.claude2"):
        return "claude2"
    if cfg_dir.endswith("/.claude3"):
        return "claude3"
    return "claude"


def session_id_for_claude_pid(claude_pid, cfg_dir):
    """The CLI writes its own <config_dir>/sessions/<pid>.json while
    running (claude-usage-daemon.py already reads these for the usage
    panel) - {"sessionId": ..., "cwd": ..., "tmux": "sess:@win.%pane", ...}.
    Capturing sessionId here, proactively, at snapshot time is a real
    --resume uuid straight from the source: no after-the-crash scrollback
    archaeology (grepping pane_contents_history for an OSC-8 footer, then
    matching it back to a jsonl transcript) needed for any session this
    was captured for. That archaeology remains the only option for
    sessions from before this field existed, or whose sessions/<pid>.json
    already got cleaned up by the time a snapshot ran."""
    base = Path(cfg_dir) if cfg_dir else Path.home() / ".claude"
    try:
        data = json.loads((base / "sessions" / f"{claude_pid}.json").read_text())
    except (OSError, ValueError):
        return None
    return data.get("sessionId")


def resolve_claude_account(pane_pid, children, pid_info):
    """Mirrors claude-account-window-rename-hook.sh's resolution exactly,
    but reuses the single global ps sweep instead of spawning pgrep."""
    claude_pid = next(
        (c for c in children.get(pane_pid, []) if pid_info.get(c, {}).get("comm") == "claude"),
        None,
    )
    if claude_pid is None:
        return None
    cfg_dir = read_proc_environ(claude_pid).get("CLAUDE_CONFIG_DIR", "")
    return {
        "claude_pid": claude_pid,
        "config_dir": cfg_dir or None,
        "account": account_for_config_dir(cfg_dir),
        "session_id": session_id_for_claude_pid(claude_pid, cfg_dir),
    }


def get_tmux_state(children, pid_info):
    """Sessions -> windows -> panes, plus which client (tty) is currently
    looking at which session/window, plus claude-account resolution per pane."""
    if not run(["tmux", "list-sessions"]):
        return {"sessions": [], "clients": []}

    sessions = []
    sess_out = run(["tmux", "list-sessions", "-F",
                     f"#{{session_name}}{US}#{{session_windows}}{US}#{{session_attached}}"])
    for line in sess_out.splitlines():
        parts = line.split(US)
        if len(parts) != 3:
            continue
        name, nwin, attached = parts
        windows = []
        win_out = run(["tmux", "list-windows", "-t", name, "-F",
                        f"#{{window_index}}{US}#{{window_name}}{US}#{{window_active}}"])
        for wline in win_out.splitlines():
            wparts = wline.split(US)
            if len(wparts) != 3:
                continue
            widx, wname, wactive = wparts
            panes = []
            pane_out = run(["tmux", "list-panes", "-t", f"{name}:{widx}", "-F",
                             f"#{{pane_index}}{US}#{{pane_pid}}{US}#{{pane_current_command}}"
                             f"{US}#{{pane_current_path}}{US}#{{pane_active}}"])
            for pline in pane_out.splitlines():
                pparts = pline.split(US)
                if len(pparts) != 5:
                    continue
                pidx, ppid_s, cmd, cwd, pactive = pparts
                try:
                    ppid = int(ppid_s)
                except ValueError:
                    continue
                pane = {
                    "pane_index": pidx,
                    "pane_pid": ppid,
                    "current_command": cmd,
                    "cwd": cwd,
                    "active": pactive == "1",
                }
                if cmd == "claude":
                    acc = resolve_claude_account(ppid, children, pid_info)
                    if acc:
                        pane["claude"] = acc
                panes.append(pane)
            windows.append({
                "index": widx,
                "name": wname,
                "active": wactive == "1",
                "panes": panes,
            })
        sessions.append({
            "name": name,
            "window_count": nwin,
            "attached": attached != "0",
            "windows": windows,
        })

    clients = []
    client_out = run(["tmux", "list-clients", "-F",
                       f"#{{client_tty}}{US}#{{session_name}}{US}#{{window_index}}{US}#{{window_name}}"])
    for line in client_out.splitlines():
        parts = line.split(US)
        if len(parts) != 4:
            continue
        tty, session, widx, wname = parts
        clients.append({
            "tty": tty,
            "tty_short": tty.removeprefix("/dev/"),
            "session": session,
            "window_index": widx,
            "window_name": wname,
        })

    return {"sessions": sessions, "clients": clients}


def get_hyprland_state(children, pid_info, tmux_clients):
    monitors = hyprctl_json("monitors") or []
    workspaces = hyprctl_json("workspaces") or []
    active = hyprctl_json("activewindow")
    raw_clients = hyprctl_json("clients") or []

    tty_index = {c["tty_short"]: c for c in tmux_clients}

    clients = []
    for c in raw_clients:
        pid = c.get("pid")
        entry = {
            "address": c.get("address"),
            "class": c.get("class"),
            "title": c.get("title"),
            "workspace": c.get("workspace"),
            "monitor": c.get("monitor"),
            "at": c.get("at"),
            "size": c.get("size"),
            "floating": c.get("floating"),
            "fullscreen": c.get("fullscreen"),
            "pid": pid,
        }
        if pid:
            entry["cmdline"] = read_proc_cmdline(pid)
            entry["cwd"] = read_proc_cwd(pid)
            # Is this window's process tree hosting a tmux client? (i.e. is
            # it a terminal emulator attached to a tmux session) - matched
            # by tty, not by pid, since the tmux *client* process is a
            # descendant of the terminal emulator's pid, not the pid itself.
            for desc_pid in descendants(pid, children):
                tty = pid_info.get(desc_pid, {}).get("tty")
                if tty in tty_index:
                    entry["tmux_session"] = tty_index[tty]
                    break
        clients.append(entry)

    # Relative tiling order, not absolute position: for the "master"
    # layout in use here, a fresh spawn becomes master if the workspace
    # was empty, else joins the stack - so replaying spawns in the same
    # relative order reproduces the layout without needing pixel
    # coordinates (which don't survive a monitor/resolution change
    # anyway). Sort each workspace's windows left-to-right, top-to-bottom
    # (master conventionally occupies the leftmost/largest area, stack
    # members are ordered top-to-bottom to its right) and store that rank.
    # tiledLayout (the "master"/"dwindle" algorithm) lives only in the
    # separate workspaces[] list from hyprctl - stamp it onto each client
    # too so anything consuming per-session data (restore_plan.py's
    # session->workspace map, say) has it without a manual join.
    tiled_layout_by_ws = {w["id"]: w.get("tiledLayout") for w in workspaces}
    by_workspace = {}
    for entry in clients:
        ws_id = (entry.get("workspace") or {}).get("id")
        entry["tiled_layout"] = tiled_layout_by_ws.get(ws_id)
        by_workspace.setdefault(ws_id, []).append(entry)
    for ws_clients in by_workspace.values():
        for rank, entry in enumerate(
            sorted(ws_clients, key=lambda e: tuple(e.get("at") or (0, 0)))
        ):
            entry["tile_order"] = rank

    return {
        "monitors": monitors,
        "workspaces": workspaces,
        "active_window": active,
        "clients": clients,
    }


def capture():
    pid_info, children = get_ps_tree()
    tmux_state = get_tmux_state(children, pid_info)
    hypr_state = get_hyprland_state(children, pid_info, tmux_state["clients"])
    return {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "hyprland": hypr_state,
        "tmux": tmux_state,
        "note": ("tmux pane scrollback/layout is restored via tmux-resurrect "
                 "(~/.tmux/resurrect, prefix+C-r) - this snapshot only adds "
                 "Hyprland window geometry/workspace and the tmux<->claude-account "
                 "cross-reference that resurrect doesn't track."),
    }


def write_snapshot(data):
    SNAP_DIR.mkdir(parents=True, exist_ok=True)
    ts = time.strftime("%Y%m%dT%H%M%S")
    path = SNAP_DIR / f"snapshot_{ts}.json"
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2))
    tmp.rename(path)
    tmp_latest = LATEST.with_suffix(".tmp")
    tmp_latest.write_text(json.dumps(data, indent=2))
    tmp_latest.rename(LATEST)
    return path


def rotate(retention_days=RETENTION_DAYS):
    """Generational thinning, bucketed on wall-clock boundaries (not
    age-at-check-time) so repeated runs converge instead of re-deciding
    which file "wins" a bucket differently each time.

    Mirrors resurrect-rotate-pane-contents.sh's own bucket schedule
    exactly (full resolution <=1h, 20min buckets to 3h, 1h buckets to
    18h, daily buckets beyond, out to a 30-day cutoff) instead of an
    independent one. A resurrect layout/content pair and the
    desktop-snapshot from that same moment should survive or age out
    together - confirmed a real disaster-recovery gap 2026-09-06 where a
    good resurrect pair survived its own thinning while the matching
    desktop-snapshot had already been thinned out under a different
    (2h/30min/4h) schedule, leaving no Hyprland placement data for an
    otherwise-perfectly-restorable tmux session."""
    if not SNAP_DIR.is_dir():
        return
    now = time.time()
    cutoff = now - retention_days * 86400
    files = sorted(SNAP_DIR.glob("snapshot_*.json"), key=lambda p: p.stat().st_mtime, reverse=True)
    seen_buckets = set()
    for f in files:
        mtime = f.stat().st_mtime
        if mtime < cutoff:
            f.unlink(missing_ok=True)
            continue
        age = now - mtime
        if age <= 3600:
            continue
        granularity = 20 * 60 if age <= 3 * 3600 else 3600 if age <= 18 * 3600 else 86400
        bucket = (granularity, int(mtime // granularity))
        if bucket in seen_buckets:
            f.unlink(missing_ok=True)
        else:
            seen_buckets.add(bucket)


def tmux_running():
    return bool(run(["tmux", "list-sessions"]).strip())


def save_tmux_resurrect():
    """Fire one tmux-resurrect save (layout .txt + pane_contents.tar.gz +
    the @resurrect-hook-post-save-all rotation hook). Returns True on
    success. Skips silently if tmux isn't up; logs and returns False on a
    missing script or a timeout/error."""
    if not RESURRECT_SAVE_SCRIPT.is_file():
        print(f"resurrect save: {RESURRECT_SAVE_SCRIPT} not found -- is tmux-resurrect checked out?",
              file=sys.stderr)
        return False
    if not tmux_running():
        return False
    try:
        r = subprocess.run(
            ["bash", str(RESURRECT_SAVE_SCRIPT), "quiet"],
            capture_output=True, text=True, timeout=RESURRECT_SAVE_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        print(f"resurrect save: timed out after {RESURRECT_SAVE_TIMEOUT}s", file=sys.stderr)
        return False
    except Exception as e:
        print(f"resurrect save: {e}", file=sys.stderr)
        return False
    if r.returncode != 0:
        print(f"resurrect save: exit {r.returncode} {r.stderr.strip()[:200]}", file=sys.stderr)
        return False
    return True


def do_capture(resurrect=False):
    path = write_snapshot(capture())
    rotate()
    if resurrect:
        save_tmux_resurrect()
    return path


def daemon(interval, resurrect_interval):
    running = True

    def stop(signum, frame):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    last_resurrect = 0.0
    while running:
        now = time.monotonic()
        due = resurrect_interval > 0 and (now - last_resurrect) >= resurrect_interval
        try:
            do_capture(resurrect=due)
        except Exception as e:
            print(f"snapshot failed: {e}", file=sys.stderr)
        if due:
            last_resurrect = now
        for _ in range(interval):
            if not running:
                break
            time.sleep(1)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)
    cp = sub.add_parser("capture", help="take one metadata snapshot now and exit")
    cp.add_argument("--resurrect", action="store_true",
                    help="also fire a tmux-resurrect save (off by default for a manual capture)")
    dp = sub.add_parser("daemon", help="loop, capturing on an interval")
    dp.add_argument("--interval", type=int, default=300,
                    help="seconds between metadata snapshots (default 300)")
    dp.add_argument("--resurrect-interval", type=int, default=DEFAULT_RESURRECT_INTERVAL,
                    help=f"seconds between tmux-resurrect saves (default {DEFAULT_RESURRECT_INTERVAL}); "
                         "0 disables")
    dp.add_argument("--no-resurrect", action="store_true",
                    help="don't drive tmux-resurrect saves at all")
    args = p.parse_args()

    if args.cmd == "capture":
        path = do_capture(resurrect=args.resurrect)
        print(path)
    elif args.cmd == "daemon":
        ri = 0 if args.no_resurrect else args.resurrect_interval
        daemon(args.interval, ri)


if __name__ == "__main__":
    main()
