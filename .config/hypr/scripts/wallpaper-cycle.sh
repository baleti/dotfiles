#!/usr/bin/env bash
# Steps to the next/previous image in ~/wallpapers (sorted, wrapping),
# based on wherever set-wallpaper.sh last recorded as the source. No
# current record (nothing ever set, or the file's no longer there) just
# starts from the first one.
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

index=-1
for i in "${!candidates[@]}"; do
    if [ "${candidates[$i]}" = "$current" ]; then
        index=$i
        break
    fi
done

n=${#candidates[@]}
if [ "$index" -eq -1 ]; then
    next_index=0
elif [ "$1" = "next" ]; then
    next_index=$(( (index + 1) % n ))
else
    next_index=$(( (index - 1 + n) % n ))
fi

~/.config/hypr/scripts/set-wallpaper.sh "${candidates[$next_index]}"
