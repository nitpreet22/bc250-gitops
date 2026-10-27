#!/usr/bin/env bash
# Phase 6: the directories on bc250-2's USB hard drive (there is no NAS). The drive is prepared
# and mounted at /srv/hdd by 06-backup-disk.sh; run that first.
#
#   scp bootstrap/06-backup-dirs.sh bc250-2:/tmp/ && ssh bc250-2 bash /tmp/06-backup-dirs.sh
#
# Creates /srv/hdd/restic, the restic REST server's repositories (root only, like the server).
# SELinux is enforcing on the boards, so the tree gets the container_file_t label (persistently,
# through semanage) that pods need to use it.
#
# Safe to re-run: existing directories and their contents are left alone; only labels are reapplied.
set -euo pipefail

readonly DISK_MOUNT=/srv/hdd
readonly RESTIC_ROOT=$DISK_MOUNT/restic

step() { printf '\n==> %s\n' "$*"; }

# Without the drive, the folders would land on the NVMe (the root disk).
if ! mountpoint -q "$DISK_MOUNT"; then
  echo "error: $DISK_MOUNT is not mounted; plug in the drive or run 06-backup-disk.sh" >&2
  exit 1
fi

step "restic repositories: $RESTIC_ROOT"
sudo install -d -o root -g root -m 0700 "$RESTIC_ROOT"

step "SELinux label container_file_t"
if ! sudo semanage fcontext --list | grep -qF "$DISK_MOUNT(/.*)?"; then
  sudo semanage fcontext --add --type container_file_t "$DISK_MOUNT(/.*)?"
fi
sudo restorecon -R "$DISK_MOUNT"
sudo ls -dZ "$RESTIC_ROOT"
df -h "$DISK_MOUNT"
