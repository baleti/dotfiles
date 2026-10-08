#!/bin/sh
# One "<remote> <about-json>" line per non-overlay rclone remote that supports
# `rclone about`. Overlays (crypt/alias/...) have a `remote =` and are skipped.
remotes=$(rclone config dump 2>/dev/null | python3 -c '
import json, sys
for k, v in json.load(sys.stdin).items():
    if not v.get("remote"):
        print(k)
')
hidden=$HOME/.local/state/sysmond/hidden-mounts.conf
for r in $remotes; do
    grep -qx "rclone:$r" "$hidden" 2>/dev/null && continue
    ( o=$(timeout -k 1 15 rclone about "$r": --json 2>/dev/null) && printf '%s %s\n' "$r" "$(echo "$o" | tr -d '\n')" ) &
done
wait
