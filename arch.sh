#!/usr/bin/env bash
# =============================================================================
# Arch Linux Bootstrap + Hibernate + BitNet Setup
# Target user : radwrld
# Filesystem  : Btrfs  |  Bootloader: GRUB  |  DE: Hyprland + SDDM
# =============================================================================

set -euo pipefail

# ── Globals ──────────────────────────────────────────────────────────────────
USERNAME="radwrld"
REAL_HOME="/home/$USERNAME"
HOSTNAME_VAL="$(cat /etc/hostname 2>/dev/null || echo unknown-host)"
SWAP_DEVICE="/dev/sda4"
SWAP_SIZE="8G"
FISH_BIN="/usr/bin/fish"
BITNET_DIR="$REAL_HOME/BitNet"
MODEL_DIR="$BITNET_DIR/model"
MODEL_URL="https://huggingface.co/microsoft/bitnet-b1.58-2B-4T-gguf/resolve/main/ggml-model-i2_s.gguf"
MODEL_FILE="$MODEL_DIR/ggml-model-i2_s.gguf"
REMOTE_INSTALLER_URL="https://raw.githubusercontent.com/radwrld/installer/main/install.sh"

FAILED_STEPS=()
REAL_USER="$USERNAME"

# ── Helpers ───────────────────────────────────────────────────────────────────
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
    shift

    io "$desc"

    if "$@"; then
        echo "  ✔  $desc"
    else
        echo "  ✘  FATAL: $desc"
        exit 1
    fi
}


# =============================================================================
# STAGE 1 — System Update
# =============================================================================
io "Stage 1 — System Update"

run_step "Update pacman repositories and packages" \
    pacman -Syu --noconfirm

# =============================================================================
# STAGE 2 — Dependency Installation
# =============================================================================
io "Stage 2 — Dependency Installation"

PACKAGES=(
    # Desktop / Compositor
    hyprland waybar wofi sddm
    # Development
    base-devel git cmake ninja clang python python-pip
    # Networking
    networkmanager nm-connection-editor
    # Android
    android-tools
    # Shell
    fish starship
    # Utilities
    curl wget rsync htop fastfetch bat eza fd ripgrep
    fzf zoxide tmux neovim openssh
)

run_step "Install all packages" \
    pacman -S --needed --noconfirm "${PACKAGES[@]}"

# =============================================================================
# STAGE 3 — AUR Helper (yay)
# =============================================================================
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

# =============================================================================
# STAGE 4 — SSH Configuration
# =============================================================================
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

# =============================================================================
# STAGE 5 — Shell Configuration (fish)
# =============================================================================
io "Stage 5 — Shell Configuration"

if [[ -x "$FISH_BIN" ]]; then
    run_shell "Set fish as default login shell" \
        "chsh -s $FISH_BIN $USERNAME"
else
    FAILED_STEPS+=("Set fish as default shell (fish binary not found)")
    echo "  ✘  fish not found at $FISH_BIN"
fi

# =============================================================================
# STAGE 6 — SDDM Autologin
# =============================================================================
io "Stage 6 — SDDM Autologin"

run_shell "Create SDDM config directory" \
    "mkdir -p /etc/sddm.conf.d"

run_shell "Write autologin.conf" \
    "cat > /etc/sddm.conf.d/autologin.conf <<EOF
[Autologin]
User=$USERNAME
Session=hyprland
EOF"

run_step "Enable and start SDDM" \
    systemctl enable sddm

# =============================================================================
# STAGE 7 — GRUB Configuration
# =============================================================================
io "Stage 7 — GRUB Configuration"

GRUB_CFG="/etc/default/grub"

run_shell "Set GRUB_TIMEOUT=0" \
    "sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' $GRUB_CFG"

run_shell "Set GRUB_TIMEOUT_STYLE=hidden" \
    "sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/' $GRUB_CFG"

# Append if keys are absent
run_shell "Ensure GRUB_TIMEOUT is present" \
    "grep -q '^GRUB_TIMEOUT=' $GRUB_CFG || echo 'GRUB_TIMEOUT=0' >> $GRUB_CFG"

run_shell "Ensure GRUB_TIMEOUT_STYLE is present" \
    "grep -q '^GRUB_TIMEOUT_STYLE=' $GRUB_CFG || echo 'GRUB_TIMEOUT_STYLE=hidden' >> $GRUB_CFG"

run_step "Regenerate grub.cfg" \
    grub-mkconfig -o /boot/grub/grub.cfg

# =============================================================================
# STAGE 8 — Hibernate + Btrfs Swap Setup
# =============================================================================
io "Stage 8 — Hibernate + Btrfs Swap Setup"

# Prompt user to confirm/override device
read -rp "  Enter Btrfs swap partition [default: $SWAP_DEVICE]: " USER_DEVICE
SWAP_DEVICE="${USER_DEVICE:-$SWAP_DEVICE}"
io "Using device: $SWAP_DEVICE"

read -rp "  Enter swap size [default: $SWAP_SIZE]: " USER_SWAP_SIZE
SWAP_SIZE="${USER_SWAP_SIZE:-$SWAP_SIZE}"
io "Swap size: $SWAP_SIZE"

# Disable zram
run_shell "Disable zram-generator service" \
    "systemctl stop systemd-zram-setup@zram0.service 2>/dev/null || true"
run_shell "Disable zram swap" \
    "swapoff /dev/zram0 2>/dev/null || true"
run_shell "Mask zram services" \
    "systemctl mask systemd-zram-setup@zram0.service 2>/dev/null || true"

# Create Btrfs @swap subvolume
run_shell "Create Btrfs @swap subvolume" \
    "mkdir -p /tmp/btrfs-swap
     mount $SWAP_DEVICE /tmp/btrfs-swap 2>/dev/null || true
     btrfs subvolume create /tmp/btrfs-swap/@swap 2>/dev/null || true
     umount /tmp/btrfs-swap 2>/dev/null || true"

# Mount @swap subvolume
run_shell "Mount @swap subvolume at /swap" \
    "mkdir -p /swap
     mount -o subvol=@swap $SWAP_DEVICE /swap"

# Create swapfile
run_shell "Create Btrfs-compatible swapfile" \
    "truncate -s 0 /swap/swapfile
     chattr +C /swap/swapfile
     dd if=/dev/zero of=/swap/swapfile bs=1M count=8192 status=progress
     chmod 600 /swap/swapfile
     mkswap /swap/swapfile"

# Enable swap
run_shell "Enable swapfile" \
    "swapon /swap/swapfile"

# fstab entries
run_shell "Append swap mount to /etc/fstab" \
    "SWAP_UUID=\$(blkid -s UUID -o value $SWAP_DEVICE)
     grep -q '/swap' /etc/fstab || echo \"UUID=\$SWAP_UUID /swap btrfs subvol=@swap,defaults,noatime 0 0\" >> /etc/fstab
     grep -q '/swap/swapfile' /etc/fstab || echo '/swap/swapfile none swap defaults 0 0' >> /etc/fstab"

# Calculate resume offset (Btrfs physical offset)
run_shell "Calculate resume_offset and inject into GRUB" \
    "SWAP_UUID=\$(blkid -s UUID -o value $SWAP_DEVICE)
     RESUME_OFFSET=\$(btrfs inspect-internal map-swapfile -r /swap/swapfile)
     RESUME_PARAMS=\"resume=UUID=\$SWAP_UUID resume_offset=\$RESUME_OFFSET\"
     if ! grep -q 'resume=' $GRUB_CFG; then
         sed -i \"s|^GRUB_CMDLINE_LINUX_DEFAULT=\\\"|GRUB_CMDLINE_LINUX_DEFAULT=\\\"\$RESUME_PARAMS |\" $GRUB_CFG
     fi"

# mkinitcpio resume hook
run_shell "Add resume hook to mkinitcpio.conf" \
    "if ! grep -q 'resume' /etc/mkinitcpio.conf; then
         sed -i 's/\<filesystems\>/resume filesystems/' /etc/mkinitcpio.conf
     fi"
     
run_step "Rebuild initramfs" \
    mkinitcpio -P

run_step "Regenerate GRUB config (post-resume params)" \
    grub-mkconfig -o /boot/grub/grub.cfg

# =============================================================================
# STAGE 9 — llama.cpp Build
# =============================================================================
io "Stage 9 — llama.cpp Build"

LLAMA_DIR="$REAL_HOME/llama.cpp"

critical_step "Install llama.cpp build dependencies" \
    pacman -S --needed --noconfirm \
        cmake ninja clang openmp git

critical_step "Clone llama.cpp repository" \
    bash -c "
        rm -rf '$LLAMA_DIR'
        sudo -u '$USERNAME' git clone https://github.com/ggerganov/llama.cpp.git '$LLAMA_DIR'
    "

critical_step "Configure llama.cpp build" \
    bash -c "
        cd '$LLAMA_DIR'

        if [[ -f build/bin/llama-cli || -f build/bin/main ]]; then
            echo 'llama.cpp already compiled — skipping configure'
            exit 0
        fi

        sudo -u '$USERNAME' cmake -B build -G Ninja \
            -DCMAKE_BUILD_TYPE=Release \
            -DGGML_OPENMP=ON
    "

critical_step "Compile llama.cpp" \
    bash -c "
        cd '$LLAMA_DIR'

        if [[ -f build/bin/llama-cli || -f build/bin/main ]]; then
            echo 'llama.cpp already compiled — skipping build'
            exit 0
        fi

        sudo -u '$USERNAME' ninja -C build
    "

# =============================================================================
# STAGE 10 — Model Download
# =============================================================================
io "Stage 10 — Model Download"

run_shell "Create model directory" \
    "mkdir -p '$MODEL_DIR'
     chown -R '$USERNAME:$USERNAME' '$BITNET_DIR'"

critical_step "Download BitNet GGUF model from HuggingFace" \
    bash -c "sudo -u '$USERNAME' wget -c -O '$MODEL_FILE' '$MODEL_URL'"

# =============================================================================
# STAGE 11 — Inference Test
# =============================================================================
io "Stage 11 — Inference Test"

LLAMA_CLI=""

for candidate in \
    "$LLAMA_DIR/build/bin/llama-cli" \
    "$LLAMA_DIR/build/bin/main" \
    "$LLAMA_DIR/build/bin/Release/llama-cli" \
    "$LLAMA_DIR/build/bin/Release/main"
do
    if [[ -x "$candidate" ]]; then
        LLAMA_CLI="$candidate"
        break
    fi
done

critical_step "Validate model and binary exist, then run test inference" \
    bash -c "
        if [[ -z '$LLAMA_CLI' ]]; then
            echo 'No llama executable found'
            exit 1
        fi

        if [[ ! -f '$MODEL_FILE' ]]; then
            echo 'Model file not found at $MODEL_FILE'
            exit 1
        fi

        echo 'Using binary: $LLAMA_CLI'

        '$LLAMA_CLI' \
            -m '$MODEL_FILE' \
            -p 'Hello, BitNet. Describe yourself in one sentence.' \
            -n 64 \
            --temp 0.0
    "

# WARNING: Executes arbitrary remote code as root.
# Review before executing.
# =============================================================================
# STAGE 12 — Remote Installer
# =============================================================================
io "Stage 12 — Remote Installer"

# WARNING: Executes arbitrary remote code. Verify URL before running.
critical_step "Download remote installer" \
    "curl -fsSL \"$REMOTE_INSTALLER_URL\" -o /tmp/installer.sh"

critical_step "Execute remote installer" \
    "bash /tmp/installer.sh"

# =============================================================================
# STAGE 13 — Failure Report
# =============================================================================
io "Stage 13 — Failure Report"

echo ""
echo "============================================="
if [[ ${#FAILED_STEPS[@]} -eq 0 ]]; then
    echo "  ✔  All stages completed successfully."
else
    echo "  ✘  The following steps failed:"
    for step in "${FAILED_STEPS[@]}"; do
        echo "      -  $step"
    done
fi
echo "============================================="
echo ""
