#!/bin/bash
# Fired by a per-window `window-renamed` hook (registered by
# claude-account-window-hook-setup.sh) whenever a window's name changes:
# either tmux's own automatic-rename noticing the pane's foreground
# command became "claude", or our own rename-window call a few lines
# down, which fires this same hook too -- the "already correct" check at
# the bottom is what stops that from looping any further than one harmless
# extra self-check.
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
# ---------------------------------------------------------------------
# Known, accepted limitation, deliberately NOT patched over with a poll
# (2026-09-06, confirmed against tmux(1) 3.7c itself -- the actual
# installed version, man page regenerated fresh and diffed against a
# cached copy to rule out stale docs -- not just empirical testing):
#
# Once THIS hook renames a window, tmux permanently disables that
# window's automatic-rename as a side effect of the rename-window call --
# straight from the manual: "This flag is automatically disabled for an
# individual window when a name is specified... later with
# rename-window." rename-window is the only command in the entire
# manual that can set a window's real name, so there's no alternative
# way to label it that doesn't also disable tracking.
#
# The one path that DOESN'T call rename-window -- automatic-rename-format's
# #() shell-out -- doesn't get around this either, for a separate,
# equally documented reason: "tmux does not wait for #() commands to
# finish; instead, the previous result from running the same command is
# used, or a placeholder if the command has not been run before." That's
# an inherently async, cached-by-exact-command-string job model,
# structurally unable to synchronously reflect which account a pane just
# switched to, no matter how fast the underlying script is -- retested
# directly against this exact resolve logic and it reproduced exactly
# that: permanently one step behind, never catching up.
#
# Net effect: once a window has been labeled by this hook, tmux stops
# noticing any further command change in it on its own -- exiting claude
# and running something else, or launching a different account's claude
# in that same window, won't rename it again. There is no tmux hook or
# event left to react to for that; the only way to close the gap would
# be a background poll checking pane_current_command on a schedule,
# which is exactly the CPU/heat problem this whole redesign (see git
# history around commit b01c482 and the daemon-era design before it)
# was to get rid of.
#
# Decided (2026-09-06) to accept the gap outright instead: this label is
# purely cosmetic (which account a pane WAS running, at a glance in the
# status line and in tools like winswitch that key off window_name) --
# nothing here depends on it staying live-accurate for the rest of that
# window's life. A window's account label going stale after its first
# claude session is a fair trade against reintroducing any kind of
# polling, however narrow. No daemon, no cache, no loop -- purely this
# one event hook, reacting only to a window's first claude launch.
# ---------------------------------------------------------------------

target="$1"

cur_cmd=$(tmux display-message -t "$target" -p '#{pane_current_command}')

marker=$(tmux display-message -t "$target" -p '#{@claude_autoname}')
lastset=$(tmux display-message -t "$target" -p '#{@claude_lastset}')
win_name=$(tmux display-message -t "$target" -p '#{window_name}')

# A manual rename since our last write wins -- stop managing this window
# for good (there's no later re-arming here, per the note above: we're
# not trying to catch a second claude launch reusing the same window
# anyway). Same "manual rename disables automatic-rename" contract tmux's
# own engine has, applied to our own tracking.
if [ "$marker" = "1" ] && [ "$win_name" != "$lastset" ]; then
    tmux set-window-option -t "$target" -u "@claude_autoname"
    tmux set-window-option -t "$target" -u "@claude_lastset"
    exit 0
fi

[ "$cur_cmd" = "claude" ] || exit 0

pane_pid=$(tmux display-message -t "$target" -p '#{pane_pid}')

# Direct child of the pane's own process, not a recursive descendant
# search: a claude process spawning further "claude"-comm children
# (subagents) would otherwise be mistaken for the top-level session this
# pane is actually running.
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

if [ "$win_name" != "$desired" ]; then
    tmux rename-window -t "$target" "$desired"
    tmux set-window-option -t "$target" "@claude_autoname" 1
    tmux set-window-option -t "$target" "@claude_lastset" "$desired"
fi
