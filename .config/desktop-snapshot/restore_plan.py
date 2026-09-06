#!/usr/bin/env python3
"""Turn a desktop-snapshot JSON (see snapshot.py) into a recovery plan.

Modes:
  plan        (default) - read-only. Prints what was running, where, and
                           under which Claude account, so a human can
                           recreate it. Never touches tmux, Hyprland, or
                           any process.
  apply       --yes      - best-effort automation for the *non-tmux* GUI
                           apps only (hyprctl exec + move to their recorded
                           workspace/position).
  apply-tmux  --yes      - attach an Alacritty window per restored tmux
                           session onto its pre-crash workspace/monitor,
                           without stealing focus (see below). Requires
                           tmux-resurrect to have already restored the
                           sessions themselves (this never touches tmux
                           content, only spawns terminals that attach to
                           what's already there) - see
                           ~/.config/docs/tmux-disaster-recovery.md for the
                           tmux-resurrect side (socket-detach gotcha,
                           desktop-snapshot.service clobbering the staged
                           archive, etc).
                           Add --resume to also resolve each pane's exact
                           `claude --resume <uuid>` (via the pane-contents
                           OSC-8-footer method, see the same doc) and type
                           it into the attached pane with `tmux send-keys`
                           - that's tmux-side and carries zero focus risk
                           regardless of whether any window is watching.

Validated 2026-09-06 against a real incident - see
~/.config/docs/tmux-disaster-recovery.md for the full writeup this
implementation is drawn from. No longer "unexercised": apply-tmux's
placement primitives (silent spawn + monitor.move) were checked directly
against `hyprctl activewindow` and each monitor's `activeWorkspace`
before/after, not assumed safe. `apply`'s plain GUI-relaunch path is
still separately unexercised - read its plan output before ever passing
--apply --yes.

Usage:
  restore_plan.py [snapshot.json]                                  # plan
  restore_plan.py [snapshot.json] --apply --yes
  restore_plan.py [snapshot.json] --apply-tmux --yes [--resume]
                  [--pane-contents PATH_TO_TAR_GZ] [--exclude-session ID]
"""
import argparse
import json
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path

DEFAULT = Path.home() / ".cache" / "desktop-snapshot" / "latest.json"
SNAPSHOTS_DIR = Path.home() / ".cache" / "desktop-snapshot" / "snapshots"
CLAUDE_DIRS = [Path.home() / ".claude", Path.home() / ".claude2", Path.home() / ".claude3"]


def load(path):
    return json.loads(Path(path).read_text())


def tmux_workspace_mapping_count(snapshot_path):
    """How many Hyprland clients this snapshot cross-references to a tmux
    session (hyprland.clients[].tmux_session) - the thing
    build_session_workspace_map() actually consumes. A snapshot can have
    plenty of tmux sessions recorded and still ~0 of these (e.g. captured
    right after a tmux-only restore, before any Alacritty window existed
    to attach to them yet), so tmux.sessions alone is misleading."""
    try:
        snap = load(snapshot_path)
    except (OSError, json.JSONDecodeError):
        return 0
    clients = snap.get("hyprland", {}).get("clients", [])
    return sum(1 for c in clients if c.get("tmux_session"))


def find_best_snapshot():
    """`latest.json` is whatever the daemon most recently wrote - right
    after a crash+reboot that's an empty just-started snapshot, not the
    rich pre-crash one a restore actually wants. "Most recent with any
    mapping" isn't the right fallback either: the sparsest moment right
    after a crash (a handful of clients reconnecting) is more recent than
    the rich pre-crash state, but far less useful. Pick whichever
    candidate - latest.json or any snapshots/*.json - has the most
    tmux<->Hyprland cross-references, not just the newest non-empty one.
    Still returns DEFAULT if nothing beats it, so this only ever helps."""
    candidates = [DEFAULT] + list(SNAPSHOTS_DIR.glob("snapshot_*.json"))
    best = max(candidates, key=tmux_workspace_mapping_count, default=DEFAULT)
    return str(best) if tmux_workspace_mapping_count(best) > 0 else str(DEFAULT)


def summarize_snapshot(path):
    """One line of `#windows/#tmux-sessions/#claude-sessions/#other-apps`
    per candidate, so a human picking a snapshot (see
    choose_snapshot_interactive) can tell a rich pre-crash capture from
    the near-empty one the daemon writes right after the crash/restart
    itself - the exact ambiguity that burned a restore earlier (latest.json
    was the freshly-started, almost-empty state, not the one anyone wanted)."""
    try:
        snap = load(path)
    except (OSError, json.JSONDecodeError):
        return None
    hypr = snap.get("hyprland", {})
    tmux = snap.get("tmux", {})
    clients = hypr.get("clients", [])
    ws_ids = {c["workspace"]["id"] for c in clients if c.get("workspace") and c["workspace"].get("id")}
    claude_idx = index_claude_by_session_window(tmux)
    return {
        "path": str(path),
        "timestamp": snap.get("timestamp") or "?",
        "workspaces": len(ws_ids),
        "windows": len(clients),
        "tmux_sessions": len(tmux.get("sessions", [])),
        "claude_sessions": sum(len(v) for v in claude_idx.values()),
        "other_apps": sum(1 for c in clients if not c.get("tmux_session")),
    }


def list_snapshots():
    """All distinct snapshots (latest.json plus every snapshots/*.json),
    newest first, deduplicated by the snapshot's own timestamp field -
    latest.json is a separate on-disk copy of whatever the daemon captured
    most recently (not a symlink), so a resolved-path dedup doesn't catch
    it; two rows with the same timestamp are the same capture written
    twice. The snapshots/ copy wins the slot (it's the durable, uniquely-
    named one) and latest.json is dropped whenever it duplicates one."""
    # snapshots/ entries checked before DEFAULT (latest.json) so the
    # durable, uniquely-named file wins the slot on a timestamp match.
    candidates = sorted(SNAPSHOTS_DIR.glob("snapshot_*.json"), reverse=True) + [DEFAULT]
    seen_ts = set()
    out = []
    for p in candidates:
        if not Path(p).is_file():
            continue
        s = summarize_snapshot(p)
        if not s:
            continue
        if s["timestamp"] in seen_ts:
            continue
        seen_ts.add(s["timestamp"])
        out.append(s)
    return out


def abort_prompt():
    """Clean exit for Ctrl+C/Ctrl+D/Escape during any interactive prompt in
    this module - no traceback, no partial action taken (called before any
    of these prompts' answers are acted on, only used to gather a
    decision)."""
    print("\nAborted.", file=sys.stderr)
    sys.exit(130)  # 128+SIGINT, the standard convention for a Ctrl+C exit


def ask(prompt_text):
    """input() wrapped so Ctrl+C (KeyboardInterrupt), Ctrl+D/closed stdin
    (EOFError), or Escape all abort the whole script immediately instead
    of raising a raw traceback or being silently treated as some other
    answer. A bare terminal in cooked line mode still hands Escape to
    input() as a literal \\x1b byte prepended to whatever's typed (it does
    not submit the line on its own) - checking for a leading ESC here
    catches "pressed Escape" whether or not Enter followed it, without
    needing a raw/cbreak terminal reader for what's otherwise plain
    line-based y/n and numeric prompts."""
    try:
        response = input(prompt_text)
    except (KeyboardInterrupt, EOFError):
        abort_prompt()
    if response.startswith("\x1b"):
        abort_prompt()
    return response.strip()


def choose_snapshot_interactive():
    """Print every available snapshot with enough of a summary to tell
    them apart (workspaces/windows/tmux sessions/claude sessions/other
    apps), and make the human pick one explicitly - no auto-picking
    "most recent", since most recent is exactly what a fresh, nearly-empty
    daemon capture after a restart/reboot looks like."""
    summaries = list_snapshots()
    if not summaries:
        print("no snapshots found under ~/.cache/desktop-snapshot", file=sys.stderr)
        sys.exit(1)
    # 25 wide, not 20: an ISO timestamp with a numeric timezone offset
    # ("2026-09-06T21:27:34+0100") is 24 characters - a 20-wide field let
    # it overflow and shift every column after it out of alignment with
    # the header, confirmed from a real run's misaligned output.
    print(f"\n{'#':>3}  {'captured':<25} {'ws':>3} {'win':>4} {'tmux':>5} {'claude':>7} {'other':>6}  file")
    for i, s in enumerate(summaries):
        print(f"{i+1:>3}  {s['timestamp']:<25} {s['workspaces']:>3} {s['windows']:>4} "
              f"{s['tmux_sessions']:>5} {s['claude_sessions']:>7} {s['other_apps']:>6}  {Path(s['path']).name}")
    while True:
        choice = ask(f"\nSelect snapshot to restore [1-{len(summaries)}]: ")
        if choice.isdigit() and 1 <= int(choice) <= len(summaries):
            return summaries[int(choice) - 1]["path"]
        print("invalid choice, try again")


def _nearest_at_or_before(paths_by_ts, target_ts):
    """paths_by_ts: {fixed-width timestamp string -> Path}. Returns the
    Path whose timestamp is the largest one <= target_ts, or None -
    fixed-width resurrect timestamps sort lexicographically, so a plain
    string compare works (same trick resurrect-restore.sh uses)."""
    best = None
    for ts in sorted(paths_by_ts):
        if ts <= target_ts:
            best = ts
        else:
            break
    return paths_by_ts.get(best) if best else None


def sync_resurrect_to_snapshot(snapshot_timestamp_iso, socket_path=None):
    """Repoint ~/.tmux/resurrect/last and pane_contents.tar.gz to whatever
    tmux-resurrect actually had at-or-before the CHOSEN desktop-snapshot's
    own timestamp - the same "nearest at-or-before" match
    ~/.config/tmux/scripts/resurrect-restore.sh already does for the
    interactive prefix+C-r picker.

    Without this, restore_tmux() always restores whatever `last` currently
    points to (tmux-resurrect's own most recent save) regardless of which
    snapshot the user picked from choose_snapshot_interactive() - confirmed
    a real gap 2026-09-06: picking a near-empty snapshot captured right
    after a restart still went ahead and restored the full pre-reboot
    session count, because `last` had never been repointed to match the
    chosen snapshot's moment. The two ARE captured on the same timer
    (snapshot.py's daemon drives both from one loop - see its module
    docstring) so a matching resurrect layout genuinely exists for most
    snapshots; this just makes the restore actually use that pairing
    instead of always reaching for the newest save.

    Queries @resurrect-dir from socket_path (the server about to be
    restored into) rather than hardcoding ~/.tmux/resurrect, same
    reasoning as resolve_restore_sh's server-side lookup - falls back to
    the documented default if the option isn't set for any reason."""
    resurrect_dir = None
    if socket_path:
        r = subprocess.run(["tmux", "-S", socket_path, "show-options", "-gqv", "@resurrect-dir"],
                            capture_output=True, text=True)
        if r.stdout.strip():
            resurrect_dir = Path(r.stdout.strip().replace("~", str(Path.home()), 1))
    resurrect_dir = resurrect_dir or (Path.home() / ".tmux" / "resurrect")
    hist_dir = resurrect_dir / "pane_contents_history"

    # "2026-09-06T21:22:10+0100" -> "20260906T212210" (resurrect's own
    # filename timestamp format).
    m = re.match(r"(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})", snapshot_timestamp_iso or "")
    if not m:
        print(f"could not parse snapshot timestamp {snapshot_timestamp_iso!r} - "
              f"leaving tmux-resurrect's 'last' pointer as-is", file=sys.stderr)
        return
    target_ts = f"{m.group(1)}{m.group(2)}{m.group(3)}T{m.group(4)}{m.group(5)}{m.group(6)}"

    layouts = {p.stem.removeprefix("tmux_resurrect_"): p for p in resurrect_dir.glob("tmux_resurrect_*.txt")}
    layout = _nearest_at_or_before(layouts, target_ts)
    if layout is None:
        print(f"no tmux-resurrect layout at or before {target_ts} - leaving 'last' as-is", file=sys.stderr)
        return
    layout_ts = layout.stem.removeprefix("tmux_resurrect_")
    print(f"tmux-resurrect: repointing 'last' -> {layout.name} (matches chosen snapshot's {target_ts})")
    last_link = resurrect_dir / "last"
    last_link.unlink(missing_ok=True)
    last_link.symlink_to(layout.name)

    archives = ({p.stem.removeprefix("pane_contents_"): p for p in hist_dir.glob("pane_contents_*.tar.gz")}
                if hist_dir.is_dir() else {})
    archive = _nearest_at_or_before(archives, layout_ts)
    if archive is None:
        print(f"no pane_contents archive at or before {layout_ts} - pane scrollback won't be restored",
              file=sys.stderr)
        return
    current = resurrect_dir / "pane_contents.tar.gz"
    if current.is_file():
        # Fold whatever's live right now into history first, under its own
        # "now" timestamp, so swapping to an older archive never discards
        # it - same reasoning as resurrect-restore.sh's own swap.
        hist_dir.mkdir(parents=True, exist_ok=True)
        now_ts = time.strftime("%Y%m%dT%H%M%S")
        shutil.copy2(current, hist_dir / f"pane_contents_{now_ts}.tar.gz")
    shutil.copy2(archive, current)
    print(f"tmux-resurrect: repointed pane_contents.tar.gz -> {archive.name}")


def get_other_clients(hypr_state):
    """Hyprland windows this snapshot recorded that are NOT a tmux client
    (i.e. not something apply_tmux's Alacritty-attach path already
    handles) - the general "any other application" set apply()/
    choose_apps_interactive() work from."""
    return [c for c in hypr_state.get("clients", []) if not c.get("tmux_session")]


def choose_apps_interactive(other_clients):
    """Per-app prompt instead of silently launching everything: show
    class/title/workspace and whether a window of that class is already
    running, then ask. Already-running apps default to "leave alone" (a
    restart closes the existing window first, so it must be opt-in); apps
    that aren't running default to "restore". Bare Alacritty windows with
    no tmux cross-reference are skipped here - relaunching an empty
    terminal restores nothing meaningful; apply_tmux already owns every
    Alacritty window that actually hosts a tmux session."""
    current = json.loads(subprocess.run(["hyprctl", "-j", "clients"], capture_output=True, text=True).stdout or "[]")
    running_classes = {c.get("class") for c in current}
    real = [c for c in other_clients if c.get("class") != "Alacritty"]
    decisions = []
    if not real:
        print("\nno other (non-Alacritty) application windows recorded in this snapshot.")
        return decisions
    print(f"\n{len(real)} other application window(s) recorded in this snapshot:")
    for c in real:
        running = c.get("class") in running_classes
        status = "already running" if running else "not running"
        ws = (c.get("workspace") or {}).get("name")
        cmd = " ".join(c.get("cmdline") or []) or None
        print(f"\n  {c.get('class')} - '{c.get('title')}'  (ws {ws}, {status})")
        if cmd:
            print(f"    cmd: {cmd}")
        else:
            print("    no cmdline captured - cannot relaunch automatically, skipping")
            continue
        if running:
            ans = ask("    restart this one too (closes the running window, relaunches onto its recorded workspace)? [y/N]: ").lower()
            if ans in ("y", "yes"):
                decisions.append((c, "restart"))
        else:
            ans = ask("    restore this one? [Y/n]: ").lower()
            if ans not in ("n", "no"):
                decisions.append((c, "launch"))
    return decisions


def apply_selected(decisions):
    """Launch (or restart-then-launch) exactly the (client, action) pairs
    choose_apps_interactive picked, positioning each new window onto its
    recorded workspace/position/size. Same "diff clients before/after to
    find the new address" approach as apply(), just driven by an explicit
    per-app decision list instead of a blanket running-class skip."""
    for c, action in decisions:
        cmdline = c.get("cmdline")
        cmd = " ".join(cmdline)
        if action == "restart":
            before_close = json.loads(subprocess.run(["hyprctl", "-j", "clients"], capture_output=True, text=True).stdout or "[]")
            for w in before_close:
                if w.get("class") == c.get("class"):
                    subprocess.run(["hyprctl", "dispatch", "closewindow", f"address:{w['address']}"])
            time.sleep(1)
        before = json.loads(subprocess.run(["hyprctl", "-j", "clients"], capture_output=True, text=True).stdout or "[]")
        before_addrs = {w.get("address") for w in before}
        print(f"exec: {cmd}")
        subprocess.run(["hyprctl", "dispatch", "exec", "--", cmd])
        time.sleep(1.5)
        ws = (c.get("workspace") or {}).get("name")
        at = c.get("at")
        size = c.get("size")
        newest = json.loads(subprocess.run(["hyprctl", "-j", "clients"], capture_output=True, text=True).stdout or "[]")
        candidates = [w for w in newest if w.get("class") == c.get("class") and w.get("address") not in before_addrs]
        if not candidates:
            print(f"  warning: could not identify the new window for [{c.get('class')}] to reposition it", file=sys.stderr)
            continue
        addr = candidates[0]["address"]
        if ws:
            subprocess.run(["hyprctl", "dispatch", "movetoworkspacesilent", f"{ws},address:{addr}"])
        if at:
            subprocess.run(["hyprctl", "dispatch", "movewindowpixel", f"exact {at[0]} {at[1]},address:{addr}"])
        if size:
            subprocess.run(["hyprctl", "dispatch", "resizewindowpixel", f"exact {size[0]} {size[1]},address:{addr}"])


def index_claude_by_session_window(tmux_state):
    idx = {}
    for sess in tmux_state.get("sessions", []):
        for win in sess.get("windows", []):
            for pane in win.get("panes", []):
                if "claude" in pane:
                    idx.setdefault((sess["name"], win["index"]), []).append({
                        "pane_index": pane["pane_index"],
                        "cwd": pane["cwd"],
                        **pane["claude"],
                    })
    return idx


def print_plan(snap):
    print(f"Snapshot from {snap.get('timestamp')}\n")

    tmux_state = snap.get("tmux", {})
    hypr_state = snap.get("hyprland", {})
    claude_idx = index_claude_by_session_window(tmux_state)

    print("=" * 70)
    print("TMUX (pane layout/scrollback: restore via prefix+C-r / resurrect-restore.sh first)")
    print("=" * 70)
    if not tmux_state.get("sessions"):
        print("  (no tmux sessions in this snapshot)")
    for sess in tmux_state.get("sessions", []):
        flag = "attached" if sess.get("attached") else "detached"
        print(f"\n  session '{sess['name']}' ({sess['window_count']} windows, {flag})")
        for win in sess.get("windows", []):
            claude_panes = claude_idx.get((sess["name"], win["index"]), [])
            claude_note = ""
            if claude_panes:
                accounts = ", ".join(f"pane {c['pane_index']}={c['account']} (cwd {c['cwd']})" for c in claude_panes)
                claude_note = f"  <- claude: {accounts}"
            active = " *" if win.get("active") else ""
            print(f"    window {win['index']} '{win['name']}'{active}{claude_note}")

    print()
    print("=" * 70)
    print("HYPRLAND WINDOWS")
    print("=" * 70)
    terminal_clients = [c for c in hypr_state.get("clients", []) if c.get("tmux_session")]
    other_clients = get_other_clients(hypr_state)

    print(f"\n  {len(terminal_clients)} window(s) hosting a tmux client (position only - content via tmux-resurrect):")
    for c in terminal_clients:
        ts = c["tmux_session"]
        ws = c.get("workspace", {}).get("name")
        print(f"    [{c.get('class')}] ws={ws} at={c.get('at')} size={c.get('size')}"
              f" -> tmux session '{ts['session']}' window {ts['window_index']} '{ts['window_name']}'")

    print(f"\n  {len(other_clients)} other application window(s) (relaunch + reposition manually, or see --apply):")
    for c in other_clients:
        ws = c.get("workspace", {}).get("name")
        cmd = " ".join(c.get("cmdline") or []) or "(cmdline unreadable)"
        print(f"    [{c.get('class')}] '{c.get('title')}' ws={ws} at={c.get('at')} size={c.get('size')}")
        print(f"        cmd: {cmd}")
        if c.get("cwd"):
            print(f"        cwd: {c['cwd']}")

    print()
    print("Recovery order suggestion:")
    print("  1. Restore tmux panes/layout: prefix+C-r in tmux (uses tmux-resurrect).")
    print("  2. For each 'claude:' line above, in that pane run:")
    print("       CLAUDE_CONFIG_DIR=~/.claudeN claude   (omit the env var for the plain 'claude' account)")
    print("  3. Relaunch the 'other application window(s)' listed above, then move/resize")
    print("     each to its recorded workspace/position (or run this script with --apply --yes).")


def stop_desktop_snapshot():
    """desktop-snapshot.service saves tmux-resurrect state on its own
    5-minute timer. A restore that takes longer than that (it will) gets
    its staged pane_contents.tar.gz / last symlink silently overwritten
    mid-recovery - see ~/.config/docs/tmux-disaster-recovery.md. Stop it
    for the duration rather than race it; returns whether it was active
    so the caller can restart it afterward."""
    r = subprocess.run(["systemctl", "--user", "is-active", "desktop-snapshot.service"],
                        capture_output=True, text=True)
    was_active = r.stdout.strip() == "active"
    if was_active:
        print("stopping desktop-snapshot.service for the duration of the restore")
        subprocess.run(["systemctl", "--user", "stop", "desktop-snapshot.service"])
    return was_active


def start_desktop_snapshot():
    print("restarting desktop-snapshot.service")
    subprocess.run(["systemctl", "--user", "start", "desktop-snapshot.service"])


def hypr_eval(lua):
    r = subprocess.run(["hyprctl", "eval", lua], capture_output=True, text=True)
    return r.stdout.strip()


def get_activewindow_pid():
    d = json.loads(subprocess.run(["hyprctl", "-j", "activewindow"], capture_output=True, text=True).stdout or "{}")
    return d.get("pid")


def get_monitor_active_workspaces():
    d = json.loads(subprocess.run(["hyprctl", "-j", "monitors"], capture_output=True, text=True).stdout or "[]")
    return {m["name"]: m["activeWorkspace"]["id"] for m in d}


def build_session_workspace_map(hypr_state, tmux_state=None):
    """(session, window_index) -> (workspace_id, monitor_name, account),
    from a PRE-CRASH snapshot's hyprland.clients[].tmux_session
    cross-reference (computed by snapshot.py via tty ownership) joined
    against hyprland.workspaces[].monitor and, separately,
    tmux.sessions[].windows[].panes[].claude (account/config_dir) via
    index_claude_by_session_window() - a completely different part of the
    same snapshot that this function used to ignore entirely. Without
    that second join, resolve_resume_uuid()'s file search can't
    disambiguate which account a session belongs to (~/.claude*/projects/
    <cwd> is the same inode across all three accounts, so a search across
    them always matches the first one checked, silently resuming
    everything as the default account regardless of which one actually
    owned it - confirmed as a real bug, not a snapshot gap). A post-crash
    snapshot has none of this - pass in an old one, not latest.json, once
    trouble starts."""
    ws_by_id = {w["id"]: w for w in hypr_state.get("workspaces", [])}
    claude_idx = index_claude_by_session_window(tmux_state or {})
    mapping = {}
    for c in hypr_state.get("clients", []):
        ts = c.get("tmux_session")
        if not ts:
            continue
        ws = c.get("workspace", {})
        ws_meta = ws_by_id.get(ws.get("id"), {})
        key = ts["session"]
        if key in mapping:
            continue
        claude_panes = claude_idx.get((key, ts["window_index"]), [])
        account = claude_panes[0]["account"] if claude_panes else None
        config_dir = claude_panes[0].get("config_dir") if claude_panes else None
        # Direct from the CLI's own sessions/<pid>.json, captured at
        # snapshot time (see snapshot.py's claude_self_reported) - the
        # real --resume uuid with no scrollback parsing needed, when a
        # snapshot recent enough to have it is available.
        session_id = claude_panes[0].get("session_id") if claude_panes else None
        # claude_cwd (CLI self-reported, from the same sessions/<pid>.json)
        # takes precedence over the pane-level cwd (from /proc/<pid>/cwd) -
        # confirmed a real incident where the latter was silently
        # corrupted for a pane on an rclone FUSE mount, reproduced
        # identically by tmux's own capture, so reading /proc more
        # carefully wouldn't have helped; the CLI's own report doesn't
        # route through that same symlink resolution.
        cwd = (claude_panes[0].get("claude_cwd") or claude_panes[0].get("cwd")) if claude_panes else None
        mapping[key] = {
            "window_index": ts["window_index"],
            "workspace_id": ws.get("id"),
            "monitor": ws_meta.get("monitor"),
            "session_id": session_id,
            "cwd": cwd,
            "tile_order": c.get("tile_order", 0),
            "tiled_layout": c.get("tiled_layout") or ws_meta.get("tiledLayout"),
            "account": account,
            "config_dir": config_dir,
        }
    return mapping


def resolve_resume_uuid(pane_contents_dir, session, window_index, pane_index, exclude_jsonl=(), cwd=None):
    """Extract the claude.ai/code/session_<id> OSC-8 footer from a
    pane's saved scrollback, then find the jsonl transcript whose
    bridgeSessionId matches - its filename (sans .jsonl) is the real
    --resume uuid. See tmux-disaster-recovery.md: cwd+account cannot
    disambiguate concurrent sessions since ~/.claude*/projects/<cwd> is
    the same inode across accounts *for a given cwd*.

    Matches the precise `"bridgeSessionId":"cse_<suffix>"` JSON field, not
    a bare substring of the URL-style id - confirmed a real false-positive
    class doing it the naive way: a transcript that happens to mention
    another session's URL anywhere in its own history (most commonly a
    git commit's own `Claude-Session: https://claude.ai/code/session_<id>`
    attribution line, which this codebase's own commits carry) matches on
    substring alone, misattributing that other session's uuid entirely.
    The quoted bridgeSessionId field is only ever written by the system
    establishing that specific session's own bridge, never incidentally
    produced by conversation content.

    `cwd`, when given, picks the right project directory
    (`~/.claude*/projects/<cwd with every "/" replaced by "-">`) instead
    of the hardcoded "-home-user1" this used to always search - confirmed
    a real bug: any pane whose cwd wasn't the home directory (e.g. a
    project checked out under a mounted drive) silently never resolved,
    since the search was looking in the wrong project dir entirely. Falls
    back to "-home-user1" when cwd is unknown, for backward compat."""
    pane_file = Path(pane_contents_dir) / f"pane-{session}:{window_index}.{pane_index}"
    if not pane_file.exists():
        return None
    text = pane_file.read_text(errors="replace")
    ids = re.findall(r"session_([A-Za-z0-9]+)", text)
    if not ids:
        return None
    footer_id = f'"bridgeSessionId":"cse_{ids[-1]}"'
    proj_name = cwd.replace("/", "-") if cwd else "-home-user1"
    for claude_dir in CLAUDE_DIRS:
        proj = claude_dir / "projects" / proj_name
        if not proj.is_dir():
            continue
        for jf in proj.glob("*.jsonl"):
            if jf.name in exclude_jsonl or jf.stem in exclude_jsonl:
                continue
            try:
                if footer_id in jf.read_text(errors="replace"):
                    return jf.stem
            except OSError:
                continue
    return None


def account_for_config_dir(cfg_dir):
    """Mirrors snapshot.py's own account_for_config_dir() - kept as a
    small local copy rather than importing that module, since nothing
    else here needs it."""
    if cfg_dir.endswith("/.claude2"):
        return "claude2"
    if cfg_dir.endswith("/.claude3"):
        return "claude3"
    return "claude"


def sanitize_config_dir(config_dir):
    """Some panes' captured CLAUDE_CONFIG_DIR carries literal quote
    characters (e.g. "'/home/user1/.claude'") or placeholder junk (e.g.
    "<account>") - artifacts of how a stale capture read that process's
    environment, not a real path. Strip surrounding quotes; reject
    anything that still doesn't look like an absolute path rather than
    inject garbage into a live shell command."""
    if not config_dir:
        return None
    cleaned = config_dir.strip().strip("'\"")
    return cleaned if cleaned.startswith("/") else None


def inject_resume(sess, window_index, pane_index, config_dir, account, session_id, cwd, get_pane_dir, exclude_jsonl):
    """Resolve and type `claude --resume <uuid>` into one pane. Shared by
    both the attached (has a Hyprland placement) and detached (tmux
    session with no client ever attached to it, so nothing to place -
    tmux-resurrect restores its content unconditionally regardless of
    attachment, but the Hyprland placement step only ever saw sessions
    with a client cross-reference) code paths - this is tmux-side only
    (`tmux send-keys`), so it works identically for both."""
    config_dir = sanitize_config_dir(config_dir)
    if config_dir:
        # config_dir is the ground truth; a separately-stored account
        # field can be stale (confirmed: some captures have a corrupted
        # config_dir - fixed by sanitize_config_dir above - alongside an
        # account field that was already wrongly derived from the
        # corrupted value at capture time, e.g. config_dir clearly
        # ".claude2" but account left as the "claude" default).
        account = account_for_config_dir(config_dir)
    target = f"{sess}:{window_index}.{pane_index}"
    current_cmd = subprocess.run(
        ["tmux", "display-message", "-p", "-t", target, "#{pane_current_command}"],
        capture_output=True, text=True).stdout.strip()
    if current_cmd == "claude":
        # Already running (e.g. a prior --resume run already fixed this
        # one) - typing another `claude --resume` into a live TUI doesn't
        # relaunch it, it just sends that text as a chat message.
        # Confirmed the hard way.
        print(f"  {target}: already running claude, skipping resume injection")
        return
    if session_id:
        uuid = session_id
        print(f"  {target}: session_id known directly from the snapshot (no scrollback parsing needed)")
    else:
        uuid = resolve_resume_uuid(get_pane_dir(), sess, window_index, pane_index, exclude_jsonl, cwd=cwd)
    if uuid:
        # Every account's project store for a given cwd is the same inode
        # (see resolve_resume_uuid's docstring), so the uuid search can't
        # tell accounts apart - without this prefix every resume silently
        # ran as whichever account happened to be checked first (confirmed
        # live: sessions captured under claude2/claude3 all came back as
        # the default account). config_dir/account come from
        # tmux.sessions[].windows[].panes[].claude instead.
        prefix = f"CLAUDE_CONFIG_DIR={config_dir} " if config_dir else ""
        print(f"  {target}: injecting {prefix}claude --resume {uuid} (account={account or 'claude'})")
        subprocess.run(["tmux", "send-keys", "-t", target,
                         f"{prefix}claude --resume {uuid}", "Enter"])
    else:
        print(f"  {target}: could not resolve a --resume uuid, leaving pane as-is", file=sys.stderr)


def apply_tmux(snap, resume=False, pane_contents=None, exclude_session=None, manage_daemon=True):
    was_active = stop_desktop_snapshot() if manage_daemon else False
    try:
        _apply_tmux_body(snap, resume=resume, pane_contents=pane_contents, exclude_session=exclude_session)
    finally:
        if manage_daemon and was_active:
            start_desktop_snapshot()


def _apply_tmux_body(snap, resume=False, pane_contents=None, exclude_session=None):
    hypr_state = snap.get("hyprland", {})
    mapping = build_session_workspace_map(hypr_state, snap.get("tmux", {}))
    if not mapping:
        print("no tmux_session cross-references in this snapshot - is it pre-crash?", file=sys.stderr)
        sys.exit(1)

    live = set(subprocess.run(["tmux", "list-sessions", "-F", "#{session_name}"],
                               capture_output=True, text=True).stdout.split())
    todo = {s: m for s, m in mapping.items() if s in live}
    missing = [s for s in mapping if s not in live]
    if missing:
        print(f"skipping {len(missing)} session(s) not present on the live tmux server "
              f"(not yet restored via tmux-resurrect?): {', '.join(missing[:10])}"
              f"{' ...' if len(missing) > 10 else ''}", file=sys.stderr)

    # Scrollback parsing is now only the fallback (see build_session_workspace_map's
    # session_id, sourced straight from the CLI's own sessions/<pid>.json)
    # - extract lazily, only if some session actually needs it, so --resume
    # doesn't require --pane-contents at all when every session already
    # has a direct session_id.
    pane_dir = None
    tmp = None

    def get_pane_dir():
        nonlocal pane_dir, tmp
        if pane_dir is None:
            if not pane_contents:
                print("a session has no direct session_id and needs scrollback fallback, "
                      "but --pane-contents wasn't given", file=sys.stderr)
                sys.exit(1)
            tmp = tempfile.TemporaryDirectory()
            with tarfile.open(pane_contents) as tf:
                tf.extractall(tmp.name)
            pane_dir = Path(tmp.name) / "pane_contents"
        return pane_dir

    exclude_jsonl = {exclude_session} if exclude_session else set()

    baseline_pid = get_activewindow_pid()
    baseline_ws = get_monitor_active_workspaces()
    print(f"baseline: activewindow pid={baseline_pid}, per-monitor active workspaces={baseline_ws}")

    by_workspace = {}
    for sess, m in todo.items():
        by_workspace.setdefault(m["workspace_id"], {"monitor": m["monitor"], "sessions": []})
        by_workspace[m["workspace_id"]]["sessions"].append(
            (sess, m["window_index"], m["tile_order"], m.get("config_dir"), m.get("account"),
             m.get("session_id"), m.get("cwd")))

    # A session with an already-attached client already has a window
    # showing it, whether from an earlier run of this same function or
    # anything else - spawning another `alacritty -e tmux attach` for it
    # duplicates the window instead of placing it. Confirmed a real gap
    # 2026-09-07: this loop had no such check at all, making a second call
    # (e.g. to redo just the --resume pass below after a placement-only
    # run) spawn a duplicate window per already-placed session.
    already_attached = set(subprocess.run(
        ["tmux", "list-clients", "-F", "#{client_session}"],
        capture_output=True, text=True).stdout.split())

    for ws_id, info in sorted(by_workspace.items(), key=lambda kv: (kv[0] is None, kv[0])):
        # Spawn in the recorded tile_order (left-to-right, top-to-bottom
        # from the pre-crash layout): for the "master" layout, spawn
        # order alone reproduces which window ends up master vs. stack
        # position, with no pixel coordinates or extra dispatch needed.
        info["sessions"].sort(key=lambda t: t[2])
        for sess, window_index, _rank, config_dir, account, session_id, cwd in info["sessions"]:
            if sess in already_attached:
                print(f"  {sess}: already has an attached client, skipping placement")
                continue
            cmd = f"alacritty -e tmux attach -t {sess}"
            lua = f'hl.dispatch(hl.dsp.exec_cmd("[workspace {ws_id} silent] {cmd}"))'
            hypr_eval(lua)
            time.sleep(0.4)
            already_attached.add(sess)
        # Pin the monitor only after real windows exist in it - Hyprland
        # destroys an empty non-persistent workspace the instant its last
        # window closes, silently undoing any earlier pin. Do this once
        # per workspace, not per window.
        if info["monitor"]:
            lua = f'hl.dispatch(hl.dsp.workspace.move({{ workspace = {ws_id}, monitor = "{info["monitor"]}" }}))'
            hypr_eval(lua)

    if resume:
        # Deliberately decoupled from the placement loop above: resume is
        # purely tmux-side (`tmux send-keys`), so it works identically
        # whether a pane has a Hyprland window watching it or not. One
        # pass over every (session, window, pane) with a known claude
        # record - from index_claude_by_session_window(), not filtered
        # through the Hyprland-attached mapping at all - covers every gap
        # that mapping can't see: a session nobody ever opened a window on
        # (tmux-resurrect restores its content unconditionally regardless
        # of attachment), an extra window in an otherwise-attached session
        # (confirmed live: session 33's window 0 was claude3, window 4 a
        # completely different claude2 conversation - Hyprland only ever
        # cross-referenced window 4), and an extra pane within one window
        # (confirmed live: window 3:2's pane 0 was untouched zsh while
        # pane 1 ran claude - `tmux send-keys -t session:window` with no
        # .pane targets whichever pane happens to be active, silently
        # skipping siblings). The "already running" check inside
        # inject_resume makes this safe to run over everything rather
        # than needing to track what the placement loop already covered.
        claude_idx = index_claude_by_session_window(snap.get("tmux", {}))
        for (sess, window_index), panes in claude_idx.items():
            if sess not in live:
                continue
            for p in panes:
                cwd = p.get("claude_cwd") or p.get("cwd")  # see build_session_workspace_map's comment
                inject_resume(sess, window_index, p["pane_index"], p.get("config_dir"), p.get("account"),
                              p.get("session_id"), cwd, get_pane_dir, exclude_jsonl)
                # Launching 100+ claude processes back-to-back with no
                # gap is real load (confirmed: taxed the system enough to
                # crash several already-launched sessions earlier in this
                # same incident) - pace it instead of firing all at once.
                time.sleep(1.5)

    if tmp:
        tmp.cleanup()

    now_pid = get_activewindow_pid()
    now_ws = get_monitor_active_workspaces()
    if now_pid != baseline_pid or now_ws != baseline_ws:
        print(f"WARNING: focus or a monitor's visible workspace changed during apply-tmux "
              f"(pid {baseline_pid} -> {now_pid}, workspaces {baseline_ws} -> {now_ws}). "
              f"This should not happen - investigate before trusting this run.", file=sys.stderr)
    else:
        print("verified: no focus/visible-workspace change occurred during placement.")


def apply(snap):
    """Non-interactive path for the plain `restore_plan.py --apply --yes`
    CLI: launch every other-app the snapshot recorded, skipping (not
    restarting) any whose class already has a window open. The
    interactive per-app prompt (restart-or-leave, shown running/not) lives
    in choose_apps_interactive + apply_selected instead - that's what
    restore_desktop_session.py's default flow uses."""
    other_clients = get_other_clients(snap.get("hyprland", {}))
    current = json.loads(subprocess.run(["hyprctl", "-j", "clients"], capture_output=True, text=True).stdout or "[]")
    running_classes = {c.get("class") for c in current}

    decisions = []
    for c in other_clients:
        if not c.get("cmdline"):
            print(f"skip [{c.get('class')}]: no cmdline captured", file=sys.stderr)
            continue
        if c.get("class") in running_classes:
            print(f"skip [{c.get('class')}]: a window of this class is already running (not matching instances)")
            continue
        decisions.append((c, "launch"))
    apply_selected(decisions)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("snapshot", nargs="?", default=None,
                    help="desktop-snapshot JSON (default: auto - latest.json if it has tmux "
                         "sessions, else the newest snapshots/*.json that does)")
    p.add_argument("--apply", action="store_true", help="relaunch+reposition non-tmux GUI apps (unexercised - see module docstring)")
    p.add_argument("--apply-tmux", action="store_true",
                   help="attach an Alacritty window per restored tmux session onto its pre-crash workspace/monitor")
    p.add_argument("--yes", action="store_true", help="required alongside --apply/--apply-tmux to actually act")
    p.add_argument("--resume", action="store_true",
                   help="with --apply-tmux: also resolve+inject each pane's claude --resume uuid via tmux send-keys")
    p.add_argument("--pane-contents", metavar="PATH",
                   help="path to a pane_contents_<ts>.tar.gz to resolve --resume uuids from (required with --resume)")
    p.add_argument("--exclude-session", metavar="JSONL_STEM",
                   help="skip this jsonl file (by stem/uuid) when matching --resume uuids "
                        "- use this session's own id to avoid self-matching")
    args = p.parse_args()

    snapshot_path = args.snapshot or find_best_snapshot()
    if args.snapshot is None and snapshot_path != str(DEFAULT):
        print(f"latest.json has no tmux sessions - using {snapshot_path} instead", file=sys.stderr)
    snap = load(snapshot_path)

    if args.apply and args.apply_tmux:
        print("--apply and --apply-tmux are separate passes - run one at a time.", file=sys.stderr)
        sys.exit(1)

    if args.apply:
        if not args.yes:
            print("--apply requires --yes (this launches processes and moves windows).", file=sys.stderr)
            sys.exit(1)
        apply(snap)
    elif args.apply_tmux:
        if not args.yes:
            print("--apply-tmux requires --yes (this launches processes and moves workspaces).", file=sys.stderr)
            sys.exit(1)
        apply_tmux(snap, resume=args.resume, pane_contents=args.pane_contents, exclude_session=args.exclude_session)
    else:
        print_plan(snap)


if __name__ == "__main__":
    main()
