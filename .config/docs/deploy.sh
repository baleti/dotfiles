#!/usr/bin/env bash
# Build the docs site (build.py) and publish it to the `gh-pages` branch of
# the dotfiles repo, which GitHub Pages serves at:
#
#     https://baleti.github.io/dotfiles/
#
# The gh-pages branch is an orphan holding ONLY the generated site. This
# script never checks it out in the live $HOME worktree - it builds a
# throwaway git repo inside ./site/ and force-pushes that. Safe to run from
# anywhere; touches neither the working tree nor the current branch.
#
#   ./deploy.sh            build + push
#   ./deploy.sh --setup    also (re)enable GitHub Pages on the gh-pages branch
set -euo pipefail
cd "$(dirname "$0")"

REMOTE="${DOCS_REMOTE:-git@github.com:baleti/dotfiles.git}"
BRANCH="gh-pages"
SETUP=0
[[ "${1:-}" == "--setup" ]] && SETUP=1

./build.py

name="$(git config user.name  || echo 'docs deploy')"
email="$(git config user.email || echo 'docs@localhost')"
# The dotfiles repo pins a specific deploy key via core.sshCommand; the
# throwaway repo below won't inherit it, so carry it over explicitly.
ssh_cmd="$(git config core.sshCommand || true)"

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
