#!/usr/bin/env bash
# 5.sh

set -e
set -u
set -o pipefail

USERNAME="radwrld"
REAL_HOME="/home/$USERNAME"
BITNET_DIR="$REAL_HOME/BitNet"
MODEL_DIR="$BITNET_DIR/model"
MODEL_FILE="$MODEL_DIR/ggml-model-i2_s.gguf"
LLAMA_DIR="$REAL_HOME/llama.cpp"

echo "==> [CONFIG]"
echo "    REAL_HOME  : $REAL_HOME"
echo "    USERNAME   : $USERNAME"
echo "    LLAMA_DIR  : $LLAMA_DIR"
echo "    MODEL_FILE : $MODEL_FILE"

echo ""
echo "==> [STAGE 9] Build llama.cpp"

echo "--> Installing build dependencies..."
sudo pacman -S --needed --noconfirm cmake ninja clang openmp git

echo "--> Removing old llama.cpp directory (if any)..."
sudo rm -rf "$LLAMA_DIR"

echo "--> Cloning llama.cpp from GitHub..."
sudo -u "$USERNAME" git clone https://github.com/ggerganov/llama.cpp.git "$LLAMA_DIR"

LLAMA_EXEC=""
for candidate in \
    "$LLAMA_DIR/build/bin/llama-cli" \
    "$LLAMA_DIR/build/bin/main" \
    "$LLAMA_DIR/build/bin/Release/llama-cli" \
    "$LLAMA_DIR/build/bin/Release/main"; do
    if [[ -x "$candidate" ]]; then
        LLAMA_EXEC="$candidate"
        break
    fi
done

if [[ -n "$LLAMA_EXEC" ]]; then
    echo "--> Executable already exists at: $LLAMA_EXEC — skipping build."
else

    echo "--> Configuring CMake build (Release + OpenMP)..."
    sudo -u "$USERNAME" cmake \
        -S "$LLAMA_DIR" \
        -B "$LLAMA_DIR/build" \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DGGML_OPENMP=ON

    # --- 9.5 Compile ---
    echo "--> Compiling with Ninja..."
    sudo -u "$USERNAME" ninja -C "$LLAMA_DIR/build"
fi

echo ""
echo "==> [STAGE 10] Prepare BitNet GGUF Model"

echo "--> Creating model directory: $MODEL_DIR"
mkdir -p "$MODEL_DIR"

echo "--> Setting ownership to $USERNAME..."
chown -R "$USERNAME":"$USERNAME" "$BITNET_DIR"

echo "--> Downloading BitNet GGUF model (resume-capable)..."
sudo -u "$USERNAME" wget -c \
    -O "$MODEL_FILE" \
    "https://huggingface.co/microsoft/bitnet-b1.58-2B-4T-gguf/resolve/main/ggml-model-i2_s.gguf"

echo "--> Model download complete."

echo ""
echo "==> [STAGE 11] Validate Runtime"

LLAMA_EXEC=""
for candidate in \
    "$LLAMA_DIR/build/bin/llama-cli" \
    "$LLAMA_DIR/build/bin/main" \
    "$LLAMA_DIR/build/bin/Release/llama-cli" \
    "$LLAMA_DIR/build/bin/Release/main"; do
    if [[ -x "$candidate" ]]; then
        LLAMA_EXEC="$candidate"
        echo "--> Found executable: $LLAMA_EXEC"
        break
    fi
done

if [[ -z "$LLAMA_EXEC" ]]; then
    echo "[ERROR] No llama executable found after build. Aborting."
    exit 1
fi

if [[ ! -f "$MODEL_FILE" ]]; then
    echo "[ERROR] Model file not found: $MODEL_FILE. Aborting."
    exit 1
fi


echo "--> Running inference validation..."
echo "    Prompt     : 'Hello, BitNet. Describe yourself in one sentence.'"
echo "    Max tokens : 64"
echo "    Temperature: 0.0"
echo ""

sudo -u "$USERNAME" "$LLAMA_EXEC" \
    --model "$MODEL_FILE" \
    --prompt "Hello, BitNet. Describe yourself in one sentence." \
    --n-predict 64 \
    --temp 0.0

echo ""
echo "==> [DONE] Inference validation complete."
