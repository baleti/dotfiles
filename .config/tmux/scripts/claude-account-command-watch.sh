#!/bin/bash
# What this is: a small background loop, started once by ~/.tmux.conf,
# that exists only to notice when the command running in your CURRENTLY
# FOCUSED pane changes -- e.g. you exit `claude` (any account) and either
# run a plain command or start a different account's claude in that same
# window. When it sees that, it re-runs claude-account-window-rename-hook.sh
# for that one window, same as tmux's own window-renamed hook does.
#
# Why this exists at all (requested 2026-09-06: "i think we should still
# have that hook act even if previously manual renaming happend - we
# could run claude2 in one terminal, then exit claude2, then run claude3
# in the same terminal - it should keep renaming windows accordingly"):
# tmux's own automatic-rename is what normally notices a pane's command
# changing, and window-renamed is what we react to -- but automatic-rename
# gets permanently switched off for a window the first time ANYONE renames
# it (rename-window is the only command that can set a window's real
# name, and doing so always disables automatic-rename for that window --
# straight from tmux(1) 3.7c: "This flag is automatically disabled for an
# individual window when a name is specified... later with rename-window").
# So after our hook labels a window "claude2" once, tmux stops watching
# that window's command on its own, for good -- there is no other tmux
# hook or event that fires when a pane's foreground command changes
# (automatic-rename-format's #() alternative doesn't disable
# automatic-rename, but doesn't help either: "tmux does not wait for #()
# commands to finish; instead, the previous result... is used", so it's
# always one step behind and never catches up -- confirmed by direct
# testing against this exact resolve script, not just the docs).
#
# Given that, the only way left to catch "claude2 exited, claude3
# started, same window" is to check periodically -- so this is a
# deliberate, narrow exception to the "no polling" design used
# everywhere else in this file, not an oversight. Kept as cheap as
# possible:
#   - Scoped to only the active pane of the active window in sessions
#     with an attached client -- i.e. only a window you're actually,
#     currently looking at right now. A window nobody's looking at can
#     wait until it's actually focused; nothing here needs to track
#     every window on the server the way the old (removed) daemon-backed
#     design did.
#   - One single `tmux list-panes` call per tick covers every such pane
#     at once (there's rarely more than one or two) -- tmux is just
#     reading its own already-tracked state for that, no subprocess
#     spawned beyond the tmux call itself.
#   - The real per-window work (pgrep + reading /proc/<pid>/environ,
#     inside claude-account-window-rename-hook.sh) only runs for a pane
#     whose command actually changed since the last tick -- not on every
#     tick for every watched pane.
# Measured cost of the daemon-backed design this whole feature replaced:
# ~35% of a core, continuously, sweeping every window on the server every
# 3s. This loop's shape is fundamentally different -- its cost doesn't
# grow with how many windows exist on the server, only with how many
# panes are actually focused across attached clients right now (normally
# 1).

HOOK="$HOME/.config/tmux/scripts/claude-account-window-rename-hook.sh"
LOCK_DIR="$HOME/.cache/tmux"
LOCK="$LOCK_DIR/claude-account-command-watch.pid"

mkdir -p "$LOCK_DIR"

if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
    exit 0
fi

(
    echo $BASHPID > "$LOCK"
    US=$'\x1f'
    declare -A last_cmd
    while true; do
        while IFS=$US read -r target cur_cmd; do
            [ -n "$target" ] || continue
            if [ "${last_cmd[$target]}" != "$cur_cmd" ]; then
                last_cmd["$target"]="$cur_cmd"
                "$HOOK" "$target"
            fi
        done < <(tmux list-panes -a \
                      -f "#{&&:#{&&:#{pane_active},#{window_active}},#{session_attached}}" \
                      -F "#{session_name}:#{window_index}${US}#{pane_current_command}" 2>/dev/null)
        sleep 2
    done
) </dev/null >/dev/null 2>&1 &
disown
