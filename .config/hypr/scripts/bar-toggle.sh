#!/usr/bin/env bash
# mod+n/p/m/t/d/g (keybinds.lua): toggle one of the quickshell bar's hover-
# graph panels open/closed on whichever monitor is currently focused.
#
# Each monitor runs its own Bar.qml instance (shell.qml's Variants over
# Quickshell.screens), and each registers its own IpcHandler target
# "bar-<screen name>" -- a single shared "bar" target would collide across
# those instances, so this resolves the focused monitor's name first.
set -uo pipefail

func="$1"

mon=$(hyprctl -j monitors | python3 -c "import json,sys; d=json.load(sys.stdin); print(next((m['name'] for m in d if m.get('focused')), ''))")
[ -n "$mon" ] || exit 0

qs ipc call "bar-$mon" "$func"
