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
SIZES="$STATE_DIR/sizes"
LARGE="$STATE_DIR/large"
# cliphist store silently drops entries above ~5 MB (returns 0, keeps nothing;
# 5 MB kept, 6 MB dropped, checked live) - anything over this goes to $LARGE.
OVERFLOW_MIN=4000000
mkdir -p "$STATE_DIR"
touch "$LOG"

exec 9>"$LOCK"
flock 9


tmp=$(mktemp "${TMPDIR:-/tmp}/cliphist-store.XXXXXX")
trap 'rm -f "$tmp"' EXIT
cat > "$tmp"

# An empty read (wl-paste --watch delivered nothing, e.g. the source failed to
# serve a large image) must not be stored or re-asserted: wl-copy of empty
# input would replace the source app's still-valid selection with an empty
# one, so paste elsewhere finds no data at all.
#
# Large images from Thunderbird hit this: wl-paste's own type inference
# fails on its offer (image/png, image/bmp, ... SAVE_TARGETS, no text), so
# wl-paste --watch hands us 0 bytes even though asking for a type explicitly
# returns the full image at once (17 MB PNG in 0.3s, checked live). So on an
# empty read, pick a type ourselves - image/png if offered, else the first
# real type - and read that. Never accept the untyped `wl-paste` here: it
# returned 1 stray byte once and that got re-asserted over the image.
if [[ ! -s "$tmp" ]]; then
    types=$(timeout 2 wl-paste --list-types 2>/dev/null)
    pick=$(grep -m1 -x 'image/png' <<<"$types" \
        || grep -m1 -v -x -E 'SAVE_TARGETS|TARGETS|TIMESTAMP|MULTIPLE' <<<"$types")
    if [[ -n "$pick" ]]; then
        for _ in 1 2 3 4 5 6; do
            timeout 15 wl-paste -t "$pick" > "$tmp" 2>/dev/null
            [[ -s "$tmp" ]] && break
            sleep 0.5
        done
    fi
fi
if [[ ! -s "$tmp" ]]; then
    exit 0
fi

# Deliberately overriding wl-paste's CLIPBOARD_STATE=sensitive skip here
# too, same as the inline command this replaced - see hyprland.lua's
# comment on why (retention is time-bounded by cliphist-expire.sh instead).
unset CLIPBOARD_STATE

hash=$(sha256sum "$tmp" | cut -d' ' -f1)

# Oversized data: keep the real bytes in a private (700/600) file named by
# content hash, and give cliphist a small placeholder instead so ordering,
# the 750-item cap, expiry and dedup all keep working. The placeholder's
# last line is `overflow:<sha256>`; clipboard-picker's decode() resolves it
# back to the file, and cliphist-expire.sh deletes blobs no live entry
# references. The first line copies cliphist's own binary-data preview so the
# picker treats it as an image row.
store_src="$tmp"
if (( $(stat -c %s "$tmp") > OVERFLOW_MIN )); then
    if ( umask 077; mkdir -p "$LARGE" && chmod 700 "$LARGE" \
            && { [[ -e "$LARGE/$hash" ]] || { cp "$tmp" "$LARGE/$hash.part" && mv "$LARGE/$hash.part" "$LARGE/$hash"; }; } \
            && touch "$LARGE/$hash" ); then
        bytes=$(stat -c %s "$tmp")
        mib=$(( (bytes + 524288) / 1048576 ))
        mime=$(file -b --mime-type "$tmp")
        if [[ "$mime" == image/* ]]; then
            sub=${mime#image/}; sub=${sub#x-}
            dims=$(file -b "$tmp" | grep -oE '[0-9]+ ?x ?[0-9]+' | tail -1 | tr -d ' ')
            label="[[ binary data $mib MiB $sub${dims:+ $dims} ]]"
        elif [[ "$mime" == text/* ]]; then
            label="$(head -c 200 "$tmp" | iconv -f UTF-8 -t UTF-8 -c | tr -s '[:space:]' ' ') [$mib MiB]"
        else
            label="[[ binary data $mib MiB ${mime#*/} ]]"
        fi
        store_src=$(mktemp "${TMPDIR:-/tmp}/cliphist-store.XXXXXX")
        printf '%s\noverflow:%s\n' "$label" "$hash" > "$store_src"
        trap 'rm -f "$tmp" "$store_src"' EXIT
    fi
fi
cliphist store < "$store_src"

id=$(cliphist list 2>/dev/null | head -1 | cut -f1)
new_id=""
if [[ "$id" =~ ^[0-9]+$ ]]; then
    new_id="$id"
    printf '%s\t%s\n' "$(date +%s)" "$id" >> "$LOG"
fi

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

# Per-entry `id<TAB>chars<TAB>lines` for the mod+v picker's size badge, read
# by clipboard-picker's `list` so opening the picker never has to decode
# entries to count them (an entry's content is immutable, so this is
# computed once, here, and never again). Deliberately last: the selection
# re-assert above is what other apps are waiting on, this only has to land
# before the user next opens the picker. Text only (valid UTF-8, <8 MiB) -
# images/binary get no line and the picker shows no badge for them. Same
# trimming as the picker's own `stats` backfill: trailing newlines dropped,
# lines = newline count + 1.
if [[ -n "$new_id" ]] && (( $(stat -c %s "$tmp") < 8388608 )) \
        && LC_ALL=C.UTF-8 iconv -f UTF-8 -t UTF-8 "$tmp" >/dev/null 2>&1; then
    text=$(<"$tmp")
    if [[ -n "$text" ]]; then
        chars=$(printf '%s' "$text" | LC_ALL=C.UTF-8 wc -m)
        nl=$(printf '%s' "$text" | wc -l)
        printf '%s\t%s\t%s\n' "$new_id" "$chars" "$((nl + 1))" >> "$SIZES"
    fi
fi
