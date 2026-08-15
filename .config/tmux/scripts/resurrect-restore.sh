#!/usr/bin/env bash
# Entry point for prefix+C-r (see .tmux.conf), replacing tmux-resurrect's
# own C-r binding. Runs as a plain backgrounded run-shell job (bind-key ->
# run-shell -b), the same invocation shape tmux-resurrect's own default
# C-r binding uses (bind-key -> run-shell restore.sh) - restore.sh's
# internal `tmux switch-client -t ...` call (scripts/restore.sh:213) needs
# that shape to correctly resolve "the client that pressed the key".
#
# Deliberately NOT calling restore.sh from inside a display-popup: popups
# break that resolution (hit the hard way building window-search.py - see
# the tmux_popup_format_expansion / window-search-debugging-session
# memories; #{client_tty} needing explicit --client bridging past a popup
# boundary is the same underlying quirk). So the popup below is used only
# for the interactive picker (resurrect-restore-picker.sh, which never
# touches switch-client or restore.sh); its answer comes back through a
# temp file since display-popup doesn't hand the invoked command's stdout
# back to the caller. The actual file swap + restore.sh handoff happen
# here, after that popup has already closed.
#
# $1: client_tty, format-expanded by the run-shell in .tmux.conf before
# this script ever sees it - a literal #{client_tty} written inside a
# script body (as opposed to inside run-shell's own shell-command string)
# is never expanded by tmux, so it has to arrive as a plain argument.
set -euo pipefail

client_tty="${1:?client_tty required}"

# tmux-resurrect itself publishes this once loaded (resurrect.tmux:
# set_script_path_options), pointing at wherever its own scripts/restore.sh
# actually lives - manual checkout here, but this keeps the script working
# unmodified on a TPM-managed install (~/.tmux/plugins/tmux-resurrect) too.
restore_sh="$(tmux show-options -gqv @resurrect-restore-script-path 2>/dev/null || true)"
restore_sh="${restore_sh:-$HOME/.tmux/plugins/tmux-resurrect/scripts/restore.sh}"
restore_sh="${restore_sh/#\~/$HOME}"
picker_sh=~/.config/tmux/scripts/resurrect-restore-picker.sh

resurrect_dir="$(tmux show-options -gqv @resurrect-dir 2>/dev/null || true)"
resurrect_dir="${resurrect_dir:-$HOME/.tmux/resurrect}"
resurrect_dir="${resurrect_dir/#\~/$HOME}"
hist_dir="$resurrect_dir/pane_contents_history"

result_file="$(mktemp)"
trap 'rm -f "$result_file"' EXIT

# -EE (not -E): only auto-close on the picker's clean exit, so a picker
# failure (fzf missing, etc.) stays on screen to be read - same reasoning
# as prefix+C-w's popup, see that binding's comment in .tmux.conf
tmux display-popup -c "$client_tty" -w 90% -h 90% -EE \
	"$picker_sh > '$result_file'"

chosen_ts="$(cat "$result_file" 2>/dev/null || true)"
[ -n "$chosen_ts" ] || exit 0

if [ "$chosen_ts" = "LIVE" ]; then
	exec "$restore_sh"
fi

archive="$hist_dir/pane_contents_${chosen_ts}.tar.gz"
if [ ! -f "$archive" ]; then
	tmux display-message "resurrect: snapshot archive missing: $archive"
	exit 1
fi

# nearest layout file at-or-before the chosen content snapshot, since
# layout .txt files are far sparser than content snapshots (save.sh dedupes
# unchanged layouts, and the rotate hook thins them further) - fixed-width
# timestamps sort lexicographically, so a plain string compare works
layout_ts=""
while IFS= read -r lf; do
	[ -e "$lf" ] || continue
	lts="$(basename "$lf")"
	lts="${lts#tmux_resurrect_}"
	lts="${lts%.txt}"
	if [[ "$lts" > "$chosen_ts" ]]; then
		break
	fi
	layout_ts="$lts"
done < <(printf '%s\n' "$resurrect_dir"/tmux_resurrect_*.txt | sort)

# `last` is a symlink, so repointing it never destroys anything - the
# layout file it used to point at stays on disk untouched.
if [ -n "$layout_ts" ]; then
	ln -sf "tmux_resurrect_${layout_ts}.txt" "$resurrect_dir/last"
fi

# pane_contents.tar.gz is a plain file (save.sh writes through it with a
# `>` redirect every cycle, so it can never safely be a symlink - see the
# rotate hook's comment), so swapping it means genuinely overwriting it.
# Fold the live one into history under its own "now" timestamp first, so
# nothing more recent than the last rotation cycle is ever lost.
if [ -f "$resurrect_dir/pane_contents.tar.gz" ]; then
	mkdir -p "$hist_dir"
	cp -f "$resurrect_dir/pane_contents.tar.gz" "$hist_dir/pane_contents_$(date +%Y%m%dT%H%M%S).tar.gz"
fi
cp -f "$archive" "$resurrect_dir/pane_contents.tar.gz"

tmux display-message "resurrect: restoring pane contents from ${chosen_ts}$( [ -n "$layout_ts" ] && printf ' (layout %s)' "$layout_ts" )"
exec "$restore_sh"
