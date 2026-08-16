#!/usr/bin/env bash
# Appends the pane a client just navigated to onto an MRU log, most-recent
# first. Invoked ONLY from tmux hooks tied to actual navigation commands
# (after-select-pane, after-select-window, after-last-window,
# client-session-changed - see .tmux.conf) - never from a pane merely
# producing output. That's the whole point: a Claude Code session churning
# in a background pane never calls select-pane, so it never lands here.
# Since every one of those commands only ever runs because a bound key or
# mouse action on an attached client triggered it, there is nothing extra to
# check for "attached" - a detached session has no client to press keys on.
set -euo pipefail

pane_id=$1
cache_dir=~/.cache
log="$cache_dir/tmux-focus-order.log"
lock="$cache_dir/tmux-focus-order.lock"
max_lines=200

mkdir -p "$cache_dir"
exec 9>"$lock"
flock 9

tmp=$(mktemp "${log}.XXXXXX")
{
  printf '%s\t%s\n' "$(date +%s)" "$pane_id"
  # drop any earlier entry for this pane (move-to-front) rather than letting
  # it accumulate duplicates further down the file. Plain `[ -f "$log" ] &&
  # awk ...` looks equivalent but isn't under `set -e`: the first run (no
  # log file yet) makes the `&&`'s left side fail, and since this whole
  # statement isn't inside an if/while, that failure aborts the script -
  # the `if` form is what actually suppresses -e for a condition check.
  if [ -f "$log" ]; then
    awk -F'\t' -v p="$pane_id" '$2 != p' "$log"
  fi
} | head -n "$max_lines" > "$tmp"
mv "$tmp" "$log"
