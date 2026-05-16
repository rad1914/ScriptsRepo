#!/usr/bin/env bash
set -euo pipefail

BITNET_DIR="$REAL_HOME/BitNet"
MODEL_DIR="$BITNET_DIR/model"
MODEL_FILE="$MODEL_DIR/ggml-model-i2_s.gguf"

echo "[Stage 10] Creating model directory..."
mkdir -p "$MODEL_DIR"
chown -R "$USERNAME":"$USERNAME" "$BITNET_DIR"

echo "[Stage 10] Downloading GGUF model as $USERNAME..."
sudo -u "$USERNAME" wget -c -O "$MODEL_FILE" \
    "https://huggingface.co/microsoft/bitnet-b1.58-2B-4T-gguf/resolve/main/ggml-model-i2_s.gguf"

echo "[Stage 10] Model download complete."

echo "[Stage 11] Searching for llama executable..."

LLAMA_CLI=""
for candidate in \
    "$LLAMA_DIR/build/bin/llama-cli" \
    "$LLAMA_DIR/build/bin/main" \
    "$LLAMA_DIR/build/bin/Release/llama-cli" \
    "$LLAMA_DIR/build/bin/Release/main"
do
    if [[ -x "$candidate" ]]; then
        LLAMA_CLI="$candidate"
        echo "[Stage 11] Found executable: $LLAMA_CLI"
        break
    fi
done

if [[ -z "$LLAMA_CLI" ]]; then
    echo "[ERROR] No llama executable found in $LLAMA_DIR/build/bin/" >&2
    exit 1
fi

if [[ ! -f "$MODEL_FILE" ]]; then
    echo "[ERROR] Model file not found: $MODEL_FILE" >&2
    exit 1
fi

echo "[Stage 11] Running inference test..."
"$LLAMA_CLI" \
    -m "$MODEL_FILE" \
    -p "Hello, BitNet. Describe yourself in one sentence." \
    -n 64 \
    --temp 0.0

echo "[Stage 11] Inference test complete."