#!/usr/bin/env bash
set -euo pipefail

echo "========================================"
echo "🚀 Fresh Ubuntu 24.04 WSL2 + RTX 3060 12GB Installer"
echo "   CUDA 12.6 + Optimized llama.cpp + Hermes Agent"
echo "========================================"

MODELS_DIR="/home/$USER/llm-models"
LLAMA_DIR="/home/$USER/llama.cpp"
HERMES_SCRIPT="/home/$USER/start-hermes.sh"
PORT="8080"

# ====================== 1. FULL SYSTEM & CUDA SETUP ======================
setup_fresh_system() {
  echo "→ Updating system and installing all dependencies..."

  sudo apt-get update -qq
  sudo apt-get upgrade -y -qq

  echo "→ Installing build tools and dependencies..."
  sudo apt-get install -y \
    build-essential \
    cmake \
    git \
    curl \
    wget \
    python3 \
    python3-pip \
    linux-headers-generic

  # Install CUDA 12.6 for WSL2 (recommended for RTX 3060)
  echo "→ Installing CUDA Toolkit 12.6..."
  wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
  sudo dpkg -i cuda-keyring_1.1-1_all.deb
  sudo apt-get update -qq
  sudo apt-get install -y cuda-toolkit-12-6

  # Set CUDA environment permanently
  cat << EOF | sudo tee /etc/profile.d/cuda.sh > /dev/null
export PATH=/usr/local/cuda-12.6/bin\${PATH:+:\${PATH}}
export LD_LIBRARY_PATH=/usr/local/cuda-12.6/lib64\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}
EOF

  source /etc/profile.d/cuda.sh

  echo "✅ CUDA 12.6 and all dependencies installed successfully."
}

# ====================== 2. AUTO TUNING FOR YOUR HARDWARE ======================
auto_tune_settings() {
  CTX="65536"      # Safe & good performance on 12GB VRAM
  NGL="94"         # 94 layers = excellent speed with headroom
  BATCH="1024"
  UBATCH="512"
  echo "→ Auto-tuned for RTX 3060 12GB + 16GB RAM: 65k context, 94 layers"
}

# ====================== 3. BUILD LLAMA.CPP ======================
build_llama() {
  echo "→ Cloning and building latest llama.cpp with CUDA 12.6..."

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
    -DCMAKE_BUILD_TYPE=Release

  echo "→ Building llama.cpp (this may take 8-15 minutes)..."
  cmake --build build --config Release -j "$(nproc)"

  echo "✅ llama.cpp built successfully for your RTX 3060!"
}

# ====================== 4. CREATE OPTIMIZED HERMES AGENT ======================
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

echo "🚀 Starting Hermes Agent (65k ctx | 94 layers | Optimized for RTX 3060 12GB)"

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

echo "✅ Hermes Agent running!"
echo "   Endpoint: http://localhost:\${PORT}/v1"
echo "   Monitor VRAM: watch -n 0.5 nvidia-smi"
EOF

  chmod +x "$HERMES_SCRIPT"
  echo "✅ Hermes Agent start script created."
}

# ====================== 5. MAIN MENU ======================
main_menu() {
  while true; do
    echo ""
    echo "========================================"
    echo "          RTX 3060 WSL2 Menu"
    echo "========================================"
    echo "1) Rebuild llama.cpp"
    echo "2) Download Harmonic-Hermes-9B-Q5_K_M.gguf"
    echo "3) Create/Update Hermes Agent script"
    echo "4) Start Hermes Agent"
    echo "5) Exit"
    read -rp "Choose [1-5]: " option

    case $option in
      1) build_llama ;;
      2)
        mkdir -p "$MODELS_DIR"
        echo "→ Downloading Harmonic-Hermes-9B-Q5_K_M.gguf..."
        wget --show-progress -O "${MODELS_DIR}/Harmonic-Hermes-9B-Q5_K_M.gguf" \
          https://huggingface.co/mradermacher/Harmonic-Hermes-9B-GGUF/resolve/main/Harmonic-Hermes-9B-Q5_K_M.gguf
        echo "✅ Model downloaded to ${MODELS_DIR}"
        ;;
      3) create_hermes_script ;;
      4)
        if [[ -x "$HERMES_SCRIPT" ]]; then
          "$HERMES_SCRIPT"
        else
          echo "Please run option 3 first."
        fi
        ;;
      5) echo "Goodbye!"; exit 0 ;;
      *) echo "Invalid option." ;;
    esac
  done
}

# ====================== EXECUTION STARTS HERE ======================
echo "→ Starting fresh installation on Ubuntu 24.04 WSL2..."
setup_fresh_system
mkdir -p "$MODELS_DIR"

build_llama
create_hermes_script

echo ""
echo "========================================"
echo "✅ Installation Completed Successfully!"
echo ""
echo "Next steps:"
echo "   1. Download model     → Press 2"
echo "   2. Create start script → Press 3"
echo "   3. Start server       → Press 4"
echo ""
echo "Your RTX 3060 12GB is now optimized (65k context recommended)."
main_menu
