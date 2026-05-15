#!/usr/bin/env bash
set -uo pipefail

FAILED_STEPS=()

run_step() {
  local desc="$1"
  shift

  echo
  echo "==> $desc"

  if "$@"; then
    echo "[OK] $desc"
  else
    echo "[FAILED] $desc"
    FAILED_STEPS+=("$desc")
  fi
}

run_shell() {
  local desc="$1"
  local cmd="$2"

  echo
  echo "==> $desc"

  if bash -c "$cmd"; then
    echo "[OK] $desc"
  else
    echo "[FAILED] $desc"
    FAILED_STEPS+=("$desc")
  fi
}

io() {
  printf '\n==> %s\n' "$1"
}

TMP="${TMP:-/tmp/bootstrap-$USER}"
mkdir -p "$TMP"

run_step \
  "Updating packages" \
  sudo pacman -Syu --noconfirm

run_step \
  "Installing dependencies" \
  sudo pacman -S --noconfirm --needed \
  fish \
  jdk17-openjdk \
  which \
  openssh \
  git \
  curl \
  wget \
  unzip \
  nodejs \
  htop \
  thunar \
  firefox \
  android-apktool \
  android-tools \
  base \
  clang \
  cmake \
  direnv \
  distrobox \
  github-cli \
  grub \
  jq \
  nano \
  nvm \
  pm2 \
  python-virtualenv \
  python \
  smali \
  tailscale \
  tmux \
  tor \
  tree \
  uv \
  yarn \
  yt-dlp \
  zip

if ! command -v yay >/dev/null 2>&1; then
  io "Installing yay..."

  run_step \
    "Installing yay dependencies" \
    sudo pacman -S --noconfirm --needed base-devel git

  cd "$TMP"

  rm -rf yay

  run_step \
    "Cloning yay" \
    git clone https://aur.archlinux.org/yay.git

  if [ ! -d yay ]; then
    echo "[SKIPPED] Building yay because clone failed"
  else
    cd yay

    run_step \
      "Building yay" \
      makepkg -si --noconfirm
  fi
fi

mkdir -p ~/.ssh

if [ ! -f ~/.ssh/id_ed25519 ]; then
  run_step \
    "Generating SSH key" \
    ssh-keygen \
    -t ed25519 \
    -N "" \
    -f ~/.ssh/id_ed25519 \
    -C "$(whoami)@$(hostname)"
fi

io "Changing shell to fish..."
if command -v fish >/dev/null 2>&1; then
  run_step \
    "Changing shell to fish" \
    chsh -s "$(command -v fish)"
fi

run_step \
  "Creating SDDM config directories" \
  sudo mkdir -p /etc/sddm.conf.d

run_shell \
  "Configuring autologin" \
  'sudo tee /etc/sddm.conf.d/autologin.conf >/dev/null <<EOF
[Autologin]
User=radwrld
Session=hyprland.desktop
EOF
'

run_step \
  "Configuring GRUB timeout" \
  sudo sed -i \
  -e 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' \
  -e 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/' \
  /etc/default/grub

if ! grep -q '^GRUB_TIMEOUT=' /etc/default/grub; then
  echo 'GRUB_TIMEOUT=3' | sudo tee -a /etc/default/grub >/dev/null
fi

if ! grep -q '^GRUB_TIMEOUT_STYLE=' /etc/default/grub; then
  echo 'GRUB_TIMEOUT_STYLE=hidden' | sudo tee -a /etc/default/grub >/dev/null
fi

run_step \
  "Generating GRUB config" \
  sudo grub-mkconfig -o /boot/grub/grub.cfg

SWAPSIZE="9G"

io "Disabling zram if present..."
run_shell \
  "Disabling zram service" \
  'sudo systemctl disable --now systemd-zram-setup@zram0.service 2>/dev/null || true'

run_shell \
  "Disabling zram swap" \
  'sudo swapoff /dev/zram0 2>/dev/null || true'

run_shell \
  "Creating swap subvolume" \
  'sudo btrfs subvolume create /@swap || true'

run_step \
  "Creating /swap mountpoint" \
  sudo mkdir -p /swap

run_step \
  "Mounting swap subvolume" \
  sudo mount -o subvol=@swap /dev/sda4 /swap

run_step \
  "Creating Btrfs-compatible swapfile" \
  sudo btrfs filesystem mkswapfile \
  --size "$SWAPSIZE" \
  --uuid clear \
  /swap/swapfile

if [ -f /swap/swapfile ]; then
  run_step \
    "Enabling swap" \
    sudo swapon /swap/swapfile
else
  echo "[SKIPPED] Swapfile missing"
fi

io "Adding swapfile to fstab..."
if ! grep -q "/swap/swapfile" /etc/fstab; then
  sudo tee -a /etc/fstab >/dev/null <<EOF
/dev/sda4 /swap btrfs subvol=@swap,defaults,noatime,compress=no 0 0
/swap/swapfile none swap defaults 0 0
EOF
fi

io "Detecting resume UUID..."
UUID=$(findmnt -no UUID -T /swap/swapfile)

if [ -f /swap/swapfile ]; then
  io "Calculating resume offset..."
  OFFSET=$(sudo btrfs inspect-internal map-swapfile -r /swap/swapfile)
else
  OFFSET=""
fi

if [ -n "${UUID:-}" ] && [ -n "${OFFSET:-}" ]; then
  run_step \
    "Configuring GRUB kernel params" \
    sudo sed -i \
    "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 resume=UUID=${UUID} resume_offset=${OFFSET}\"/" \
    /etc/default/grub
else
  echo "[SKIPPED] Resume configuration"
fi

io "Ensuring resume hook exists..."
if ! grep -q "resume" /etc/mkinitcpio.conf; then
  sudo sed -i \
    's/^HOOKS=(\(.*\)filesystems\(.*\))/HOOKS=(\1resume filesystems\2)/' \
    /etc/mkinitcpio.conf
fi

run_step \
  "Rebuilding initramfs" \
  sudo mkinitcpio -P

run_step \
  "Regenerating GRUB config" \
  sudo grub-mkconfig -o /boot/grub/grub.cfg

echo
echo "======================================"
echo "Hibernate setup complete."
echo
echo "Test with:"
echo "systemctl hibernate"
echo "======================================"

REPO="$HOME/BitNet"
MODEL_DIR="$REPO/models/BitNet-b1.58-2B-4T"
MODEL="$MODEL_DIR/ggml-model-i2_s.gguf"

run_step \
  "Installing BitNet dependencies" \
  sudo pacman -S --needed --noconfirm \
  git \
  base-devel \
  cmake \
  ninja \
  clang \
  python \
  wget \
  curl

rm -rf "$REPO"

run_step \
  "Cloning Microsoft BitNet" \
  git clone --recursive https://github.com/microsoft/BitNet.git "$REPO"

if [ -d "$REPO" ]; then
  run_step \
    "Updating BitNet submodules" \
    git -C "$REPO" submodule update --init --recursive
fi

if [ ! -d "$REPO" ]; then
  echo "[SKIPPED] BitNet build because repository missing"
else
  cd "$REPO"

  run_step \
    "Configuring BitNet build" \
    cmake -B build -G Ninja

  run_step \
    "Building BitNet" \
    cmake --build build -j"$(nproc)"
fi

mkdir -p "$MODEL_DIR"

run_step \
  "Downloading BitNet model" \
  wget -O "$MODEL" \
  https://huggingface.co/microsoft/bitnet-b1.58-2B-4T-gguf/resolve/main/ggml-model-i2_s.gguf

if [ -x "$REPO/build/bin/llama-cli" ] && [ -f "$MODEL" ]; then
  run_step \
    "Testing inference" \
    "$REPO/build/bin/llama-cli" \
    -m "$MODEL" \
    -p "Hello." \
    -n 64 \
    -t "$(nproc)" \
    -c 2048 \
    -temp 0.7 \
    -cnv
else
  echo "[SKIPPED] Inference test because binary or model missing"
fi

echo
echo "==> Environment Variables:"
echo "export LLAMA=\"$REPO/build/bin/llama-cli\""
echo "export MODEL=\"$MODEL\""

echo
echo "==> Example:"
echo "\$LLAMA -m \$MODEL -p 'Explain Linux namespaces.' -n 128 -cnv"

run_shell \
  "Running remote installer" \
  "curl -fsSL https://ii.clsty.link/get | bash"

echo
echo "======================================"

if [ ${#FAILED_STEPS[@]} -eq 0 ]; then
  echo "All steps completed successfully."
else
  echo "Some steps failed:"
  printf ' - %s\n' "${FAILED_STEPS[@]}"
fi

echo "======================================"
