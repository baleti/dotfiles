#!/usr/bin/env bash
# mod+F11/F12: volume up/down. Routes to the "current" player's MPRIS
# Volume property (~/.config/playerctl-current) when it's pixel6 - the one
# MPRIS player here that isn't already local pipewire output, since its
# Volume proxies to the phone's own STREAM_MUSIC (see
# pixel6-mpris-bridge.py's _set_volume() and Set()). Every other case keeps
# adjusting the local sink directly, same as before this script existed.
set -uo pipefail

dir="${1:?usage: playerctl-volume.sh +|-}"

if [ "$(cat "$HOME/.config/playerctl-current" 2>/dev/null)" = "pixel6" ]; then
    playerctl --player=pixel6 volume "0.05$dir" 2>/dev/null && exit 0
fi

if [ "$dir" = "+" ]; then
    wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ 5%+
else
    wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
fi
