#!/bin/bash
# One-shot pass over every tmux window: rename any window whose active pane
# is running `claude` to the account it's using (claude/claude2/claude3 --
# same accounts/order as claude-usage-daemon.py's ACCOUNTS and the bar's
# Claude usage pill), and keep tracking that window's plain command name
# (mirroring tmux's own default automatic-rename behavior) once claude
# exits, rather than handing it back to tmux's native automatic-rename.
#
# Not handed back: confirmed by direct testing that turning automatic-rename
# back on immediately blanks a window's stored name regardless of what was
# just set via rename-window, pending a recompute that a detached (no
# attached client) session never seems to receive on its own. Once a window
# has run claude, this script's own poll loop (see
# claude-account-window-name-watch.sh) is a more reliable way to keep its
# name current than tmux's own engine turned out to be here.
#
# @claude_autoname marks a window as self-managed by this script (only set
# on windows it renamed itself, so a window a user happens to have manually
# called "claude2" for unrelated reasons is never mistaken for one of
# ours); @claude_lastset records the name this script last wrote, so a
# manual rename in between two passes is detected (current name no longer
# matches what we last set) and respected -- same "manual rename wins"
# contract tmux's own automatic-rename has, applied to our own tracking.
#
# Triggered by the after-new-window / pane-focus-in hooks in ~/.tmux.conf,
# and backstopped by claude-account-window-name-watch.sh's poll loop for the
# one case tmux has no hook for: typing `claude` at an already-focused idle
# shell prompt.

resolve_account() {
    local pane_pid="$1" claude_pid cfg_dir
    # Direct child of the pane's own process, not a recursive descendant
    # search: a claude process spawning further "claude"-comm children
    # (subagents) would otherwise be mistaken for the top-level session
    # this pane is actually running.
    claude_pid=$(pgrep -x -P "$pane_pid" claude | head -n1)
    cfg_dir=""
    if [ -n "$claude_pid" ] && [ -r "/proc/$claude_pid/environ" ]; then
        cfg_dir=$(tr '\0' '\n' < "/proc/$claude_pid/environ" | sed -n 's/^CLAUDE_CONFIG_DIR=//p')
    fi
    case "$cfg_dir" in
        */.claude2) echo "claude2" ;;
        */.claude3) echo "claude3" ;;
        *) echo "claude" ;;
    esac
}

tmux list-windows -a -F "#{session_name}:#{window_index}	#{pane_pid}	#{pane_current_command}	#{window_name}	#{@claude_autoname}	#{@claude_lastset}" |
while IFS=$'\t' read -r target pane_pid cur_cmd win_name marker lastset; do
    # A manual rename since our last write wins -- stop managing this
    # window, same as tmux's own "manual rename disables automatic-rename"
    # contract.
    if [ "$marker" = "1" ] && [ "$win_name" != "$lastset" ]; then
        tmux set-window-option -t "$target" -u "@claude_autoname"
        tmux set-window-option -t "$target" -u "@claude_lastset"
        marker=""
    fi

    desired=""
    if [ "$cur_cmd" = "claude" ]; then
        desired=$(resolve_account "$pane_pid")
    elif [ "$marker" = "1" ]; then
        desired="$cur_cmd"
    fi

    if [ -n "$desired" ] && [ "$win_name" != "$desired" ]; then
        tmux rename-window -t "$target" "$desired"
        tmux set-window-option -t "$target" "@claude_autoname" 1
        tmux set-window-option -t "$target" "@claude_lastset" "$desired"
    fi
done
