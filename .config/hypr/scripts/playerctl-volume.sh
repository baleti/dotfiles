#!/usr/bin/env bash
# mod+F11/F12: volume up/down, then flashes the side OSD
# (~/.config/quickshell/osd/VolumeOsd.qml) via VolumeOsdSvc, a
# process-wide singleton every screen's OSD instance listens to; only the
# one on Hyprland's currently focused monitor actually draws (same
# mouse-follows-focus behaviour as notification cards). Monitor selection
# used to be done here (active window's monitor via hyprctl, deliberately
# avoiding "focused" because of follow_mouse=1), but that was in service of
# a per-screen IPC target that only ever reliably mapped on one output -
# see VolumeOsd.qml's history. Now the OSD picks its own monitor the same
# way notifications do, so this script no longer needs to.
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

qs ipc call volume-osd display "$percent" "$muted"
