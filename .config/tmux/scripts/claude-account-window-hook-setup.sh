#!/bin/bash
# Registers a per-window `window-renamed` hook (see
# claude-account-window-rename-hook.sh) for one specific window (called from
# after-new-window in ~/.tmux.conf with that new window's own target), or for
# every existing window when called with no argument (a one-time migration
# run once at tmux server start / `tmux source-file` reload).
#
# Also does one immediate check for the target(s) it just wired up, since
# window-renamed only fires on a *change* -- a window created already
# running claude (or already sitting on a stale name from before this
# rewrite) would otherwise never get labeled/relabeled until its command
# next changes.
#
# Must set the hook with -w (window-scoped): confirmed by direct testing
# that -g (global) silently never fires for window-renamed on this tmux
# version (3.7c).

HOOK_SCRIPT="$HOME/.config/tmux/scripts/claude-account-window-rename-hook.sh"

setup_one() {
    local target="$1"
    tmux set-hook -t "$target" -w window-renamed "run-shell '$HOOK_SCRIPT \"#{session_name}:#{window_index}\"'"
    "$HOOK_SCRIPT" "$target"
}

if [ -n "$1" ]; then
    setup_one "$1"
else
    tmux list-windows -a -F "#{session_name}:#{window_index}" | while IFS= read -r target; do
        setup_one "$target"
    done
fi
