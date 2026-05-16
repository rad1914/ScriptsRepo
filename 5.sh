#!/usr/bin/env bash
# 5.sh

set -e
set -u
set -o pipefail

USERNAME="radwrld"
REAL_HOME="/home/$USERNAME"
BITNET_DIR="$REAL_HOME/BitNet"
MODEL_SUBDIR="models/BitNet-b1.58-2B-4T"
MODEL_DIR="$BITNET_DIR/$MODEL_SUBDIR"
MODEL_FILE="$MODEL_DIR/ggml-model-i2_s.gguf"

echo "==> [CONFIG]"
echo "    REAL_HOME  : $REAL_HOME"
echo "    USERNAME   : $USERNAME"
echo "    BITNET_DIR : $BITNET_DIR"
echo "    MODEL_FILE : $MODEL_FILE"

echo ""
echo "==> [STAGE 9] Build BitNet"

echo "--> Installing build dependencies..."
sudo pacman -S --needed --noconfirm \
    base-devel \
    cmake \
    ninja \
    clang \
    openmp \
    llvm-openmp \
    git \
    python \
    python-pip \
    python-huggingface-hub \
    python-virtualenv \
    uv

echo "--> Removing old BitNet directory (if any)..."
sudo rm -rf "$BITNET_DIR"

echo "--> Cloning BitNet from GitHub..."
sudo -u "$USERNAME" git clone --recursive https://github.com/microsoft/BitNet.git "$BITNET_DIR"

cd "$BITNET_DIR"

echo "--> Installing Python requirements..."
sudo -u "$USERNAME" bash <<EOF
set -e

cd "$BITNET_DIR"

rm -rf .venv

uv venv --python 3.12 .venv

source .venv/bin/activate

uv pip install --upgrade pip

uv pip install -r requirements.txt
EOF


echo ""
echo "==> [STAGE 10] Download Model and Build Runtime"

echo "--> Creating model directory: $MODEL_DIR"
sudo -u "$USERNAME" mkdir -p "$MODEL_DIR"

echo "--> Downloading BitNet GGUF model..."
sudo -u "$USERNAME" hf download \
    microsoft/BitNet-b1.58-2B-4T-gguf \
    --local-dir "$MODEL_DIR"

echo "--> Building BitNet runtime and preparing GGUF..."
sudo -u "$USERNAME" bash <<EOF
set -e

cd "$BITNET_DIR"

echo "--> Patching ggml-bitnet-mad.cpp for Clang const correctness..."
sed -i \
    's/int8_t \* y_col = y + col \* by;/const int8_t * y_col = y + col * by;/' \
    src/ggml-bitnet-mad.cpp

export CC=clang
export CXX=clang++
export CMAKE_C_COMPILER=clang
export CMAKE_CXX_COMPILER=clang++

source .venv/bin/activate

python setup_env.py -md "$MODEL_SUBDIR" -q i2_s
EOF

echo ""
echo "==> [STAGE 11] Validate Runtime"

LLAMA_EXEC=""
for candidate in \
    "$BITNET_DIR/build/bin/llama-cli" \
    "$BITNET_DIR/build/bin/main" \
    "$BITNET_DIR/build/bin/Release/llama-cli" \
    "$BITNET_DIR/build/bin/Release/main"; do
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
