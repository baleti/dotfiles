#!/bin/sh
# Resume a pane's process previously suspended by freeze-process-cgroup.sh.
#
# Usage: thaw-process-cgroup.sh <pid> <pane_id>
set -eu

pid="$1"
pane_id="$2"

cgroup_line=$(grep '^0::' "/proc/$pid/cgroup") || {
	echo "thaw-process-cgroup: /proc/$pid/cgroup has no cgroup v2 line" >&2
	exit 1
}
relpath="${cgroup_line#0::}"
base=$(basename "$relpath")

if [ "$base" != "tmux-freeze-$pid" ]; then
	echo "thaw-process-cgroup: pid $pid is not in its freeze cgroup" >&2
	exit 1
fi

echo 0 > "/sys/fs/cgroup$relpath/cgroup.freeze"
tmux set-option -p -t "$pane_id" @frozen 0
