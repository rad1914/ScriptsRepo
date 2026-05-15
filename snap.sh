#!/usr/bin/env bash

set -uo pipefail

step() {
    echo
    echo "==> $1"
}

run_step() {
    local desc="$1"
    shift

    step "$desc"

    if ! "$@"; then
        echo
        echo "ERROR: Step failed -> $desc"
        read -rp "Continue anyway? [y/N]: " ans

        case "$ans" in
            [yY]|[yY][eE][sS])
                echo "Continuing..."
                ;;
            *)
                echo "Aborted."
                exit 1
                ;;
        esac
    fi
}

run_step "Installing snapper stack..." \
    sudo pacman -S --needed --noconfirm \
        snapper \
        snap-pac \
        grub-btrfs \
        inotify-tools \
        btrfs-progs

step "Detecting BTRFS root device..."

ROOT_DEV="$(findmnt -no SOURCE /)" || {
    echo "Failed detecting root device."
    exit 1
}

ROOT_UUID="$(blkid -s UUID -o value "$ROOT_DEV")" || {
    echo "Failed detecting UUID."
    exit 1
}

echo "Root Device: $ROOT_DEV"
echo "Root UUID:   $ROOT_UUID"

run_step "Unmounting old /.snapshots" \
    sudo umount /.snapshots

run_step "Removing old /.snapshots" \
    sudo rm -rf /.snapshots

run_step "Creating temporary mountpoint" \
    sudo mkdir -p /mnt/btrfs-root

run_step "Mounting BTRFS top-level subvolume" \
    sudo mount -o subvolid=5 "$ROOT_DEV" /mnt/btrfs-root

step "Checking @snapshots subvolume..."

if ! sudo btrfs subvolume list /mnt/btrfs-root | grep -q "@snapshots"; then
    run_step "Creating @snapshots subvolume" \
        sudo btrfs subvolume create /mnt/btrfs-root/@snapshots
else
    echo "@snapshots already exists."
fi

run_step "Unmounting temporary mount" \
    sudo umount /mnt/btrfs-root

run_step "Creating /.snapshots directory" \
    sudo mkdir -p /.snapshots

step "Checking fstab entry..."

if ! grep -q "@snapshots" /etc/fstab; then
    run_step "Adding @snapshots to fstab" \
        bash -c "echo 'UUID=$ROOT_UUID /.snapshots btrfs subvol=@snapshots,compress=zstd,noatime 0 0' | sudo tee -a /etc/fstab"
else
    echo "fstab entry already exists."
fi

run_step "Mounting /.snapshots" \
    sudo mount /.snapshots

run_step "Creating snapper config" \
    sudo snapper -c root create-config /

run_step "Unmounting /.snapshots" \
    sudo umount /.snapshots

run_step "Recreating /.snapshots directory" \
    sudo rm -rf /.snapshots

run_step "Creating clean /.snapshots directory" \
    sudo mkdir /.snapshots

run_step "Mounting /.snapshots again" \
    sudo mount /.snapshots

run_step "Fixing permissions" \
    sudo chmod 750 /.snapshots

run_step "Enabling snapper timeline timer" \
    sudo systemctl enable --now snapper-timeline.timer

run_step "Enabling snapper cleanup timer" \
    sudo systemctl enable --now snapper-cleanup.timer

run_step "Enabling grub-btrfs daemon" \
    sudo systemctl enable --now grub-btrfsd

run_step "Regenerating GRUB config" \
    sudo grub-mkconfig -o /boot/grub/grub.cfg

run_step "Creating initial snapshot" \
    sudo snapper -c root create --description "Initial clean snapshot"

run_step "Ensuring /.snapshots exists" \
    sudo mkdir -p /.snapshots

run_step "Running mount -a" \
    sudo mount -a

step "Checking existing snapper config..."

if ! sudo snapper list-configs | grep -q "^root "; then
    run_step "Creating missing snapper config" \
        sudo snapper -c root create-config /
else
    echo "Snapper config already exists."
fi

run_step "Re-enabling snapper timeline timer" \
    sudo systemctl enable --now snapper-timeline.timer

run_step "Re-enabling snapper cleanup timer" \
    sudo systemctl enable --now snapper-cleanup.timer

run_step "Re-enabling grub-btrfs daemon" \
    sudo systemctl enable --now grub-btrfsd

run_step "Rebuilding GRUB config again because computers enjoy repetition rituals" \
    sudo grub-mkconfig -o /boot/grub/grub.cfg

run_step "Creating fresh install snapshot" \
    sudo snapper -c root create --description "Fresh Install"

run_step "Listing snapshots" \
    sudo snapper list

echo
echo "Done."
echo "Pacman transactions now auto-create snapshots."
echo "GRUB menu will show bootable snapshots."
