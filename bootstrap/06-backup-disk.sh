#!/usr/bin/env bash
# Phase 6: the USB hard drive on bc250-2 that holds the restic repositories. Run this once per
# drive or board, before 06-backup-dirs.sh.
#
#   scp bootstrap/06-backup-disk.sh bc250-2:/tmp/
#   ssh bc250-2 bash /tmp/06-backup-disk.sh /dev/disk/by-id/usb-Seagate_Portable_NT3GDPTE-0:0
#
# Takes the whole disk by its stable /dev/disk/by-id name (sdX letters can change between boots).
# ERASES the disk: one GPT partition, XFS labelled "media". Re-running on a disk that already has
# that filesystem formats nothing; it only makes sure of the fstab entry and the mount.
#
# The drive is mounted at /srv/hdd with `nofail`, so a missing drive doesn't stop the board
# booting. The empty mount point underneath is made immutable: while the drive is absent nothing
# can create folders under /srv/hdd on the NVMe, so pods using it (hostPath, type Directory)
# wait instead of starting against an empty disk or filling the root disk.
set -euo pipefail

readonly DISK=${1:?usage: 06-backup-disk.sh /dev/disk/by-id/<whole disk>}
readonly MOUNT_POINT=/srv/hdd
readonly LABEL=media

step() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ $(lsblk -dno TYPE "$DISK") == disk ]] || die "$DISK is not a whole disk"

partition=$(lsblk -lnpo NAME,TYPE "$DISK" | awk '$2 == "part" {print $1}' | head -n 1)
existing_label=""
[[ -n $partition ]] && existing_label=$(sudo blkid -s LABEL -o value "$partition" || true)
existing_type=""
[[ -n $partition ]] && existing_type=$(sudo blkid -s TYPE -o value "$partition" || true)

if [[ $existing_type == xfs && $existing_label == "$LABEL" ]]; then
  step "$partition is already XFS '$LABEL'; not formatting"
else
  if lsblk -no MOUNTPOINTS "$DISK" | grep -q .; then
    die "$DISK has a mounted filesystem; unmount it first"
  fi
  step "Erasing $DISK: one GPT partition, XFS '$LABEL'"
  sudo wipefs --all "$DISK"
  sudo parted --script "$DISK" mklabel gpt mkpart "$LABEL" xfs 1MiB 100%
  sudo udevadm settle
  partition=$(lsblk -lnpo NAME,TYPE "$DISK" | awk '$2 == "part" {print $1}' | head -n 1)
  sudo mkfs.xfs -L "$LABEL" "$partition"
fi

uuid=$(sudo blkid -s UUID -o value "$partition")

step "Mount point $MOUNT_POINT (immutable while the drive is absent)"
if ! mountpoint -q "$MOUNT_POINT"; then
  sudo install -d -m 0755 "$MOUNT_POINT"
  sudo chattr +i "$MOUNT_POINT"
fi

step "fstab entry"
# nofail: boot carries on without the drive; the device timeout keeps that wait short.
fstab_line="UUID=$uuid $MOUNT_POINT xfs defaults,nofail,x-systemd.device-timeout=30s 0 0"
if ! grep -q "^UUID=$uuid " /etc/fstab; then
  echo "$fstab_line" | sudo tee -a /etc/fstab >/dev/null
  sudo systemctl daemon-reload
fi
grep "^UUID=$uuid " /etc/fstab

step "Mount"
mountpoint -q "$MOUNT_POINT" || sudo mount "$MOUNT_POINT"
findmnt "$MOUNT_POINT"
df -h "$MOUNT_POINT"
echo
echo "Next: bootstrap/06-backup-dirs.sh creates the restic folder in $MOUNT_POINT."
