#!/usr/bin/env python3
"""Session/window state snapshot daemon.

Captures, on an interval, everything needed to reconstruct "what was running
and where" on this desktop: Hyprland window positions/workspaces, tmux
sessions/windows/panes, and which Claude account (CLAUDE_CONFIG_DIR) each
claude pane was running under. Pane *contents*/scrollback and pane *layout*
restore are already handled by tmux-resurrect/continuum (~/.tmux/resurrect,
wired in ~/.tmux.conf) - this daemon deliberately does not duplicate that.
What it adds is the piece nothing else here captures: the Hyprland-level
window geometry/workspace for every app (terminals and non-terminals alike),
and an explicit cross-reference tying each terminal window to the tmux
session/window/claude-account it was showing, resolved the same way
claude-account-window-rename-hook.sh does (pgrep -x -P <pane_pid> claude,
then /proc/<pid>/environ for CLAUDE_CONFIG_DIR) rather than trusting the
window name, which can be stale under a manual rename.

Read-only. Never touches tmux, Hyprland, or any other process - only
hyprctl -j, tmux list-*, and /proc reads.
"""
import argparse
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

CACHE_DIR = Path.home() / ".cache" / "system-snapshot"
SNAP_DIR = CACHE_DIR / "snapshots"
LATEST = CACHE_DIR / "latest.json"
US = "\x1f"  # field separator, matches claude-account-window-rename-hook.sh's convention

RETENTION_DAYS = 14


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
    which file "wins" a bucket differently each time: keep everything from
    the last 2h, 1-per-30min out to 1d, 1-per-4h out to 7d, 1-per-day out
    to retention_days, delete beyond that."""
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
        if age <= 2 * 3600:
            continue
        granularity = 1800 if age <= 86400 else 4 * 3600 if age <= 7 * 86400 else 86400
        bucket = (granularity, int(mtime // granularity))
        if bucket in seen_buckets:
            f.unlink(missing_ok=True)
        else:
            seen_buckets.add(bucket)


def do_capture():
    path = write_snapshot(capture())
    rotate()
    return path


def daemon(interval):
    running = True

    def stop(signum, frame):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    while running:
        try:
            do_capture()
        except Exception as e:
            print(f"snapshot failed: {e}", file=sys.stderr)
        for _ in range(interval):
            if not running:
                break
            time.sleep(1)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("capture", help="take one snapshot now and exit")
    dp = sub.add_parser("daemon", help="loop, capturing on an interval")
    dp.add_argument("--interval", type=int, default=300, help="seconds between snapshots (default 300)")
    args = p.parse_args()

    if args.cmd == "capture":
        path = do_capture()
        print(path)
    elif args.cmd == "daemon":
        daemon(args.interval)


if __name__ == "__main__":
    main()
