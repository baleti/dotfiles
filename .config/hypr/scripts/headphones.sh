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
# every toggle/reboot: try the last known one, else scan for it.
phone_release() {
    [ -n "${PHONE_HOST:-}" ] || return 0
    command -v adb >/dev/null || return 0
    # Bail fast if the phone is off the tunnel (a scan of a dead host is slow).
    timeout 3 ping -c1 -W2 "$PHONE_HOST" >/dev/null 2>&1 || return 1
    local cache="${XDG_RUNTIME_DIR:-/tmp}/headphones-phone-port" port serial=""
    port="$(cat "$cache" 2>/dev/null)"
    if [ -n "$port" ] && timeout 5 adb connect "$PHONE_HOST:$port" 2>&1 | grep -q '^\(already \)\?connected'; then
        serial="$PHONE_HOST:$port"
    else
        for port in $(timeout 20 nmap -Pn -n -p 30000-50000 --open -T4 --max-retries 1 "$PHONE_HOST" 2>/dev/null | awk -F/ '/\/tcp.*open/{print $1}'); do
            if timeout 5 adb connect "$PHONE_HOST:$port" 2>&1 | grep -q '^\(already \)\?connected'; then
                serial="$PHONE_HOST:$port"; echo "$port" > "$cache"; break
            fi
        done
    fi
    [ -n "$serial" ] || return 1
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
