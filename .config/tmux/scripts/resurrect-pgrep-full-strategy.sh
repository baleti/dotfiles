#!/usr/bin/env bash
# Local addition, not part of the upstream plugin -- see ~/.tmux.conf's
# @resurrect-save-command-strategy comment. Same idea as the shipped
# pgrep.sh (single targeted `pgrep -P <pane_pid>` instead of ps.sh's
# whole-system `ps -ao ppid,args` dump per pane) but with `-af` instead of
# pgrep.sh's `-lf`: `-l` prints PID + process NAME only (args dropped
# entirely), `-a` prints PID + the full command line. pgrep.sh's `-lf`
# silently truncated every `claude --resume <uuid> --dangerously-skip-
# permissions` pane down to bare `claude` in the resurrect layout file --
# harmless for the scrollback archive (capture_pane_contents() never
# calls this strategy at all) but would have relaunched every claude pane
# as a fresh, un-resumed session on restore. Verified byte-identical to
# ps.sh's output across all 179 live panes at the time this was written
# (ps.sh itself had one false-negative on a pid it failed to match; this
# strategy resolved that one correctly too).

PANE_PID="$1"

exit_safely_if_empty_ppid() {
	if [ -z "$PANE_PID" ]; then
		exit 0
	fi
}

full_command() {
	\pgrep -af -P "$PANE_PID" |
		cut -d' ' -f2-
}

main() {
	exit_safely_if_empty_ppid
	full_command
}
main
