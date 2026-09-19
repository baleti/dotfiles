#!/usr/bin/env sh
# ~/.cache is excluded wholesale (rebuildable, and its own btrfs subvolume), so the small
# service state files that live there are listed as explicit FILE targets (a file or glob-expanded
# file is never excluded, but everything inside a directory target would be, hence the globs).
# NOT included on purpose: cliphist (clipboard history, has its own expiry timer), rssd/media,
# newsdigest-server models/tts-cache, notifyd (ephemeral), all build/tool caches.
restic backup \
    /home/user1 \
    /home/user1/music/host3 \
    /home/user1/notes \
    /var/spool/cron \
    "/home/user1/gdrive/part 3" \
    /home/user1/.cache/rssd/items.jsonl \
    /home/user1/.cache/rssd/seen.json \
    /home/user1/.cache/rssd/read.json \
    /home/user1/.cache/claude-usage/state.json \
    /home/user1/.cache/newsdigest/*.jsonl \
    /home/user1/.cache/newsdigest/cursors/* \
    /home/user1/.cache/newsdigest-server/digest/*.json \
    /home/user1/.cache/quickshell/launcher-history.json \
    /home/user1/.cache/quickshell/launcher-query-history.json \
    /home/user1/.cache/quickshell/winswitch-query-history.json \
    /home/user1/.cache/tmux-focus-picker-history \
    /home/user1/.cache/claude-history-query-history \
    --exclude /home/user1/.cache \
    --exclude /home/user1/.pyenv \
    --exclude /home/user1/src \
    --exclude /home/user1/temp \
    --exclude /home/user1/Downloads \
    --exclude /home/user1/virtual-machines \
    --exclude /home/user1/.local/share/fsearch \
    --one-file-system \
    --repo rclone:gdrive:backups/host3-restic \
    --password-file=/home/user1/.config/restic/password-file-host3 \
    --tag systemd.timer

systemctl stop --user mount-backup-host3.service

restic unlock --repo rclone:gdrive:backups/host3-restic \
    --password-file=/home/user1/.config/restic/password-file-host3

restic forget --tag systemd.timer \
    --keep-daily 7 --keep-weekly 3 --keep-monthly 6 --keep-yearly 10 \
    --prune --repo rclone:gdrive:backups/host3-restic \
    --password-file=/home/user1/.config/restic/password-file-host3

sleep 10
systemctl start --user mount-backup-host3.service --no-block
