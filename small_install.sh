#!/usr/bin/env bash
set -euo pipefail

echo "========================================"
echo "🚀 Advanced One-Command llama.cpp Installer"
echo "   Auto VRAM Detection + Interactive Menu"
echo "========================================"

MODELS_DIR="/home/$USER/llm-models"
LLAMA_DIR="/home/$USER/llama.cpp"
HERMES_SCRIPT="/home/$USER/start-hermes.sh"
PORT="8080"

# ====================== AUTO VRAM DETECTION ======================
detect_vram() {
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "Warning: nvidia-smi not found. Defaulting to conservative settings (12GB)."
    VRAM_GB=12
    return
  fi

  VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n1)
  VRAM_GB=$((VRAM_MB / 1024))

  echo "✅ Detected GPU VRAM: ${VRAM_GB} GB"
}

# Auto-tune CTX and NGL based on VRAM (conservative but performant)
auto_tune_settings() {
  detect_vram

  if [[ $VRAM_GB -ge 24 ]]; then
    CTX="131072"
    NGL="99"
    echo "→ High VRAM mode: 131k context, full offload"
  elif [[ $VRAM_GB -ge 16 ]]; then
    CTX="131072"
    NGL="99"
    echo "→ Good VRAM mode: 131k context, full offload"
  elif [[ $VRAM_GB -ge 12 ]]; then
    CTX="65536"
    NGL="95"
    echo "→ Medium VRAM mode: 65k context, near-full offload"
  else
    CTX="32768"
    NGL="80"
    echo "→ Low VRAM mode: 32k context, reduced offload"
  fi
}

# ====================== ADVANCED BUILD ======================
build_llama() {
  echo "→ Building/updating llama.cpp with advanced CUDA optimizations..."

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
    -DGGML_CUDA_ENABLE_UNIFIED_MEMORY=ON \
    -DGGML_NATIVE=ON \
    -DCMAKE_CUDA_ARCHITECTURES="native" \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLAMA_CURL=ON \
    -DGGML_LTO=ON

  cmake --build build --config Release -j "$(nproc)"

  echo "✅ Advanced build completed!"
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
BATCH="2048"
UBATCH="1024"

CACHE_K="q8_0"
CACHE_V="q4_0"
FLASH_ATTN="1"

EXTRA_FLAGS="--no-mmap --defrag-thold 0.1"

export GGML_CUDA_GRAPH_OPT=1

echo "🚀 Starting Hermes Agent (Auto-tuned: \${CTX} ctx, \${NGL} layers)"

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

echo "✅ Running on http://localhost:\${PORT}/v1"
echo "   Monitor: watch -n 0.5 nvidia-smi"
EOF

  chmod +x "$HERMES_SCRIPT"
  echo "✅ Hermes start script updated with auto-tuned settings"
}

# ====================== MAIN MENU ======================
main_menu() {
  while true; do
    echo ""
    echo "========================================"
    echo "          LLM Installer Menu"
    echo "========================================"
    echo "1) Build / Update llama.cpp (advanced CUDA)"
    echo "2) Download / Select Model"
    echo "3) Create/Update Hermes Agent script (auto VRAM tune)"
    echo "4) Start Hermes Agent now"
    echo "5) Show current auto-tuned settings"
    echo "6) Exit"
    echo "========================================"
    read -rp "Choose an option [1-6]: " option

    case $option in
      1)
        build_llama
        ;;
      2)
        mkdir -p "$MODELS_DIR"
        echo ""
        echo "Model Selector:"
        echo "1) Harmonic-Hermes-9B-Q5_K_M.gguf (recommended)"
        echo "2) Meta-Llama-3.1-8B-Instruct-Q5_K_M.gguf"
        echo "3) Custom GGUF URL"
        read -rp "Choose [1-3]: " model_choice

        case $model_choice in
          1)
            URL="https://huggingface.co/mradermacher/Harmonic-Hermes-9B-GGUF/resolve/main/Harmonic-Hermes-9B-Q5_K_M.gguf"
            NAME="Harmonic-Hermes-9B-Q5_K_M.gguf"
            ;;
          2)
            URL="https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q5_K_M.gguf"
            NAME="Meta-Llama-3.1-8B-Instruct-Q5_K_M.gguf"
            ;;
          3)
            read -rp "Enter full GGUF URL: " URL
            NAME=$(basename "$URL")
            ;;
          *)
            echo "Invalid choice."
            continue
            ;;
        esac

        if [[ ! -f "${MODELS_DIR}/$NAME" ]]; then
          echo "→ Downloading $NAME ..."
          wget --show-progress -O "${MODELS_DIR}/$NAME" "$URL"
        else
          echo "→ Model already exists."
        fi
        ;;
      3)
        create_hermes_script
        ;;
      4)
        if [[ -x "$HERMES_SCRIPT" ]]; then
          "$HERMES_SCRIPT"
        else
          echo "Hermes script not found. Please run option 3 first."
        fi
        ;;
      5)
        auto_tune_settings
        echo "Current auto-tuned settings:"
        echo "   Context : ${CTX} tokens"
        echo "   Layers  : ${NGL}"
        ;;
      6)
        echo "Goodbye!"
        exit 0
        ;;
      *)
        echo "Invalid option."
        ;;
    esac
  done
}

# ====================== INITIAL SETUP ======================
echo "→ Running first-time setup..."
mkdir -p "$MODELS_DIR"
build_llama
create_hermes_script

echo ""
echo "✅ Initial setup completed!"
echo "You can now use the menu for further actions."
main_menu
