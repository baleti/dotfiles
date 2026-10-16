#!/bin/sh
# Mount the btrfs top-level subvolume (subvolid=5) read-only at /run/btrfs-top (a normal read-only mount;
# file permissions are unchanged, and the snapshots it shows are already mounted elsewhere).
set -e
src=$(findmnt -no SOURCE -T "${FANWATCH_VOLUME:-/}")
mkdir -p /run/btrfs-top
mountpoint -q /run/btrfs-top || mount -o ro,subvolid=5 "${src%%\[*}" /run/btrfs-top
