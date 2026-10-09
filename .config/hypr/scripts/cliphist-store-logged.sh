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
# Also re-asserts the selection after every store, so content survives the
# source app closing - replaces wl-clip-persist (removed 2026-09-18).
# wl-clip-persist ran as its own independent wlr-data-control client,
# reading the same clipboard payload a second time in parallel with this
# script's own wl-paste --watch; for large copies that doubled the read
# load on the source app (reported: Thunderbird stalling a few seconds
# copying a large image) and, worse, wl-clip-persist's periodic
# re-assertion of the selection looks like a fresh external copy to
# wl-paste --watch, re-triggering this script in a loop (caught live: one
# unchanged image's id re-logged three times in 14s). Doing the re-assert
# ourselves means the source app is only ever read once per real copy; the
# self-hash guard below is what stops our own re-assert from re-triggering
# itself the same way - it still calls `cliphist store` on the bounce-back
# (so a genuine back-to-back identical copy still gets its own fresh
# id/timestamp, same as before this change), it just skips reasserting that
# second time, which is enough to break the cycle after one harmless extra
# store.
#
# Type selection and multi-format bundles (added 2026-09-27): cliphist
# itself only ever stores one payload per entry (no upstream support for
# more - see its own -h). wl-paste --watch's own inference for *which*
# offered type to hand us on stdin turned out to be unreliable (caught
# live: a Facebook/Messenger image copy got read as its sidecar
# text/x-moz-url instead of image/png - UTF-16, so it stored
# null-interleaved garbled bytes with no image at all). So this script no
# longer trusts that inference for anything but a last-resort fallback: it
# enumerates every currently-offered real MIME type itself, picks one
# deliberately as cliphist's single required primary blob, and - closer to
# what KDE's Klipper actually does (checked its source,
# historymodel.cpp/updateclipboardjob.cpp: it persists *every* offered
# format per entry, not just one, and only prioritizes which to display -
# url > text > image, never discarding anything) - also fetches and keeps
# every other offered format alongside it, in a side-store bundle keyed by
# the primary's content hash. clipboard-picker's `activate`/
# `reassert-bundle` then offer the whole bundle at once via
# wl-clipboard-rs's copy_multi, so a paste target can still get HTML, a
# URL, or an image from the same history entry, not just whichever one
# happened to become the cliphist blob.
set -uo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cliphist-expire"
LOG="$STATE_DIR/timestamps"
LOCK="$STATE_DIR/store.lock"
SELF_HASH="$STATE_DIR/last-selfcopy-sha256"
SIZES="$STATE_DIR/sizes"
LARGE="$STATE_DIR/large"
FORMATS="$STATE_DIR/formats"
FORMATS_INDEX="$STATE_DIR/formats-index"
PICKER="$HOME/.config/hypr/clipboard-picker/target/release/clipboard-picker"
# cliphist store silently drops entries above ~5 MB (returns 0, keeps nothing;
# 5 MB kept, 6 MB dropped, checked live) - anything over this goes to $LARGE.
OVERFLOW_MIN=4000000
mkdir -p "$STATE_DIR"
touch "$LOG"

exec 9>"$LOCK"
flock 9

# Hard circuit breaker, independent of every other loop-prevention mechanism
# below: if this script has fired more than 20 times without a 10s gap
# anywhere in the run, stop dead rather than trust hash/timing comparisons
# to catch it. Caught live 2026-09-27: a stale-alias bug (see the "known
# legacy text aliases" comment further down) made the self-echo hash
# unstable, so the *intended* guard never matched and this script re-stored
# + re-asserted itself thousands of times in under a minute before being
# killed by hand. That bug is fixed below too, but this breaker stays
# regardless - it doesn't need to know *why* something is looping, only
# that it is.
STREAK_FILE="$STATE_DIR/reassert-streak"
now_s=$(date +%s)
last_t=0; streak=0
if [[ -f "$STREAK_FILE" ]]; then
    read -r last_t streak < "$STREAK_FILE" 2>/dev/null || true
    [[ "$last_t" =~ ^[0-9]+$ ]] || last_t=0
    [[ "$streak" =~ ^[0-9]+$ ]] || streak=0
fi
(( now_s - last_t > 10 )) && streak=0
streak=$((streak + 1))
printf '%s %s\n' "$now_s" "$streak" > "$STREAK_FILE"
if (( streak > 20 )); then
    exit 0
fi


tmp=$(mktemp "${TMPDIR:-/tmp}/cliphist-store.XXXXXX")
trap 'rm -f "$tmp"' EXIT
# Bounded: a delayed-render source (xfreerdp's cliprdr, caught live
# 2026-10-09) can offer a selection and never deliver the bytes, leaving
# wl-paste --watch's stdin open forever. An unbounded cat then held the
# flock above indefinitely, wedging every later clipboard event.
timeout 10 cat > "$tmp"

# Every real type currently on offer, pseudo/marker targets excluded.
# x-kde-force-image-copy carries no data of its own (see below); TARGETS/
# SAVE_TARGETS/TIMESTAMP/MULTIPLE are protocol bookkeeping, not content.
all_types=$(timeout 2 wl-paste --list-types 2>/dev/null)
real_types=$(grep -v -x -E 'SAVE_TARGETS|TARGETS|TIMESTAMP|MULTIPLE|x-kde-force-image-copy' <<<"$all_types")

# Our priority ladder for cliphist's one required primary blob. Image-first,
# unlike Klipper's own url > text > image order, because Klipper never has
# to discard the other representations (it keeps them all - see header) so
# it can afford to rank image last for *display*; we can only keep one
# primary, and a browser's sidecar text/html/moz-url next to an offered
# image is a machine fallback the human never chose. Klipper's explicit
# override for this ambiguity - Spectacle tags screenshot copies with the
# (data-less) marker x-kde-force-image-copy - doesn't actually change our
# ordering (image already wins whenever it's offered), so honouring it here
# is a no-op today; kept only in case a "don't prefer images" mode is ever
# added and needs an escape hatch.
#
# text/html ranks *below* plain text here (originally had it above, ranked
# by "richness" like the image case - wrong: caught live 2026-09-27, a
# Thunderbird copy of a 6-digit code stored raw
# `<meta ...><span class="rio-text...">652258</span>` as cliphist's own
# primary/preview/paste content instead of the plain "652258" a human
# obviously wants for something like a verification code. Unlike an
# image's sidecar text, HTML alongside plain text is usually the *same*
# content with formatting bolted on, not richer content - plain text is
# the safer default primary, html stays available as a bundle member for
# paste targets that actually want the formatting.
primary_type=""
for want in image/png image/jpeg image/webp image/gif image/bmp text/uri-list "text/plain;charset=utf-8" text/plain text/html; do
    grep -qx "$want" <<<"$real_types" && { primary_type="$want"; break; }
done
[[ -z "$primary_type" ]] && primary_type=$(head -1 <<<"$real_types")

primary_tmp=""
if [[ -n "$primary_type" ]]; then
    primary_tmp=$(mktemp "${TMPDIR:-/tmp}/cliphist-store.XXXXXX")
    for _ in 1 2 3 4 5 6; do
        # -n: wl-paste appends a trailing newline by default. Without this,
        # every explicit fetch mutates text content by growing it one \n -
        # caught live 2026-09-27: that made the self-echo hash change on
        # every single bounce (fetch -> store -> reassert -> re-fetch adds
        # another \n -> ...), so the loop-breaker never matched and this
        # script re-stored + re-asserted itself thousands of times before
        # being killed by hand. The circuit breaker further down is a
        # second line of defense against this same class of bug, but this
        # is the actual fix.
        timeout 15 wl-paste -n -t "$primary_type" > "$primary_tmp" 2>/dev/null
        [[ -s "$primary_tmp" ]] && break
        sleep 0.5
    done
fi

if [[ -n "$primary_tmp" && -s "$primary_tmp" ]]; then
    mv "$primary_tmp" "$tmp"
elif [[ -n "$primary_tmp" ]]; then
    rm -f "$primary_tmp"
fi
# else: explicit fetch unavailable or came up empty (e.g. the clipboard
# already changed again by the time we got here) - fall back to whatever
# wl-paste --watch originally handed us on stdin, same last-resort this
# script always used before per-type fetching existed.

# text/html only wins primary_type when there's no plain-text alternative
# at all (the 652258 case above: Thunderbird offered text/html plus its
# _moz_htmlcontext/_moz_htmlinfo/x-moz-url-priv siblings and nothing else).
# Demoting html in the ladder doesn't help here - there's nothing else to
# rank it against - so synthesize a plain-text fallback by stripping tags,
# and use *that* as the actual primary/preview/paste content instead. The
# real HTML still gets captured as a bundle member below (primary_type is
# now text/plain, so the secondary loop no longer skips it), so a paste
# target that wants formatting can still ask for it.
if [[ "$primary_type" == "text/html" && -s "$tmp" ]]; then
    plain_tmp=$(mktemp "${TMPDIR:-/tmp}/cliphist-store.XXXXXX")
    if python3 -c '
import sys, re, html
data = sys.stdin.buffer.read().decode("utf-8", "replace")
text = re.sub(r"<[^>]*>", "", data)
text = html.unescape(text)
text = re.sub(r"[ \t]+", " ", text).strip()
sys.stdout.write(text)
' < "$tmp" > "$plain_tmp" 2>/dev/null && [[ -s "$plain_tmp" ]]; then
        mv "$plain_tmp" "$tmp"
        primary_type="text/plain"
    else
        rm -f "$plain_tmp"
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
# Our own reassert below re-fires wl-paste --watch. Recognise that echo
# (same content, within seconds of our own reassert) and skip it whole:
# storing again would only delete this entry and reissue it under a new id,
# orphaning the thumbnail generated for the first one.
if [[ -f "$SELF_HASH" && "$(<"$SELF_HASH")" == "$hash" ]] \
        && (( $(date +%s) - $(stat -c %Y "$SELF_HASH") < 5 )); then
    exit 0
fi

store_src="$tmp"
overflow_file=""
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
            sub=${mime#*/}; sub=${sub#x-}; sub=${sub##*[.+]}
            label="[[ binary data $mib MiB $sub ]]"
            overflow_file=1
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

# Multi-format bundle: every other real type currently offered, fetched and
# kept alongside the primary under $FORMATS/<hash>/ - manifest is
# `<file>\t<mimetype>` lines, file 0 is always the primary (already have its
# bytes in $tmp, no need to re-fetch). Skipped if a bundle for this exact
# content already exists (repeat/dedup copy - same hash, nothing new to
# capture) so a back-to-back identical copy doesn't re-fetch every format.
# One fetch attempt each, not the primary's full retry loop: a missing
# secondary format just means that one representation isn't in the bundle,
# not a lost entry, so it's not worth the same latency budget.
if [[ -n "$new_id" ]]; then
    printf '%s\t%s\n' "$new_id" "$hash" >> "$FORMATS_INDEX"
    bundle_dir="$FORMATS/$hash"
    if [[ ! -s "$bundle_dir/manifest" ]] && ( umask 077; mkdir -p "$bundle_dir" ); then
        manifest_tmp=$(mktemp "${TMPDIR:-/tmp}/cliphist-manifest.XXXXXX")
        n=0
        cp "$tmp" "$bundle_dir/$n" && printf '%s\t%s\n' "$n" "$primary_type" >> "$manifest_tmp"
        n=$((n + 1))
        # Known legacy plain-text aliases (X11-era names plus the two
        # text/plain spellings) all name the *same* content, never a
        # distinct representation - wl-clipboard-rs's copy_multi already
        # regenerates all of these automatically from whichever one text
        # source we give it (its own documented behaviour). Capturing them
        # separately here doesn't just waste space (2026-09-27's incident
        # left 2456 near-duplicate bundle dirs, 58 MiB, from exactly this):
        # it actively broke self-echo detection, because copy_multi's own
        # auto-aliasing and our separately-captured copies of the same
        # alias could disagree on which bytes "text/plain" et al. actually
        # served on the next reassert, so the content hash was never
        # stable across bounces and the loop-breaker downstream never saw
        # a match. Skip them all unconditionally, regardless of which one
        # ended up as primary_type.
        while IFS= read -r t; do
            [[ -z "$t" || "$t" == "$primary_type" ]] && continue
            case "$t" in
                TEXT | STRING | UTF8_STRING | text/plain | text/plain\;charset=utf-8) continue ;;
            esac
            f=$(mktemp "${TMPDIR:-/tmp}/cliphist-fmt.XXXXXX")
            if timeout 5 wl-paste -n -t "$t" > "$f" 2>/dev/null && [[ -s "$f" ]]; then
                mv "$f" "$bundle_dir/$n"
                printf '%s\t%s\n' "$n" "$t" >> "$manifest_tmp"
                n=$((n + 1))
            else
                rm -f "$f"
            fi
        done <<<"$(head -25 <<<"$real_types")"
        mv "$manifest_tmp" "$bundle_dir/manifest"
    fi
fi

last_hash=""
[[ -f "$SELF_HASH" ]] && last_hash=$(<"$SELF_HASH")

# fd 9 (the flock lock) must be closed before the reassert below spawns: it
# forks a detached daemon that outlives this script to keep serving paste
# requests, and that daemon would otherwise inherit fd 9 and hold the lock
# open forever, wedging every subsequent invocation at `flock 9` (hit live
# with the old plain-wl-copy reassert - a leaked daemon holding the lock
# hung the next store indefinitely; the same risk applies here unchanged).
exec 9>&-

if [[ "$hash" != "$last_hash" ]]; then
    # Hash first: the echo run can start before the reassert returns.
    echo "$hash" > "$SELF_HASH"
    "$PICKER" reassert-bundle "$hash"
fi

# Pre-generate the picker thumbnail now, off the critical path, so opening
# mod+v finds it cached instead of decoding a multi-MB image on the spot.
if [[ -n "$new_id" && ( -n "$overflow_file" || "$(file -b --mime-type "$tmp")" == image/* ) ]]; then
    setsid -f "$PICKER" thumbs "$new_id" >/dev/null 2>&1
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
