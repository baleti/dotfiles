#!/bin/bash
# Fired two ways:
#  - a per-window `window-renamed` hook (registered by
#    claude-account-window-hook-setup.sh) whenever a window's name
#    changes: tmux's own automatic-rename noticing the pane's foreground
#    command became "claude" for the first time in that window, or our
#    own rename-window call further down, which fires this same hook too
#    -- the "already correct" check at the bottom is what stops that from
#    looping any further than one harmless extra self-check.
#  - claude-account-command-watch.sh, a narrow background loop (see its
#    own header comment) that notices a command change in the currently
#    focused, attached pane and calls this script directly with that
#    pane's target -- needed because of the automatic-rename limitation
#    below.
#
# Renames a window to whichever Claude Code account (claude/claude2/
# claude3) its "claude" pane is running, by reading CLAUDE_CONFIG_DIR
# straight from that process's own /proc/<pid>/environ -- the binary is
# invoked exactly one of three ways on this machine:
#   claude --dangerously-skip-permissions            -> claude
#   CLAUDE_CONFIG_DIR=~/.claude2 claude ...           -> claude2
#   CLAUDE_CONFIG_DIR=~/.claude3 claude ...           -> claude3
# authoritative regardless of relative/absolute invocation path --
# pane_current_command already resolves to the bare comm name ("claude")
# either way, so the path used to invoke it never matters.
#
# Once a window has run claude at least once, this script ALSO takes over
# plain automatic-rename duty for it (2026-09-06: "may as well pick up
# from tmux and rename window to whatever tmux report current pane's
# current command is") -- tracking whatever cur_cmd tmux itself reports
# for any later, non-claude command too, exactly like vanilla
# automatic-rename would, not just claude<->claude account switches. See
# the limitation this is working around below for why that hand-off has
# to happen at all, and claude-account-command-watch.sh's own header
# comment for how tmux exposes pane_current_command in the first place
# (a cheap ioctl(fd, TIOCGPGRP) poll on the pty master it already holds,
# confirmed directly via strace 2026-09-06 -- not a kernel push
# notification, which is exactly why there's no hook to just subscribe
# to instead of checking ourselves).
#
# ---------------------------------------------------------------------
# Known, accepted limitation (2026-09-06, confirmed against tmux(1) 3.7c
# itself -- the actual installed version, man page regenerated fresh and
# diffed against a cached copy to rule out stale docs -- not just
# empirical testing):
#
# The FIRST time this script (or anyone) renames a window, tmux
# permanently disables that window's own automatic-rename as a side
# effect of the rename-window call -- straight from the manual: "This
# flag is automatically disabled for an individual window when a name is
# specified... later with rename-window." rename-window is the only
# command in the entire manual that can set a window's real name, so
# there's no alternative way to label it that doesn't also disable
# tracking.
#
# The one path that DOESN'T call rename-window -- automatic-rename-format's
# #() shell-out -- doesn't get around this either, for a separate,
# equally documented reason: "tmux does not wait for #() commands to
# finish; instead, the previous result from running the same command is
# used, or a placeholder if the command has not been run before." That's
# an inherently async, cached-by-exact-command-string job model,
# structurally unable to synchronously reflect the current command,
# regardless of how fast the underlying script is -- retested directly
# against this exact resolve logic and it reproduced exactly that:
# permanently one step behind, never catching up.
#
# Net effect: once this script labels a window, tmux's own engine goes
# fully silent on it -- no window-renamed will ever fire for it again on
# tmux's own initiative, for ANY command change, claude-related or not.
# claude-account-command-watch.sh's poll (scoped to just the currently
# focused, attached pane -- see its own comment) is what re-invokes this
# script when that happens instead, which is why the branch below tracks
# the plain command name too, not just "claude" -- once we've taken over
# a window, we're now the only thing keeping its name current at all.
# ---------------------------------------------------------------------

target="$1"

cur_cmd=$(tmux display-message -t "$target" -p '#{pane_current_command}')

marker=$(tmux display-message -t "$target" -p '#{@claude_autoname}')
lastset=$(tmux display-message -t "$target" -p '#{@claude_lastset}')
win_name=$(tmux display-message -t "$target" -p '#{window_name}')

# A manual rename since our last write wins -- stop managing this window
# and don't act any further THIS invocation (found by direct testing:
# falling through here instead of exiting re-triggers the "cur_cmd =
# claude" branch below for the still-unchanged, still-running claude
# process that was already labeled, immediately fighting the rename that
# was just made). A genuinely later claude launch -- a different pid,
# firing its own separate window-renamed/watcher invocation once cur_cmd
# actually transitions away from and back to "claude" -- re-claims the
# window unconditionally in that later, separate call, regardless of
# marker. Same "manual rename disables automatic-rename" contract tmux's
# own engine has, applied to our own tracking.
if [ "$marker" = "1" ] && [ "$win_name" != "$lastset" ]; then
    tmux set-window-option -t "$target" -u "@claude_autoname"
    tmux set-window-option -t "$target" -u "@claude_lastset"
    exit 0
fi

if [ "$cur_cmd" = "claude" ]; then
    pane_pid=$(tmux display-message -t "$target" -p '#{pane_pid}')
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
        */.claude2) desired="claude2" ;;
        */.claude3) desired="claude3" ;;
        *) desired="claude" ;;
    esac
elif [ "$marker" = "1" ]; then
    # Already ours to manage (and not a fresh manual override, per above)
    # -- keep tracking the plain command name, same as tmux's own
    # automatic-rename would if it were still switched on for this window.
    desired="$cur_cmd"
else
    # Never claimed this window, and it's not running claude right now --
    # leave it alone. Vanilla automatic-rename is still active for it
    # (we've never called rename-window on it), so tmux is already
    # tracking it for free; nothing for this script to do.
    exit 0
fi

if [ "$win_name" != "$desired" ]; then
    tmux rename-window -t "$target" "$desired"
    tmux set-window-option -t "$target" "@claude_autoname" 1
    tmux set-window-option -t "$target" "@claude_lastset" "$desired"
fi
