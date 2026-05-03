#!/bin/bash
set -euo pipefail

SDK="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
TMP="${TMPDIR:-/tmp}"
ZIP="$TMP/sdk.zip"

io(){ echo "[+] $*"; }
e(){ echo "[!] $*" >&2; }
die(){ e "$*"; exit 1; }

detect_os() {
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    printf '%s\n' "${ID:-unknown}"
    return 0
  fi

  if [ -n "${OSTYPE:-}" ] && printf '%s' "$OSTYPE" | grep -qi 'linux'; then
    printf '%s\n' "linux"
    return 0
  fi

  printf '%s\n' "unknown"
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "Run this script as root on Arch Linux."
}

require_user() {
  [ "$(id -u)" -ne 0 ] || die "Run this script as your normal user on NixOS."
}

download() {
  if command -v wget >/dev/null 2>&1; then
    wget -O "$2" "$1"
  else
    curl -fSL -o "$2" "$1"
  fi
}

install_arch_deps() {
  require_root

  io "Updating packages..."
  pacman -Syu --noconfirm

  io "Installing dependencies..."
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
}

install_nixos_deps() {
  require_user

  command -v nix-env >/dev/null 2>&1 || die "nix-env is required on NixOS."

  io "Installing dependencies with nix-env..."
  nix-env -iA \
    nixpkgs.fish \
    nixpkgs.openjdk17 \
    nixpkgs.maven \
    nixpkgs.android-tools \
    nixpkgs.which \
    nixpkgs.openssh \
    nixpkgs.git \
    nixpkgs.curl \
    nixpkgs.wget \
    nixpkgs.unzip \
    nixpkgs.nodejs
}

setup_fish_env() {
  local fish_conf_dir="$HOME/.config/fish/conf.d"
  local fish_conf_file="$fish_conf_dir/android-sdk.fish"

  mkdir -p "$fish_conf_dir"

  cat >"$fish_conf_file" <<EOL
set -gx JAVA_HOME "/usr/lib/jvm/java-17-openjdk"
set -gx ANDROID_SDK_ROOT "$SDK"
set -gx ANDROID_HOME "$SDK"
fish_add_path $JAVA_HOME/bin \
              $ANDROID_SDK_ROOT/platform-tools \
              $ANDROID_SDK_ROOT/cmdline-tools/latest/bin
EOL
}

install_sdk() {
  mkdir -p "$SDK/cmdline-tools"
  rm -rf "$SDK/cmdline-tools/latest"

  io "Downloading Android SDK..."
  download https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip "$ZIP"

  [ -s "$ZIP" ] || die "Download failed."

  (
    cd "$SDK/cmdline-tools"
    unzip -q "$ZIP"
    mv cmdline-tools latest
  )
  rm -f "$ZIP"

  export JAVA_HOME="/usr/lib/jvm/java-17-openjdk"
  export ANDROID_SDK_ROOT="$SDK"
  export ANDROID_HOME="$SDK"
  export PATH="$JAVA_HOME/bin:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$PATH"

  io "Accepting licenses..."
  yes | sdkmanager --sdk_root="$SDK" --licenses || true

  io "Installing SDK components..."
  sdkmanager --sdk_root="$SDK" \
    "platform-tools" \
    "platforms;android-34" \
    "build-tools;34.0.0" || true
}

set_fish_shell() {
  local fish_bin
  fish_bin="$(command -v fish || true)"
  [ -n "$fish_bin" ] || return 0

  if command -v chsh >/dev/null 2>&1 && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER:-}" != "root" ]; then
    chsh -s "$fish_bin" "$SUDO_USER" || true
  fi
}

main() {
  case "$(detect_os)" in
    arch)
      install_arch_deps
      ;;
    nixos)
      install_nixos_deps
      ;;
    *)
      die "Unsupported operating system. This script supports Arch Linux and NixOS."
      ;;
  esac

  setup_fish_env
  install_sdk
  set_fish_shell

  io "Done. SDK at $SDK"
}

main "$@"
