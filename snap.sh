#!/usr/bin/env bash
set -uo pipefail

failures=0

step() {
  echo
  echo "==> $1"
}

run() {
  local desc="$1"
  shift
  if ! "$@"; then
    echo "!! Failed: $desc"
    failures=$((failures + 1))
    return 1
  fi
}

step "Installing snapper stack"
run "pacman install" sudo pacman -S --needed --noconfirm \
  snapper \
  snap-pac \
  grub-btrfs \
  inotify-tools \
  btrfs-progs

step "Detecting BTRFS root device"
ROOT_DEV="$(findmnt -no SOURCE /)" || {
  echo "!! Failed: could not detect root device"
  failures=$((failures + 1))
  ROOT_DEV=""
}
ROOT_UUID=""
if [ -n "${ROOT_DEV:-}" ]; then
  ROOT_UUID="$(blkid -s UUID -o value "$ROOT_DEV" 2>/dev/null || true)"
fi

echo "Root Device: ${ROOT_DEV:-unknown}"
echo "Root UUID:   ${ROOT_UUID:-unknown}"

if [ -z "${ROOT_DEV:-}" ] || [ -z "${ROOT_UUID:-}" ]; then
  echo "!! Skipping BTRFS setup because root device or UUID is missing"
  failures=$((failures + 1))
else
  step "Preparing /.snapshots subvolume"

  run "unmount /.snapshots" sudo umount /.snapshots 2>/dev/null || true
  run "remove /.snapshots" sudo rm -rf /.snapshots

  run "create mount point" sudo mkdir -p /mnt/btrfs-root
  run "mount subvolid=5" sudo mount -o subvolid=5 "$ROOT_DEV" /mnt/btrfs-root

  if sudo btrfs subvolume list /mnt/btrfs-root | grep -q "@snapshots"; then
    echo "==> @snapshots already exists"
  else
    run "create @snapshots subvolume" sudo btrfs subvolume create /mnt/btrfs-root/@snapshots
  fi

  run "unmount /mnt/btrfs-root" sudo umount /mnt/btrfs-root
  run "create /.snapshots directory" sudo mkdir -p /.snapshots

  if grep -q "@snapshots" /etc/fstab; then
    echo "==> fstab entry for @snapshots already present"
  else
    run "append fstab entry" bash -c \
      "echo 'UUID=$ROOT_UUID /.snapshots btrfs subvol=@snapshots,compress=zstd,noatime 0 0' | sudo tee -a /etc/fstab >/dev/null"
  fi

  run "mount /.snapshots" sudo mount /.snapshots

  step "Creating snapper config"
  if ! sudo snapper -c root create-config /; then
    echo "!! snapper create-config failed"
    failures=$((failures + 1))
  fi

  step "Fixing permissions"
  run "chmod /.snapshots" sudo chmod 750 /.snapshots

  step "Enabling automatic snapshots"
  run "enable snapper-timeline.timer" sudo systemctl enable --now snapper-timeline.timer
  run "enable snapper-cleanup.timer" sudo systemctl enable --now snapper-cleanup.timer

  step "Enabling grub-btrfs"
  run "enable grub-btrfsd" sudo systemctl enable --now grub-btrfsd

  step "Regenerating GRUB"
  run "grub-mkconfig" sudo grub-mkconfig -o /boot/grub/grub.cfg

  step "Creating initial snapshot"
  run "create initial snapshot" sudo snapper -c root create --description "Initial clean snapshot"
fi

step "Final mount sync"
run "mount -a" sudo mount -a

step "Final snapper config retry"
if ! sudo snapper -c root list >/dev/null 2>&1; then
  run "create-config retry" sudo snapper -c root create-config /
fi

step "Final service enable retry"
run "enable snapper-timeline.timer" sudo systemctl enable --now snapper-timeline.timer
run "enable snapper-cleanup.timer" sudo systemctl enable --now snapper-cleanup.timer
run "enable grub-btrfsd" sudo systemctl enable --now grub-btrfsd

step "Final GRUB regeneration retry"
run "grub-mkconfig retry" sudo grub-mkconfig -o /boot/grub/grub.cfg

step "Final snapshot retry"
run "create fresh install snapshot" sudo snapper -c root create --description "Fresh Install"

step "Listing snapshots"
run "snapper list" sudo snapper list

echo
echo "Done."
echo "Pacman transactions now auto-create snapshots."
echo "GRUB menu will show bootable snapshots."

if [ "$failures" -gt 0 ]; then
  echo "Completed with $failures failed step(s)."
  exit 1
fi
