#!/usr/bin/env bash
# mod+shift+n: pick one of a notification's actions via rofi and invoke it
# (replaces dunstctl context, which no longer exists once notifyd is the
# running daemon). Defaults to the most recently received notification;
# pass an id explicitly to target a specific one instead (e.g. from a
# future picker "show actions for this entry" affordance).

notifyctl="$HOME/.config/hypr/notifyd/target/release/notifyctl"

id="$1"
if [[ -z "$id" ]]; then
    id=$("$notifyctl" list | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['id'] if d else '')")
fi
[[ -n "$id" ]] || exit 0

actions="$("$notifyctl" actions "$id")"
[[ -n "$actions" ]] || exit 0

# rofi shows labels only (column 2); -format i gives back the 0-based index
# of whichever line was picked, which maps back to that same line's key
# (column 1) below.
index=$(echo "$actions" | cut -f2 | rofi -dmenu -i -p "notifyd:" -format i)
[[ -n "$index" ]] || exit 0

selected_key=$(echo "$actions" | cut -f1 | sed -n "$((index + 1))p")
[[ -n "$selected_key" ]] || exit 0

"$notifyctl" invoke-action "$id" "$selected_key"
