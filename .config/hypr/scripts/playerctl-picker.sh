#!/usr/bin/env bash
# Player picker for ALT+CTRL+SHIFT+m. Never touches ~/.config/playerctl-current
# on Escape/Cancel (zenity exits non-zero, or prints nothing) -- the old
# `zenity ... > playerctl-current` one-liner unconditionally redirected
# stdout, so cancelling truncated the file to empty.
#
# Uses plain --list, not --radiolist: a radiolist's Enter key only toggles
# the checkbox, it doesn't submit the dialog, so accepting still needed a
# separate OK click. Plain --list submits immediately on Enter, same as
# before, and to still "preselect" the current player we put it first in the
# list -- zenity always starts the list widget highlighted on row one, and
# there's no other flag to preselect a specific row in this mode.
set -uo pipefail

current_file="$HOME/.config/playerctl-current"
current=$(cat "$current_file" 2>/dev/null || true)

mapfile -t players < <(playerctl --list-all 2>/dev/null)
[ "${#players[@]}" -eq 0 ] && exit 0

ordered=()
rest=()
for p in "${players[@]}"; do
    if [ "$p" = "$current" ]; then
        ordered+=("$p")
    else
        rest+=("$p")
    fi
done
ordered+=("${rest[@]}")

selected=$(zenity --list --title="Choose player" --text="Choose player" --column="" "${ordered[@]}")
rc=$?

if [ "$rc" -eq 0 ] && [ -n "$selected" ]; then
    printf '%s' "$selected" > "$current_file"
fi
