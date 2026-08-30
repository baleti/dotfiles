#!/usr/bin/env bash
# Sole sanctioned way to change the desktop wallpaper. Copies the given
# image to the fixed path Background.qml displays and calls gen-theme.py
# directly, so both the background image and the Material You theme
# pick up the change immediately -- no separate manual "now re-run the
# theme script" step, and no polling daemon (wallpaper-watch.sh, retired
# 2026-08-30 -- this script is the only thing that ever wrote this path).
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
# cp isn't atomic, so Background.qml's FileView (reading this same path
# independently) could catch dest mid-write. rename() on the same
# filesystem is atomic, so a reader only ever sees the fully-old or
# fully-new file.
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
# gen-theme.py's own progress prints (one "wrote ..." line per target) are
# noise on the common path now that this runs synchronously in whatever
# shell called set-wallpaper.sh, not silently inside wallpaper-watch.sh's
# background loop like before -- log them instead, only surfaced on failure.
log="$HOME/.local/state/quickshell/gen-theme.log"
if ! python3 "$HOME/.config/hypr/scripts/gen-theme.py" --image "$dest" > "$log" 2>&1; then
    echo "set-wallpaper: gen-theme.py failed, theme not updated for this change (see $log)" >&2
    tail -n 20 "$log" >&2
fi
echo "wallpaper set to $src"
