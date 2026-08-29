#!/usr/bin/env bash
# graph_<widget> submaps (keybinds.lua): sets a bar graph panel's history
# tier on whichever monitor is currently focused. Companion to
# bar-toggle.sh, which only forwards no-arg toggle functions - this passes
# the tier code through as well.
set -uo pipefail

func="${1:?usage: bar-set-tier.sh <setXxxTier> <tier-code>}"
code="${2:?usage: bar-set-tier.sh <setXxxTier> <tier-code>}"

mon=$(hyprctl -j monitors | python3 -c "import json,sys; d=json.load(sys.stdin); print(next((m['name'] for m in d if m.get('focused')), ''))")
[ -n "$mon" ] || exit 0

qs ipc call "bar-$mon" "$func" "$code"
