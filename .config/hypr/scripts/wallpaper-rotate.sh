#!/usr/bin/env bash
# Picks a random image from ~/wallpapers every 15 minutes and hands it to
# set-wallpaper.sh -- which is what actually updates the displayed
# background AND (via wallpaper-watch.sh polling the same fixed path)
# triggers the Material You re-theme, so nothing extra is needed here for
# colors to follow along automatically. 15 minutes is a "for now" testing
# cadence (2026-08-28), not a considered final value.
#
# ~/wallpapers, not ~/pictures (switched 2026-08-28 x7): pictures were
# whatever renders/photos happened to be lying around, with no guarantee
# of a clear, intentional palette -- ~/wallpapers is deliberately
# color-graded images with one clear primary + 1-2 accent colors, so
# gen-theme.py's extraction has real designed-in contrast to work with
# instead of guessing at hue rotations from a muted source photo.
set -uo pipefail

INTERVAL_SECS=900

while true; do
    mapfile -t candidates < <(find ~/wallpapers -maxdepth 1 -type f ! -iname ".*" \
        \( -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.jp2" \) 2>/dev/null)
    if [ "${#candidates[@]}" -gt 0 ]; then
        pick="${candidates[RANDOM % ${#candidates[@]}]}"
        ~/.config/hypr/scripts/set-wallpaper.sh "$pick"
    fi
    sleep "$INTERVAL_SECS"
done
