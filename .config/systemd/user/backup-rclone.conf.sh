#!/bin/sh
# Checked daily, uploaded only when something changed: bundle the credentials
# needed to reach the restic repo from a blank machine (rclone.conf holds the
# gdrive-crypt passwords; plus the restic password files) and upload them to
# Drive, encrypted to the pass key.
#
# Encrypting needs only the PUBLIC key, so this runs unattended whether the pass
# coffin is open or closed and never touches the smartcard. Decrypting needs the
# card:  rclone cat gdrive:password-store/rclone.conf-incrementals/<file> | gpg -d | tar x -C <dir>
set -eu

dest="gdrive:password-store/rclone.conf-incrementals"
hashfile="$HOME/.local/state/backup-rclone.conf.sha256"
recipient=$(cat "$HOME/.password-store/.gpg-id")

mkdir -p "$(dirname "$hashfile")"
cd "$HOME"

# The bundle is encrypted (random session key each time), so compare a checksum of
# the PLAINTEXT instead. rclone rewrites its OAuth "token =" lines on every refresh;
# those are excluded so only real changes (remotes, crypt passwords, restic
# passwords) trigger an upload. A stale token is harmless: the refresh token lives on.
current=$( { grep -v '^token = ' .config/rclone/rclone.conf; cat .config/restic/*; } | sha256sum | cut -d' ' -f1)
if [ -f "$hashfile" ] && [ "$(cat "$hashfile")" = "$current" ]; then
    exit 0
fi

tmp=$(mktemp "${XDG_RUNTIME_DIR:-/tmp}/rclone.conf-backup.XXXXXX")
trap 'rm -f "$tmp"' EXIT

tar -c .config/rclone/rclone.conf .config/restic \
    | gpg --batch --yes --quiet --no-encrypt-to -e -r "$recipient" -o "$tmp"

[ -s "$tmp" ] || { echo "empty bundle, aborting" >&2; exit 1; }
name="rclone.conf-$(date +%Y-%m-%dT%H%M%S).tar.gpg"
rclone copyto "$tmp" "$dest/$name"
[ "$(rclone size --json "$dest/$name" | sed -n 's/.*"bytes":\([0-9]*\).*/\1/p')" = "$(wc -c < "$tmp")" ] \
    || { echo "uploaded size mismatch" >&2; exit 1; }

# Thin old copies (files are ~2 KB, so this is generous): keep the newest 8,
# the newest of each month for 24 months, and the newest of each year forever.
# Only names matching rclone.conf-YYYY-MM-DD[THHMMSS].tar.gpg are ever considered.
cutoff=$(date -d '24 months ago' +%Y-%m)
rclone lsf "$dest" --files-only \
    | grep -E '^rclone\.conf-[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{6})?\.tar\.gpg$' | sort -r \
    | awk -v cutoff="$cutoff" '
        { y = substr($0, 13, 4); m = substr($0, 13, 7)
          keep = (NR <= 8) || (m >= cutoff && !(m in sm)) || !(y in sy)
          sm[m] = 1; sy[y] = 1
          if (!keep) print }' \
    | while read -r f; do rclone deletefile "$dest/$f"; done
printf %s "$current" > "$hashfile"
