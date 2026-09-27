#!/bin/sh
# Suspend a tmux pane's process using the Linux cgroup v2 freezer instead of
# a job-control signal - SIGSTOP/SIGTSTP is reversed almost instantly, both
# by the pane's own shell (job-control reclaims the terminal) and by tmux
# itself (server_child_stopped() in server.c unconditionally SIGCONTs any
# stopped pane process). Freezing a cgroup never delivers a signal or
# produces a wait()-visible state change, so neither reflex ever fires.
#
# Usage: freeze-process-cgroup.sh <pid> <pane_id>
set -eu

pid="$1"
pane_id="$2"

cgroup_line=$(grep '^0::' "/proc/$pid/cgroup") || {
	echo "freeze-process-cgroup: /proc/$pid/cgroup has no cgroup v2 line" >&2
	exit 1
}
relpath="${cgroup_line#0::}"
base=$(basename "$relpath")

if [ "$base" = "tmux-freeze-$pid" ]; then
	dir="/sys/fs/cgroup$relpath"
else
	dir="/sys/fs/cgroup$relpath/tmux-freeze-$pid"
	mkdir -p "$dir"
	echo "$pid" > "$dir/cgroup.procs"
fi

echo 1 > "$dir/cgroup.freeze"
tmux set-option -p -t "$pane_id" @frozen 1
