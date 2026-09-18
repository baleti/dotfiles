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
#
# Also re-asserts the selection via wl-copy after every store, so content
# survives the source app closing - replaces wl-clip-persist (removed
# 2026-09-18). wl-clip-persist ran as its own independent wlr-data-control
# client, reading the same clipboard payload a second time in parallel with
# this script's own wl-paste --watch; for large copies that doubled the
# read load on the source app (reported: Thunderbird stalling a few
# seconds copying a large image) and, worse, wl-clip-persist's periodic
# re-assertion of the selection looks like a fresh external copy to
# wl-paste --watch, re-triggering this script in a loop (caught live: one
# unchanged image's id re-logged three times in 14s). Doing the re-assert
# ourselves, from the same stdin wl-paste --watch already handed us, means
# the source app is only ever read once; the self-hash guard below is what
# stops our own re-assert from re-triggering itself the same way - it
# still calls `cliphist store` on the bounce-back (so a genuine
# back-to-back identical copy still gets its own fresh id/timestamp, same
# as before this change), it just skips wl-copy that second time, which is
# enough to break the cycle after one harmless extra store.
set -uo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cliphist-expire"
LOG="$STATE_DIR/timestamps"
LOCK="$STATE_DIR/store.lock"
SELF_HASH="$STATE_DIR/last-selfcopy-sha256"
mkdir -p "$STATE_DIR"
touch "$LOG"

exec 9>"$LOCK"
flock 9

tmp=$(mktemp "${TMPDIR:-/tmp}/cliphist-store.XXXXXX")
trap 'rm -f "$tmp"' EXIT
cat > "$tmp"

# Deliberately overriding wl-paste's CLIPBOARD_STATE=sensitive skip here
# too, same as the inline command this replaced - see hyprland.lua's
# comment on why (retention is time-bounded by cliphist-expire.sh instead).
unset CLIPBOARD_STATE
cliphist store < "$tmp"

id=$(cliphist list 2>/dev/null | head -1 | cut -f1)
if [[ "$id" =~ ^[0-9]+$ ]]; then
    printf '%s\t%s\n' "$(date +%s)" "$id" >> "$LOG"
fi

hash=$(sha256sum "$tmp" | cut -d' ' -f1)
last_hash=""
[[ -f "$SELF_HASH" ]] && last_hash=$(<"$SELF_HASH")

# fd 9 (the flock lock) must be closed before wl-copy spawns: it forks a
# detached daemon that outlives this script to keep serving paste requests,
# and that daemon would otherwise inherit fd 9 and hold the lock open
# forever, wedging every subsequent invocation at `flock 9` (hit live while
# testing this - a leaked wl-copy holding the lock hung the next store
# indefinitely).
exec 9>&-

if [[ "$hash" != "$last_hash" ]]; then
    wl-copy < "$tmp"
    echo "$hash" > "$SELF_HASH"
fi
