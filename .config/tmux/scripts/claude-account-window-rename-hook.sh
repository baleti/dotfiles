#!/bin/bash
# Fired by:
#  - a per-window `window-renamed` hook (registered by
#    claude-account-window-hook-setup.sh -- once per window at creation, and
#    once for every already-existing window at tmux server start / `tmux
#    source-file` reload) whenever that window's name changes: tmux's own
#    automatic-rename detecting the pane's foreground command changed, or
#    our own rename-window call below, which also fires this same hook --
#    the checks below are what stop that from recursing further.
#  - a global `pane-focus-in` hook (~/.tmux.conf), passing just the pane
#    that was actually focused -- see the pid-tracking note below for why
#    this second trigger is needed at all.
#
# Resolves which Claude account a `claude` pane is using by reading
# CLAUDE_CONFIG_DIR from its own /proc/<pid>/environ -- the binary is
# invoked exactly one of three ways on this machine:
#   claude --dangerously-skip-permissions            -> claude
#   CLAUDE_CONFIG_DIR=~/.claude2 claude ...           -> claude2
#   CLAUDE_CONFIG_DIR=~/.claude3 claude ...           -> claude3
# authoritative regardless of relative/absolute invocation path --
# pane_current_command already resolves to the bare comm name ("claude")
# either way, so the path used to invoke it never matters.
#
# No polling, no cache, no daemon dependency (2026-09-06 rewrite -- see
# git history ee2ed70..b01c482 for the poll-loop + claude-usage-daemon
# cache design this replaces, and why: that design assumed tmux had no way
# to detect a pane's command changing without polling, which turned out to
# be wrong, confirmed by direct testing -- tmux's own automatic-rename
# already does that detection natively, in well under a second, including
# for detached sessions).
#
# Manual-rename-wins, and why pid tracking (not just command-name
# tracking) is needed for it -- both found by direct testing of earlier
# cuts of this script:
#  - Any rename-window call, including our own, permanently flips that
#    window's automatic-rename off as a side effect, and turning it back
#    on to re-arm detection immediately blanks the name back to the raw
#    command name instead of leaving our custom label alone (re-confirmed
#    on this tmux, 3.7c, before trusting it -- the same landmine the
#    daemon-era script's own comments described). So window-renamed alone
#    only reliably catches a window's *first* claude launch; a second
#    claude launch reusing the same already-labeled window (exit claude,
#    later start a different account's claude in that same pane) produces
#    no further automatic-rename event at all. pane-focus-in is the
#    backstop for that: a direct recheck of just the pane you switched to,
#    triggered only by real focus activity, never a sweep.
#  - A manual rename while claude is STILL the same running process must
#    NOT be immediately fought back to the resolved account name just
#    because cur_cmd == "claude" is still true. But cur_cmd alone can't
#    tell "the same still-running claude, user just renamed it, leave it"
#    apart from "a different claude process now, label it" -- both read as
#    the literal string "claude" either way. @claude_last_pid records the
#    actual resolved claude pid (not just the command name) from the
#    *previous* invocation so that distinction can be made on pid
#    identity instead: a pid change (including none -> some) always
#    (re-)labels, even across a prior override, since that override
#    applied to whatever was running before, not to this new process; the
#    same pid persisting respects a standing override and stays hands-off.

target="$1"

US=$'\x1f'
info=$(tmux display-message -t "$target" -p "#{pane_pid}${US}#{pane_current_command}${US}#{window_name}${US}#{@claude_autoname}${US}#{@claude_lastset}${US}#{@claude_last_pid}")
IFS=$US read -r pane_pid cur_cmd win_name marker lastset prev_pid <<< "$info"

# A manual rename since our last write wins -- stop managing this window
# (until a different claude process appears) same as tmux's own "manual
# rename disables automatic-rename" contract.
if [ "$marker" = "1" ] && [ "$win_name" != "$lastset" ]; then
    tmux set-window-option -t "$target" -u "@claude_autoname"
    tmux set-window-option -t "$target" -u "@claude_lastset"
    marker=""
fi

claude_pid=""
account=""
if [ "$cur_cmd" = "claude" ]; then
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
        */.claude2) account="claude2" ;;
        */.claude3) account="claude3" ;;
        *) account="claude" ;;
    esac
fi

fresh=0
[ -n "$claude_pid" ] && [ "$claude_pid" != "$prev_pid" ] && fresh=1

desired=""
if [ -n "$account" ] && { [ "$marker" = "1" ] || [ "$fresh" = 1 ]; }; then
    desired="$account"
elif [ "$cur_cmd" != "claude" ] && [ "$marker" = "1" ]; then
    desired="$cur_cmd"
fi

if [ -n "$desired" ] && [ "$win_name" != "$desired" ]; then
    tmux rename-window -t "$target" "$desired"
    tmux set-window-option -t "$target" "@claude_autoname" 1
    tmux set-window-option -t "$target" "@claude_lastset" "$desired"
fi

tmux set-window-option -t "$target" "@claude_last_pid" "$claude_pid"
