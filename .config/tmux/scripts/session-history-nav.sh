#!/usr/bin/env bash
# Ctrl+Tab / Ctrl+Shift+Tab: step back/forward through session visit
# history, wrapping at both ends - unlike prefix+Tab (session-jump.sh),
# which always jumps to the single most-recently-visited OTHER session,
# repeated presses here keep walking further through the list instead of
# just toggling between the same two sessions.
#
# The list is a snapshot of live sessions ordered by the same shared MRU
# log prefix+W's focus-picker.py reads (~/.cache/tmux-focus-order.log,
# written by focus-track.sh), deduped from pane-level entries down to one
# slot per session, most-recently-visited first.
#
# That snapshot is taken fresh only the first time this client presses
# either key after actually landing somewhere by other means. A per-client
# state file (keyed by client_tty, like session-jump.sh's own targeting)
# records the snapshot plus which list slot the cursor is on, and is
# reused - cursor just moves - for as long as the client is still sitting
# on exactly the session the last press left it on. Any other kind of
# session switch in between (prefix+Tab, clicking, choose-tree, ...)
# invalidates it, so the next press rebuilds from the client's actual
# current session instead of silently continuing a stale walk.
set -euo pipefail

client_tty=$1
current_session=$2
direction=$3  # prev | next

log=~/.cache/tmux-focus-order.log
state_dir=~/.cache
mkdir -p "$state_dir"
state="$state_dir/tmux-session-nav-$(printf '%s' "$client_tty" | tr -c 'A-Za-z0-9' '_').state"

# pane_id -> session_name for live panes, to translate the pane-level log
# into a session-level order. Same -F $'...\t...' requirement as
# session-jump.sh - tmux's format engine doesn't expand a literal \t.
declare -A pane_session
while IFS=$'\t' read -r pid sess; do
  pane_session[$pid]=$sess
done < <(tmux list-panes -a -F $'#{pane_id}\t#{session_name}')

build_fresh_list() {
  declare -A seen
  local out=()
  if [ -f "$log" ]; then
    while IFS=$'\t' read -r _ pid; do
      sess=${pane_session[$pid]:-}
      [ -z "$sess" ] && continue
      [ -n "${seen[$sess]:-}" ] && continue
      seen[$sess]=1
      out+=("$sess")
    done < "$log"
  fi
  # any live session never hit by the log (brand new) tacked on at the end
  # - same convention focus-picker.py uses for un-logged panes
  while IFS= read -r sess; do
    [ -z "$sess" ] && continue
    [ -n "${seen[$sess]:-}" ] && continue
    seen[$sess]=1
    out+=("$sess")
  done < <(tmux list-sessions -F '#{session_name}')
  printf '%s\n' "${out[@]}"
}

reuse=0
if [ -f "$state" ]; then
  mapfile -t state_lines < "$state"
  recorded_session=${state_lines[0]:-}
  cursor=${state_lines[1]:-0}
  list=("${state_lines[@]:2}")
  if [ "$recorded_session" = "$current_session" ] && [ "${#list[@]}" -gt 0 ]; then
    reuse=1
    for s in "${list[@]}"; do
      tmux has-session -t "=$s" 2>/dev/null || { reuse=0; break; }
    done
  fi
fi

if [ "$reuse" -ne 1 ]; then
  mapfile -t list < <(build_fresh_list)
  cursor=0
  for i in "${!list[@]}"; do
    if [ "${list[$i]}" = "$current_session" ]; then
      cursor=$i
      break
    fi
  done
fi

n=${#list[@]}
if [ "$n" -eq 0 ]; then
  tmux display-message "session-history-nav: no session history yet"
  exit 0
fi
if [ "$n" -eq 1 ]; then
  tmux display-message "session-history-nav: only one session"
  exit 0
fi

if [ "$direction" = "prev" ]; then
  cursor=$(( (cursor + 1) % n ))
else
  cursor=$(( (cursor - 1 + n) % n ))
fi

target=${list[$cursor]}

{
  printf '%s\n' "$target"
  printf '%s\n' "$cursor"
  printf '%s\n' "${list[@]}"
} > "$state"

tmux switch-client -c "$client_tty" -t "$target"
