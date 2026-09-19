#!/usr/bin/env sh
# Fail loudly instead of quietly operating on wrong paths (e.g. "/.cache/...") if this
# is ever run from a stripped environment. Cronie's PAM session sets HOME normally.
: "${HOME:?HOME not set}"
# ~/.cache is excluded wholesale (rebuildable, and its own btrfs subvolume), so the small
# service state files that live there are listed as explicit FILE targets (a file or glob-expanded
# file is never excluded, but everything inside a directory target would be, hence the globs).
# The /etc paths are the hand-picked, world-readable system config worth keeping (root-only
# ones like /etc/wireguard and NetworkManager connections would need a root job). Only the
# custom systemd units are listed (not the whole dir), and no dracut config: it is stock.
# Thunderbird's ImapMail is only a re-downloadable IMAP cache (16 GB, churns constantly);
# its Mail/ folder (Local Folders, old office365 mail) and Evolution's mail/local are REAL
# local mail and stay backed up.
# NOT included on purpose: cliphist (clipboard history, has its own expiry timer), rssd/media,
# newsdigest-server models/tts-cache, notifyd (ephemeral), all build/tool caches.
restic backup \
    "$HOME" \
    "$HOME/music/host3" \
    "$HOME/notes" \
    /var/spool/cron \
    "$HOME/gdrive/part 3" \
    "$HOME/.cache/rssd/items.jsonl" \
    "$HOME/.cache/rssd/seen.json" \
    "$HOME/.cache/rssd/read.json" \
    "$HOME/.cache/claude-usage/state.json" \
    "$HOME"/.cache/newsdigest/*.jsonl \
    "$HOME"/.cache/newsdigest/cursors/* \
    "$HOME"/.cache/newsdigest-server/digest/*.json \
    "$HOME/.cache/quickshell/launcher-history.json" \
    "$HOME/.cache/quickshell/launcher-query-history.json" \
    "$HOME/.cache/quickshell/winswitch-query-history.json" \
    "$HOME/.cache/tmux-focus-picker-history" \
    "$HOME/.cache/claude-history-query-history" \
    /etc/fstab \
    /etc/pacman.conf \
    /etc/systemd/system/paccache.service \
    /etc/systemd/system/paccache.timer \
    /etc/systemd/system/ssd-health-check.service \
    /etc/systemd/system/ssd-health-check.timer \
    /etc/systemd/system/win10-off-virtual-keyboard.service \
    /etc/ssh/sshd_config \
    /etc/ssh/sshd_config.d \
    /etc/fuse.conf \
    /etc/default/grub \
    /etc/hosts \
    /etc/environment \
    /etc/udev/rules.d \
    /etc/modprobe.d \
    /etc/firewalld/zones/wgtunnel.xml \
    --exclude "$HOME/.cache" \
    --exclude "$HOME/.pyenv" \
    --exclude "$HOME/src" \
    --exclude "$HOME/temp" \
    --exclude "$HOME/Downloads" \
    --exclude "$HOME/virtual-machines" \
    --exclude "$HOME/.local/share/fsearch" \
    --exclude "$HOME/.thunderbird/*/ImapMail" \
    --one-file-system \
    --repo rclone:gdrive:backups/host3-restic \
    --password-file="$HOME/.config/restic/password-file-host3" \
    --tag systemd.timer

# forget only (no --prune): cheap metadata-only op, safe to run every cycle. It retires
# the snapshot list on schedule; the data behind aged-out snapshots isn't actually
# reclaimed until the weekly backup-restic-prune.sh runs. See that script for why
# --prune is split out (restic's own advice: forget often, prune rarely - it repacks
# data and is heavy on a remote/rclone backend).
systemctl stop --user mount-backup-host3.service

restic unlock --repo rclone:gdrive:backups/host3-restic \
    --password-file="$HOME/.config/restic/password-file-host3"

restic forget --tag systemd.timer \
    --keep-daily 7 --keep-weekly 3 --keep-monthly 6 --keep-yearly 10 \
    --repo rclone:gdrive:backups/host3-restic \
    --password-file="$HOME/.config/restic/password-file-host3"

sleep 10
systemctl start --user mount-backup-host3.service --no-block
