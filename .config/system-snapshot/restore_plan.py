#!/usr/bin/env python3
"""Turn a system-snapshot JSON (see snapshot.py) into a recovery plan.

Two modes:
  plan   (default) - read-only. Prints what was running, where, and under
                      which Claude account, so a human can recreate it. Never
                      touches tmux, Hyprland, or any process.
  apply  --yes      - best-effort automation for the *non-tmux* GUI apps
                      only (hyprctl dispatch exec + move to their recorded
                      workspace/position). Deliberately does NOT touch tmux
                      or relaunch claude itself: tmux-resurrect already owns
                      pane layout/content restore (prefix+C-r), and blindly
                      relaunching `claude --dangerously-skip-permissions` or
                      re-attaching sessions from a script is the kind of
                      thing that should be reviewed, not run unattended.
                      UNEXERCISED as of writing - read the plan output and
                      go in with eyes open before ever passing --yes.

Usage:
  restore_plan.py [snapshot.json]            # default: ~/.cache/system-snapshot/latest.json
  restore_plan.py [snapshot.json] --apply --yes
"""
import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

DEFAULT = Path.home() / ".cache" / "system-snapshot" / "latest.json"


def load(path):
    return json.loads(Path(path).read_text())


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
    p.add_argument("snapshot", nargs="?", default=str(DEFAULT))
    p.add_argument("--apply", action="store_true", help="relaunch+reposition non-tmux GUI apps (unexercised - see module docstring)")
    p.add_argument("--yes", action="store_true", help="required alongside --apply to actually act")
    args = p.parse_args()

    snap = load(args.snapshot)

    if args.apply:
        if not args.yes:
            print("--apply requires --yes (this launches processes and moves windows).", file=sys.stderr)
            sys.exit(1)
        apply(snap)
    else:
        print_plan(snap)


if __name__ == "__main__":
    main()
