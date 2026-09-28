#!/bin/sh
# Toggle-suspend a tmux pane's process using the Linux cgroup v2 freezer,
# instead of a job-control signal - SIGSTOP/SIGTSTP is reversed almost
# instantly, both by the pane's own shell (job-control reclaims the
# terminal) and by tmux itself (server_child_stopped() in server.c
# unconditionally SIGCONTs any stopped pane process). Freezing a cgroup
# never delivers a signal or produces a wait()-visible state change, so
# neither reflex ever fires.
#
# Usage: freeze-process-cgroup-toggle.sh <pane_pid> <pane_id>
set -eu

pane_pid="$1"
pane_id="$2"

# #{pane_pid} is the pane's own top-level process, which in the common case
# (a program typed into an ordinary interactive shell) is the shell, not
# whatever's actually running - freezing the shell alone does nothing,
# since the real foreground program is a separate process that simply
# keeps running unaffected (confirmed live for both claude and htop).
#
# The generic, program-agnostic fix: read the pty's current foreground
# process group (tpgid, /proc/<pid>/stat field 8 - using the same
# skip-past-comm approach as this daemon's _read_proc_state/_is_cgroup_
# frozen, since the comm field can itself contain spaces or parens) rather
# than searching for a specific program by name. In ordinary job control, a
# job's pgid equals the pid of its leading process, so tpgid IS that
# process's own pid directly - this is exactly what tcgetpgrp() would
# report, i.e. "whichever program the shell has currently ceded the
# terminal to", with no knowledge of what that program is. Falls back to
# pane_pid itself if this can't be read (e.g. pid raced and already
# exited), which for an idle shell prompt is the correct target anyway -
# the shell itself is what's in the foreground when nothing else is
# running. Does not handle a multi-process pipeline job whose leading
# process has since exited (rare for an interactive foreground program).
rest=$(awk -F')' '{print $NF}' "/proc/$pane_pid/stat" 2>/dev/null) || rest=""
tpgid=$(echo "$rest" | awk '{print $6}')
if [ -n "$tpgid" ] && [ -d "/proc/$tpgid" ]; then
	pid="$tpgid"
else
	pid="$pane_pid"
fi

cgroup_line=$(grep '^0::' "/proc/$pid/cgroup") || {
	echo "freeze-process-cgroup-toggle: /proc/$pid/cgroup has no cgroup v2 line" >&2
	exit 1
}
relpath="${cgroup_line#0::}"
base=$(basename "$relpath")

if [ "$base" = "tmux-freeze-$pid" ]; then
	dir="/sys/fs/cgroup$relpath"
	current=$(cat "$dir/cgroup.freeze" 2>/dev/null || echo 0)
else
	dir="/sys/fs/cgroup$relpath/tmux-freeze-$pid"
	current=0
fi

# claude-usage-daemon.py otherwise only learns about this on its next
# regular 30s poll: freezing/thawing touches cgroupfs and a tmux pane
# option, neither of which it watches (a tmux pane option isn't backed by
# any file at all - it lives in the server's own memory). It does already
# inotify-watch each account's sessions/ dir for IN_CLOSE_WRITE, to react
# promptly when the CLI itself rewrites its own sessions/<pid>.json - so
# rather than teaching it to separately watch cgroup.freeze (verified live
# that cgroup pseudo-files do support real inotify, e.g. writing
# cgroup.freeze fires IN_MODIFY - but every freeze cgroup lives at a
# different, dynamically-created path, so watching them all would mean
# adding/removing a watch per freeze/thaw), nudge_claude_usage_panel below
# gives the daemon a reason to recompute right now through the exact
# mechanism it already has: open the target's own sessions/<pid>.json for
# write and close it without changing a single byte - confirmed live that
# this alone fires IN_CLOSE_WRITE, same as if the CLI had rewritten it.
# Bounded by the daemon's existing SESSIONS_MIN_GAP (3s) floor, not
# instant, but far better than up to 30s - and every other status
# transition already goes through the same floor, so this isn't a new
# risk. Silently does nothing for a pid with no session file at all (e.g.
# freezing htop or less). Called after the state change actually lands,
# not before, so the daemon's recompute never races a still-mid-transition
# cgroup.
nudge_claude_usage_panel() {
	for d in "$HOME/.claude" "$HOME/.claude2" "$HOME/.claude3"; do
		f="$d/sessions/$pid.json"
		[ -f "$f" ] && python3 -c "open('$f', 'r+').close()" 2>/dev/null
	done
}

if [ "$current" = "1" ]; then
	# Keystrokes typed while frozen don't vanish - they queue up in the
	# pty's own kernel input buffer (nobody's reading them, since the
	# process isn't scheduled at all) and get delivered all at once,
	# instantly, the moment it resumes reading - confirmed live, including
	# a stray Ctrl-C landing and firing right on thaw. Flush that queue
	# (tcflush/TCIFLUSH - discards received-but-unread input) right before
	# unfreezing, so it resumes into a clean prompt instead.
	pane_tty=$(tmux display-message -p -t "$pane_id" "#{pane_tty}")
	python3 -c "
import sys, os, termios
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NONBLOCK | os.O_NOCTTY)
termios.tcflush(fd, termios.TCIFLUSH)
os.close(fd)
" "$pane_tty"
	echo 0 > "$dir/cgroup.freeze"
	tmux set-option -p -t "$pane_id" @frozen 0
	nudge_claude_usage_panel
else
	if [ "$base" != "tmux-freeze-$pid" ]; then
		mkdir -p "$dir"
		echo "$pid" > "$dir/cgroup.procs"
	fi
	echo 1 > "$dir/cgroup.freeze"
	tmux set-option -p -t "$pane_id" @frozen 1
	nudge_claude_usage_panel
fi
