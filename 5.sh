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
sudo pacman -S --needed --noconfirm cmake ninja clang openmp git python python-pip python-virtualenv python312

echo "--> Removing old BitNet directory (if any)..."
sudo rm -rf "$BITNET_DIR"

echo "--> Cloning BitNet from GitHub..."
sudo -u "$USERNAME" git clone --recursive https://github.com/microsoft/BitNet.git "$BITNET_DIR"

cd "$BITNET_DIR"

echo "--> Installing Python requirements..."
sudo -u "$USERNAME" bash <<EOF
set -e

cd "$BITNET_DIR"

python3.12 -m venv .venv

source .venv/bin/activate

pip install --upgrade pip

pip install -r requirements.txt
EOF


echo ""
echo "==> [STAGE 10] Download Model and Build Runtime"

echo "--> Creating model directory: $MODEL_DIR"
sudo -u "$USERNAME" mkdir -p "$MODEL_DIR"

echo "--> Downloading BitNet GGUF model..."
sudo -u "$USERNAME" huggingface-cli download \
    microsoft/BitNet-b1.58-2B-4T-gguf \
    --local-dir "$MODEL_DIR"

echo "--> Building BitNet runtime and preparing GGUF..."
sudo -u "$USERNAME" bash <<EOF
set -e

cd "$BITNET_DIR"

source .venv/bin/activate

python3.12 setup_env.py -md "$MODEL_SUBDIR" -q i2_s
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
