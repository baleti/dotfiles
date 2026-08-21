#!/usr/bin/env bash
# Shared lookup: prints the name of the most-recently-visited session other
# than the given one, sourced from the same global MRU log focus-track.sh
# writes (see focus-picker.py's header for the five hooks that feed it).
# Used by session-jump.sh (prefix+Tab) and session-kill-return.sh (prefix+x)
# so both "what's my other session" notions never drift apart.
#
# Exit status distinguishes the two empty cases callers may want to report
# differently: 2 = log file doesn't exist yet (no focus history at all),
# 1 = log exists but has no OTHER live session in it. 0 + stdout = found.
set -euo pipefail

current_session=$1
log=~/.cache/tmux-focus-order.log

[ -f "$log" ] || exit 2

# pane_id -> session_name, live panes only - a log entry for a pane/session
# that no longer exists is worthless as a jump target.
#
# -F must get a REAL tab, not the two characters \t: tmux's format engine
# does not expand \t into a tab itself (confirmed directly - a single-quoted
# '...\t...' comes back with literal backslash-t in the output), so this
# has to be bash's own $'...' expansion, not a plain single-quoted string.
declare -A pane_session
while IFS=$'\t' read -r pid sess; do
  pane_session[$pid]=$sess
done < <(tmux list-panes -a -F $'#{pane_id}\t#{session_name}')

declare -A seen
while IFS=$'\t' read -r _ pid; do
  sess=${pane_session[$pid]:-}
  [ -z "$sess" ] && continue
  [ "$sess" = "$current_session" ] && continue
  [ -n "${seen[$sess]:-}" ] && continue
  seen[$sess]=1
  echo "$sess"
  exit 0
done < "$log"

exit 1
