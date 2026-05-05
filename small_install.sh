#!/usr/bin/env bash
set -euo pipefail

echo "========================================"
echo "🚀 Gemma 4 26B-A4B UD-IQ3_XXS Installer for RTX 3060 12GB"
echo "   Optimized for 64K Context"
echo "========================================"

# ====================== CONFIG ======================
MODELS_DIR="/home/$USER/llm-models"
LLAMA_DIR="/home/$USER/llama.cpp"
START_SCRIPT="/home/$USER/start-llm.sh"
PORT="8080"

# Tuned settings for your hardware
CONTEXT=65536
NGL=72
BATCH=512
UBATCH=256

echo "→ Using 64K Context | -ngl ${NGL}"

# ====================== BUILD LLAMA.CPP ======================
build_llama() {
  echo "→ Updating / Building llama.cpp..."
  cd /home/"$USER" || exit

  if [[ -d "$LLAMA_DIR" ]]; then
    echo "   Updating existing llama.cpp..."
    cd "$LLAMA_DIR"
    git pull --ff-only || true
  else
    echo "   Cloning llama.cpp..."
    git clone https://github.com/ggerganov/llama.cpp.git "$LLAMA_DIR"
    cd "$LLAMA_DIR"
  fi

  rm -rf build

  cmake -B build \
    -DGGML_CUDA=ON \
    -DGGML_CUDA_FA=ON \
    -DGGML_CUDA_FA_ALL_QUANTS=ON \
    -DCMAKE_CUDA_ARCHITECTURES="86" \
    -DCMAKE_BUILD_TYPE=Release

  echo "→ Compiling (this can take 8-15 minutes)..."
  cmake --build build --config Release -j "$(nproc)"

  echo "✅ llama.cpp built successfully!"
}

# ====================== CREATE START SCRIPT ======================
create_start_script() {
  cat > "$START_SCRIPT" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

GGUF="/home/user/llm-models/gemma-4-26B-A4B-it-UD-IQ3_XXS.gguf"
LLAMA_BIN="/home/user/llama.cpp/build/bin/llama-server"
PORT="8080"
CONTEXT=65536

echo "🚀 Starting Gemma 4 26B-A4B UD-IQ3_XXS | 64K Context"

pkill -9 llama-server 2>/dev/null || true
sleep 2

"${LLAMA_BIN}" \
  -m "${GGUF}" \
  -ngl 72 \
  -fa on \
  -c ${CONTEXT} \
  --cache-type-k q4_0 \
  --cache-type-v q4_0 \
  -b 512 \
  -ub 256 \
  -np 1 \
  --no-mmap \
  --host 0.0.0.0 \
  --port ${PORT} \
  --jinja
EOF

  chmod +x "$START_SCRIPT"
  echo "✅ Start script created → $START_SCRIPT"
}

# ====================== MAIN ======================
echo "→ Starting installation..."

sudo apt-get update -qq
sudo apt-get install -y build-essential cmake git curl wget python3 python3-pip

mkdir -p "$MODELS_DIR"

build_llama
create_start_script

echo ""
echo "========================================"
echo "✅ Installation Finished!"
echo ""
echo "Next Steps:"
echo "   1. Download the model (if not already):"
echo "      https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF"
echo "      → Download: gemma-4-26B-A4B-it-UD-IQ3_XXS.gguf"
echo ""
echo "   2. Start the server:"
echo "      ./start-llm.sh"
echo ""
echo "   3. Test in browser: http://localhost:8080"
echo "========================================"
