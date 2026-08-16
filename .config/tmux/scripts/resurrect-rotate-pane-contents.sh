#!/usr/bin/env bash
# Wired up as @resurrect-hook-post-save-all in .tmux.conf. tmux-resurrect's
# save.sh overwrites a single fixed pane_contents.tar.gz on every save (see
# scripts/helpers.sh: pane_contents_archive_file() always returns the same
# path) - with @continuum-save-interval 10 that means any pane scrollback
# from more than ~10 minutes ago is already gone by the time you'd want it.
#
# This hook fires (execute_hook "post-save-all" in save.sh) right after
# save.sh has rewritten that archive for this cycle and before its own
# remove_old_backups housekeeping, so the archive is guaranteed fresh here.
# It copies that snapshot into a timestamped history dir, then thins both
# that history AND tmux-resurrect's own tmux_resurrect_*.txt layout files
# (replacing resurrect's cruder "keep 5, delete after 30 days" policy for
# those) with the same keep-newest-per-bucket generational rotation: full
# 10-minute resolution for the last hour, widening to daily out past 18h,
# expiring at @resurrect-delete-backup-after - one retention knob for both,
# so neither directory accumulates without bound.
#
# Layout thinning is NOT purely independent of content thinning, though:
# every content snapshot that survives its own thinning pass gets its true
# nearest-preceding layout file (the exact one resurrect-restore.sh would
# look up for it - see nearest_layout_for below) added to a protected set
# before layout thinning runs. Without this, two genuinely different real
# layouts landing in the same age bucket would collapse to keeping only the
# newer one, and a surviving content snapshot from the older layout's era
# would silently get paired with the wrong (newer) layout on restore - not
# just coarser resolution, an actually incorrect pane arrangement. Content
# and layout timestamps still won't ever coincide exactly (save.sh only
# writes a new .txt when the layout actually changes, so there's rarely a
# same-instant pair to begin with - that mismatch is inherent to how
# tmux-resurrect itself works, not something rotation introduces), but this
# guarantees the specific layout each surviving snapshot needs never gets
# thinned out from under it.
#
# Deliberately NOT reusing the timestamp in tmux-resurrect's own `last`
# symlink for the content archive: save.sh dedupes unchanged layouts (rm's
# the new .txt and leaves `last` pointing at the old one - see files_differ
# in save.sh), but pane *content* (scrollback) keeps changing every cycle
# even when the layout doesn't. Reusing the layout's timestamp would
# collapse those into a single overwritten slot and defeat the whole point.
set -euo pipefail

resurrect_dir="$(tmux show-options -gqv @resurrect-dir 2>/dev/null || true)"
resurrect_dir="${resurrect_dir:-$HOME/.tmux/resurrect}"
resurrect_dir="${resurrect_dir/#\~/$HOME}"

hist_dir="$resurrect_dir/pane_contents_history"
mkdir -p "$hist_dir"

src="$resurrect_dir/pane_contents.tar.gz"
if [ -f "$src" ]; then
	cp -f "$src" "$hist_dir/pane_contents_$(date +%Y%m%dT%H%M%S).tar.gz"
fi

delete_after_days="$(tmux show-options -gqv @resurrect-delete-backup-after 2>/dev/null || true)"
delete_after_days="${delete_after_days:-30}"
max_age_min=$(( delete_after_days * 1440 ))
now="$(date +%s)"

# $1 glob, $2 filename prefix to strip, $3 suffix to strip, $4 newline-
# separated paths to never delete regardless of age
thin() {
	local glob="$1" prefix="$2" suffix="$3" protect_list="$4"
	local -A protected
	local p real
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		real="$(readlink -f "$p" 2>/dev/null || printf '%s' "$p")"
		protected["$real"]=1
	done <<< "$protect_list"

	local -A seen_bucket
	local f base fts fepoch age_min bucket
	for f in $(ls -t $glob 2>/dev/null); do
		real="$(readlink -f "$f" 2>/dev/null || printf '%s' "$f")"
		if [ -n "${protected[$real]:-}" ]; then
			continue
		fi
		base="$(basename "$f")"
		fts="${base#$prefix}"
		fts="${fts%$suffix}"
		fepoch="$(date -d "${fts:0:4}-${fts:4:2}-${fts:6:2} ${fts:9:2}:${fts:11:2}:${fts:13:2}" +%s 2>/dev/null)" || continue
		age_min=$(( (now - fepoch) / 60 ))

		if [ "$age_min" -le 60 ]; then
			bucket="all-${fts}"                # last hour: keep every snapshot
		elif [ "$age_min" -le 180 ]; then
			bucket="20m-$(( age_min / 20 ))"   # 1h-3h: 1 per 20 min
		elif [ "$age_min" -le 1080 ]; then
			bucket="1h-$(( age_min / 60 ))"    # 3h-18h: 1 per hour
		elif [ "$age_min" -le "$max_age_min" ]; then
			bucket="1d-$(( age_min / 1440 ))"  # 18h-max_age: 1 per day
		else
			rm -f "$f"
			continue
		fi

		if [ -n "${seen_bucket[$bucket]:-}" ]; then
			rm -f "$f"
		else
			seen_bucket[$bucket]=1
		fi
	done
}

# nearest layout file at-or-before a given content timestamp - kept
# identical to resurrect-restore.sh's own lookup so whatever gets protected
# here is exactly what a restore would actually ask for. Must run against
# the full, not-yet-thinned .txt set, so this is called before layout
# thinning happens below.
nearest_layout_for() {
	local target_ts="$1"
	local layout_ts="" lf lts
	while IFS= read -r lf; do
		[ -e "$lf" ] || continue
		lts="$(basename "$lf")"
		lts="${lts#tmux_resurrect_}"
		lts="${lts%.txt}"
		if [[ "$lts" > "$target_ts" ]]; then
			break
		fi
		layout_ts="$lts"
	done < <(printf '%s\n' "$resurrect_dir"/tmux_resurrect_*.txt 2>/dev/null | sort)
	printf '%s' "$layout_ts"
}

thin "$hist_dir/pane_contents_*.tar.gz" "pane_contents_" ".tar.gz" ""

required_layouts=""
for f in "$hist_dir"/pane_contents_*.tar.gz; do
	[ -e "$f" ] || continue
	base="$(basename "$f")"
	cts="${base#pane_contents_}"
	cts="${cts%.tar.gz}"
	lts="$(nearest_layout_for "$cts")"
	if [ -n "$lts" ]; then
		required_layouts="$required_layouts
$resurrect_dir/tmux_resurrect_${lts}.txt"
	fi
done

last_target="$(readlink -f "$resurrect_dir/last" 2>/dev/null || true)"
thin "$resurrect_dir/tmux_resurrect_*.txt" "tmux_resurrect_" ".txt" "$last_target
$required_layouts"
