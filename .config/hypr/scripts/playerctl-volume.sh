#!/usr/bin/env bash
# mod+F11/F12: volume up/down, then flashes the side OSD
# (~/.config/quickshell/osd/VolumeOsd.qml) on whichever monitor is currently
# focused (same resolution as bar-toggle.sh -- each monitor runs its own
# instance, IpcHandler target "volume-osd-<screen name>").
#
# Routes to the "current" player's MPRIS Volume property
# (~/.config/playerctl-current) when it's pixel6 - the one MPRIS player here
# that isn't already local pipewire output, since its Volume proxies to the
# phone's own STREAM_MUSIC (see pixel6-mpris-bridge.py's _set_volume() and
# Set()). Every other case adjusts the local sink directly, same as before
# this script existed.
set -uo pipefail

dir="${1:?usage: playerctl-volume.sh +|-}"
muted=false

if [ "$(cat "$HOME/.config/playerctl-current" 2>/dev/null)" = "pixel6" ]; then
    if ! playerctl --player=pixel6 volume "0.05$dir" 2>/dev/null; then
        exit 0
    fi
    frac="$(playerctl --player=pixel6 volume 2>/dev/null)"
else
    if [ "$dir" = "+" ]; then
        wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ 5%+
    else
        wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
    fi
    out="$(wpctl get-volume @DEFAULT_AUDIO_SINK@)"
    frac="$(printf '%s' "$out" | awk '{print $2}')"
    case "$out" in *MUTED*) muted=true ;; esac
fi

[ -z "${frac:-}" ] && exit 0
percent=$(awk -v f="$frac" 'BEGIN { printf "%d", f * 100 + 0.5 }')

mon=$(hyprctl -j monitors | python3 -c "import json,sys; d=json.load(sys.stdin); print(next((m['name'] for m in d if m.get('focused')), ''))")
[ -n "$mon" ] || exit 0
qs ipc call "volume-osd-$mon" display "$percent" "$muted"
