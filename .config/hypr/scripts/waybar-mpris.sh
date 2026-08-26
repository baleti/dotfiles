#!/usr/bin/env bash
# waybar custom/mpris module. Mirrors whichever player playerctl-picker.sh
# picked as "current" (~/.config/playerctl-current) -- same target as the
# mod+ctrl+p/x/z keybinds, so the bar shows/controls the same player.
# Polled by waybar on an interval (see config.jsonc); empty output hides the pill.
#
# Truncates itself rather than using waybar's "max-length": on this waybar
# build (0.15.0) that option hides the whole custom module -- even with
# short text -- instead of truncating it. Confirmed by bisecting a static
# echo exec down to the bare option with no other change.
set -uo pipefail

max_len=50

current_file="$HOME/.config/playerctl-current"
player=$(cat "$current_file" 2>/dev/null || true)
[ -z "$player" ] && { echo '{"text":""}'; exit 0; }

status=$(playerctl --player="$player" status 2>/dev/null) || { echo '{"text":""}'; exit 0; }

artist=$(playerctl --player="$player" metadata artist 2>/dev/null)
title=$(playerctl --player="$player" metadata title 2>/dev/null)
[ -z "$title" ] && { echo '{"text":""}'; exit 0; }

case "$status" in
    Playing) icon="" ;;
    Paused)  icon="" ;;
    *)       icon="" ;;
esac

text="$title"
[ -n "$artist" ] && text="$artist - $title"
if [ "${#text}" -gt "$max_len" ]; then
    text="${text:0:$((max_len - 1))}…"
fi
text="$icon $text"

json_escape() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '%s' "$s"; }
text_esc=$(json_escape "$text")

printf '{"text":"%s","tooltip":"%s","class":"%s"}\n' "$text_esc" "$text_esc" "${status,,}"
