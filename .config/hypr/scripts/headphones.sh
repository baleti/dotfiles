#!/usr/bin/env bash
# Connect / disconnect the Bluetooth headphones named in
# ~/.config/hypr/bluetooth-headphones.conf (HEADPHONES_ID=<MAC>).
# usage: headphones.sh connect|disconnect
#
# connect first makes the phone (PHONE_HOST) release the headphones, since a
# headset held by the phone refuses this host. That step is best-effort: if the
# phone is unreachable or adb isn't paired, it is skipped.
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
conf="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/bluetooth-headphones.conf"
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

# Ask the phone to drop the headphones. Wireless debugging's port changes on
# every toggle/reboot, so ask the Companion app on the phone (it learns the
# port from adbd's mDNS advert) instead of scanning.
phone_release() {
    [ -n "${PHONE_HOST:-}" ] || return 0
    command -v adb >/dev/null || return 0
    local port serial
    port="$(curl -sf -m 2 -H 'X-Peer-Agent: 1' "http://$PHONE_HOST:8788/adb-port")" || return 1
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    serial="$PHONE_HOST:$port"
    timeout 5 adb connect "$serial" 2>&1 | grep -q '^\(already \)\?connected' || return 1
    timeout 10 adb -s "$serial" push "$dir/phone-bt/btdisc.dex" /data/local/tmp/btdisc.dex >/dev/null 2>&1 || return 1
    timeout 15 adb -s "$serial" shell "CLASSPATH=/data/local/tmp/btdisc.dex app_process /system/bin BtDisconnect $HEADPHONES_ID disconnect" >/dev/null 2>&1
    sleep 1   # let the headset go back to connectable
}

[ "$action" = connect ] && phone_release

# bluetoothctl colours its output even when piped; strip the ANSI escapes.
out="$(timeout 15 bluetoothctl "$action" "$HEADPHONES_ID" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
if grep -q "successful" <<<"$out"; then
    notify-send -t 2500 "Headphones" "${action^}ed $HEADPHONES_ID"
else
    notify-send -u critical "Headphones: $action failed" "$(grep -m1 -i 'fail' <<<"$out" || tail -n1 <<<"$out")"
    exit 1
fi
