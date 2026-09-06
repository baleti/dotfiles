#!/bin/bash
# Backstop for the one case no tmux hook covers at all: a new command
# starting in a pane that's already focused and idle -- e.g. running
# `claude`, exiting it, then typing `htop` right after, all without ever
# switching away from that window. Confirmed necessary by direct testing
# (2026-09-06, in response to: "when i exit claude and try to run another
# command window renaming stops working... after i run claude now it
# stops working, window no longer changes to htop"):
#
#  - window-renamed can't fire for this, because once a window has been
#    claude-labeled even once, tmux disables that window's own
#    automatic-rename permanently -- straight from tmux(1)'s own docs:
#    "This flag is automatically disabled for an individual window when a
#    name is specified... later with rename-window", and rename-window is
#    the only way we (or anyone) can actually set window_name (confirmed:
#    real downstream tools -- winswitch's enrich.rs, window-search.py,
#    focus-picker.py -- read the real window_name for claude-account
#    filtering, so a cosmetic-only fix via window-status-format, which
#    would leave window_name itself untouched, isn't an option here).
#  - automatic-rename-format's #() shell-out -- the one path that doesn't
#    disable automatic-rename, since it never calls rename-window --
#    turned out not to be a way around this either: directly retested
#    with this same fast resolve logic (not just the old slow cache-based
#    command the previous design had ruled it out for) and it reproduced
#    the same staleness tmux bug either way: the job evaluates once and
#    then never re-runs on further command changes, one step behind
#    forever.
#
# So this is a deliberate, narrow exception to "no polling", not a return
# to the old design: scoped ONLY to the active pane of the active window
# in sessions with an attached client, not every window on the server --
# this only needs to catch a change in a pane someone is actually,
# currently looking at. A window nobody's looking at right now still gets
# the same information for free the moment it's actually focused
# (pane-focus-in handles that instantly, without waiting for this loop's
# next tick). That keeps the check's cost independent of total window
# count -- never more than a handful of panes, typically exactly one --
# unlike the old design, which measured ~35% of a core sweeping every
# window on the server every 3s regardless of what was focused.
#
# Only re-invokes the real hook script (the one that actually does the
# pgrep + /proc/<pid>/environ work) when a watched pane's own
# pane_current_command actually changed since the last tick -- the
# `tmux list-panes` call itself is the only per-tick cost otherwise, and
# that's tmux reading its own already-tracked state, no subprocess spawn.

HOOK="$HOME/.config/tmux/scripts/claude-account-window-rename-hook.sh"
LOCK_DIR="$HOME/.cache/tmux"
LOCK="$LOCK_DIR/claude-account-focused-pane-watch.pid"

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
