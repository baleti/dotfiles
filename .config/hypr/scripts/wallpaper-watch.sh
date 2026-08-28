#!/usr/bin/env bash
# Autostarted (see hyprland.lua) alongside sysmond/notifyd. Regenerates the
# Material You theme the moment the wallpaper file actually changes on disk
# -- via set-wallpaper.sh or anything else that writes to this path --
# instead of requiring gen-theme.py to be run by hand after every change.
#
# Polls mtime rather than inotifywait: inotify-tools isn't installed here
# and installing it needs an interactive sudo password this script can't
# provide. A wallpaper changes rarely (human-triggered, not high-frequency),
# so a 2s poll is imperceptible and avoids the new dependency entirely.
#
# Deliberately NOT `set -e`: this is a long-running daemon loop, not a
# one-shot script -- a transient bad read must never take the whole loop
# down. Confirmed happening live (2026-08-28 x8): set-wallpaper.sh's `cp`
# isn't atomic, so this could catch a partially-written PNG mid-copy;
# Image.open() threw, gen-theme.py exited non-zero, and set -e killed this
# entire script right then -- every wallpaper switch after that silently
# stopped re-theming at all (confirmed: the displayed wallpaper kept
# changing correctly via set-wallpaper.sh's own direct IPC trigger, but
# colors were frozen on whatever gen-theme.py last produced before the
# crash, for potentially hours). set-wallpaper.sh now writes atomically too
# (temp file + rename) so this exact race shouldn't recur, but the loop
# survives a bad read either way now.
target="$HOME/.local/state/quickshell/wallpaper.png"
mkdir -p "$(dirname "$target")"

last_mtime=""
while true; do
    if [ -s "$target" ]; then
        mtime=$(stat -c %Y "$target" 2>/dev/null || echo "")
        if [ -n "$mtime" ] && [ "$mtime" != "$last_mtime" ]; then
            last_mtime="$mtime"
            if ! python3 "$HOME/.config/hypr/scripts/gen-theme.py" --image "$target"; then
                echo "wallpaper-watch: gen-theme.py failed for this change, will retry on the next one" >&2
            fi
        fi
    fi
    sleep 2
done
