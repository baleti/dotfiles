#!/usr/bin/env bash
# Background/foreground a Claude Code session via standard shell job
# control (Ctrl+Z / `fg`), not a raw external SIGSTOP - so it behaves
# exactly like any other suspended shell job, shows up in the pane's own
# `jobs`, and resumes with a plain `fg`. Verified live: CPU time is
# provably frozen while stopped (checked across a 5s window via `ps
# time`), and a stopped session's memory/context/MCP connections stay
# fully intact - `fg` brings it back with zero loss. Once stopped,
# claude-usage-daemon.py's own /proc/<pid>/stat read (not the CLI's own
# self-reported status, which a stopped process can't update) surfaces
# it as "stopped" in the CTRL+ALT+C usage panel automatically.
#
# Usage:
#   claude-bg.sh stop   <tmux-target>   # e.g. 800  or  800:0  or  800:0.0
#   claude-bg.sh resume <tmux-target>
#   claude-bg.sh status <tmux-target>
set -euo pipefail

cmd="${1:?usage: claude-bg.sh stop|resume|status TMUX_TARGET}"
target="${2:?usage: claude-bg.sh stop|resume|status TMUX_TARGET}"

pane_pid="$(tmux display-message -p -t "$target" '#{pane_pid}')"
claude_pid="$(pgrep -P "$pane_pid" -x claude || true)"

case "$cmd" in
	stop)
		if [ -z "$claude_pid" ]; then
			echo "no claude process in $target (not running, or already something else)" >&2
			exit 1
		fi
		tmux send-keys -t "$target" C-z
		echo "sent Ctrl+Z to $target (claude pid $claude_pid)"
		;;
	resume)
		tmux send-keys -t "$target" fg Enter
		echo "sent fg to $target"
		;;
	status)
		if [ -z "$claude_pid" ]; then
			echo "no claude process in $target"
			exit 0
		fi
		state="$(awk -F')' '{print $2}' "/proc/$claude_pid/stat" 2>/dev/null | awk '{print $1}')"
		case "$state" in
			T) echo "$target: stopped (pid $claude_pid)" ;;
			""|Z) echo "$target: not running (pid $claude_pid gone or zombie)" ;;
			*) echo "$target: running (pid $claude_pid, state $state)" ;;
		esac
		;;
	*)
		echo "unknown command: $cmd (expected stop|resume|status)" >&2
		exit 1
		;;
esac
