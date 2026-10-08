#!/bin/sh
# Deterministic half of the whatsmeow supply-chain check (run by
# check-aur-security.sh before the headless review).
#
# whatsmeow is a Go library compiled into ~/bin/wa, not an AUR package, so the
# PKGBUILD diff pass never sees it. This mirrors upstream, picks a CANDIDATE
# commit (newest commit at least $MIN_AGE_DAYS old, so the community has had
# time to spot a bad push), and writes into $WM/pending/:
#   whatsmeow.diff  reviewed..candidate, generated *.pb.go excluded
#   meta.txt        commits, authors, ancestry, vanity-import host check
#   candidate       the candidate commit (12 hex), used for the marker
# $WM/reviewed-ok holds the last commit the review judged CLEAN; wa's updater
# (bin/wa/update.sh) will only ever install that exact commit.
# Baseline on first run is the commit currently pinned in bin/wa/go.mod.
set -eu

STATEDIR="$HOME/.local/share/aur-security-check"
WM="$STATEDIR/whatsmeow"
MIRROR="$WM/whatsmeow.git"
OUT="$WM/pending"
MIN_AGE_DAYS=3
REPO=https://github.com/tulir/whatsmeow

mkdir -p "$WM"
rm -rf "$OUT"
mkdir -p "$OUT"

if [ -d "$MIRROR" ]; then
  git -C "$MIRROR" fetch --quiet --prune --force origin '+refs/heads/*:refs/heads/*'
else
  git clone --quiet --mirror "$REPO" "$MIRROR"
fi

pinned=$(cd "$HOME/bin/wa" && go list -m -f '{{.Version}}' go.mau.fi/whatsmeow | sed 's/.*-//' | cut -c1-12)
reviewed=$(cat "$WM/reviewed-ok" 2>/dev/null || echo "$pinned")
candidate=$(git -C "$MIRROR" rev-list -1 --before="$MIN_AGE_DAYS days ago" HEAD | cut -c1-12)
[ -n "$candidate" ] || { echo "no candidate commit older than $MIN_AGE_DAYS days"; exit 1; }
echo "$candidate" > "$OUT/candidate"

# candidate == baseline, or baseline already ahead of the (age-gated) candidate
if [ "$candidate" = "$reviewed" ] || git -C "$MIRROR" merge-base --is-ancestor "$candidate" "$reviewed" 2>/dev/null; then
  echo "nothing to review: baseline $reviewed is at or ahead of candidate $candidate" > "$OUT/nothing-to-review"
  exit 0
fi

if git -C "$MIRROR" merge-base --is-ancestor "$reviewed" "$candidate" 2>/dev/null; then
  ancestry="yes (normal fast-forward history)"
else
  ancestry="NO - reviewed commit is not an ancestor of the candidate (history rewritten or force-pushed?)"
fi

{
  echo "reviewed baseline: $reviewed"
  echo "candidate:         $candidate ($(git -C "$MIRROR" log -1 --format='%cI' "$candidate"))"
  echo "baseline is ancestor of candidate: $ancestry"
  echo "upstream repo expected: $REPO"
  echo "go.mau.fi vanity import now says:"
  curl -fsSL --max-time 20 'https://go.mau.fi/whatsmeow?go-get=1' | grep -io '<meta name="go-import"[^>]*>' || echo "  (could not fetch vanity import page)"
  echo
  echo "commits: $(git -C "$MIRROR" rev-list --count "$reviewed..$candidate" 2>/dev/null || echo '?')"
  echo "authors in range:"
  git -C "$MIRROR" log --format='%an <%ae>' "$reviewed..$candidate" 2>/dev/null | sort | uniq -c | sort -rn
  echo "authors that already appear in the 500 commits before the baseline:"
  git -C "$MIRROR" log -500 --format='%an <%ae>' "$reviewed" 2>/dev/null | sort -u | head -40
  echo
  echo "files changed (excluding generated *.pb.go):"
  git -C "$MIRROR" diff --stat "$reviewed" "$candidate" -- . ':(exclude)*.pb.go' 2>/dev/null | tail -60
  echo
  echo "go.mod / go.sum changes:"
  git -C "$MIRROR" diff "$reviewed" "$candidate" -- go.mod 2>/dev/null
  echo
  echo "commit log:"
  git -C "$MIRROR" log --format='%h %an: %s' "$reviewed..$candidate" 2>/dev/null | head -150
} > "$OUT/meta.txt"

git -C "$MIRROR" diff "$reviewed" "$candidate" -- . ':(exclude)*.pb.go' ':(exclude)go.sum' > "$OUT/whatsmeow.diff" 2>/dev/null || true
echo "prepared whatsmeow review $reviewed..$candidate ($(wc -c < "$OUT/whatsmeow.diff") bytes of diff)"
