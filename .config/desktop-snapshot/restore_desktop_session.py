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
  3. Interactively restore other (non-Alacritty) application windows the
     chosen snapshot recorded: per app, show its class/title/workspace and
     whether a window of that class is already running, and ask before
     touching anything - an already-running app defaults to "leave alone"
     (restarting it closes the running window first, so that's opt-in);
     one that isn't running defaults to "restore". See
     restore_plan.choose_apps_interactive/apply_selected.

Which snapshot to use is also interactive by default (restore_plan.
choose_snapshot_interactive): every candidate under ~/.cache/desktop-snapshot
is listed with its workspace/window/tmux-session/claude-session/other-app
counts so a human can tell a rich pre-crash capture apart from the
near-empty one the daemon writes right after this very script's own
tmux.service restart. Pass --snapshot to skip the prompt.

Server acquisition modes (mutually exclusive):
  (default)        systemctl --user restart tmux.service - kills whatever
                    is currently on the default socket and starts a
                    genuinely empty one. tmux.service has no ExecStop
                    anymore, so nothing auto-saves the outgoing state first
                    - if that ever matters, save deliberately before
                    running this. This is the important part: restore.sh
                    is NOT idempotent against a server that already has
                    the sessions (see kill_duplicate_panes.py and the doc)
                    - starting fresh sidesteps that bug entirely instead
                    of working around it after the fact.
                    Refuses to run in this mode if $TMUX already points at
                    this exact socket - the restart would kill the pane
                    running this script along with everything else, mid-run.
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
  restore_desktop_session.py --snapshot PATH.json  # skip the snapshot-picker prompt
  restore_desktop_session.py --no-place            # skip Hyprland placement (tmux restore only)
  restore_desktop_session.py --no-apps             # skip the other-application restore prompt
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

# ~/.config/tmux/plugins/, NOT ~/.tmux/plugins/ - .tmux.conf's own
# self-healing checkout line (`run '~/.config/tmux/plugins/tmux-resurrect/
# resurrect.tmux'`) clones there, and that's the copy paired with
# snapshot.py's RESURRECT_SAVE_SCRIPT. A stale ~/.tmux/plugins/tmux-resurrect/
# checkout (2021-dated, unreferenced by any config) sat alongside it with an
# INCOMPATIBLE pane-line field order (pane_title vs window_name in
# different slots) - this constant pointed at that stale one, so restore.sh
# misread window titles as pane indices, producing exactly the "no current
# client" / "can't find pane: <window title>" garbage seen 2026-09-06
# (confirmed by diffing both checkouts' save.sh/restore.sh field orders
# directly - restore_pane_processes.sh's switch-client+select-pane pair,
# called once per window, was receiving a window title string instead of a
# numeric pane index).
RESURRECT_RESTORE_SH = Path.home() / ".config" / "tmux" / "plugins" / "tmux-resurrect" / "scripts" / "restore.sh"
TMUX_SOCKET_DIR = Path(f"/tmp/tmux-{os.getuid()}")


def run(cmd, **kw):
    print(f"+ {' '.join(cmd)}")
    return subprocess.run(cmd, **kw)


def acquire_default_server():
    """Restart the systemd unit: no ExecStop hook anymore (tmux.service
    dropped it - it existed only to snapshot live state on the way down,
    which flashed "Saving..." on every attached client and, worse, raced
    this script's own repointing of last/pane_contents.tar.gz whenever the
    script itself ran from a pane on the server being restarted). The
    restart is now just a plain stop+start: kills the server, then
    ExecStart brings up a genuinely fresh, empty one on the normal default
    socket. Trade-off: nothing auto-saves current live state before the
    kill anymore - if that ever matters, save deliberately first."""
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


def resolve_restore_sh(socket_path):
    """Same resolution ~/.config/tmux/scripts/resurrect-restore.sh uses for
    the real prefix+C-r binding: ask the *target* server's own
    @resurrect-restore-script-path (set by resurrect.tmux's
    set_script_path_options when .tmux.conf's `run` line loads the plugin
    on that server), falling back to RESURRECT_RESTORE_SH only if the
    option is somehow unset. Querying the server instead of hardcoding a
    second path means this can't independently drift from wherever
    .tmux.conf's own self-healing checkout line points, the way the
    previous hardcoded ~/.tmux/plugins/... constant silently did - see
    RESURRECT_RESTORE_SH's docstring for the incident that caught it."""
    r = subprocess.run(["tmux", "-S", socket_path, "show-options", "-gqv", "@resurrect-restore-script-path"],
                        capture_output=True, text=True)
    path = r.stdout.strip()
    return path if path else str(RESURRECT_RESTORE_SH)


def restore_tmux(socket_path):
    fake_tmux = f"{socket_path},0,0"
    restore_sh = resolve_restore_sh(socket_path)
    print(f"restoring onto socket {socket_path} (restore.sh: {restore_sh})")
    r = run(["bash", restore_sh], env={**os.environ, "TMUX": fake_tmux})
    if r.returncode != 0:
        print("restore.sh exited non-zero - check output above before continuing", file=sys.stderr)
        sys.exit(1)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--own-server", action="store_true", help="use a private throwaway tmux server")
    mode.add_argument("--server", metavar="ID", help="restore into an existing running server named ID (tmux -L ID)")
    p.add_argument("--snapshot", default=None,
                    help="desktop-snapshot JSON to source the workspace/monitor mapping from "
                         "(default: prompt interactively - see restore_plan.choose_snapshot_interactive)")
    p.add_argument("--no-place", action="store_true", help="only restore tmux sessions, skip the Hyprland placement step")
    p.add_argument("--no-apps", action="store_true", help="skip the other-application (non-Alacritty) restore prompt")
    p.add_argument("--resume", action="store_true", help="see restore_plan.py --resume")
    p.add_argument("--pane-contents", metavar="PATH", help="see restore_plan.py --pane-contents (required with --resume)")
    p.add_argument("--exclude-session", metavar="JSONL_STEM", help="see restore_plan.py --exclude-session")
    args = p.parse_args()

    # Default mode restarts tmux.service, which kills every pane on that
    # server - including this script's own, if it's running inside one of
    # them. That's fatal partway through: the restart's own save.sh has
    # already clobbered last/pane_contents.tar.gz by the time the kill
    # lands, and the repair step right after never gets to run. Detect and
    # refuse rather than silently corrupt the staging.
    running_inside_this_server = (
        not args.own_server and not args.server
        and os.environ.get("TMUX", "").split(",")[0] == str(TMUX_SOCKET_DIR / "default")
    )
    if running_inside_this_server:
        print("Refusing: this script is running inside a pane on the default tmux server, "
              "and default mode restarts that exact server - it would kill this script's own "
              "process mid-restore, right after the restart's save.sh has already overwritten "
              "your staged pane_contents.tar.gz/last, before the repair step can run.\n"
              "Run this from outside tmux (a plain TTY/VT, or a terminal not attached to the "
              "default socket), or use --own-server / --server ID instead.", file=sys.stderr)
        sys.exit(1)

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

        # Snapshot choice drives both the tmux placement and the app-restore
        # step below, so it's picked once, up front, before restore.sh runs -
        # not because restore.sh needs it, but so a mistaken pick doesn't
        # mean restoring tmux twice.
        snapshot_path = args.snapshot or restore_plan.choose_snapshot_interactive()
        snap = restore_plan.load(snapshot_path)

        # Repoint tmux-resurrect's own 'last'/pane_contents.tar.gz to match
        # the CHOSEN snapshot's moment, not whatever resurrect save happens
        # to be newest right now - see sync_resurrect_to_snapshot's
        # docstring for the gap this closes (picking an old/near-empty
        # snapshot used to still restore the newest tmux state regardless).
        restore_plan.sync_resurrect_to_snapshot(snap.get("timestamp"), socket_path)

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

        restore_plan.apply_tmux(snap, resume=args.resume, pane_contents=args.pane_contents,
                                 exclude_session=args.exclude_session, manage_daemon=False)

        if not args.no_apps:
            other_clients = restore_plan.get_other_clients(snap.get("hyprland", {}))
            decisions = restore_plan.choose_apps_interactive(other_clients)
            if decisions:
                restore_plan.apply_selected(decisions)
    finally:
        if was_active:
            restore_plan.start_desktop_snapshot()


if __name__ == "__main__":
    main()
