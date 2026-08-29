#!/usr/bin/env bash
# media_seek submap (mod+m enters it, digits 0-9 while active): seeks the
# "current" player (~/.config/playerctl-current) to N*10% of the track's
# length - "2" jumps to 20%, "9" to 90%, etc. Absolute seek (bare `playerctl
# position <secs>`, not a +/- relative one), same mechanism confirmed live
# for pixel6's MPRIS SetPosition.
set -uo pipefail

digit="${1:?usage: playerctl-seek-percent.sh 0-9}"

player="$(cat "$HOME/.config/playerctl-current" 2>/dev/null)"
[ -z "$player" ] && exit 0

length_us="$(playerctl --player="$player" metadata mpris:length 2>/dev/null)"
[ -z "$length_us" ] && exit 0

target_s=$(awk -v len="$length_us" -v d="$digit" 'BEGIN { printf "%.3f", (len / 1000000) * d / 10 }')
playerctl --player="$player" position "$target_s" 2>/dev/null
