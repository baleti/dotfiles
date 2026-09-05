#!/bin/bash
# Background poll loop backstopping claude-account-window-names-refresh.sh's
# hook-driven runs (after-new-window / pane-focus-in in ~/.tmux.conf) for the
# one case tmux exposes no hook for at all: a pane's foreground process
# changing while it stays the same, already-focused pane -- e.g. typing
# `claude` at an idle shell prompt in the window you're already looking at.
#
# Started once via `run-shell` at the bottom of ~/.tmux.conf, which reruns on
# every server start *and* every `tmux source-file` reload -- the pidfile
# lock stops a reload (or several) from stacking up duplicate loops.

LOCK_DIR="$HOME/.cache/tmux"
LOCK="$LOCK_DIR/claude-account-window-watch.pid"
REFRESH="$HOME/.config/tmux/scripts/claude-account-window-names-refresh.sh"

mkdir -p "$LOCK_DIR"

if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
    exit 0
fi

(
    echo $BASHPID > "$LOCK"
    while true; do
        "$REFRESH"
        sleep 3
    done
) </dev/null >/dev/null 2>&1 &
disown
