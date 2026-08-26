#!/usr/bin/env bash
# waybar custom/mpris module. Polled by waybar on "interval" (config.jsonc) --
# NOT a self-looping continuous script: that was tried first (waybar's own
# docs say a script with no interval/signal "loops itself" and each stdout
# line is a live update), and it reliably went stale mid-playback - the
# script's own internal state kept advancing correctly (confirmed via debug
# logging: status/position tracked real changes fine), but waybar stopped
# picking up new lines from it after a while. Whatever the cause, plain
# interval-polling doesn't have that problem, so that's what this uses.
#
# To still avoid a real playerctl/busctl round trip on every poll: real
# values are cached to a state file and only re-fetched every REQUERY_S
# seconds, or immediately if the player changed or isn't Playing (so a
# pause/resume is picked up on the very next poll rather than waiting out
# a stale cache). Between real fetches, position is interpolated with pure
# arithmetic (awk) against the cached base position + timestamp + on-device
# playback rate - no subprocess/D-Bus calls at all for those polls.
#
# No "max-length" in config.jsonc: on this waybar build (0.15.0) it hides
# the whole custom module instead of truncating it, even with short text.
# The track portion is truncated in-script instead.
set -uo pipefail

REQUERY_S=3
track_max_len=40
current_file="$HOME/.config/playerctl-current"
state_file="${XDG_RUNTIME_DIR:-/tmp}/waybar-mpris-state"

fmt_time() {
    local total=$1 h m s
    h=$((total / 3600)); m=$(((total % 3600) / 60)); s=$((total % 60))
    if [ "$h" -gt 0 ]; then printf '%d:%02d:%02d' "$h" "$m" "$s"
    else printf '%d:%02d' "$m" "$s"; fi
}

json_escape() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '%s' "$s"; }

player="$(cat "$current_file" 2>/dev/null || true)"
if [ -z "$player" ]; then
    rm -f "$state_file"
    printf '{"text":""}\n'
    exit 0
fi

now=$EPOCHREALTIME

cached_player="" cached_status="" cached_artist="" cached_title=""
cached_app="" cached_rate=1 cached_len_sec=0 cached_base_pos=0 cached_epoch=0
# shellcheck disable=SC1090
[ -f "$state_file" ] && source "$state_file" 2>/dev/null

stale=1
if [ "$cached_player" = "$player" ] && [ "$cached_status" = "Playing" ]; then
    stale=$(awk -v t0="$cached_epoch" -v t1="$now" -v r="$REQUERY_S" \
        'BEGIN { print (t1 - t0) >= r ? 1 : 0 }')
fi

if [ "$stale" = "1" ]; then
    status=$(playerctl --player="$player" status 2>/dev/null)
    if [ -z "$status" ]; then
        rm -f "$state_file"
        printf '{"text":""}\n'
        exit 0
    fi
    artist=$(playerctl --player="$player" metadata artist 2>/dev/null)
    title=$(playerctl --player="$player" metadata title 2>/dev/null)
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
    base_epoch=$now

    {
        printf 'cached_player=%q\n' "$player"
        printf 'cached_status=%q\n' "$status"
        printf 'cached_artist=%q\n' "$artist"
        printf 'cached_title=%q\n' "$title"
        printf 'cached_app=%q\n' "$app"
        printf 'cached_rate=%s\n' "$rate"
        printf 'cached_len_sec=%s\n' "$len_sec"
        printf 'cached_base_pos=%s\n' "$base_pos"
        printf 'cached_epoch=%s\n' "$base_epoch"
    } > "$state_file"
else
    status="$cached_status"
    artist="$cached_artist"
    title="$cached_title"
    app="$cached_app"
    rate="$cached_rate"
    len_sec="$cached_len_sec"
    base_pos="$cached_base_pos"
    base_epoch="$cached_epoch"
fi

if [ -z "$title" ]; then
    printf '{"text":""}\n'
    exit 0
fi

case "$status" in
    Playing) icon="" ;;
    Paused)  icon="" ;;
    *)       icon="" ;;
esac

if [ "$status" = "Playing" ]; then
    pos_sec=$(awk -v b="$base_pos" -v t0="$base_epoch" -v t1="$now" -v r="$rate" \
        'BEGIN { p = b + (t1 - t0) * r; if (p < 0) p = 0; printf "%d", p + 0.5 }')
else
    pos_sec=$(awk -v b="$base_pos" 'BEGIN { printf "%d", b + 0.5 }')
fi
if [ "$len_sec" -gt 0 ] && [ "$pos_sec" -gt "$len_sec" ]; then
    pos_sec=$len_sec
fi

time_str=""
[ "$len_sec" -gt 0 ] && time_str="$(fmt_time "$pos_sec")/$(fmt_time "$len_sec")"

track="$title"
[ -n "$artist" ] && track="$artist - $title"
if [ "${#track}" -gt "$track_max_len" ]; then
    track="${track:0:$((track_max_len - 1))}…"
fi

text="$icon $app"
[ -n "$time_str" ] && text="$text  $time_str"
text="$text · $track"

text_esc=$(json_escape "$text")
printf '{"text":"%s","tooltip":"%s","class":"%s"}\n' "$text_esc" "$text_esc" "${status,,}"
