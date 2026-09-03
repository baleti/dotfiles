#!/usr/bin/env bash
# Build the multi-branch docs site and publish it to the orphan `gh-pages`
# branch of the dotfiles repo, served at https://baleti.github.io/dotfiles/ .
#
# build.py reads every machine branch's .config/docs/ from throwaway
# `git worktree`s, so this fetches current origin/<branch> refs first. The
# gh-pages branch is force-pushed from a throwaway git repo inside ./site/ -
# it is NEVER checked out in the live $HOME worktree.
#
#   ./deploy.sh                fetch + build + push
#   ./deploy.sh --if-changed   skip entirely if no doc source changed since
#                              the last deploy (used by the systemd timer);
#                              also treats "offline" as a no-op, not a failure
#   ./deploy.sh --setup        also (re)point GitHub Pages at the gh-pages branch
set -euo pipefail
cd "$(dirname "$0")"

REMOTE="${DOCS_REMOTE:-git@github.com:baleti/dotfiles.git}"
BRANCH="gh-pages"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles-docs-deploy.fingerprint"
SETUP=0
IF_CHANGED=0
for arg in "$@"; do
  case "$arg" in
    --setup)      SETUP=1 ;;
    --if-changed) IF_CHANGED=1 ;;
    *) echo "deploy.sh: unknown arg $arg" >&2; exit 2 ;;
  esac
done

# Serialize deploys: build.py wipes and rebuilds ./site/ from scratch, so a
# manual run overlapping the hourly timer races rmtree against read_text and
# crashes mid-build. The timer's --if-changed run bows out; a manual run waits.
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/dotfiles-docs-deploy.lock"
if [[ "$IF_CHANGED" == 1 ]]; then
  flock -n 9 || { echo "deploy.sh: another deploy is running - nothing to do"; exit 0; }
else
  flock -w 600 9 || { echo "deploy.sh: timed out waiting for another deploy to finish" >&2; exit 1; }
fi

if ! git fetch -q origin 2>/dev/null; then
  if [[ "$IF_CHANGED" == 1 ]]; then
    echo "deploy.sh: git fetch failed (offline?) - nothing to do"
    exit 0
  fi
  echo "deploy.sh: git fetch failed" >&2
  exit 1
fi

FP="$(./build.py --fingerprint)"
if [[ "$IF_CHANGED" == 1 && -f "$STATE" && "$(cat "$STATE")" == "$FP" ]]; then
  echo "deploy.sh: no doc changes since last deploy - nothing to do"
  exit 0
fi

./build.py

name="$(git config user.name  || echo 'docs deploy')"
email="$(git config user.email || echo 'docs@localhost')"
# The dotfiles repo pins a deploy key via a repo-local core.sshCommand; the
# throwaway repo below won't inherit it, so carry it over (expand a leading ~).
ssh_cmd="$(git config core.sshCommand || true)"
ssh_cmd="${ssh_cmd/#\~\//$HOME/}"
ssh_cmd="${ssh_cmd//-i \~\//-i $HOME/}"

(
  cd site
  rm -rf .git
  git init -q
  [[ -n "$ssh_cmd" ]] && git config core.sshCommand "$ssh_cmd"
  git checkout -q -b "$BRANCH"
  git add -A
  git -c user.name="$name" -c user.email="$email" \
      commit -qm "Deploy docs site $(date -u +%FT%TZ)"
  git push -f -q "$REMOTE" "$BRANCH"
  rm -rf .git
)

mkdir -p "$(dirname "$STATE")"
printf '%s\n' "$FP" > "$STATE"
echo "deploy.sh: pushed $BRANCH -> $REMOTE"

if [[ "$SETUP" == 1 ]]; then
  if command -v gh >/dev/null; then
    gh api -X POST "repos/baleti/dotfiles/pages" \
      -f "source[branch]=$BRANCH" -f "source[path]=/" 2>/dev/null \
    || gh api -X PUT "repos/baleti/dotfiles/pages" \
         -f "source[branch]=$BRANCH" -f "source[path]=/" \
    || echo "deploy.sh: could not configure Pages via gh (set it in repo Settings > Pages)"
    echo "deploy.sh: Pages configured (branch=$BRANCH, path=/)"
  else
    echo "deploy.sh: gh CLI not found - enable Pages manually (Settings > Pages, branch gh-pages, / root)"
  fi
fi

echo "deploy.sh: live at https://baleti.github.io/dotfiles/ (first publish can take ~1 min)"
