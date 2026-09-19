#!/bin/sh
# Weekly: bundle the credentials needed to reach the restic repo from a blank
# machine (rclone.conf holds the gdrive-crypt passwords; restic password files)
# and upload them to Drive, encrypted to the pass key.
#
# Encrypting needs only the PUBLIC key, so this runs unattended whether the pass
# coffin is open or closed and never touches the smartcard. Decrypting needs the
# card:  rclone cat gdrive:password-store/recovery/<file> | gpg -d | tar x -C <dir>
set -eu

dest="gdrive:password-store/recovery"
stamp="$HOME/.local/state/backup-recovery-secrets.stamp"
recipient=$(cat "$HOME/.password-store/.gpg-id")

mkdir -p "$(dirname "$stamp")"
# weekly gate: the unit fires daily, upload only if the last success is 7+ days old
if [ -f "$stamp" ] && [ -z "$(find "$stamp" -mtime +6 2>/dev/null)" ]; then
    exit 0
fi

tmp=$(mktemp "${XDG_RUNTIME_DIR:-/tmp}/recovery-secrets.XXXXXX")
trap 'rm -f "$tmp"' EXIT

cd "$HOME"
tar -c .config/rclone/rclone.conf .config/restic \
    | gpg --batch --yes --quiet --no-encrypt-to -e -r "$recipient" -o "$tmp"

[ -s "$tmp" ] || { echo "empty bundle, aborting" >&2; exit 1; }
name="recovery-$(date +%Y-%m-%d).tar.gpg"
rclone copyto "$tmp" "$dest/$name"
[ "$(rclone size --json "$dest/$name" | sed -n 's/.*"bytes":\([0-9]*\).*/\1/p')" = "$(wc -c < "$tmp")" ] \
    || { echo "uploaded size mismatch" >&2; exit 1; }

# Thin old copies (files are ~2 KB, so this is generous): keep the newest 8,
# the newest of each month for 24 months, and the newest of each year forever.
# Only names matching recovery-YYYY-MM-DD.tar.gpg are ever considered.
cutoff=$(date -d '24 months ago' +%Y-%m)
rclone lsf "$dest" --files-only \
    | grep -E '^recovery-[0-9]{4}-[0-9]{2}-[0-9]{2}\.tar\.gpg$' | sort -r \
    | awk -v cutoff="$cutoff" '
        { y = substr($0, 10, 4); m = substr($0, 10, 7)
          keep = (NR <= 8) || (m >= cutoff && !(m in sm)) || !(y in sy)
          sm[m] = 1; sy[y] = 1
          if (!keep) print }' \
    | while read -r f; do rclone deletefile "$dest/$f"; done
touch "$stamp"
