#!/usr/bin/env bash
# prefix+x: kill the current session and land on the session actually last
# visited (same shared MRU log as prefix+Tab's session-jump.sh), instead of
# tmux's own `switch-client -n`, which steps to the next session in tmux's
# internal session-list order (roughly creation order) - not visit order,
# hence it looking "random" from the user's seat.
#
# Switch happens BEFORE kill so the client is never left attached to a
# session that's about to disappear.
set -euo pipefail

client_tty=$1
current_session=$2

if target=$(~/.config/tmux/scripts/session-mru-target.sh "$current_session"); then
  tmux switch-client -c "$client_tty" -t "$target"
else
  # no focus history, or no other session in it - fall back to tmux's own
  # next-session order rather than leaving the client stranded.
  tmux switch-client -c "$client_tty" -n
fi

tmux kill-session -t "$current_session"
