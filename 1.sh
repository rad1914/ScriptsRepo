#!/usr/bin/env bash
# @path: scripts/1.sh


set -euo pipefail

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
REMOTE_INSTALLER_URL="https://ii.clsty.link/get"

FAILED_STEPS=()
REAL_USER="$USERNAME"

io() {
    printf '\n  ▶  %s\n\n' "$*"
}

run() {
    local msg="$1"
    shift

    io "$msg"

    "$@" \
        && echo "  ✔  $msg" \
        || {
            echo "  ✘  FAILED: $msg"
            FAILED_STEPS+=("$msg")
        }
}

run_sh() {
    run "$1" bash -c "$2"
}

critical() {
    local msg="$1"
    shift

    io "$msg"

    "$@" \
        && echo "  ✔  $msg" \
        || {
            echo "  ✘  FATAL: $msg"
            exit 1
        }
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
        chsh root /usr/bin/fish
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

io "Stage 10 — Model Download"

run_shell "Create model directory" \
    "mkdir -p '$MODEL_DIR'
     chown -R '$USERNAME:$USERNAME' '$BITNET_DIR'"

critical_step "Download BitNet GGUF model from HuggingFace" \
    bash -c "sudo -u '$USERNAME' wget -c -O '$MODEL_FILE' '$MODEL_URL'"

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

io "Stage 12 — Remote Installer"

critical_step "Download remote installer" \
    "curl -fsSL \"$REMOTE_INSTALLER_URL\" -o /tmp/installer.sh"

critical_step "Execute remote installer" \
    "sudo bash /tmp/installer.sh"

io "Stage 13 — Failure Report"

echo

if ((${#FAILED_STEPS[@]} == 0)); then
    echo "✔ All stages completed successfully."
else
    echo "✘ Failed steps:"
    printf '  - %s\n' "${FAILED_STEPS[@]}"
fi

echo
