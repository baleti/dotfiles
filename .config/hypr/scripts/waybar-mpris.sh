#!/usr/bin/env bash
# waybar custom/mpris module. Mirrors whichever player playerctl-picker.sh
# picked as "current" (~/.config/playerctl-current) -- same target as the
# mod+ctrl+p/x/z keybinds, so the bar shows/controls the same player.
# Polled by waybar on an interval (see config.jsonc); empty output hides the pill.
#
# Layout: <state icon> <app>  <position>/<length> \xc2\xb7 <artist - title>
# App name comes from MPRIS Identity (org.mpris.MediaPlayer2, via busctl since
# playerctl only exposes Player-interface metadata) -- works for any player,
# not just the phone bridge. pixel6-mpris-bridge.py reports a real per-app
# Identity (e.g. "NewPipe") derived from the Android package name, not just
# the bus name "pixel6".
#
# No "max-length" here: on this waybar build (0.15.0) it hides the whole
# custom module instead of truncating it, even with short text. The track
# portion is truncated in-script instead.
set -uo pipefail

track_max_len=40

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

app=$(busctl --user get-property "org.mpris.MediaPlayer2.$player" \
    /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2 Identity 2>/dev/null)
app=${app#s }
app=${app#\"}
app=${app%\"}
[ -z "$app" ] && app="$player"

fmt_time() {
    local total=$1 h m s
    h=$((total / 3600)); m=$(((total % 3600) / 60)); s=$((total % 60))
    if [ "$h" -gt 0 ]; then printf '%d:%02d:%02d' "$h" "$m" "$s"
    else printf '%d:%02d' "$m" "$s"; fi
}

time_str=""
pos_raw=$(playerctl --player="$player" position 2>/dev/null)
len_us=$(playerctl --player="$player" metadata mpris:length 2>/dev/null)
if [ -n "$pos_raw" ] && [ -n "$len_us" ] && [ "$len_us" -gt 0 ] 2>/dev/null; then
    pos_sec=$(printf '%.0f' "$pos_raw")
    len_sec=$((len_us / 1000000))
    time_str="$(fmt_time "$pos_sec")/$(fmt_time "$len_sec")"
fi

track="$title"
[ -n "$artist" ] && track="$artist - $title"
if [ "${#track}" -gt "$track_max_len" ]; then
    track="${track:0:$((track_max_len - 1))}…"
fi

text="$icon $app"
[ -n "$time_str" ] && text="$text  $time_str"
text="$text · $track"

json_escape() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '%s' "$s"; }
text_esc=$(json_escape "$text")

printf '{"text":"%s","tooltip":"%s","class":"%s"}\n' "$text_esc" "$text_esc" "${status,,}"
