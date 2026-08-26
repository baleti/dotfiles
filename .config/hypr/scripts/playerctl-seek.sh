#!/usr/bin/env bash
# Seeks the "current" player (~/.config/playerctl-current) 5s.
#
# No pause+play "kick" here, unlike the old KDE net.local.playerctl-2/5.desktop
# Exec= lines this was restored from. Confirmed unnecessary AND actively
# harmful for the phone (pixel6-mpris-bridge): plain seeking settles back to
# the correct playing/paused state on its own every time (tested 3/3 with
# explicit status polling after seeking-while-playing, no kick). The kick
# instead introduced a real race - its play/pause calls are two more D-Bus
# round trips to the phone, tightly chained, and sometimes the final "play"
# landed before NewPipe's post-seek "buffering" state had settled into
# "paused", so it was silently dropped and playback stayed paused (reported:
# seeking while playing sometimes paused the video). If some other player
# genuinely needs a refresh kick after seeking, that should be handled
# per-player rather than unconditionally for everything.
set -uo pipefail

dir="${1:?usage: playerctl-seek.sh +|-}"
player="$(cat "$HOME/.config/playerctl-current" 2>/dev/null)"
[ -z "$player" ] && exit 0

playerctl --player="$player" position "5$dir" 2>/dev/null
