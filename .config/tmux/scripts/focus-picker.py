#!/usr/bin/env python3
"""MRU pane switcher for tmux (prefix+W), distinct from both prefix+w
(tmux's own choose-tree) and prefix+C-w (window-search.py's full-text
search): this one lists windows/panes in the order the user last actually
*visited* them, most-recent first - no scoring, no scrollback content
involved.

Two independent focus signals feed the ordering, because tmux only ever
sees one of them:

  - Within one terminal window: a tmux hook fired for an explicit
    navigation command (after-select-pane, after-select-window,
    session-window-changed, client-session-changed - registered in
    .tmux.conf, logged by focus-track.sh into
    ~/.cache/tmux-focus-order.log). Those hooks only fire when a bound key
    or mouse action on an attached client changes the active pane - never
    when an unfocused pane merely produces output, which is what keeps a
    Claude Code session churning away in a background window from
    polluting the order: it never calls select-pane, so it never appends
    to the log no matter how much it prints.
  - Across terminal windows: clicking a different Hyprland window (or
    alt-tabbing to one) runs no tmux command at all, so the hooks above
    never fire for it - tmux has no visibility into window-manager focus.
    Hyprland does, though, and keeps it as persistent state rather than a
    stream you'd need to have been listening to: `hyprctl clients -j`
    reports every window's `focusHistoryID` (0 = most recently focused),
    updated internally by Hyprland itself regardless of whether anything
    is watching - the exact field ~/.config/hypr/winswitch already sorts
    by for its own alt-tab order (see its hyprctl.rs). So this queries it
    fresh on each invocation instead of running a listener daemon: no
    events to miss, nothing to keep alive.

The two signals are combined by resolving each attached tmux client's pid
up its /proc ancestry to the Hyprland window hosting it (tmux client -> its
shell -> the terminal emulator, 2 hops in practice), which gives each
*session* a Hyprland-recency rank. Panes are then sorted by
(session's Hyprland rank, pane's own position in the tmux-hook log) - so
switching terminal windows at the OS level reorders whole sessions, and
switching panes/windows with tmux's own keys reorders within a session, and
either one alone still produces a sensible list if the other source has
nothing to say (no Hyprland running, or a pane never hit by a hook yet).

Deps: tmux, fzf, python3. hyprctl is optional - its absence (not running
under Hyprland, e.g. over ssh) just drops back to log-only ordering.
"""
import argparse
import json
import os
import subprocess
import sys

LOG_PATH = os.path.expanduser("~/.cache/tmux-focus-order.log")
UNRANKED = 1 << 30


def die(msg):
    print(f"focus-picker: {msg}", file=sys.stderr)
    sys.exit(1)


def read_focus_order():
    """pane_id -> most recent visit timestamp (int), in file order (which is
    already newest-first, see focus-track.sh) - order is what matters here,
    the timestamp is only used for the display label."""
    order = []
    seen = set()
    try:
        with open(LOG_PATH) as f:
            for line in f:
                ts, _, pane_id = line.rstrip("\n").partition("\t")
                if not pane_id or pane_id in seen:
                    continue
                seen.add(pane_id)
                order.append((pane_id, ts))
    except FileNotFoundError:
        pass
    return order


def list_live_panes():
    fields = ["pane_id", "session_name", "window_index", "window_name",
              "window_flags", "pane_active", "pane_title"]
    fmt = "\t".join(f"#{{{f}}}" for f in fields)
    r = subprocess.run(["tmux", "list-panes", "-a", "-F", fmt],
                        capture_output=True, text=True)
    if r.returncode != 0:
        die(f"tmux list-panes failed (rc={r.returncode}): {r.stderr.strip()}")
    panes = {}
    for line in r.stdout.splitlines():
        pane_id, session, widx, wname, wflags, active, ptitle = line.split("\t")
        panes[pane_id] = {
            "session": session, "window_index": widx, "window_name": wname,
            "window_flags": wflags, "active": active == "1", "pane_title": ptitle,
        }
    return panes


def current_pane(client):
    r = subprocess.run(
        ["tmux", "display-message", "-p", "-t", client, "#{pane_id}"],
        capture_output=True, text=True,
    )
    return r.stdout.strip() if r.returncode == 0 else None


def hypr_window_focus_order():
    """pid -> focusHistoryID (0 = most recently focused) for every current
    Hyprland window. Not fatal if unavailable - not running under Hyprland
    (e.g. an ssh-in session) just means this contributes nothing and
    ordering falls back to the tmux-hook log alone."""
    try:
        r = subprocess.run(["hyprctl", "clients", "-j"],
                            capture_output=True, text=True, timeout=2)
        if r.returncode != 0:
            return {}
        clients = json.loads(r.stdout)
    except (FileNotFoundError, subprocess.TimeoutExpired,
            json.JSONDecodeError, OSError):
        return {}
    return {c["pid"]: c["focusHistoryID"] for c in clients
            if "pid" in c and "focusHistoryID" in c}


def parent_pid(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            data = f.read()
        # comm (2nd field) is parenthesized and may itself contain spaces
        # or parens, so split on the *last* ')' rather than whitespace
        rest = data[data.rindex(")") + 2:]
        return int(rest.split()[1])  # state ppid ... -> ppid is index 1
    except (OSError, ValueError, IndexError):
        return None


def window_pid_for(pid, window_ranks, max_hops=25):
    """Walk pid's ancestry up to the nearest ancestor that is a known
    Hyprland window - i.e. the terminal emulator hosting this tmux client.
    In practice this is tmux client -> shell -> terminal, 2 hops (verified
    against a live session before wiring this in), but the walk isn't
    hardcoded to that depth since an intermediate multiplexer/wrapper would
    add one without changing the underlying relationship."""
    seen = set()
    for _ in range(max_hops):
        if pid in window_ranks:
            return pid
        if pid is None or pid <= 1 or pid in seen:
            return None
        seen.add(pid)
        pid = parent_pid(pid)
    return None


def session_hypr_ranks():
    """session_name -> best (lowest) Hyprland focusHistoryID among its
    attached clients. Sessions that don't resolve to any live Hyprland
    window (detached, attached only via a remote/ssh client, or hyprctl
    unavailable) are simply absent - callers must treat missing as
    "unranked", not as rank 0, or every unresolved session would appear to
    tie for most-recently-focused."""
    window_ranks = hypr_window_focus_order()
    if not window_ranks:
        return {}
    r = subprocess.run(["tmux", "list-clients", "-F", "#{client_pid}\t#{session_name}"],
                        capture_output=True, text=True)
    if r.returncode != 0:
        return {}
    ranks = {}
    for line in r.stdout.splitlines():
        pid_s, session = line.split("\t")
        wpid = window_pid_for(int(pid_s), window_ranks)
        if wpid is None:
            continue
        rank = window_ranks[wpid]
        if session not in ranks or rank < ranks[session]:
            ranks[session] = rank
    return ranks


def row(pane_id, p):
    label = f'{p["session"]}:{p["window_index"]} {p["window_name"]}{p["window_flags"]}: "{p["pane_title"]}"'
    return f"{pane_id}\t{label}"


def resolve_client():
    """Fallback bridge for a tmux server still running an old bind-key - see
    window-search.py's resolve_client(), same reasoning, kept in sync with it
    rather than shared because it's five lines and not worth a shared module
    for one script pair."""
    r = subprocess.run(["tmux", "show-environment", "-g", "TMUX_FOCUS_PICKER_CLIENT"],
                        capture_output=True, text=True)
    subprocess.run(["tmux", "set-environment", "-gu", "TMUX_FOCUS_PICKER_CLIENT"],
                    capture_output=True, text=True)
    if r.returncode != 0 or "=" not in r.stdout:
        return None
    return r.stdout.strip().split("=", 1)[1]


def jump(client, pane_id):
    """Land the client that opened the popup on the chosen pane. Mirrors
    window-search.py's jump() exactly (see its comments for why each step is
    there - the #{client_tty} bridging, the three-command fallback chain,
    and verifying against list-clients rather than display-message -c) -
    that function was hard-won against a real switch-client bug, so this
    reuses the same verified sequence rather than a fresh guess."""
    if not client:
        die("TMUX_FOCUS_PICKER_CLIENT was empty or unset - the bind-key's "
            "`run-shell \"tmux set-environment -g ...\"` step did not run, or "
            "another invocation consumed it first (see .tmux.conf, prefix+W)")

    cr = subprocess.run(["tmux", "list-clients", "-F", "#{client_tty}\t#{session_name}"],
                        capture_output=True, text=True)
    if cr.returncode != 0:
        die(f"tmux list-clients failed (rc={cr.returncode}): {cr.stderr.strip()}")
    clients = {c: s for c, s in (line.split("\t") for line in cr.stdout.splitlines())}
    if client not in clients:
        die(f"client {client!r} isn't in the current attached-client list "
            f"{sorted(clients)!r} - can't target a switch-client to it")

    for cmd in (["switch-client", "-c", client, "-t", pane_id],
                ["select-window", "-t", pane_id],
                ["select-pane", "-t", pane_id]):
        r = subprocess.run(["tmux", *cmd], capture_output=True, text=True)
        if r.returncode != 0:
            die(f"tmux {' '.join(cmd)} failed: {r.stderr.strip()}")

    after = {c: p for c, p in (
        line.split("\t") for line in
        subprocess.run(["tmux", "list-clients", "-F", "#{client_tty}\t#{pane_id}"],
                        capture_output=True, text=True).stdout.splitlines()
    )}
    actual = after.get(client)
    if actual != pane_id:
        die(f"selected {pane_id} but client {client} ended up on {actual!r} instead - "
            f"switch-client silently landed on the wrong pane")


def drive(client=None):
    client = client or resolve_client()
    live = list_live_panes()
    if not live:
        die("tmux list-panes returned no panes - nothing to switch to")

    me = current_pane(client) if client else None

    log_rank = {pid: i for i, (pid, _) in enumerate(read_focus_order())}
    hypr_rank = session_hypr_ranks()

    def sort_key(pid):
        # primary: how recently this pane's session was focused at the OS
        # level (a different terminal window entirely); secondary: how
        # recently this exact pane was visited within its own terminal via
        # tmux's own navigation. Panes missing from one or both signals
        # (never logged yet, or a session with no Hyprland-resolvable
        # client) just sink to the end of that key instead of erroring -
        # dict.get's list-panes iteration order is the final tiebreaker,
        # via Python's sort stability, so nothing is ever hidden.
        session = live[pid]["session"]
        return (hypr_rank.get(session, UNRANKED), log_rank.get(pid, UNRANKED))

    ordered_ids = sorted((pid for pid in live if pid != me), key=sort_key)

    if not ordered_ids:
        die("no other panes to switch to")

    rows = "\n".join(row(pid, live[pid]) for pid in ordered_ids)

    result = subprocess.run(
        [
            "fzf", "--ansi", "--layout=reverse",
            "--delimiter", "\t", "--with-nth", "2..",
            "--prompt", "focus history> ",
        ],
        input=rows, capture_output=True, text=True,
    )
    selected = result.stdout.strip()
    if not selected:
        return
    pane_id = selected.split("\t", 1)[0]
    jump(client, pane_id)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--client", metavar="TTY",
                        help="tty of the client that opened the popup; the "
                             "bind-key interpolates #{client_tty} here")
    args = parser.parse_args()
    drive(args.client)


if __name__ == "__main__":
    main()
