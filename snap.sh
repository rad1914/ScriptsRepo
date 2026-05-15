#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '\n==> %s\n' "$1"
}

require_root_mount() {
  local fs
  fs="$(findmnt -no FSTYPE /)"

  if [[ "$fs" != "btrfs" ]]; then
    echo "ERROR: Root filesystem is not BTRFS."
    exit 1
  fi
}

log "Validating BTRFS root..."
require_root_mount

log "Installing snapshot stack..."
sudo pacman -S --needed --noconfirm \
  snapper \
  snap-pac \
  grub-btrfs \
  inotify-tools \
  btrfs-progs

log "Detecting root device..."
ROOT_DEV="$(findmnt -no SOURCE /)"
ROOT_UUID="$(blkid -s UUID -o value "$ROOT_DEV")"

echo "Root Device: $ROOT_DEV"
echo "Root UUID:   $ROOT_UUID"

TMP_MOUNT="/mnt/btrfs-root"

log "Preparing temporary mount..."
sudo mkdir -p "$TMP_MOUNT"

if mountpoint -q "$TMP_MOUNT"; then
  sudo umount "$TMP_MOUNT"
fi

log "Mounting top-level BTRFS subvolume..."
sudo mount -o subvolid=5 "$ROOT_DEV" "$TMP_MOUNT"

cleanup() {
  sudo umount "$TMP_MOUNT" 2>/dev/null || true
}
trap cleanup EXIT

log "Creating @snapshots subvolume if missing..."
if ! sudo btrfs subvolume list "$TMP_MOUNT" | grep -q 'path @snapshots$'; then
  sudo btrfs subvolume create "$TMP_MOUNT/@snapshots"
else
  echo "@snapshots already exists."
fi

log "Preparing /.snapshots mountpoint..."

if mountpoint -q /.snapshots; then
  sudo umount /.snapshots
fi

sudo rm -rf /.snapshots
sudo mkdir -p /.snapshots

log "Adding @snapshots to fstab if missing..."

FSTAB_LINE="UUID=$ROOT_UUID /.snapshots btrfs subvol=@snapshots,compress=zstd,noatime 0 0"

if ! grep -q 'subvol=@snapshots' /etc/fstab; then
  echo "$FSTAB_LINE" | sudo tee -a /etc/fstab >/dev/null
else
  echo "fstab entry already exists."
fi

log "Mounting /.snapshots..."
sudo mount /.snapshots

log "Removing old snapper config if present..."
if sudo snapper list-configs | awk '{print $1}' | grep -qx root; then
  sudo snapper -c root delete-config || true
fi

log "Creating snapper config..."
sudo snapper -c root create-config /

log "Re-mounting dedicated @snapshots subvolume..."

sudo umount /.snapshots

sudo rm -rf /.snapshots
sudo mkdir -p /.snapshots

sudo mount /.snapshots

log "Fixing permissions..."
sudo chmod 750 /.snapshots

log "Enabling snapper timers..."
sudo systemctl enable --now snapper-timeline.timer
sudo systemctl enable --now snapper-cleanup.timer

log "Enabling grub-btrfs daemon..."
sudo systemctl enable --now grub-btrfsd

log "Regenerating GRUB menu..."
sudo grub-mkconfig -o /boot/grub/grub.cfg

log "Creating initial snapshot..."
sudo snapper -c root create \
  --description "Initial clean snapshot"

log "Installed snapshots:"
sudo snapper list

echo
echo "Done."
echo "Pacman transactions now auto-create snapshots."
echo "GRUB can boot snapshots."
echo "Rollback support enabled."
