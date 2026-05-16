#!/usr/bin/env bash
# @path: scripts/2.sh

set -euo pipefail

USERNAME="radwrld"
REAL_HOME="/home/$USERNAME"
HOSTNAME_VAL="$(cat /etc/hostname 2>/dev/null || echo unknown-host)"
SWAP_DEVICE="/dev/sda4"
SWAP_SIZE="8G"
FISH_BIN="/usr/bin/fish"


FAILED_STEPS=()
REAL_USER="$USERNAME"

io() {
    echo ""
    echo "  ▶  $*"
    echo ""
}

run_step() {
    local desc="$1"
    shift
    io "$desc"
    if "$@"; then
        echo "  ✔  $desc"
    else
        echo "  ✘  FAILED: $desc"
        FAILED_STEPS+=("$desc")
    fi
}

run_shell() {
    local desc="$1"
    local cmd="$2"
    io "$desc"
    if bash -c "$cmd"; then
        echo "  ✔  $desc"
    else
        echo "  ✘  FAILED: $desc"
        FAILED_STEPS+=("$desc")
    fi
}

critical_step() {
    local desc="$1"
    local cmd="$2"

    io "$desc"

    if bash -c "$cmd"; then
        echo "  ✔  $desc"
    else
        echo "  ✘  FATAL: $desc"
        exit 1
    fi
}

io "Stage 1 — System Update"

run_step "Update pacman repositories and packages" \
    pacman -Syu --noconfirm

io "Stage 2 — Dependency Installation"

PACKAGES=(
    jdk17-openjdk which curl wget unzip nodejs
    base-devel git cmake ninja clang python python-pip
    android-tools
    fish starship
    curl wget rsync htop fastfetch bat eza fd ripgrep
    fzf zoxide tmux neovim openssh ytdlp nodejs 
)

run_step "Install all packages" \
    pacman -S --needed --noconfirm "${PACKAGES[@]}"

io "Stage 3 — AUR Helper Setup"

if ! command -v yay &>/dev/null; then
    run_step "Install base-devel and git (yay prereqs)" \
        pacman -S --needed --noconfirm base-devel git

    run_shell "Clone yay AUR repository" \
        "git clone https://aur.archlinux.org/yay.git /tmp/yay"

    run_shell "Build and install yay" \
        "cd /tmp/yay && makepkg -si --noconfirm"
else
    io "yay already installed — skipping"
fi

io "Stage 4 — SSH Configuration"

run_shell "Create ~/.ssh directory" \
    "mkdir -p ~/.ssh && chmod 700 ~/.ssh"

KEY_PATH="$HOME/.ssh/id_ed25519"
if [[ ! -f "$KEY_PATH" ]]; then
    run_step "Generate ed25519 SSH key" \
        ssh-keygen -t ed25519 -C "${USERNAME}@${HOSTNAME_VAL}" -f "$KEY_PATH" -N ""
else
    io "SSH key already exists at $KEY_PATH — skipping"
fi

io "Stage 4.5 — OpenSSH Daemon Configuration"

SSHD_CONFIG="/etc/ssh/sshd_config"

run_shell "Ensure Port 22 is configured" \
    "if grep -q '^#\?Port ' \"$SSHD_CONFIG\"; then
         sed -i 's/^#\?Port .*/Port 22/' \"$SSHD_CONFIG\"
     else
         echo 'Port 22' >> \"$SSHD_CONFIG\"
     fi"

run_shell "Enable root login" \
    "if grep -q '^#\?PermitRootLogin ' \"$SSHD_CONFIG\"; then
         sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin yes/' \"$SSHD_CONFIG\"
     else
         echo 'PermitRootLogin yes' >> \"$SSHD_CONFIG\"
     fi"

run_shell "Ensure PasswordAuthentication is enabled" \
    "if grep -q '^#\?PasswordAuthentication ' \"$SSHD_CONFIG\"; then
         sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' \"$SSHD_CONFIG\"
     else
         echo 'PasswordAuthentication yes' >> \"$SSHD_CONFIG\"
     fi"

run_step "Enable OpenSSH service" \
    systemctl enable sshd

run_step "Restart OpenSSH service" \
    systemctl restart sshd

io "Stage 5 — Shell Configuration"

if [[ -x "$FISH_BIN" ]]; then
    run_shell "Set fish as default login shell" \
        "chsh -s $FISH_BIN $USERNAME"
else
    FAILED_STEPS+=("Set fish as default shell (fish binary not found)")
    echo "  ✘  fish not found at $FISH_BIN"
fi

io "Stage 6 — SDDM Autologin"

run_shell "Create SDDM config directory" \
    "mkdir -p /etc/sddm.conf.d"

run_shell "Write autologin.conf" \
    "cat > /etc/sddm.conf.d/autologin.conf <<EOF
[Autologin]
User=$USERNAME
EOF"

run_step "Enable and start SDDM" \
    systemctl enable sddm

io "Stage 7 — GRUB Configuration"

GRUB_CFG="/etc/default/grub"

run_shell "Set GRUB_TIMEOUT=0" \
    "sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' $GRUB_CFG"

run_shell "Set GRUB_TIMEOUT_STYLE=hidden" \
    "sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/' $GRUB_CFG"

run_shell "Ensure GRUB_TIMEOUT is present" \
    "grep -q '^GRUB_TIMEOUT=' $GRUB_CFG || echo 'GRUB_TIMEOUT=0' >> $GRUB_CFG"

run_shell "Ensure GRUB_TIMEOUT_STYLE is present" \
    "grep -q '^GRUB_TIMEOUT_STYLE=' $GRUB_CFG || echo 'GRUB_TIMEOUT_STYLE=hidden' >> $GRUB_CFG"

run_step "Regenerate grub.cfg" \
    grub-mkconfig -o /boot/grub/grub.cfg

io "Stage 12 — Remote Installer"

bash <(curl -s https://ii.clsty.link/get)

echo

if ((${#FAILED_STEPS[@]} == 0)); then
    echo "✔ All stages completed successfully."
else
    echo "✘ Failed steps:"
    printf '  - %s\n' "${FAILED_STEPS[@]}"
fi

echo
