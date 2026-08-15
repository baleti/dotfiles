#!/usr/bin/env bash
# Interactive picker only - runs inside the inner display-popup spawned by
# resurrect-restore.sh. Deliberately does nothing client-context-sensitive
# (no switch-client, no calling restore.sh itself): switch-client doesn't
# reliably resolve "the client that pressed the key" when run from inside a
# nested popup - the same tmux quirk window-search.py had to work around
# (see the window-search-debugging-session / tmux_popup_format_expansion
# memories). This just prints the chosen timestamp (or LIVE) to stdout;
# resurrect-restore.sh, running in a plain non-popup context, does the
# actual file swap and restore.sh handoff after this popup has closed.
set -euo pipefail

resurrect_dir="$(tmux show-options -gqv @resurrect-dir 2>/dev/null || true)"
resurrect_dir="${resurrect_dir:-$HOME/.tmux/resurrect}"
resurrect_dir="${resurrect_dir/#\~/$HOME}"
hist_dir="$resurrect_dir/pane_contents_history"

now="$(date +%s)"

relative_age() {
	local secs=$(( now - $1 ))
	if [ "$secs" -lt 60 ]; then echo "just now"
	elif [ "$secs" -lt 3600 ]; then echo "$(( secs / 60 ))m ago"
	elif [ "$secs" -lt 86400 ]; then echo "$(( secs / 3600 ))h ago"
	else echo "$(( secs / 86400 ))d ago"
	fi
}

list_entries() {
	printf 'LIVE\tcurrent state (no snapshot swap)\n'
	[ -d "$hist_dir" ] || return 0
	for f in $(ls -t "$hist_dir"/pane_contents_*.tar.gz 2>/dev/null); do
		local base ts human epoch
		base="$(basename "$f")"
		ts="${base#pane_contents_}"
		ts="${ts%.tar.gz}"
		epoch="$(date -d "${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:9:2}:${ts:11:2}:${ts:13:2}" +%s 2>/dev/null)" || continue
		human="${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:9:2}:${ts:11:2}:${ts:13:2}"
		printf '%s\t%s (%s)\n' "$ts" "$human" "$(relative_age "$epoch")"
	done
}

# fzf exits 130 on Esc/Ctrl-C (its own docs: 0 selected, 1 no match, 130
# interrupted) - under pipefail that's the pipeline's exit status, and
# without the `|| true` here, `set -e` would abort this script right at
# this assignment on a plain cancel, before the exit-0 handling below ever
# runs. That's what actually caused the "Esc behaves weirdly" bug: this
# script died with an uncaught 130, the nested display-popup (-EE) then sat
# there waiting for a dismiss keypress since it only auto-closes on a clean
# exit, and once dismissed resurrect-restore.sh inherited that same 130
# under its own set -e and run-shell surfaced its generic error overlay -
# none of which was an actual failure, just an uncancelled cancel.
selection="$(list_entries | fzf --delimiter='\t' --with-nth=2 --prompt='restore snapshot > ' --header='Enter to restore, Esc to cancel')" || true
[ -n "$selection" ] || exit 0

printf '%s\n' "$(printf '%s' "$selection" | cut -f1)"
