#!/usr/bin/env python3
"""MRU pane switcher for tmux (prefix+W), distinct from both prefix+w
(tmux's own choose-tree) and prefix+C-w (window-search.py's full-text
search): this one lists windows/panes in the order the user last actually
*visited* them, most-recent first - no scoring, no scrollback content
involved.

Every entry in that order comes from one real-timestamped log
(~/.cache/tmux-focus-order.log, written by focus-track.sh) fed by five tmux
hooks registered in .tmux.conf:

  - after-select-pane, after-select-window, session-window-changed,
    client-session-changed: explicit navigation commands *within* one
    terminal window (arrow keys, prefix+w, mouse, this picker's own jump).
    These only fire when a bound key or mouse action on an attached client
    changes the active pane - never when an unfocused pane merely produces
    output, which is what keeps a Claude Code session churning away in a
    background window from polluting the order: it never calls
    select-pane, so it never appends to the log no matter how much it
    prints.
  - client-focus-in: *switching to a different terminal window* (click,
    alt-tab, any window manager) runs no tmux command at all, so the four
    hooks above never fire for it - tmux has no visibility into
    window-manager focus by itself. What it does have natively is the
    terminal's own standard focus-reporting escape sequences (DEC private
    mode 1004, `focus-events on` in .tmux.conf): Alacritty sends focus-in
    to whichever pty currently has it the instant real OS focus changes,
    independent of window manager - no polling, no IPC socket, no daemon.

All five write through the same script into the same log with real
Unix timestamps, so - unlike an earlier version of this picker that tried
to merge tmux's log against a separately-queried Hyprland window-order
snapshot - there is one honest clock behind the whole list: no signal can
dominate the other just because it happens to update on a different scale.
A pane simply not yet hit by any hook sorts last, which is the only case
this can't say anything about.

The list is paired with a live preview of the highlighted pane's recent
scrollback (see preview()) and the same dynamic list/preview resize
window-search.py and claude-history already use - the list only takes as
many rows as it has matches, the preview gets the rest, both reacting to
fzf's own built-in filtering as you type (this list is static, handed to
fzf once, not reloaded).

Deps: tmux, fzf, python3.
"""
import argparse
import os
import shlex
import subprocess
import sys

LOG_PATH = os.path.expanduser("~/.cache/tmux-focus-order.log")
PREVIEW_LINES = 500  # recent scrollback only - this isn't a search tool
# (that's prefix+C-w), so there's no match to jump to or highlight; just
# enough tail to answer "what was I doing here"


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


def row(pane_id, p):
    label = f'{p["session"]}:{p["window_index"]} {p["window_name"]}{p["window_flags"]}: "{p["pane_title"]}"'
    return f"{pane_id}\t{label}"


def preview(pane_id):
    # -e (unlike window-search.py's preview): nothing here inserts its own
    # highlight ANSI codes on top, so the pane's real colors can just be
    # kept instead of stripped - there's no query to match/highlight, this
    # is a plain "what was I doing here" glance, not a search result
    r = subprocess.run(
        ["tmux", "capture-pane", "-p", "-e", "-J", "-t", pane_id,
         "-S", f"-{PREVIEW_LINES}"],
        capture_output=True, text=True, errors="replace",
    )
    if r.returncode != 0:
        sys.stdout.write(f"[capture-pane {pane_id} failed: {r.stderr.strip()}]\n")
        return
    sys.stdout.write(r.stdout)


def current_client_tty():
    """The tty of the client viewing THIS pane, resolved from directly
    inside the pane's own process tree. .tmux.conf runs this script via
    `new-window`, a real pane - not a popup, which has no controlling pane
    of its own to resolve #{client_tty} *from* (see window-search.py's
    current_client_tty() and its .tmux.conf entry for the full saga this
    sidesteps). A real pane needs none of it: tmux resolves "#{client_tty}"
    the same as if you'd typed the command at the prompt yourself."""
    r = subprocess.run(["tmux", "display-message", "-p", "#{client_tty}"],
                       capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def jump(client, pane_id):
    """Land the client that opened this window on the chosen pane. Mirrors
    window-search.py's jump() exactly (see its comments for why each step is
    there - the three-command fallback chain, and verifying against
    list-clients rather than display-message -c) - that function was
    hard-won against a real switch-client bug, so this reuses the same
    verified sequence rather than a fresh guess."""
    if not client:
        die("current_client_tty() couldn't resolve #{client_tty} for this "
            "pane - can't switch-client without it (see .tmux.conf, prefix+W)")

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


def drive():
    client = current_client_tty()
    live = list_live_panes()
    if not live:
        die("tmux list-panes returned no panes - nothing to switch to")

    me = current_pane(client) if client else None

    ordered_ids = [pid for pid, _ in read_focus_order() if pid in live and pid != me]
    # panes that exist but were never logged (created since the last focus
    # event, or from before focus-track.sh existed) still have to be
    # reachable - tacked on at the end, in list-panes' own order, rather than
    # silently hidden from the picker
    for pid in live:
        if pid != me and pid not in ordered_ids:
            ordered_ids.append(pid)

    if not ordered_ids:
        die("no other panes to switch to")

    rows = "\n".join(row(pid, live[pid]) for pid in ordered_ids)

    py = f"{shlex.quote(sys.executable)} {shlex.quote(os.path.abspath(__file__))}"
    preview_cmd = f"{py} --preview {{1}}"
    # same list/preview split as window-search.py and claude-history: react
    # to each match-set change (fzf's own built-in filtering here, not a
    # reload - this list is static, piped in once) and give the list just
    # enough rows for $FZF_MATCH_COUNT, preview gets the rest - EXCEPT the
    # list is also capped at half of FZF_LINES, so the preview never drops
    # below half regardless of match count, and grows past half on its own
    # the fewer results there are to list (same cap claude-history uses;
    # +3 is the prompt line plus the match-count info line plus one more,
    # measured short at +2 in window-search.py's original version).
    resize_on_result = (
        'c=$FZF_MATCH_COUNT; list_rows=$((c + 3)); '
        '[ "$list_rows" -lt 4 ] && list_rows=4; '
        'half=$((FZF_LINES / 2)); '
        '[ "$list_rows" -gt "$half" ] && list_rows=$half; '
        'echo "change-preview-window(down,$((FZF_LINES - list_rows)))"'
    )
    result = subprocess.run(
        [
            "fzf", "--ansi", "--layout=reverse",
            "--delimiter", "\t", "--with-nth", "2..",
            "--prompt", "focus history> ",
            "--preview", preview_cmd,
            "--preview-window", "down,50%,border-top,wrap",
            "--bind", f"result:transform:{resize_on_result}",
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
    parser.add_argument("--preview", metavar="PANE_ID")
    args = parser.parse_args()
    if args.preview:
        preview(args.preview)
    else:
        drive()


if __name__ == "__main__":
    main()
