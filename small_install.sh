#!/usr/bin/env bash
set -euo pipefail

echo "========================================"
echo "🚀 Fresh Ubuntu 24.04 WSL2 + RTX 3060 Installer"
echo "   Full CUDA + llama.cpp + Hermes Agent"
echo "========================================"

MODELS_DIR="/home/$USER/llm-models"
LLAMA_DIR="/home/$USER/llama.cpp"
HERMES_SCRIPT="/home/$USER/start-hermes.sh"
PORT="8080"

# ====================== 1. FULL DEPENDENCIES & CUDA SETUP (WSL2) ======================
setup_fresh_system() {
  echo "→ Updating system and installing ALL required dependencies..."

  sudo apt-get update -qq
  sudo apt-get upgrade -y -qq

  echo "→ Installing build tools, git, wget, and NVIDIA CUDA for WSL2..."
  sudo apt-get install -y \
    build-essential \
    cmake \
    git \
    curl \
    wget \
    python3 \
    python3-pip \
    linux-headers-generic

  # Install CUDA Toolkit for WSL2 (Ubuntu 24.04)
  echo "→ Installing CUDA Toolkit 12.6 (best stable for RTX 3060 on WSL2)..."
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

  echo "✅ CUDA 12.6 + all dependencies installed."
}

# ====================== 2. AUTO TUNING FOR RTX 3060 12GB + 16GB RAM ======================
auto_tune_settings() {
  CTX="65536"      # Safe and performant on 12GB
  NGL="94"         # 94 layers = very good speed, leaves headroom
  BATCH="1024"
  UBATCH="512"
  echo "→ Auto-tuned for RTX 3060 12GB + 16GB RAM: 65k context, 94 layers"
}

# ====================== 3. BUILD LLAMA.CPP ======================
build_llama() {
  echo "→ Cloning and building latest llama.cpp with CUDA..."

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

  echo "→ Building (this will take 8-15 minutes)..."
  cmake --build build --config Release -j "$(nproc)"

  echo "✅ llama.cpp built successfully!"
}

# ====================== 4. CREATE OPTIMIZED HERMES AGENT ======================
create_hermes_script() {
  auto_tune_settings

  cat > "$HERMES_SCRIPT" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

GGUF="/home/$USER/llm-models/Harmonic-Hermes-9B-Q5_K_M.gguf"
LLAMA_BIN="/home/$USER/llama.cpp/build/bin/llama-server"
PORT="8080"

CTX="65536"
NGL="94"
BATCH="1024"
UBATCH="512"

CACHE_K="q8_0"
CACHE_V="q4_0"
FLASH_ATTN="1"

EXTRA_FLAGS="--no-mmap --defrag-thold 0.1"

echo "🚀 Starting Hermes Agent (65k ctx | 94 layers | Optimized for RTX 3060 12GB)"

"$LLAMA_BIN" \
  -m "$GGUF" \
  -ngl "$NGL" \
  -fa "$FLASH_ATTN" \
  -b "$BATCH" \
  -ub "$UBATCH" \
  -c "$CTX" \
  --cache-type-k "$CACHE_K" \
  --cache-type-v "$CACHE_V" \
  --host 0.0.0.0 \
  --port "$PORT" \
  --jinja \
  ${EXTRA_FLAGS} &

echo "✅ Hermes Agent is running!"
echo "   OpenAI-compatible endpoint: http://localhost:8080/v1"
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
    echo "          Fresh WSL2 Menu"
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
        echo "→ Downloading Harmonic-Hermes-9B-Q5_K_M.gguf (best for 12GB)..."
        wget --show-progress -O "${MODELS_DIR}/Harmonic-Hermes-9B-Q5_K_M.gguf" \
          https://huggingface.co/mradermacher/Harmonic-Hermes-9B-GGUF/resolve/main/Harmonic-Hermes-9B-Q5_K_M.gguf
        echo "✅ Model downloaded."
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

# ====================== START EXECUTION ======================
echo "→ This is a fresh Ubuntu 24.04 WSL2 setup. Installing everything..."
setup_fresh_system
mkdir -p "$MODELS_DIR"

build_llama
create_hermes_script

echo ""
echo "========================================"
echo "✅ Installation Complete!"
echo ""
echo "Recommended next steps:"
echo "   1. Download the model     → Menu option 2"
echo "   2. Create start script    → Menu option 3"
echo "   3. Start the server       → Menu option 4"
echo ""
echo "Your system is now fully optimized for RTX 3060 12GB."
main_menu
