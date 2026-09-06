#!/usr/bin/env python3
"""Restore the previously-saved tmux-resurrect desktop session and map it
onto Hyprland (correct workspace/monitor per session, no focus stealing).

Two steps, always in this order:
  1. Acquire a target tmux server (see modes below), then run
     tmux-resurrect's restore.sh against it - repopulates every session
     from ~/.tmux/resurrect/last + pane_contents.tar.gz (stage those
     first if you want a specific pre-crash snapshot instead of whatever
     they currently point to - see ~/.config/docs/tmux-disaster-recovery.md).
  2. Attach an Alacritty window per restored session onto its recorded
     workspace/monitor (restore_plan.py's apply_tmux, imported directly).

Server acquisition modes (mutually exclusive):
  (default)        systemctl --user restart tmux.service - kills whatever
                    is currently on the default socket (ExecStop runs
                    save.sh first, so current state isn't lost) and starts
                    a genuinely empty server. This is the important part:
                    restore.sh is NOT idempotent against a server that
                    already has the sessions (see kill_duplicate_panes.py
                    and the doc) - starting fresh sidesteps that bug
                    entirely instead of working around it after the fact.
  --own-server      spin up an isolated, throwaway tmux server on a
                    private socket instead of touching the systemd-managed
                    default one. For testing this script without any risk
                    to a real desktop session.
  --server ID       restore into an EXISTING already-running server,
                    identified by ID (passed to tmux as `-L ID`). Additive,
                    not fresh - if sessions from this same layout already
                    exist there, expect the restore.sh non-idempotency bug;
                    run kill_duplicate_panes.py afterwards if so.

Usage:
  restore_desktop_session.py                       # default: restart + restore + place
  restore_desktop_session.py --own-server
  restore_desktop_session.py --server mytest
  restore_desktop_session.py --snapshot PATH.json  # hyprland mapping source (default: latest.json)
  restore_desktop_session.py --no-place            # steps 1 only, skip Hyprland placement
  restore_desktop_session.py --resume              # also inject claude --resume via tmux send-keys
                                                    # (needs --pane-contents, see restore_plan.py)
"""
import argparse
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import restore_plan  # noqa: E402

RESURRECT_RESTORE_SH = Path.home() / ".tmux" / "plugins" / "tmux-resurrect" / "scripts" / "restore.sh"
TMUX_SOCKET_DIR = Path(f"/tmp/tmux-{os.getuid()}")


def run(cmd, **kw):
    print(f"+ {' '.join(cmd)}")
    return subprocess.run(cmd, **kw)


def acquire_default_server():
    """Restart the systemd unit: ExecStop saves current state, ExecStart
    brings up a fresh, empty server on the normal default socket."""
    run(["systemctl", "--user", "restart", "tmux.service"], check=True)
    time.sleep(1)
    return str(TMUX_SOCKET_DIR / "default")


def acquire_own_server():
    """A private, throwaway server - never touches the real default one."""
    sock = tempfile.mktemp(prefix="tmux-restore-", dir="/tmp")
    run(["tmux", "-S", sock, "new-session", "-d"], check=True)
    return sock


def acquire_named_server(server_id):
    """An existing server the caller already has running, identified by
    the name they gave `tmux -L <server_id>` (or `tmux new -s ...` under
    a plain default socket if they mean session name - this treats it as
    a *server* identifier, i.e. socket name, matching tmux's own -L)."""
    sock = str(TMUX_SOCKET_DIR / server_id)
    if not Path(sock).exists():
        print(f"no server socket found at {sock} - start it first "
              f"(e.g. `tmux -L {server_id} new-session -d`)", file=sys.stderr)
        sys.exit(1)
    return sock


def restore_tmux(socket_path):
    fake_tmux = f"{socket_path},0,0"
    print(f"restoring onto socket {socket_path}")
    r = run(["bash", str(RESURRECT_RESTORE_SH)], env={**os.environ, "TMUX": fake_tmux})
    if r.returncode != 0:
        print("restore.sh exited non-zero - check output above before continuing", file=sys.stderr)
        sys.exit(1)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--own-server", action="store_true", help="use a private throwaway tmux server")
    mode.add_argument("--server", metavar="ID", help="restore into an existing running server named ID (tmux -L ID)")
    p.add_argument("--snapshot", default=str(restore_plan.DEFAULT),
                    help="desktop-snapshot JSON to source the workspace/monitor mapping from "
                         "(default: %(default)s - use a pre-crash one if this is stale/empty)")
    p.add_argument("--no-place", action="store_true", help="only restore tmux sessions, skip the Hyprland placement step")
    p.add_argument("--resume", action="store_true", help="see restore_plan.py --resume")
    p.add_argument("--pane-contents", metavar="PATH", help="see restore_plan.py --pane-contents (required with --resume)")
    p.add_argument("--exclude-session", metavar="JSONL_STEM", help="see restore_plan.py --exclude-session")
    args = p.parse_args()

    # Stop/restart wraps the WHOLE flow (server acquisition + tmux restore
    # + Hyprland placement), not just the placement half - the daemon's
    # periodic resurrect-save can clobber the staged files during either
    # step. apply_tmux() gets manage_daemon=False below so it doesn't
    # restart the daemon prematurely between steps.
    was_active = restore_plan.stop_desktop_snapshot()
    try:
        if args.own_server:
            socket_path = acquire_own_server()
        elif args.server:
            socket_path = acquire_named_server(args.server)
        else:
            socket_path = acquire_default_server()

        restore_tmux(socket_path)

        if args.no_place:
            print("--no-place given: tmux sessions restored, skipping Hyprland placement.")
            return

        if socket_path != str(TMUX_SOCKET_DIR / "default"):
            print(f"NOTE: placement step (Alacritty attach) below still targets the DEFAULT tmux "
                  f"socket via plain `tmux` calls, not {socket_path}. For --own-server/--server runs "
                  f"that aren't the default socket, attach manually: "
                  f"`alacritty -e tmux -S {socket_path} attach -t <session>`.", file=sys.stderr)
            return

        snap = restore_plan.load(args.snapshot)
        restore_plan.apply_tmux(snap, resume=args.resume, pane_contents=args.pane_contents,
                                 exclude_session=args.exclude_session, manage_daemon=False)
    finally:
        if was_active:
            restore_plan.start_desktop_snapshot()


if __name__ == "__main__":
    main()
