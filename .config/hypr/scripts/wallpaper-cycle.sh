#!/usr/bin/env bash
# next: switches to a random image in ~/wallpapers (never the current one,
# which set-wallpaper.sh records as the source). prev: goes back through
# the last 50 images next replaced (random one if there is no history).
#
# ~/wallpapers, not ~/pictures -- see wallpaper-rotate.sh for why.
#
# Usage: wallpaper-cycle.sh next|prev
set -euo pipefail

dir="$HOME/wallpapers"
source_file="$HOME/.local/state/quickshell/wallpaper-source"

case "${1:-}" in
    next|prev) ;;
    *) echo "usage: wallpaper-cycle.sh next|prev" >&2; exit 1 ;;
esac

mapfile -t candidates < <(find "$dir" -maxdepth 1 -type f ! -iname ".*" \
    \( -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.jp2" \) | sort)
if [ "${#candidates[@]}" -eq 0 ]; then
    echo "wallpaper-cycle: no images in $dir" >&2
    exit 1
fi

current=""
[ -f "$source_file" ] && current=$(cat "$source_file")

# next = random image (never the current one); prev = step back through
# the history of what next picked, so the two still feel like a pair.
history_file="$HOME/.local/state/quickshell/wallpaper-history"
n=${#candidates[@]}

if [ "$1" = "next" ]; then
    pick="$current"
    if [ "$n" -gt 1 ]; then
        while [ "$pick" = "$current" ]; do
            pick="${candidates[RANDOM % n]}"
        done
    else
        pick="${candidates[0]}"
    fi
    if [ -n "$current" ]; then
        echo "$current" >> "$history_file"
        tail -n 50 "$history_file" > "$history_file.tmp" && mv "$history_file.tmp" "$history_file"
    fi
else
    pick=""
    while [ -s "$history_file" ] && [ -z "$pick" ]; do
        last=$(tail -n 1 "$history_file")
        sed -i '$d' "$history_file"
        [ -f "$last" ] && pick="$last"
    done
    [ -n "$pick" ] || pick="${candidates[RANDOM % n]}"
fi

~/.config/hypr/scripts/set-wallpaper.sh "$pick"
