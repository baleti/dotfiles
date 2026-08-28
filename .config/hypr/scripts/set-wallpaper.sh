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
# Copy to a temp file then rename, not a direct `cp` onto dest -- a plain
# cp isn't atomic, so wallpaper-watch.sh (polling this same path's mtime)
# could catch dest mid-write and hand gen-theme.py a truncated PNG.
# Confirmed happening live (2026-08-28 x8): that crashed gen-theme.py,
# which -- since wallpaper-watch.sh used to run under `set -e` -- killed
# the whole watcher loop, silently freezing theme regeneration on every
# subsequent wallpaper switch. rename() on the same filesystem is atomic,
# so a reader only ever sees the fully-old or fully-new file.
tmp="$dest.tmp"
cp -- "$src" "$tmp"
mv -f -- "$tmp" "$dest"
# Remembers the real source path (dest above is always the same fixed
# filename, a copy) so wallpaper-cycle.sh can find "current" in the
# ~/pictures list for next/prev.
realpath -- "$src" > "$HOME/.local/state/quickshell/wallpaper-source"
# Tells Background.qml to reload right now -- its own FileView watchChanges
# fallback measured a 20-40s real-world delay reacting to this same write,
# vs effectively instant over IPC (same pattern bar-toggle.sh uses).
qs ipc call background reload 2>/dev/null || true
echo "wallpaper set to $src (theme will regenerate within ~2s)"
