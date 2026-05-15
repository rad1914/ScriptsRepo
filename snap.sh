#!/usr/bin/env bash
set -euo pipefail

echo "==> Installing snapper stack..."
sudo pacman -S --needed --noconfirm \
  snapper \
  snap-pac \
  grub-btrfs \
  inotify-tools \
  btrfs-progs

echo "==> Detecting BTRFS root device..."
ROOT_DEV="$(findmnt -no SOURCE /)"
ROOT_UUID="$(blkid -s UUID -o value "$ROOT_DEV")"

echo "Root Device: $ROOT_DEV"
echo "Root UUID:   $ROOT_UUID"

echo "==> Preparing /.snapshots subvolume..."

sudo umount /.snapshots 2>/dev/null || true
sudo rm -rf /.snapshots

sudo mkdir -p /mnt/btrfs-root
sudo mount -o subvolid=5 "$ROOT_DEV" /mnt/btrfs-root

if ! sudo btrfs subvolume list /mnt/btrfs-root | grep -q "@snapshots"; then
  sudo btrfs subvolume create /mnt/btrfs-root/@snapshots
fi

sudo umount /mnt/btrfs-root

sudo mkdir -p /.snapshots

if ! grep -q "@snapshots" /etc/fstab; then
  echo "UUID=$ROOT_UUID /.snapshots btrfs subvol=@snapshots,compress=zstd,noatime 0 0" \
    | sudo tee -a /etc/fstab
fi

sudo mount /.snapshots

echo "==> Creating snapper config..."

sudo snapper -c root create-config /

sudo umount /.snapshots

sudo rm -rf /.snapshots

sudo mkdir /.snapshots

sudo mount /.snapshots

echo "==> Fixing permissions..."
sudo chmod 750 /.snapshots

echo "==> Enabling automatic snapshots..."
sudo systemctl enable --now snapper-timeline.timer
sudo systemctl enable --now snapper-cleanup.timer

echo "==> Enabling grub-btrfs..."
sudo systemctl enable --now grub-btrfsd

echo "==> Regenerating GRUB..."
sudo grub-mkconfig -o /boot/grub/grub.cfg

echo "==> Creating initial snapshot..."
sudo snapper -c root create --description "Initial clean snapshot"

echo
echo "Done."
echo "Pacman transactions now auto-create snapshots."
echo "GRUB menu will show bootable snapshots."
