#!/usr/bin/env bash
# @path: scripts/3.sh

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()     { echo -e "${GREEN}[ OK ]${RESET}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()    { echo -e "${RED}[ERR ]${RESET}  $*" >&2; exit 1; }
hdr()    { echo -e "\n${BOLD}${CYAN}━━━━  $*  ━━━━${RESET}"; }

[[ "$EUID" -eq 0 ]] || die "Must run as root."

GRUB_CFG="/etc/default/grub"
GRUB_OUTPUT="/boot/grub/grub.cfg"
MKINITCPIO_CFG="/etc/mkinitcpio.conf"
SWAP_MOUNT="/swap"
SWAP_SUBVOL="@swap"
SWAPFILE="${SWAP_MOUNT}/swapfile"
TMP_MNT=""

cleanup() {
    local rc=$?
    if [[ -n "$TMP_MNT" ]] && mountpoint -q "$TMP_MNT" 2>/dev/null; then
        umount "$TMP_MNT" 2>/dev/null || true
    fi
    [[ -n "$TMP_MNT" ]] && rm -rf "$TMP_MNT"
    [[ $rc -ne 0 ]] && warn "Script exited with error code $rc — review output above."
    exit $rc
}
trap cleanup EXIT

parse_size_to_mb() {
    local raw="$1"
    local num unit
    num=$(printf '%s' "$raw" | grep -oP '^\d+') \
        || die "Could not parse numeric part of SWAP_SIZE: $raw"
    unit=$(printf '%s' "$raw" | grep -oP '[GgMmKk]$' | tr '[:lower:]' '[:upper:]') \
        || die "Could not parse unit of SWAP_SIZE: $raw (use G, M, or K)"
    case "$unit" in
        G) echo $(( num * 1024 )) ;;
        M) echo "$num" ;;
        K) echo $(( (num + 1023) / 1024 )) ;;
        *) die "Unsupported unit '$unit'. Use G, M, or K." ;;
    esac
}

fstab_append_if_missing() {
    local marker="$1"
    local line="$2"
    if grep -qF "$marker" /etc/fstab; then
        warn "fstab: entry matching '$marker' already present — skipping."
    else
        echo "$line" >> /etc/fstab
        ok "fstab: appended → $line"
    fi
}

hdr "STEP 1 · User Configuration"

echo
lsblk -fpno NAME,SIZE,FSTYPE,MOUNTPOINT
echo

read -rp "Please pick partition [sda2]: " SWAP_PARTITION
SWAP_PARTITION=${SWAP_PARTITION:-sda2}

if [[ "$SWAP_PARTITION" == /dev/* ]]; then
    SWAP_DEVICE="$SWAP_PARTITION"
else
    SWAP_DEVICE="/dev/$SWAP_PARTITION"
fi

read -rp "Swap size (e.g. 8G, 16G, 512M) [8G]: " SWAP_SIZE
SWAP_SIZE=${SWAP_SIZE:-8G}

log "SWAP_DEVICE = $SWAP_DEVICE"
log "SWAP_SIZE   = $SWAP_SIZE"

[[ -b "$SWAP_DEVICE" ]] || die "Device '$SWAP_DEVICE' is not a valid block device."
[[ -f "$GRUB_CFG"    ]] || die "GRUB config not found at '$GRUB_CFG'."
[[ -f "$MKINITCPIO_CFG" ]] || die "mkinitcpio.conf not found at '$MKINITCPIO_CFG'."

SWAP_SIZE_MB=$(parse_size_to_mb "$SWAP_SIZE")
log "Resolved swap size: ${SWAP_SIZE_MB} MiB (${SWAP_SIZE})"

hdr "STEP 2 · Disable zram"

if systemctl is-active --quiet zram-generator 2>/dev/null; then
    log "Stopping zram-generator..."
    systemctl stop zram-generator
    ok "zram-generator stopped."
else
    warn "zram-generator not active — skipping stop."
fi

for zdev in /dev/zram*; do
    [[ -b "$zdev" ]] || continue
    if swapon --show=NAME --noheadings 2>/dev/null | grep -q "^${zdev}$"; then
        log "Disabling swap on $zdev..."
        swapoff "$zdev"
        ok "Swapped off $zdev."
    else
        warn "$zdev not active as swap — skipping swapoff."
    fi
done

for unit in systemd-zram-setup@.service zram-generator.service; do
    if systemctl cat "$unit" &>/dev/null; then
        log "Masking $unit..."
        systemctl mask "$unit"
        ok "Masked $unit."
    else
        warn "$unit not found — skipping mask."
    fi
done

hdr "STEP 3 · Create Btrfs @swap Subvolume"

TMP_MNT=$(mktemp -d)
log "Temporarily mounting $SWAP_DEVICE → $TMP_MNT"
mount -o subvolid=5 "$SWAP_DEVICE" "$TMP_MNT"

if btrfs subvolume list "$TMP_MNT" | grep -qP "\s${SWAP_SUBVOL}$"; then
    warn "Subvolume '$SWAP_SUBVOL' already exists — skipping creation."
else
    log "Creating subvolume $SWAP_SUBVOL..."
    btrfs subvolume create "${TMP_MNT}/${SWAP_SUBVOL}"
    ok "Subvolume '$SWAP_SUBVOL' created."
fi

log "Unmounting temp mount..."
umount "$TMP_MNT"
ok "Temp mount cleaned up."

hdr "STEP 4 · Mount @swap at ${SWAP_MOUNT}"

if mountpoint -q "$SWAP_MOUNT"; then
    warn "$SWAP_MOUNT is already mounted — skipping."
else
    mkdir -p "$SWAP_MOUNT"
    log "Mounting $SWAP_DEVICE (@${SWAP_SUBVOL}) → $SWAP_MOUNT"
    mount -o "subvol=${SWAP_SUBVOL},defaults,noatime" "$SWAP_DEVICE" "$SWAP_MOUNT"
    ok "$SWAP_MOUNT mounted."
fi

hdr "STEP 5 · Create Swapfile (${SWAP_SIZE})"

if [[ -e "$SWAPFILE" ]]; then
    warn "Swapfile already exists at $SWAPFILE"
    read -rp "  Overwrite? This will destroy existing swap data. [y/N]: " confirm
    [[ "${confirm,,}" == "y" ]] || die "Aborted by user."
    if swapon --show=NAME --noheadings 2>/dev/null | grep -qF "$SWAPFILE"; then
        swapoff "$SWAPFILE"
        ok "Previous swapfile deactivated."
    fi
    rm -f "$SWAPFILE"
fi

log "Creating empty swapfile placeholder..."
truncate -s 0 "$SWAPFILE"

log "Disabling Copy-on-Write on $SWAPFILE..."
chattr +C "$SWAPFILE"

log "Allocating ${SWAP_SIZE_MB} MiB via dd..."
dd if=/dev/zero of="$SWAPFILE" bs=1M count="$SWAP_SIZE_MB" status=progress

log "Setting permissions (600)..."
chmod 600 "$SWAPFILE"

log "Initializing swap signature..."
mkswap "$SWAPFILE"
ok "Swapfile created at $SWAPFILE."

hdr "STEP 6 · Enable Swapfile"

if swapon --show=NAME --noheadings 2>/dev/null | grep -qF "$SWAPFILE"; then
    warn "Swapfile already active — skipping swapon."
else
    swapon "$SWAPFILE"
    ok "Swapfile activated. Current swap:"
    swapon --show
fi

hdr "STEP 7 · Persist /etc/fstab Entries"

SWAP_UUID=$(blkid -s UUID -o value "$SWAP_DEVICE") \
    || die "Could not determine UUID for $SWAP_DEVICE."
log "UUID for $SWAP_DEVICE = $SWAP_UUID"

FSTAB_MOUNT_LINE="UUID=${SWAP_UUID}  ${SWAP_MOUNT}  btrfs  subvol=${SWAP_SUBVOL},defaults,noatime  0 0"
fstab_append_if_missing "subvol=${SWAP_SUBVOL}" "$FSTAB_MOUNT_LINE"

FSTAB_SWAP_LINE="${SWAPFILE}  none  swap  defaults  0 0"
fstab_append_if_missing "$SWAPFILE" "$FSTAB_SWAP_LINE"

ok "/etc/fstab updated."

hdr "STEP 8 · Configure GRUB Hibernate Resume"

log "Calculating Btrfs swapfile physical offset..."
RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r "$SWAPFILE") \
    || die "Failed to calculate resume_offset. Is the swapfile active?"
log "resume_offset = $RESUME_OFFSET"

RESUME_PARAM="resume=UUID=${SWAP_UUID}"
OFFSET_PARAM="resume_offset=${RESUME_OFFSET}"

log "Injecting resume params into $GRUB_CFG..."

CURRENT_CMDLINE=$(grep -P '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_CFG" \
    | sed 's/^GRUB_CMDLINE_LINUX_DEFAULT=//;s/^"//;s/"$//')

CLEAN_CMDLINE=$(echo "$CURRENT_CMDLINE" \
    | sed 's/resume=UUID=[^ "]*//g;s/resume_offset=[^ "]*//g' \
    | tr -s ' ' \
    | sed 's/^ //;s/ $//')

NEW_CMDLINE="${CLEAN_CMDLINE} ${RESUME_PARAM} ${OFFSET_PARAM}"
NEW_CMDLINE=$(echo "$NEW_CMDLINE" | tr -s ' ' | sed 's/^ //;s/ $//')

sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${NEW_CMDLINE}\"|" \
    "$GRUB_CFG"

ok "GRUB_CMDLINE_LINUX_DEFAULT updated:"
grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_CFG"

hdr "STEP 9 · Configure mkinitcpio resume Hook"

HOOKS_LINE=$(grep -P '^HOOKS=' "$MKINITCPIO_CFG") \
    || die "Could not find HOOKS line in $MKINITCPIO_CFG."

log "Current HOOKS: $HOOKS_LINE"

if echo "$HOOKS_LINE" | grep -qw 'resume'; then
    warn "resume hook already present in HOOKS — skipping."
else
    if echo "$HOOKS_LINE" | grep -qw 'filesystems'; then
        sed -i 's/\bfilesystems\b/resume filesystems/' "$MKINITCPIO_CFG"
        ok "Inserted 'resume' before 'filesystems'."
    else
        warn "'filesystems' hook not found — appending 'resume' to end of HOOKS."
        sed -i 's/^\(HOOKS=([^)]*\))/\1 resume)/' "$MKINITCPIO_CFG"
    fi
    log "Updated HOOKS:"
    grep '^HOOKS=' "$MKINITCPIO_CFG"
fi

hdr "STEP 10 · Rebuild Initramfs and GRUB"

log "Regenerating all initramfs images (mkinitcpio -P)..."
mkinitcpio -P
ok "Initramfs regenerated."

log "Regenerating GRUB configuration → $GRUB_OUTPUT"
grub-mkconfig -o "$GRUB_OUTPUT"
ok "GRUB config written to $GRUB_OUTPUT."

hdr "Setup Complete"

echo -e "
${BOLD}Results:${RESET}
  Swap device  : $SWAP_DEVICE  (UUID: $SWAP_UUID)
  Swapfile     : $SWAPFILE  (${SWAP_SIZE})
  resume param : ${RESUME_PARAM}
  offset param : ${OFFSET_PARAM}
  GRUB config  : $GRUB_OUTPUT
  Initramfs    : rebuilt

${BOLD}Next steps:${RESET}
  1. Reboot to apply the new bootloader configuration.
  2. After reboot, test hibernation:
       systemctl hibernate
  3. Power back on and verify the session resumes correctly.
  4. If resume fails, double-check:
       grep 'resume' /proc/cmdline
       swapon --show
"

ok "Done."
