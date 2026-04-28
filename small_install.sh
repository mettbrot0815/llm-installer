#!/usr/bin/env bash
set -euo pipefail

echo "========================================"
echo "🚀 Optimized llama.cpp Installer for RTX 3060 12GB + 16GB RAM"
echo "========================================"

MODELS_DIR="/home/$USER/llm-models"
LLAMA_DIR="/home/$USER/llama.cpp"
HERMES_SCRIPT="/home/$USER/start-hermes.sh"
PORT="8080"

# ====================== INSTALL DEPENDENCIES ======================
install_dependencies() {
  echo "→ Installing required packages (cmake, build tools, etc.)..."
  sudo apt-get update -qq
  sudo apt-get install -y build-essential cmake git curl wget python3 python3-pip
  echo "✅ Dependencies installed."
}

# ====================== AUTO DETECTION & TUNING ======================
detect_vram() {
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "Warning: nvidia-smi not found. Using conservative 12GB settings."
    VRAM_GB=12
    return
  fi
  VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n1)
  VRAM_GB=$((VRAM_MB / 1024))
  echo "✅ Detected GPU VRAM: ${VRAM_GB} GB"
}

auto_tune_settings() {
  detect_vram
  # Best settings for RTX 3060 12GB + limited system RAM
  CTX="65536"
  NGL="95"
  BATCH="1024"
  UBATCH="512"
  echo "→ Tuned for your hardware: 65k context, 95 layers, balanced batch"
}

# ====================== BUILD LLAMA.CPP ======================
build_llama() {
  echo "→ Building/updating llama.cpp (RTX 3060 optimized)..."

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
    -DGGML_CUDA_MMQ=ON \
    -DGGML_CUDA_GRAPHS=ON \
    -DGGML_NATIVE=ON \
    -DCMAKE_CUDA_ARCHITECTURES="86" \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLAMA_CURL=ON

  cmake --build build --config Release -j "$(nproc)"

  echo "✅ llama.cpp built successfully for your RTX 3060!"
}

# ====================== CREATE HERMES SCRIPT ======================
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

echo "🚀 Starting Hermes Agent (65k ctx | 95 layers | tuned for 3060 12GB)"

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

echo "✅ Server ready at http://localhost:\${PORT}/v1"
echo "   Monitor VRAM: watch -n 0.5 nvidia-smi"
EOF

  chmod +x "$HERMES_SCRIPT"
  echo "✅ Hermes Agent script created with your hardware settings."
}

# ====================== MAIN MENU ======================
main_menu() {
  while true; do
    echo ""
    echo "========================================"
    echo "          RTX 3060 Menu"
    echo "========================================"
    echo "1) Build / Update llama.cpp"
    echo "2) Download Model"
    echo "3) Create/Update Hermes Agent script"
    echo "4) Start Hermes Agent"
    echo "5) Show tuned settings"
    echo "6) Exit"
    read -rp "Choose [1-6]: " option

    case $option in
      1) build_llama ;;
      2)
        mkdir -p "$MODELS_DIR"
        echo "1) Harmonic-Hermes-9B-Q5_K_M.gguf (recommended)"
        echo "2) Meta-Llama-3.1-8B-Instruct-Q5_K_M.gguf"
        echo "3) Custom URL"
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
          echo "Please run option 3 first."
        fi
        ;;
      5)
        auto_tune_settings
        echo "Current: Context=${CTX} | Layers=${NGL} | Batch=${BATCH}"
        ;;
      6) echo "Goodbye!"; exit 0 ;;
      *) echo "Invalid option." ;;
    esac
  done
}

# ====================== START ======================
install_dependencies
echo "→ Initial setup for RTX 3060 12GB..."
mkdir -p "$MODELS_DIR"
build_llama
create_hermes_script

echo ""
echo "✅ Setup finished! Use the menu below."
main_menu
