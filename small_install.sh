#!/usr/bin/env bash
set -euo pipefail

echo "========================================"
echo "🚀 Optimized llama.cpp Installer for RTX 3060 12GB + 16GB RAM"
echo "   Auto VRAM Detection + Smart Tuning"
echo "========================================"

MODELS_DIR="/home/$USER/llm-models"
LLAMA_DIR="/home/$USER/llama.cpp"
HERMES_SCRIPT="/home/$USER/start-hermes.sh"
PORT="8080"

# ====================== AUTO DETECTION & TUNING ======================
detect_vram() {
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "Warning: nvidia-smi not found. Using conservative 12GB settings."
    VRAM_GB=12
    return
  fi

  VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n1)
  VRAM_GB=$((VRAM_MB / 1024))
  echo "✅ Detected GPU VRAM: ${VRAM_GB} GB (System RAM: 16GB)"
}

auto_tune_settings() {
  detect_vram

  # Optimized for 12GB VRAM + low system RAM
  if [[ $VRAM_GB -ge 12 ]]; then
    CTX="65536"      # Safe 65k context with good KV cache headroom
    NGL="95"         # Near full offload (leave a few layers for stability)
    BATCH="1024"
    UBATCH="512"
    echo "→ 12GB VRAM mode: 65k context, 95 layers (balanced & stable)"
  else
    CTX="32768"
    NGL="80"
    BATCH="512"
    UBATCH="256"
    echo "→ Low VRAM fallback: 32k context"
  fi
}

# ====================== ADVANCED BUILD (RTX 3060 Optimized) ======================
build_llama() {
  echo "→ Building/updating llama.cpp with RTX 3060-tuned CUDA flags..."

  cd /home/"$USER" || exit

  if [[ -d "$LLAMA_DIR" ]]; then
    cd "$LLAMA_DIR"
    git pull --ff-only
  else
    git clone https://github.com/ggerganov/llama.cpp.git "$LLAMA_DIR"
    cd "$LLAMA_DIR"
  fi

  rm -rf build

  cmake -B build \
    -DGGML_CUDA=ON \
    -DGGML_CUDA_FA=ON \
    -DGGML_CUDA_FA_ALL_QUANTS=ON \
    -DGGML_CUDA_F16=ON \
    -DGGML_CUDA_MMQ=ON \
    -DGGML_CUDA_GRAPHS=ON \
    -DGGML_NATIVE=ON \
    -DCMAKE_CUDA_ARCHITECTURES="86" \   # Ada Lovelace (RTX 30-series)
    -DCMAKE_BUILD_TYPE=Release \
    -DLLAMA_CURL=ON \
    -DGGML_LTO=ON

  cmake --build build --config Release -j "$(nproc)"

  echo "✅ Build completed for RTX 3060!"
}

# ====================== CREATE HERMES START SCRIPT ======================
create_hermes_script() {
  auto_tune_settings

  cat > "$HERMES_SCRIPT" << EOF
#!/usr/bin/env bash
set -euo pipefail

GGUF="${MODELS_DIR}/Harmonic-Hermes-9B-Q5_K_M.gguf"
LLAMA_BIN="${LLAMA_DIR}/build/bin/llama-server"
PORT="${PORT}"

CTX="${CTX}"
NGL="${NGL}"
BATCH="${BATCH}"
UBATCH="${UBATCH}"

CACHE_K="q8_0"
CACHE_V="q4_0"
FLASH_ATTN="1"

EXTRA_FLAGS="--no-mmap --defrag-thold 0.1"

echo "🚀 Starting Hermes Agent (RTX 3060 tuned: \${CTX} ctx, \${NGL} layers)"

"\$LLAMA_BIN" \
  -m "\$GGUF" \
  -ngl "\$NGL" \
  -fa "\$FLASH_ATTN" \
  -b "\$BATCH" \
  -ub "\$UBATCH" \
  -c "\$CTX" \
  --cache-type-k "\$CACHE_K" \
  --cache-type-v "\$CACHE_V" \
  --host 0.0.0.0 \
  --port "\$PORT" \
  --jinja \
  \${EXTRA_FLAGS} &

echo "✅ Server running → http://localhost:\${PORT}/v1"
echo "   Monitor: watch -n 0.5 nvidia-smi"
echo "   Tip: If OOM occurs, edit start-hermes.sh and lower CTX or NGL"
EOF

  chmod +x "$HERMES_SCRIPT"
  echo "✅ Hermes Agent script created/updated with your hardware settings"
}

# ====================== MAIN MENU ======================
main_menu() {
  while true; do
    echo ""
    echo "========================================"
    echo "          RTX 3060 Installer Menu"
    echo "========================================"
    echo "1) Build / Update llama.cpp"
    echo "2) Download Model (Harmonic-Hermes or others)"
    echo "3) Create/Update Hermes Agent script (auto-tuned)"
    echo "4) Start Hermes Agent"
    echo "5) Show current tuned settings"
    echo "6) Exit"
    echo "========================================"
    read -rp "Choose [1-6]: " option

    case $option in
      1) build_llama ;;
      2)
        mkdir -p "$MODELS_DIR"
        echo ""
        echo "1) Harmonic-Hermes-9B-Q5_K_M.gguf (recommended for 12GB)"
        echo "2) Meta-Llama-3.1-8B-Instruct-Q5_K_M.gguf"
        echo "3) Custom GGUF URL"
        read -rp "Choose [1-3]: " mc
        case $mc in
          1) URL="https://huggingface.co/mradermacher/Harmonic-Hermes-9B-GGUF/resolve/main/Harmonic-Hermes-9B-Q5_K_M.gguf"; NAME="Harmonic-Hermes-9B-Q5_K_M.gguf" ;;
          2) URL="https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q5_K_M.gguf"; NAME="Meta-Llama-3.1-8B-Instruct-Q5_K_M.gguf" ;;
          3) read -rp "Full GGUF URL: " URL; NAME=$(basename "$URL") ;;
          *) echo "Invalid"; continue ;;
        esac
        if [[ ! -f "${MODELS_DIR}/$NAME" ]]; then
          wget --show-progress -O "${MODELS_DIR}/$NAME" "$URL"
        else
          echo "Model already exists."
        fi
        ;;
      3) create_hermes_script ;;
      4)
        if [[ -x "$HERMES_SCRIPT" ]]; then
          "$HERMES_SCRIPT"
        else
          echo "Run option 3 first."
        fi
        ;;
      5)
        auto_tune_settings
        echo "Current settings → Context: ${CTX} | Layers: ${NGL} | Batch: ${BATCH}"
        ;;
      6) echo "Goodbye!"; exit 0 ;;
      *) echo "Invalid option." ;;
    esac
  done
}

# ====================== FIRST RUN ======================
echo "→ Performing initial setup for your RTX 3060 12GB..."
mkdir -p "$MODELS_DIR"
build_llama
create_hermes_script

echo ""
echo "✅ Setup complete! Your system is now tuned for 12GB VRAM + 16GB RAM."
echo "Recommended: Use option 4 to start the server."
main_menu
