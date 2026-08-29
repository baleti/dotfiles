#!/usr/bin/env bash
# Wraps `cliphist store` (invoked once per wl-paste --watch clipboard-change
# event, see hyprland.lua) to additionally log an exact copy timestamp per
# entry. cliphist itself keeps none - see cliphist-expire.sh's own comment
# on this - so without this, clipboard-picker's $date: field would only
# have that script's coarser ~15min-bucketed id/time watermark (built for
# age-based expiry, not per-entry display) to work from.
#
# cliphist store prints nothing and ids are assigned strictly sequentially
# (confirmed directly against a throwaway db - even a dedup-triggered
# re-store of identical content gets a *new* id, the old one deleted), so
# "the id `cliphist list`'s top line has right after this store call" is
# the id that was just assigned. flock serializes this read-after-write
# across overlapping invocations - wl-paste --watch can fire more than one
# of these concurrently on rapid clipboard changes, and without the lock a
# second store landing between our own store and list calls would
# misattribute this timestamp to the wrong (its) id.
set -uo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cliphist-expire"
LOG="$STATE_DIR/timestamps"
LOCK="$STATE_DIR/store.lock"
mkdir -p "$STATE_DIR"
touch "$LOG"

exec 9>"$LOCK"
flock 9

# Deliberately overriding wl-paste's CLIPBOARD_STATE=sensitive skip here
# too, same as the inline command this replaced - see hyprland.lua's
# comment on why (retention is time-bounded by cliphist-expire.sh instead).
unset CLIPBOARD_STATE
cliphist store

id=$(cliphist list 2>/dev/null | head -1 | cut -f1)
if [[ "$id" =~ ^[0-9]+$ ]]; then
    printf '%s\t%s\n' "$(date +%s)" "$id" >> "$LOG"
fi
