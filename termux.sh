#!/data/data/com.termux/files/usr/bin/bash
# @path: scripts/termux.sh

set -euo pipefail

echo "[1/19] Granting storage access..."
termux-setup-storage || true

echo "[2/19] Installing base Termux packages..."
pkg update -y
pkg install -y proot-distro

echo "[3/19] Installing Arch Linux via proot-distro..."
proot-distro install archlinux || true

echo "[4/19] Configuring auto-login in ~/.bashrc..."
BASHRC="$HOME/.bashrc"
if ! grep -q "proot-distro login archlinux" "$BASHRC" 2>/dev/null; then
    echo 'proot-distro login archlinux' >> "$BASHRC"
fi

echo "[5/19] Generating ~/arch-setup.sh..."

cat > "$HOME/arch-setup.sh" << 'ARCH_SETUP'
#!/bin/bash
set -euo pipefail

LOG() { echo -e "\n\033[1;34m>>> $*\033[0m"; }

LOG "[6] Updating Arch packages..."
pacman -Syu --noconfirm

LOG "[7] Installing development packages..."
pacman -S --noconfirm --needed \
    fish \
    jdk17-openjdk \
    maven \
    android-tools \
    which \
    openssh \
    git \
    curl \
    wget \
    unzip \
    nodejs

LOG "[8] Generating SSH keypair (ed25519)..."
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
    ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" || true
    echo "SSH key generated: $HOME/.ssh/id_ed25519"
else
    echo "SSH key already exists, skipping."
fi

LOG "[9] Preparing Android SDK directories..."
SDK="$HOME/Android/Sdk"
rm -rf "$SDK"
mkdir -p "$SDK/cmdline-tools"

LOG "[10-11] Downloading Android command-line tools..."
SDK_ZIP="$HOME/sdk.zip"
SDK_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"

download_file() {
    local url="$1" dest="$2"
    echo "Trying wget..."
    if wget -q --show-progress -O "$dest" "$url"; then
        return 0
    fi
    echo "wget failed, trying curl..."
    curl -L --progress-bar -o "$dest" "$url"
}

download_file "$SDK_URL" "$SDK_ZIP"

MIN_BYTES=1000000
ACTUAL=$(stat -c%s "$SDK_ZIP" 2>/dev/null || echo 0)
if [ "$ACTUAL" -lt "$MIN_BYTES" ]; then
    echo "ERROR: Downloaded file too small ($ACTUAL bytes). Aborting." >&2
    exit 1
fi

echo "Extracting SDK tools..."
unzip -q "$SDK_ZIP" -d "$SDK/cmdline-tools"
mv "$SDK/cmdline-tools/cmdline-tools" "$SDK/cmdline-tools/latest" 2>/dev/null || true
rm -f "$SDK_ZIP"

LOG "[12] Configuring environment variables..."
export JAVA_HOME="/usr/lib/jvm/java-17-openjdk"
export ANDROID_SDK_ROOT="$HOME/Android/Sdk"
export ANDROID_HOME="$HOME/Android/Sdk"
export PATH="$JAVA_HOME/bin:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/build-tools/34.0.0:$PATH"

LOG "[13] Writing Fish shell environment config..."
mkdir -p "$HOME/.config/fish"
FISH_CFG="$HOME/.config/fish/config.fish"

cat > "$FISH_CFG" << 'FISH_EOF'
set -gx JAVA_HOME /usr/lib/jvm/java-17-openjdk
set -gx ANDROID_SDK_ROOT $HOME/Android/Sdk
set -gx ANDROID_HOME $HOME/Android/Sdk

fish_add_path $JAVA_HOME/bin
fish_add_path $ANDROID_SDK_ROOT/cmdline-tools/latest/bin
fish_add_path $ANDROID_SDK_ROOT/platform-tools
fish_add_path $ANDROID_SDK_ROOT/build-tools/34.0.0
FISH_EOF

echo "Fish config written to $FISH_CFG"

LOG "[14] Accepting Android SDK licenses..."
yes | sdkmanager --licenses || true

LOG "[15] Installing SDK components..."
sdkmanager --install \
    "platform-tools" \
    "platforms;android-34" \
    "build-tools;34.0.0" || true

LOG "[16] Deploying custom aapt2 binary..."
AAPT2_SRC="/storage/emulated/0/_Box/aapt2"
AAPT2_DST="/data/data/com.termux/files/usr/bin/aapt2"

if [ -f "$AAPT2_SRC" ]; then
    cp "$AAPT2_SRC" "$AAPT2_DST"
    chmod +x "$AAPT2_DST"
    echo "aapt2 deployed. Version:"
    aapt2 version || true
else
    echo "WARNING: aapt2 source not found at $AAPT2_SRC — skipping."
fi

LOG "[17] Building Android project..."
PROJECT_DIR="/storage/emulated/0/_Box/WaMi"

if [ -d "$PROJECT_DIR" ]; then
    cd "$PROJECT_DIR"
    sh ./gradlew assembleDebug
    echo "Build complete. APK output:"
    find . -name "*.apk" 2>/dev/null || true
else
    echo "WARNING: Project directory not found at $PROJECT_DIR — skipping build."
fi

LOG "[18] Setting Fish as default shell..."
chsh -s /usr/bin/fish || true

LOG "Bootstrap complete."
ARCH_SETUP

chmod +x "$HOME/arch-setup.sh"
echo "arch-setup.sh written to $HOME/arch-setup.sh"

echo "[19/19] Running arch-setup.sh inside Arch Linux container..."
proot-distro login archlinux -- bash "$HOME/arch-setup.sh"