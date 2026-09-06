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
    other_clients = [c for c in hypr_state.get("clients", []) if not c.get("tmux_session")]

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


def build_session_workspace_map(hypr_state):
    """(session, window_index) -> (workspace_id, monitor_name), from a
    PRE-CRASH snapshot's hyprland.clients[].tmux_session cross-reference
    (computed by snapshot.py via tty ownership) joined against
    hyprland.workspaces[].monitor. A post-crash snapshot has none of
    this - pass in an old one, not latest.json, once trouble starts."""
    ws_by_id = {w["id"]: w for w in hypr_state.get("workspaces", [])}
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
        mapping[key] = {
            "window_index": ts["window_index"],
            "workspace_id": ws.get("id"),
            "monitor": ws_meta.get("monitor"),
            "tile_order": c.get("tile_order", 0),
        }
    return mapping


def resolve_resume_uuid(pane_contents_dir, session, window_index, pane_index, exclude_jsonl=()):
    """Extract the claude.ai/code/session_<id> OSC-8 footer from a
    pane's saved scrollback, then find the jsonl transcript whose
    bridgeSessionId matches - its filename (sans .jsonl) is the real
    --resume uuid. See tmux-disaster-recovery.md: cwd+account cannot
    disambiguate concurrent sessions since ~/.claude*/projects/<cwd> is
    the same inode across accounts."""
    pane_file = Path(pane_contents_dir) / f"pane-{session}:{window_index}.{pane_index}"
    if not pane_file.exists():
        return None
    text = pane_file.read_text(errors="replace")
    ids = re.findall(r"session_[A-Za-z0-9]+", text)
    if not ids:
        return None
    footer_id = ids[-1]
    for claude_dir in CLAUDE_DIRS:
        proj = claude_dir / "projects" / "-home-user1"
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


def apply_tmux(snap, resume=False, pane_contents=None, exclude_session=None, manage_daemon=True):
    was_active = stop_desktop_snapshot() if manage_daemon else False
    try:
        _apply_tmux_body(snap, resume=resume, pane_contents=pane_contents, exclude_session=exclude_session)
    finally:
        if manage_daemon and was_active:
            start_desktop_snapshot()


def _apply_tmux_body(snap, resume=False, pane_contents=None, exclude_session=None):
    hypr_state = snap.get("hyprland", {})
    mapping = build_session_workspace_map(hypr_state)
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

    pane_dir = None
    tmp = None
    if resume:
        if not pane_contents:
            print("--resume requires --pane-contents PATH_TO_TAR_GZ", file=sys.stderr)
            sys.exit(1)
        tmp = tempfile.TemporaryDirectory()
        with tarfile.open(pane_contents) as tf:
            tf.extractall(tmp.name)
        pane_dir = Path(tmp.name) / "pane_contents"

    exclude_jsonl = {exclude_session} if exclude_session else set()

    baseline_pid = get_activewindow_pid()
    baseline_ws = get_monitor_active_workspaces()
    print(f"baseline: activewindow pid={baseline_pid}, per-monitor active workspaces={baseline_ws}")

    by_workspace = {}
    for sess, m in todo.items():
        by_workspace.setdefault(m["workspace_id"], {"monitor": m["monitor"], "sessions": []})
        by_workspace[m["workspace_id"]]["sessions"].append((sess, m["window_index"], m["tile_order"]))

    for ws_id, info in sorted(by_workspace.items(), key=lambda kv: (kv[0] is None, kv[0])):
        # Spawn in the recorded tile_order (left-to-right, top-to-bottom
        # from the pre-crash layout): for the "master" layout, spawn
        # order alone reproduces which window ends up master vs. stack
        # position, with no pixel coordinates or extra dispatch needed.
        info["sessions"].sort(key=lambda t: t[2])
        for sess, window_index, _rank in info["sessions"]:
            if resume:
                uuid = resolve_resume_uuid(pane_dir, sess, window_index, "0", exclude_jsonl)
                if uuid:
                    print(f"  session {sess}: injecting claude --resume {uuid}")
                    subprocess.run(["tmux", "send-keys", "-t", f"{sess}:{window_index}",
                                     f"claude --resume {uuid}", "Enter"])
                else:
                    print(f"  session {sess}: could not resolve a --resume uuid, leaving pane as-is", file=sys.stderr)
            cmd = f"alacritty -e tmux attach -t {sess}"
            lua = f'hl.dispatch(hl.dsp.exec_cmd("[workspace {ws_id} silent] {cmd}"))'
            hypr_eval(lua)
            time.sleep(0.4)
        # Pin the monitor only after real windows exist in it - Hyprland
        # destroys an empty non-persistent workspace the instant its last
        # window closes, silently undoing any earlier pin. Do this once
        # per workspace, not per window.
        if info["monitor"]:
            lua = f'hl.dispatch(hl.dsp.workspace.move({{ workspace = {ws_id}, monitor = "{info["monitor"]}" }}))'
            hypr_eval(lua)

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
    hypr_state = snap.get("hyprland", {})
    other_clients = [c for c in hypr_state.get("clients", []) if not c.get("tmux_session")]
    current = json.loads(subprocess.run(["hyprctl", "-j", "clients"], capture_output=True, text=True).stdout or "[]")
    running_classes = {c.get("class") for c in current}

    for c in other_clients:
        cmdline = c.get("cmdline")
        if not cmdline:
            print(f"skip [{c.get('class')}]: no cmdline captured", file=sys.stderr)
            continue
        if c.get("class") in running_classes:
            print(f"skip [{c.get('class')}]: a window of this class is already running (not matching instances)")
            continue
        cmd = " ".join(cmdline)
        print(f"exec: {cmd}")
        subprocess.run(["hyprctl", "dispatch", "exec", "--", cmd])
        time.sleep(1.5)
        ws = c.get("workspace", {}).get("name")
        at = c.get("at")
        size = c.get("size")
        newest = json.loads(subprocess.run(["hyprctl", "-j", "clients"], capture_output=True, text=True).stdout or "[]")
        candidates = [w for w in newest if w.get("class") == c.get("class") and w.get("address") not in
                      {x.get("address") for x in current}]
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
