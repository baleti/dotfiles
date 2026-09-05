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
#
# Account resolution (2026-09-06 rewrite): claude-usage-daemon.py already
# computes exactly this mapping -- account -> every live session's
# tmux_session/tmux_window -- every SESSIONS_INTERVAL (30s) and writes it to
# ~/.cache/claude-usage/state.json, itself built from one /proc sweep plus
# one batched `tmux list-panes`, not a subprocess per session. Reusing that
# instead of each window independently spawning its own `pgrep` +
# /proc/<pid>/environ read was the whole fix here: with ~100 claude windows,
# the old per-window approach measured at 4.2s wall / 4.3 CPU-seconds *per
# pass* of a loop that ran every 3s, i.e. a sustained ~60% of a core doing
# nothing but this, forever (reported 2026-09-06, temperatures 90-100C vs
# the previously-typical 60-70C).
#
# The cache is a soft dependency, not a hard one: load_cache returns
# non-zero (leaving cache_account empty) if the state file is missing,
# unreadable, unparseable, or older than CACHE_MAX_AGE -- resolve_account
# below always still works standalone in that case, just back to one
# pgrep+environ per uncached window, exactly like before this rewrite. A
# window merely absent from the cache (a session newer than the daemon's
# last refresh) falls back the same way, per-window, without affecting any
# other window's fast-path lookup.

CACHE_STATE="$HOME/.cache/claude-usage/state.json"
# SESSIONS_INTERVAL in claude-usage-daemon.py is 30s; 90s gives a 3x margin
# before treating the cache as stale (daemon stalled/killed) rather than
# just due for its next refresh.
CACHE_MAX_AGE=90

declare -A cache_account # "tmux_session:tmux_window" -> account

load_cache() {
    command -v jq >/dev/null 2>&1 || return 1
    [ -r "$CACHE_STATE" ] || return 1

    local updated_at now updated_epoch age
    updated_at=$(jq -r '.updated_at // empty' "$CACHE_STATE" 2>/dev/null)
    [ -n "$updated_at" ] || return 1
    updated_epoch=$(date -d "$updated_at" +%s 2>/dev/null) || return 1
    now=$(date +%s)
    age=$((now - updated_epoch))
    [ "$age" -ge 0 ] && [ "$age" -le "$CACHE_MAX_AGE" ] || return 1

    local key acct
    while IFS=$'\t' read -r key acct; do
        [ -n "$key" ] && cache_account["$key"]="$acct"
    done < <(jq -r '
        .sessions | to_entries[] | .key as $acct | .value[] |
        select(.tmux_session != null and .tmux_window != null) |
        "\(.tmux_session):\(.tmux_window)\t\($acct)"
    ' "$CACHE_STATE" 2>/dev/null)
}

# Slow fallback: only reached for a window the cache doesn't (yet) cover,
# or when it's unavailable entirely -- same per-window cost as before this
# rewrite, just no longer paid for every window on every pass.
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

load_cache

# \x1f (ASCII unit separator), not a tab, joins these fields -- bash's
# `read` treats tab (along with space/newline) as IFS *whitespace* even
# when IFS is set to just that one character, which means runs of
# consecutive empty fields get collapsed and everything after them shifts
# left instead of staying aligned (confirmed live: with @claude_autoname/
# @claude_lastset both empty -- the common case -- session_name/window_id
# below always came out empty). \x1f isn't whitespace, so empty fields
# between two separators stay exactly where they are.
US=$'\x1f'
tmux list-windows -a -F "#{session_name}:#{window_index}${US}#{pane_pid}${US}#{pane_current_command}${US}#{window_name}${US}#{@claude_autoname}${US}#{@claude_lastset}${US}#{session_name}${US}#{window_id}" |
while IFS=$US read -r target pane_pid cur_cmd win_name marker lastset sess_name win_id; do
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
        desired="${cache_account["${sess_name}:${win_id#@}"]}"
        [ -n "$desired" ] || desired=$(resolve_account "$pane_pid")
    elif [ "$marker" = "1" ]; then
        desired="$cur_cmd"
    fi

    if [ -n "$desired" ] && [ "$win_name" != "$desired" ]; then
        tmux rename-window -t "$target" "$desired"
        tmux set-window-option -t "$target" "@claude_autoname" 1
        tmux set-window-option -t "$target" "@claude_lastset" "$desired"
    fi
done
