#!/usr/bin/env bash
# tailscale-setup.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Please run as root."
    exit 1
fi

echo "==> Updating package database and installing Tailscale..."
pacman -Syu --noconfirm tailscale

echo "==> Enabling and starting tailscaled service..."
systemctl enable --now tailscaled

echo "==> Current service status:"
systemctl --no-pager --full status tailscaled || true

echo
echo "==> Starting Tailscale login..."
echo "    A browser login URL will appear below."
echo

sudo -u "${SUDO_USER:-$(logname)}" tailscale up

echo
echo "==> Tailscale status:"
sudo -u "${SUDO_USER:-$(logname)}" tailscale status || true

echo
echo "==> IPv4 Address:"
sudo -u "${SUDO_USER:-$(logname)}" tailscale ip -4 || true

echo
echo "==> Done."
