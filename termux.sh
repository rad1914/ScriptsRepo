#!/data/data/com.termux/files/usr/bin/bash
termux-setup-storage
pkg update -y && pkg install -y proot-distro
proot-distro install archlinux

grep -q "proot-distro login archlinux" ~/.bashrc || \
echo 'proot-distro login archlinux' >> ~/.bashrc

cat > $HOME/arch-setup.sh <<'EOF'
#!/bin/bash
set -euo pipefail

SDK="$HOME/Android/Sdk"
TMP="${TMPDIR:-/tmp}"
ZIP="$TMP/sdk.zip"

io(){ echo "[+] $*"; }
e(){ echo "[!] $*" >&2; }

io "Updating packages..."
pacman -Syu --noconfirm

io "Installing dependencies..."
pacman -S --noconfirm --needed \
  fish jdk17-openjdk maven android-tools which openssh git curl wget unzip nodejs

mkdir -p ~/.ssh "$TMP"
[ -f ~/.ssh/id_ed25519 ] || \
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -C "$(whoami)@$(hostname)" || true

download(){
  wget -O "$2" "$1" || curl -fSL -o "$2" "$1"
}

rm -rf "$SDK"
mkdir -p "$SDK/cmdline-tools"

io "Downloading Android SDK..."
download https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip "$ZIP"

[ -s "$ZIP" ] || { e "Download failed."; exit 1; }

cd "$SDK/cmdline-tools"
unzip -q "$ZIP"
mv cmdline-tools latest
rm -f "$ZIP"

export JAVA_HOME="/usr/lib/jvm/java-17-openjdk"
export ANDROID_SDK_ROOT="$SDK"
export ANDROID_HOME="$SDK"
export PATH="$JAVA_HOME/bin:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$PATH"

mkdir -p ~/.config/fish
grep -q "ANDROID_SDK_ROOT" ~/.config/fish/config.fish 2>/dev/null || cat >> ~/.config/fish/config.fish <<EOL
set -Ux JAVA_HOME "/usr/lib/jvm/java-17-openjdk"
set -Ux ANDROID_SDK_ROOT "$SDK"
set -Ux ANDROID_HOME "$SDK"
fish_add_path \$JAVA_HOME/bin \
              \$ANDROID_SDK_ROOT/platform-tools \
              \$ANDROID_SDK_ROOT/cmdline-tools/latest/bin
EOL

io "Accepting licenses..."
yes | sdkmanager --licenses || true

io "Installing SDK components..."
sdkmanager "platform-tools" "platforms;android-34" "build-tools;34.0.0" || true

mv /storage/emulated/0/_Box/aapt2 /data/data/com.termux/files/usr/bin/
chmod +x /data/data/com.termux/files/usr/bin/aapt2
aapt2 version

cd "/storage/emulated/0/_Box/WaMi/" && sh ./gradlew assembleDebug

sleep 5 && chsh -s /usr/bin/fish
echo "Done. SDK at $SDK"
EOF

proot-distro login archlinux -- bash ~/arch-setup.sh