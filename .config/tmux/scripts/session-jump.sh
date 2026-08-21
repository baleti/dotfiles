#!/usr/bin/env bash
# prefix+Tab: jump to the session most recently visited by ANY client, other
# than this client's own current session - the session-level analog of
# switch-client -l, but sourced from the same global MRU log focus-track.sh
# already writes (see focus-picker.py's header for the five hooks that feed
# it) instead of tmux's own single-slot per-client "last session" pointer.
# That pointer only gets set once a given client has switched sessions at
# least once since attaching - empty until then, which is what produces
# tmux's native "can't find last session" error on a fresh client. The
# shared log has no such per-client blind spot: it already has entries from
# whichever session (any client) was actually visited most recently.
set -euo pipefail

client_tty=$1
current_session=$2
log=~/.cache/tmux-focus-order.log

if [ ! -f "$log" ]; then
  tmux display-message "session-jump: no focus history yet"
  exit 0
fi

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

target=""
declare -A seen
while IFS=$'\t' read -r _ pid; do
  sess=${pane_session[$pid]:-}
  [ -z "$sess" ] && continue
  [ "$sess" = "$current_session" ] && continue
  [ -n "${seen[$sess]:-}" ] && continue
  seen[$sess]=1
  target=$sess
  break
done < "$log"

if [ -z "$target" ]; then
  tmux display-message "session-jump: no other session in focus history"
  exit 0
fi

tmux switch-client -c "$client_tty" -t "$target"
