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
#
# The lookup itself lives in session-mru-target.sh, shared with
# session-kill-return.sh (prefix+x) so both never drift apart.
set -euo pipefail

client_tty=$1
current_session=$2

if target=$(~/.config/tmux/scripts/session-mru-target.sh "$current_session"); then
  tmux switch-client -c "$client_tty" -t "$target"
else
  status=$?
  if [ "$status" -eq 2 ]; then
    tmux display-message "session-jump: no focus history yet"
  else
    tmux display-message "session-jump: no other session in focus history"
  fi
fi
