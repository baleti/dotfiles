#!/usr/bin/env bash
# Seeks the "current" player (~/.config/playerctl-current) 5s, preserving
# play/pause state across the seek. The pause+play "kick" after seeking is
# from the old KDE net.local.playerctl-2/5.desktop Exec= lines -- kept
# because some player needed it to refresh position after a seek -- but it
# must not unconditionally resume playback when the player was paused
# (reported: seeking while paused on the phone started it playing).
set -uo pipefail

dir="${1:?usage: playerctl-seek.sh +|-}"
player="$(cat "$HOME/.config/playerctl-current" 2>/dev/null)"
[ -z "$player" ] && exit 0

status=$(playerctl --player="$player" status 2>/dev/null)
playerctl --player="$player" position "5$dir" 2>/dev/null
playerctl --player="$player" pause 2>/dev/null
if [ "$status" = "Playing" ]; then
    playerctl --player="$player" play 2>/dev/null
fi
