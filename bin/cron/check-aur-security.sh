#!/bin/sh
# AUR supply-chain check, every 4 days:
#   1. Deterministically diffs every installed AUR package's current PKGBUILD
#      against the last one this script saw (aur-pkgbuild-diff.py). A package
#      with no prior snapshot - whether or not it has a pending update - gets
#      its full current PKGBUILD queued for a from-scratch review: nothing is
#      presumed safe just because it predates this check or isn't due for an
#      update. This is the actual attack surface: the file that gets sourced
#      and executed on this machine.
#   2. Hands those diff/review files (if any) to a headless Claude Code run
#      to judge for supply-chain red flags, plus a lighter cross-check of
#      installed package names against known AUR compromise incidents in the
#      news (catches things reported after the fact, not via PKGBUILD change).
#   3. Emails baleti3266@gmail.com if ANYTHING looks suspicious, in either the
#      current installed state or a future change - not just new updates.
#   4. Emails baleti3266@gmail.com if the check ITSELF fails to run (e.g. the
#      claude binary not on PATH, a crash in the python helper, network
#      down) - a silent failure here means packages go unreviewed with no
#      visible gap, which is worse than a false negative from the review
#      itself (see the 2026-09-06 PATH incident this is modeled on).
set -eu

STATEDIR="$HOME/.local/share/aur-security-check"
LOGDIR="$STATEDIR/logs"
DIFFDIR="$STATEDIR/pending-diffs"
MAILBIN="/home/user1/.config/claude-email/mail"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/$(date +%Y-%m-%d_%H%M%S).log"

on_failure() {
  rc=$?
  line=$1
  set +e
  {
    echo "=== check-aur-security.sh FAILED at line $line (exit $rc), $(date -Is) ==="
  } >>"$LOGFILE" 2>&1
  tail_output=$(tail -n 60 "$LOGFILE" 2>/dev/null)
  "$MAILBIN" send --to baleti3266@gmail.com \
    --subject "AUR security check FAILED to run ($(date +%Y-%m-%d))" \
    --body "The check-aur-security.sh cron job itself failed (exit $rc) at line $line, $(date -Is) - this is separate from a package being flagged suspicious.

This means AUR packages were NOT reviewed this cycle. Treat their state as unreviewed/unknown, not clean, until a run succeeds - check manually if this recurs.

Log file: $LOGFILE

Last 60 lines of the log:
$tail_output" >>"$LOGFILE" 2>&1
  exit "$rc"
}
trap 'on_failure $LINENO' ERR

{
  echo "=== deterministic PKGBUILD diff pass ==="
  python3 /home/user1/bin/cron/aur-pkgbuild-diff.py
} >>"$LOGFILE" 2>&1

PROMPT=$(cat <<EOF
You are running unattended as a cron job on an Arch Linux system, doing an
AUR supply-chain security check. The most important part of this job has
already run deterministically: $STATEDIR/pending-diffs/ contains one file per
installed AUR package that needs review - either a real diff against the
last PKGBUILD this script saw, or (marked "NO PRIOR SNAPSHOT") the full
current PKGBUILD because this script has never reviewed that package before.
If that directory is empty, nothing needs review this run - skip straight to
step 2.

Treat the "NO PRIOR SNAPSHOT" files as a genuine, from-scratch security
review, not a formality. Before this check existed, nobody had ever actually
inspected the PKGBUILD content of packages already installed on this
machine - only package *names* got checked against news reports. A package
being long-installed, popular, or having no news coverage is NOT evidence
it's safe; review its actual content on its own merits, the same way you
would a diff.

1. Read every file in $STATEDIR/pending-diffs/ and review each one for
   supply-chain red flags, e.g.:
   - a source= URL pointing at an unfamiliar/unofficial domain, a branch/tag
     instead of a pinned commit/release, or anything that doesn't match the
     project's real upstream
   - sha256sums/b2sums changed without a corresponding pkgver/pkgrel bump (if
     reviewing a diff)
   - injected or obfuscated code in prepare()/build()/check()/package()/
     pkgver() - piping curl/wget into sh/bash, base64 decode+eval, fetching
     and executing a second-stage payload, writing to paths outside the
     package build dir, anything that looks deliberately hard to read
   - a post-install/post-upgrade hook doing anything beyond normal package
     setup
   - maintainer identity combined with a suspicious content change (a
     maintainer name alone, with otherwise unremarkable content, is not
     worth flagging on its own)
   Flag anything that meets this bar, whether it came from a diff or a
   first-time full review of an already-installed package.
2. Separately (lower priority, quick pass): run \`pacman -Qm\` to list all
   installed AUR packages and do a couple of targeted WebSearch queries for
   "AUR security incident" / "AUR malware" news from roughly the last 2-3
   weeks, to catch anything reported via AUR comments or security
   researcher writeups rather than a PKGBUILD change (e.g. a malicious
   binary fetched from an unpinned URL at build time, reported after the
   fact). Don't do exhaustive per-package research once a couple of
   searches turn up nothing new.
3. If you find credible evidence - from step 1 or step 2 - that an
   installed or about-to-be-updated package is compromised, malicious, or
   suspicious, send exactly one alert email using the exact command below
   (this literal path is pre-approved for unattended use - do not substitute
   "~" for \$HOME, a tilde won't match the pre-approved command and will hang
   waiting for an approval that will never come since this runs unattended):
     /home/user1/.config/claude-email/mail send --to baleti3266@gmail.com \\
       --subject "AUR Security Alert: <affected package name(s)>" \\
       --body "<plain text: which package(s), what specifically looked
       wrong (quote the relevant diff lines if from step 1), source URL(s)
       as evidence if from step 2, and recommended action - e.g. hold back
       this update, remove the package, or compare checksums by hand>"
4. If nothing suspicious is found, do NOT send an email - just print a
   one-line summary of what was reviewed and exit clean.
EOF
)

CLAUDE_CONFIG_DIR="$HOME/.claude3" claude -p "$PROMPT" \
  --model claude-sonnet-5 \
  --allowedTools "Read($STATEDIR/**) Bash(pacman -Qm) WebSearch WebFetch Bash(/home/user1/.config/claude-email/mail *)" \
  --no-session-persistence \
  >> "$LOGFILE" 2>&1
