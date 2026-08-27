#!/usr/bin/env bash
# Sole sanctioned way to change the desktop wallpaper. Copies the given
# image to the fixed path Background.qml displays and wallpaper-watch.sh
# polls, so both the background image and the Material You theme
# (gen-theme.py) pick up the change automatically -- no separate manual
# "now re-run the theme script" step.
#
# Usage: set-wallpaper.sh /path/to/image.{png,jpg,...}
set -euo pipefail

if [ $# -ne 1 ]; then
    echo "usage: set-wallpaper.sh <image path>" >&2
    exit 1
fi

src="$1"
if [ ! -f "$src" ]; then
    echo "set-wallpaper: no such file: $src" >&2
    exit 1
fi

dest="$HOME/.local/state/quickshell/wallpaper.png"
mkdir -p "$(dirname "$dest")"
cp -- "$src" "$dest"
echo "wallpaper set to $src (theme will regenerate within ~2s)"
