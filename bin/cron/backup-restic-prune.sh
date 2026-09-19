#!/usr/bin/env sh
# Weekly companion to backup-restic-gdrive.sh: that script runs `forget` (cheap,
# metadata-only) on every 12h backup, but leaves the actual data reclaim to this
# script. `prune` has to load the full index, work out which blobs are still
# referenced, then download/decrypt/repack/re-upload anything only partially used -
# expensive, and doubly so over rclone/Drive (bandwidth + API quota). Measured on
# this repo (2026-09-19, 137 snapshots): a prune repacked 456 MiB to reclaim 37 MiB -
# not worth paying twice a day for.
: "${HOME:?HOME not set}"

systemctl stop --user mount-backup-host3.service

restic unlock --repo rclone:gdrive:backups/host3-restic \
    --password-file="$HOME/.config/restic/password-file-host3"

restic prune --repo rclone:gdrive:backups/host3-restic \
    --password-file="$HOME/.config/restic/password-file-host3"

sleep 10
systemctl start --user mount-backup-host3.service --no-block
