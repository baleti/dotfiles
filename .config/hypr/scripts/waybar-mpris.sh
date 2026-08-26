#!/usr/bin/env bash
# waybar custom/mpris module. Long-running loop (no "interval" in
# config.jsonc - waybar's own docs: "If no interval or signal is defined, it
# is assumed that the out script loops itself" - each stdout line is a live
# update). Mirrors whichever player playerctl-picker.sh picked as "current"
# (~/.config/playerctl-current), same as the mod+ctrl+p/x/z keybinds.
#
# Real playerctl/busctl queries (the only things that touch D-Bus, and for
# the phone, the pixel6-mpris-bridge - never the phone's own 4s poll timer,
# which runs unconditionally regardless of how often anything asks it
# locally) only happen every REQUERY_S seconds, or immediately on a
# player/state change. Between those, position is interpolated with pure
# bash arithmetic (awk for the float math) - no subprocess/D-Bus calls at
# all - and redrawn every TICK_S seconds. Ticking backs off to IDLE_POLL_S
# while not Playing, since a paused/stopped position doesn't move.
#
# No "max-length" in config.jsonc: on this waybar build (0.15.0) it hides
# the whole custom module instead of truncating it, even with short text.
# The track portion is truncated in-script instead.
set -uo pipefail

TICK_S=1
REQUERY_S=3
IDLE_POLL_S=2
track_max_len=40
current_file="$HOME/.config/playerctl-current"

fmt_time() {
    local total=$1 h m s
    h=$((total / 3600)); m=$(((total % 3600) / 60)); s=$((total % 60))
    if [ "$h" -gt 0 ]; then printf '%d:%02d:%02d' "$h" "$m" "$s"
    else printf '%d:%02d' "$m" "$s"; fi
}

json_escape() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '%s' "$s"; }

player=""
status=""
app=""
artist=""
title=""
len_sec=0
base_pos=0
base_epoch=0
rate=1

query() {
    status=$(playerctl --player="$player" status 2>/dev/null)
    if [ -z "$status" ]; then
        player=""
        title=""
        return
    fi
    artist=$(playerctl --player="$player" metadata artist 2>/dev/null)
    title=$(playerctl --player="$player" metadata title 2>/dev/null)
    local len_us pos_raw
    len_us=$(playerctl --player="$player" metadata mpris:length 2>/dev/null)
    pos_raw=$(playerctl --player="$player" position 2>/dev/null)

    app=$(busctl --user get-property "org.mpris.MediaPlayer2.$player" \
        /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2 Identity 2>/dev/null)
    app=${app#s }; app=${app#\"}; app=${app%\"}
    [ -z "$app" ] && app="$player"

    rate=$(busctl --user get-property "org.mpris.MediaPlayer2.$player" \
        /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Player Rate 2>/dev/null)
    rate=${rate#d }
    case "$rate" in ''|*[!0-9.]*) rate=1 ;; esac

    len_sec=0
    if [ -n "$len_us" ] && [ "$len_us" -gt 0 ] 2>/dev/null; then
        len_sec=$((len_us / 1000000))
    fi
    base_pos=${pos_raw:-0}
    case "$base_pos" in ''|*[!0-9.]*) base_pos=0 ;; esac
    base_epoch=$EPOCHREALTIME
}

emit() {
    if [ -z "$title" ]; then
        printf '{"text":""}\n'
        return
    fi

    local icon pos_sec
    case "$status" in
        Playing) icon="" ;;
        Paused)  icon="" ;;
        *)       icon="" ;;
    esac

    if [ "$status" = "Playing" ]; then
        pos_sec=$(awk -v b="$base_pos" -v t0="$base_epoch" -v t1="$EPOCHREALTIME" -v r="$rate" \
            'BEGIN { p = b + (t1 - t0) * r; if (p < 0) p = 0; printf "%d", p }')
    else
        pos_sec=$(awk -v b="$base_pos" 'BEGIN { printf "%d", b }')
    fi
    if [ "$len_sec" -gt 0 ] && [ "$pos_sec" -gt "$len_sec" ]; then
        pos_sec=$len_sec
    fi

    local time_str=""
    [ "$len_sec" -gt 0 ] && time_str="$(fmt_time "$pos_sec")/$(fmt_time "$len_sec")"

    local track="$title"
    [ -n "$artist" ] && track="$artist - $title"
    if [ "${#track}" -gt "$track_max_len" ]; then
        track="${track:0:$((track_max_len - 1))}…"
    fi

    local text="$icon $app"
    [ -n "$time_str" ] && text="$text  $time_str"
    text="$text · $track"

    local text_esc
    text_esc=$(json_escape "$text")
    printf '{"text":"%s","tooltip":"%s","class":"%s"}\n' "$text_esc" "$text_esc" "${status,,}"
}

while true; do
    new_player=$(cat "$current_file" 2>/dev/null || true)

    if [ -z "$new_player" ]; then
        player=""
        title=""
        printf '{"text":""}\n'
        sleep "$IDLE_POLL_S"
        continue
    fi

    need_query=0
    [ "$new_player" != "$player" ] && need_query=1
    [ "$status" != "Playing" ] && need_query=1
    if [ "$need_query" -eq 0 ]; then
        stale=$(awk -v t0="$base_epoch" -v t1="$EPOCHREALTIME" -v r="$REQUERY_S" \
            'BEGIN { print (t1 - t0) >= r ? 1 : 0 }')
        [ "$stale" = "1" ] && need_query=1
    fi

    if [ "$need_query" -eq 1 ]; then
        player="$new_player"
        query
    fi

    emit

    if [ "$status" = "Playing" ]; then
        sleep "$TICK_S"
    else
        sleep "$IDLE_POLL_S"
    fi
done
