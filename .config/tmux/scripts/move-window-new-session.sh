#!/bin/sh
# Move the current window into a brand-new session in one step (bound to
# prefix+C-. in .tmux.conf). Refuses if the window is the last one in its
# session - moving it would empty and destroy that session, and with
# detach-on-destroy on (the default) that silently kicks the attached
# client back to a raw shell.
#
# The new session's name is derived from the *source* session's name by
# incrementing its trailing number (or appending " 2" if it has none),
# not tmux's own server-wide auto-naming counter - so it sorts right
# after the source session instead of wherever that counter happens to
# be. If the resulting name collides with a session that already exists,
# it keeps incrementing until it finds one that doesn't.
set -eu

window_id="$1"
session_name="$2"
window_name="$3"
client_tty="$4"
session_windows="$5"

if [ "$session_windows" -eq 1 ]; then
  tmux display-message -d 5000 -c "$client_tty" \
    "refusing to move window $window_id ($window_name): it is the only window in session $session_name - moving it would destroy the session, so nothing happened"
  exit 0
fi

case "$session_name" in
  *[!0-9]*)
    num=$(printf '%s' "$session_name" | sed -n 's/^.*[^0-9]\([0-9][0-9]*\)$/\1/p')
    if [ -n "$num" ]; then
      base=$(printf '%s' "$session_name" | sed 's/[0-9][0-9]*$//')
    else
      base="$session_name "
      num=1
    fi
    ;;
  *)
    base=""
    num="$session_name"
    ;;
esac

newnum=$((num + 1))
candidate="${base}${newnum}"
while tmux has-session -t "$candidate" 2>/dev/null; do
  newnum=$((newnum + 1))
  candidate="${base}${newnum}"
done

tmux new-session -d -s "$candidate"
placeholder=$(tmux display-message -p -t "$candidate" -F '#{window_id}')
tmux move-window -s "$window_id" -t "$candidate:"
tmux kill-window -t "$placeholder"
tmux switch-client -c "$client_tty" -t "$candidate:"
