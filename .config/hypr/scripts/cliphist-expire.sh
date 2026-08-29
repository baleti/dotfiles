#!/usr/bin/env bash
# Age-based expiry for cliphist.
#
# cliphist stores no timestamps - `list` gives you `id<TAB>preview` and nothing
# else - so entry age can't be read from the database. But ids increase
# monotonically, so we can record a watermark ("at time T the highest id was N")
# on every run and later treat "id <= the watermark from MAX_AGE ago" as "older
# than MAX_AGE". This is still what drives the actual expiry decision below,
# unchanged.
#
# Consequence worth knowing: entries that already existed when this was first
# installed have unknown age, so they're treated as first seen at install time
# and survive one full MAX_AGE window before expiring.
#
# A second, more precise log now exists alongside this one:
# cliphist-store-logged.sh (wired into hyprland.lua's wl-paste --watch)
# appends an exact copy-time per entry as it's stored, which is what
# clipboard-picker's $date: field actually reads - real timestamps rather
# than this script's ~15min-bucketed watermark interpolation. This script
# doesn't consume that log for its own expiry math (no need to - the
# watermark approach already works and changing a script that deletes
# clipboard history is not something to do incidentally), it only prunes
# it below, in step with whatever this run just expired.

set -uo pipefail

# Hour-granularity (not day-granularity) so short windows like "3 hours" --
# needed once the sensitive-clipboard override in hyprland.lua started
# letting app passwords/TOTP codes/etc. into cliphist -- are expressible.
MAX_AGE_HOURS="${CLIPHIST_MAX_AGE_HOURS:-48}"
# Optional override so this can be exercised against a throwaway database
# rather than the live clipboard history. Deleting is destructive; being able
# to test it for real matters.
CLIPHIST=(cliphist)
[[ -n "${CLIPHIST_DB:-}" ]] && CLIPHIST=(cliphist -db-path "$CLIPHIST_DB")
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cliphist-expire"
WATERMARKS="$STATE_DIR/watermarks"
TIMESTAMPS="$STATE_DIR/timestamps"
# Keep a bit more history than we need, so the file stays small but we never
# lose the sample we're about to look for.
KEEP_HOURS=$(( MAX_AGE_HOURS * 5 + 1 ))

mkdir -p "$STATE_DIR"
touch "$WATERMARKS" "$TIMESTAMPS"

now=$(date +%s)
max_id=$("${CLIPHIST[@]}" list 2>/dev/null | head -1 | cut -f1)

# Empty history, or cliphist unavailable: nothing to do, and importantly don't
# record a watermark we can't trust.
if ! [[ "$max_id" =~ ^[0-9]+$ ]]; then
    exit 0
fi

printf '%s %s\n' "$now" "$max_id" >> "$WATERMARKS"

cutoff=$(( now - MAX_AGE_HOURS * 3600 ))

# Highest id known to have existed at or before the cutoff. Entries at or below
# it are older than MAX_AGE.
expire_below=$(awk -v c="$cutoff" '$1 <= c { id = $2 } END { if (id != "") print id }' "$WATERMARKS")

if [[ -n "$expire_below" ]]; then
    deleted=0
    while IFS= read -r line; do
        printf '%s\n' "$line" | "${CLIPHIST[@]}" delete && deleted=$(( deleted + 1 ))
    done < <("${CLIPHIST[@]}" list 2>/dev/null | awk -F'\t' -v n="$expire_below" '$1 + 0 <= n')
    [[ "$deleted" -gt 0 ]] && printf 'expired %d entries (id <= %s)\n' "$deleted" "$expire_below"
fi

# Drop watermark samples we'll never consult again.
prune_before=$(( now - KEEP_HOURS * 3600 ))
awk -v p="$prune_before" '$1 >= p' "$WATERMARKS" > "$WATERMARKS.tmp" && mv "$WATERMARKS.tmp" "$WATERMARKS"

# Prune the exact-timestamp log to match: anything copied before $cutoff was
# just (or previously) expired above, so its logged time is now for an id
# cliphist itself no longer has - $cutoff, not $prune_before, since this one
# has no interpolation to protect (each line already is an exact copy time,
# not a sample to interpolate between).
awk -v c="$cutoff" '$1 >= c' "$TIMESTAMPS" > "$TIMESTAMPS.tmp" && mv "$TIMESTAMPS.tmp" "$TIMESTAMPS"
