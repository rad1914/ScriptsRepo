#!/usr/bin/env bash
# @path: scripts/4.sh

set -euo pipefail

EFI_MOUNT="/boot/efi"
GRUB_ID="GRUB"
GRUB_CFG="/boot/grub/grub.cfg"
GRUB_DEFAULT="/etc/default/grub"

if [[ "${EUID}" -ne 0 ]]; then
    echo "[ERROR] This script must be run as root." >&2
    exit 1
fi

echo "[INFO] Running as root. Proceeding..."

echo "[INFO] Installing required packages: grub efibootmgr os-prober ntfs-3g..."
pacman -Sy --needed --noconfirm grub efibootmgr os-prober ntfs-3g

echo "[INFO] Detecting EFI partition (first VFAT partition)..."
EFI_PARTITION="$(lsblk -lno NAME,FSTYPE | awk '$2 == "vfat" { print "/dev/" $1; exit }')"

if [[ -z "${EFI_PARTITION}" ]]; then
    echo "[ERROR] No VFAT (EFI) partition detected. Aborting." >&2
    exit 1
fi

echo "[INFO] Detected EFI partition: ${EFI_PARTITION}"

mkdir -p "${EFI_MOUNT}"

if mountpoint -q "${EFI_MOUNT}"; then
    echo "[INFO] ${EFI_MOUNT} is already mounted. Skipping mount."
else
    echo "[INFO] Mounting ${EFI_PARTITION} → ${EFI_MOUNT}..."
    mount "${EFI_PARTITION}" "${EFI_MOUNT}"
fi

echo "[INFO] Enabling GRUB_DISABLE_OS_PROBER=false in ${GRUB_DEFAULT}..."

if grep -q "^GRUB_DISABLE_OS_PROBER" "${GRUB_DEFAULT}"; then
    sed -i 's/^#\?\s*GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' "${GRUB_DEFAULT}"
else
    echo "GRUB_DISABLE_OS_PROBER=false" >> "${GRUB_DEFAULT}"
fi

echo "[INFO] Installing GRUB EFI bootloader..."
grub-install \
    --target=x86_64-efi \
    --efi-directory="${EFI_MOUNT}" \
    --bootloader-id="${GRUB_ID}"

echo "[INFO] GRUB EFI bootloader installed."

echo "[INFO] Running os-prober to detect additional operating systems..."
os-prober || true

echo "[INFO] Generating GRUB configuration → ${GRUB_CFG}..."
grub-mkconfig -o "${GRUB_CFG}"

echo "[INFO] GRUB configuration generated."

echo ""
echo "──────────────────────────────────────────"
echo " Detected GRUB menu entries:"
echo "──────────────────────────────────────────"
grep -E "^menuentry " "${GRUB_CFG}" | awk -F"'" '{print "  •", $2}'
echo "──────────────────────────────────────────"
echo ""

echo "[DONE] GRUB dual-boot setup complete."
echo "       Reboot to validate the GRUB menu: reboot"