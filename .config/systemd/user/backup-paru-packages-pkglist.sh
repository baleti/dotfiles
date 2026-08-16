#!/usr/bin/sh
# Uploads today's paru package list, then thins older backups so each
# age bucket below keeps only its newest snapshot.
set -e

dest="gdrive-crypt:backups/paru-packages-host3"
today=$(date +%Y-%m-%d)

paru -Qen | rclone rcat "$dest/pkglist-$today.txt"
paru -Qem | rclone rcat "$dest/pkglist_aur-$today.txt"

set +e
for range in 2:4 5:7 8:10 11:14 15:20 21:25 26:50 51:100 101:200 201:500; do
    min=${range%:*}d
    max=${range#*:}d
    rclone lsf "$dest" --min-age "$min" --max-age "$max" \
        | head -n -1 \
        | xargs -I{} rclone delete "$dest/{}"
done
