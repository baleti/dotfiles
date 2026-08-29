#!/usr/bin/env bash
# mod+F11/F12: volume up/down, then flashes the side OSD
# (~/.config/quickshell/osd/VolumeOsd.qml) on whichever monitor the active
# window is on (each monitor runs its own instance, IpcHandler target
# "volume-osd-<screen name>").
#
# Deliberately the active *window's* monitor, not hyprctl monitors' own
# "focused" field like bar-toggle.sh uses: this Hyprland has follow_mouse=1
# (see ydotool_focus_follows_mouse_risk memory), so "focused" tracks
# whichever monitor the cursor is currently hovering, which can differ from
# where the active/keyboard-focused window actually is - showing the OSD on
# the wrong screen if the mouse happened to have drifted elsewhere.
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

mon=$(python3 -c "
import json, subprocess
aw = json.loads(subprocess.check_output(['hyprctl', '-j', 'activewindow']) or b'{}')
mons = json.loads(subprocess.check_output(['hyprctl', '-j', 'monitors']))
mid = aw.get('monitor')
name = next((m['name'] for m in mons if m.get('id') == mid), '')
if not name:
    # No active window (empty workspace) - fall back to hyprctl's own
    # notion of the focused monitor, same as bar-toggle.sh.
    name = next((m['name'] for m in mons if m.get('focused')), '')
print(name)
")
[ -n "$mon" ] || exit 0
qs ipc call "volume-osd-$mon" display "$percent" "$muted"
