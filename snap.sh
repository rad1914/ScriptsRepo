#!/usr/bin/env bash
# Automates Snapper + BTRFS snapshot integration for Arch Linux with GRUB boot snapshot support.
# Run as root (or via sudo).

set -uo pipefail

# ─── Logging & Helpers ────────────────────────────────────────────────────────

FAILURES=0

info()  { printf '\e[1;34m[INFO]\e[0m  %s\n' "$*"; }
ok()    { printf '\e[1;32m[ OK ]\e[0m  %s\n' "$*"; }
warn()  { printf '\e[1;33m[WARN]\e[0m  %s\n' "$*"; }
fail()  { printf '\e[1;31m[FAIL]\e[0m  %s\n' "$*"; (( FAILURES++ )) || true; }

# run_guarded <description> <cmd...>
# Runs a command; on failure, increments FAILURES and continues.
run_guarded() {
    local desc="$1"; shift
    info "$desc"
    if "$@"; then
        ok "$desc"
    else
        fail "$desc"
    fi
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        printf '\e[1;31m[ERROR]\e[0m Must be run as root.\n' >&2
        exit 1
    fi
}

# ─── Step 1: Require Root ─────────────────────────────────────────────────────

require_root

info "=== Arch BTRFS + Snapper + GRUB Setup ==="

# ─── Step 2: Install Required Packages ───────────────────────────────────────

info "--- Step 2: Install Required Packages ---"

PACKAGES=(
    snapper
    snap-pac
    grub-btrfs
    btrfs-progs
    inotify-tools   # grub-btrfs daemon dependency
    findutils
    util-linux
)

for pkg in "${PACKAGES[@]}"; do
    if pacman -Qi "$pkg" &>/dev/null; then
        ok "Already installed: $pkg"
    else
        run_guarded "Install $pkg" pacman -S --noconfirm --needed "$pkg"
    fi
done

# ─── Step 3: Detect Root BTRFS Device ────────────────────────────────────────

info "--- Step 3: Detect Root BTRFS Device ---"

BTRFS_OK=true

RAW_DEV=$(findmnt -n -o SOURCE /) || { fail "findmnt failed"; BTRFS_OK=false; }

if $BTRFS_OK; then
    # Strip subvolume suffix, e.g. /dev/sda2[/@] -> /dev/sda2
    ROOT_DEV=$(echo "$RAW_DEV" | sed 's/\[.*\]$//')
    info "Root device: $ROOT_DEV"

    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV") || { fail "blkid failed on $ROOT_DEV"; BTRFS_OK=false; }
fi

if $BTRFS_OK; then
    # Confirm filesystem is actually BTRFS
    FS_TYPE=$(blkid -s TYPE -o value "$ROOT_DEV")
    if [[ "$FS_TYPE" != "btrfs" ]]; then
        fail "Root device $ROOT_DEV is $FS_TYPE, not btrfs. Aborting BTRFS-specific setup."
        BTRFS_OK=false
    else
        ok "BTRFS root confirmed: $ROOT_DEV (UUID=$ROOT_UUID)"
    fi
fi

# ─── Step 4: Prepare /.snapshots Subvolume ───────────────────────────────────

if $BTRFS_OK; then
    info "--- Step 4: Prepare /.snapshots Subvolume ---"

    # Unmount if already mounted
    if mountpoint -q /.snapshots 2>/dev/null; then
        run_guarded "Unmount /.snapshots" umount /.snapshots
    fi

    # Remove stale directory or subvolume
    if [[ -d /.snapshots ]]; then
        if btrfs subvolume show /.snapshots &>/dev/null; then
            run_guarded "Delete stale .snapshots subvolume" btrfs subvolume delete /.snapshots
        else
            run_guarded "Remove stale /.snapshots directory" rm -rf /.snapshots
        fi
    fi

    # Create Snapper config for root (also creates /.snapshots subvolume)
    if snapper list-configs 2>/dev/null | grep -q '^root '; then
        ok "Snapper config 'root' already exists"
    else
        run_guarded "Create Snapper root config" snapper -c root create-config /
    fi

    # Ensure .snapshots subvolume exists (snapper may not create it on first run)
    if ! btrfs subvolume show /.snapshots &>/dev/null; then
        run_guarded "Create .snapshots BTRFS subvolume" btrfs subvolume create /.snapshots
    else
        ok ".snapshots subvolume exists"
    fi
fi

# ─── Step 5: Configure Persistent fstab Mount ────────────────────────────────

if $BTRFS_OK; then
    info "--- Step 5: Configure Persistent fstab Mount ---"

    mkdir -p /.snapshots

    FSTAB_ENTRY="UUID=$ROOT_UUID  /.snapshots  btrfs  subvol=/.snapshots,defaults,noatime,compress=zstd  0 0"

    if grep -q '/.snapshots' /etc/fstab; then
        ok "/.snapshots already present in /etc/fstab"
    else
        run_guarded "Append /.snapshots to /etc/fstab" bash -c "echo '$FSTAB_ENTRY' >> /etc/fstab"
    fi

    run_guarded "Mount /.snapshots" mount /.snapshots
fi

# ─── Step 6: Set Permissions ──────────────────────────────────────────────────

if $BTRFS_OK; then
    info "--- Step 6: Set Permissions on /.snapshots ---"
    run_guarded "chmod 750 /.snapshots" chmod 750 /.snapshots
fi

# ─── Step 7: Enable Automatic Snapshot Services ───────────────────────────────

info "--- Step 7: Enable Automatic Snapshot Services ---"

SERVICES=(
    snapper-timeline.timer
    snapper-cleanup.timer
    grub-btrfsd.service
)

for svc in "${SERVICES[@]}"; do
    run_guarded "Enable $svc" systemctl enable --now "$svc"
done

# ─── Step 8: Integrate Snapshots Into GRUB ───────────────────────────────────

info "--- Step 8: Integrate Snapshots Into GRUB ---"

run_guarded "Ensure /boot/grub exists" mkdir -p /boot/grub
run_guarded "Regenerate grub.cfg" grub-mkconfig -o /boot/grub/grub.cfg

# ─── Step 9: Create Initial Snapshots ────────────────────────────────────────

if $BTRFS_OK; then
    info "--- Step 9: Create Initial Snapshots ---"
    run_guarded "Create baseline snapshot" \
        snapper -c root create --description "Baseline - pre-configuration" --cleanup-algorithm number

    run_guarded "Create post-setup snapshot" \
        snapper -c root create --description "Fresh install - post snapper setup" --cleanup-algorithm number
fi

# ─── Step 10: Final Validation and Retry ─────────────────────────────────────

info "--- Step 10: Final Validation and Retry ---"

run_guarded "Mount all fstab entries (mount -a)" mount -a

if $BTRFS_OK; then
    if snapper -c root list &>/dev/null; then
        ok "Snapper config 'root' is valid"
    else
        fail "Snapper config 'root' not accessible"
    fi
fi

# Retry service enablement
info "Retry: enabling snapshot services"
for svc in "${SERVICES[@]}"; do
    systemctl is-enabled "$svc" &>/dev/null || run_guarded "Retry enable $svc" systemctl enable --now "$svc"
done

# Retry GRUB regeneration
info "Retry: regenerating GRUB config"
run_guarded "Retry grub-mkconfig" grub-mkconfig -o /boot/grub/grub.cfg

# List snapshots
if $BTRFS_OK; then
    info "Available snapshots:"
    snapper -c root list || warn "Could not list snapshots"
fi

# ─── Step 11: Exit Status ─────────────────────────────────────────────────────

echo ""
info "=== Setup Complete ==="

if [[ $FAILURES -eq 0 ]]; then
    ok "All operations succeeded. BTRFS + Snapper + GRUB integration is active."
    exit 0
else
    fail "$FAILURES operation(s) failed. Review output above."
    exit 1
fi
