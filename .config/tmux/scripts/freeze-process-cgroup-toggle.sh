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
# (claude typed into an ordinary interactive shell) is the shell, not
# claude - freezing the shell alone does nothing, since claude is a
# separate process in its own right and simply keeps running unaffected.
# Walk the process tree (BFS, via /proc/<pid>/task/<pid>/children) for the
# nearest descendant actually named "claude" and target that instead; if
# none is found (this pane isn't running claude), fall back to pane_pid
# itself so the toggle still works for any other long-running foreground
# process.
find_claude_pid() {
	level="$1"
	while [ -n "$level" ]; do
		next=""
		for p in $level; do
			if [ "$(cat "/proc/$p/comm" 2>/dev/null)" = "claude" ]; then
				echo "$p"
				return 0
			fi
			next="$next $(cat "/proc/$p/task/$p/children" 2>/dev/null)"
		done
		level="$next"
	done
	return 1
}
pid=$(find_claude_pid "$pane_pid") || pid="$pane_pid"

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

if [ "$current" = "1" ]; then
	echo 0 > "$dir/cgroup.freeze"
	tmux set-option -p -t "$pane_id" @frozen 0
else
	if [ "$base" != "tmux-freeze-$pid" ]; then
		mkdir -p "$dir"
		echo "$pid" > "$dir/cgroup.procs"
	fi
	echo 1 > "$dir/cgroup.freeze"
	tmux set-option -p -t "$pane_id" @frozen 1
fi
