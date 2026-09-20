#!/usr/bin/env bash
# Move the Bluetooth headphones named in ~/.config/hypr/bluetooth-headphones.conf
# (HEADPHONES_ID=<MAC>) between this host and the phone (PHONE_HOST).
# usage: headphones.sh connect|disconnect
#
#   connect     phone releases the headphones, then this host connects them
#   disconnect  this host disconnects them, then the phone connects them
#
# The phone step is best-effort: if the phone is unreachable it is skipped.
# Only the adb `shell` user may connect/disconnect a single Bluetooth device
# on Android, so this host drives adb; the Companion app on the phone
# (:8788) only lends out Wireless debugging for the duration ("dance"):
#   POST /adb/enable  -> turns Wireless debugging on if it was off, returns port
#   ...adb: run phone-bt/BtDisconnect <MAC> disconnect|connect as shell...
#   POST /adb/release -> turns it back off, only if /adb/enable turned it on
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

# adb may start its background server from inside the locked section; every adb
# call below closes the lock fd (9>&-) so the server can't inherit it and hold
# the lock forever.
peer() { curl -sf -m "$1" -X POST -H 'X-Peer-Agent: 1' "http://$PHONE_HOST:8788$2"; }

# usage: phone_do disconnect|connect   (what the PHONE should do with the headphones)
phone_do() {
    local op="$1" port serial out
    [ -n "${PHONE_HOST:-}" ] && command -v adb >/dev/null || return 0

    exec 9>"${XDG_RUNTIME_DIR:-/tmp}/headphones-phone.lock"
    flock -w 30 9 || return 1

    port="$(peer 15 /adb/enable)" || return 1     # unreachable / app down: skip
    # Always give Wireless debugging back, however the rest goes.
    trap 'peer 5 /adb/release >/dev/null 2>&1' RETURN

    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    serial="$PHONE_HOST:$port"
    out="$(timeout 8 adb connect "$serial" 2>&1 9>&-)"
    if ! grep -q '^\(already \)\?connected' <<<"$out"; then
        # Port is open but the TLS handshake was rejected: the phone no longer
        # trusts this host's adb key (adb prints "failed to connect", not
        # "cannot connect ... refused/timed out", in that case).
        if grep -q '^failed to connect' <<<"$out"; then
            notify-send -u critical -t 0 "Headphones: phone needs re-pairing" \
"The phone no longer trusts this computer's adb key, so it can't hand the headphones over. Headphones still connect/disconnect on this computer.
Fix: on the phone open Settings > Developer options > Wireless debugging > 'Pair device with pairing code', then run here:
adb pair $PHONE_HOST:<pair port> <code>"
        fi
        return 1
    fi
    timeout 10 adb -s "$serial" push "$dir/phone-bt/btdisc.dex" /data/local/tmp/btdisc.dex >/dev/null 2>&1 9>&- || return 1
    timeout 15 adb -s "$serial" shell "CLASSPATH=/data/local/tmp/btdisc.dex app_process /system/bin BtDisconnect $HEADPHONES_ID $op" >/dev/null 2>&1 9>&-
}

[ "$action" = connect ] && { phone_do disconnect; sleep 1; }   # let the headset become connectable

# bluetoothctl colours its output even when piped; strip the ANSI escapes.
out="$(timeout 15 bluetoothctl "$action" "$HEADPHONES_ID" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
if grep -q "successful" <<<"$out"; then
    notify-send -t 2500 "Headphones" "${action^}ed $HEADPHONES_ID"
    rc=0
else
    notify-send -u critical "Headphones: $action failed" "$(grep -m1 -i 'fail' <<<"$out" || tail -n1 <<<"$out")"
    rc=1
fi

[ "$action" = disconnect ] && [ "$rc" = 0 ] && { sleep 1; phone_do connect; }
exit "$rc"
