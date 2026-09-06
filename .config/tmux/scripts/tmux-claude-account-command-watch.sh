#!/bin/bash
# What this is: a small loop, managed as a systemd --user service
# (tmux-claude-account-command-watch.service, After=tmux.service,
# Restart=always), that exists only to notice when the command running in
# your CURRENTLY FOCUSED pane changes -- e.g. you exit `claude` (any
# account) and either run a plain command or start a different account's
# claude in that same window. When it sees that, it re-runs
# claude-account-window-rename-hook.sh for that one window, same as
# tmux's own window-renamed hook does.
#
# Runs in the foreground (no self-backgrounding/disown, no lock file) --
# systemd is what supervises this now (2026-09-06: "put it in systemd
# unit so systemd manages it and starts on boot after tmux and restarts
# if it dies"), replacing the run-shell + pidfile-lock dance this used to
# do to keep exactly one instance alive across ~/.tmux.conf reloads. If
# this process dies, systemd restarts it directly; it is ordered
# After=tmux.service and follows its lifecycle (Wants=/PartOf=tmux.service),
# which is safe now that tmux.service is a systemd-tracked oneshot with
# RefuseManualStop (2026-09-06: an earlier version of that same coupling,
# against an *untracked* server whose unit had ExecStop=kill-server,
# propagated a unit pull-in into a 107-session wipe). If the server isn't
# up the loop below just idles harmlessly until it is.
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
# testing against this exact resolve script, not just the docs. Nor does
# wedging a static #() job into status-right, the way tmux-continuum used
# to drive its own periodic save -- confirmed against continuum's real
# source 2026-09-06: tmux re-evaluates a status-line job once PER
# ATTACHED CLIENT, and this system routinely has dozens attached, which
# is exactly why continuum itself was dropped here -- see the
# tmux-resurrect/tmux-continuum note in ~/.tmux.conf).
#
# Given all that, the only way left to catch "claude2 exited, claude3
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
# 1). Measured live at 0.0% CPU over several minutes when this ran as a
# plain background loop, before being moved under systemd.

HOOK="$HOME/.config/tmux/scripts/claude-account-window-rename-hook.sh"
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
