#!/bin/sh
# self-healing tmux-resurrect/tmux-continuum checkout, no TPM required:
# clone on first run, refresh at most every 3 days in the background so
# tmux server startup never blocks on git

plugins_dir="$HOME/.config/tmux/plugins"

clone_if_missing() {
  repo="$1"
  entry="$2"
  dir="$plugins_dir/$repo"
  [ -f "$dir/$entry" ] || git clone --quiet --depth 1 "https://github.com/tmux-plugins/$repo" "$dir"
}

clone_if_missing tmux-resurrect resurrect.tmux
clone_if_missing tmux-continuum continuum.tmux

for repo in tmux-resurrect tmux-continuum; do
  fetch_head="$plugins_dir/$repo/.git/FETCH_HEAD"
  mtime=$(stat -c %Y "$fetch_head" 2>/dev/null || echo 0)
  if [ $(( $(date +%s) - mtime )) -gt $(( 3 * 24 * 60 * 60 )) ]; then
    touch "$fetch_head" 2>/dev/null
    ( cd "$plugins_dir/$repo" && git pull --quiet ) >/dev/null 2>&1 &
  fi
done
