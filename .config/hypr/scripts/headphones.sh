#!/usr/bin/env bash
# Connect / disconnect the Bluetooth headphones named in
# ~/.config/hypr/headphones.conf (HEADPHONES_ID=<MAC>).
# usage: headphones.sh connect|disconnect
set -uo pipefail

conf="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/headphones.conf"
action="${1:?usage: headphones.sh connect|disconnect}"

# shellcheck disable=SC1090
[ -r "$conf" ] && . "$conf"
if [ -z "${HEADPHONES_ID:-}" ]; then
    notify-send -u critical "Headphones" "HEADPHONES_ID not set in $conf"
    exit 1
fi

case "$action" in
    connect|disconnect) ;;
    *) echo "usage: headphones.sh connect|disconnect" >&2; exit 2 ;;
esac

# bluetoothctl colours its output even when piped; strip the ANSI escapes.
out="$(timeout 15 bluetoothctl "$action" "$HEADPHONES_ID" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
if grep -q "successful" <<<"$out"; then
    notify-send -t 2500 "Headphones" "${action^}ed $HEADPHONES_ID"
else
    notify-send -u critical "Headphones: $action failed" "$(grep -m1 -i 'fail' <<<"$out" || tail -n1 <<<"$out")"
    exit 1
fi
