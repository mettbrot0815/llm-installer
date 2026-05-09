#!/usr/bin/env bash
set -euo pipefail

echo "========================================"
echo "🚀 Fresh Ubuntu 24.04 WSL2 + RTX 3060 12GB Installer"
echo "   CUDA 12.8 + Carnice-9B Agent (128k Context)"
echo "========================================"

MODELS_DIR="/home/$USER/llm-models"
LLAMA_DIR="/home/$USER/llama.cpp"
START_SCRIPT="/home/$USER/start-carnice.sh"
PORT="8082"

# ====================== 1. SYSTEM & CUDA 12.8 (WSL-OPTIMISED) ======================
setup_fresh_system() {
  echo "→ Updating system..."
  sudo apt-get update

  echo "→ Installing build dependencies..."
  sudo apt-get install -y build-essential cmake git curl wget python3 python3-pip linux-headers-generic

  echo "→ Installing CUDA 12.8 (WSL repo)..."
  local keyring_deb="/tmp/cuda-keyring_1.1-1_all.deb"
  wget -q -O "$keyring_deb" https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb
  sudo dpkg -i "$keyring_deb"
  rm -f "$keyring_deb"

  sudo apt-get update -qq
  sudo apt-get install -y cuda-toolkit-12-8

  # Permanent CUDA environment
  cat << EOF | sudo tee /etc/profile.d/cuda.sh > /dev/null
export PATH=/usr/local/cuda-12.8/bin\${PATH:+:\${PATH}}
export LD_LIBRARY_PATH=/usr/local/cuda-12.8/lib64\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}
EOF

  # Apply to current session
  export PATH=/usr/local/cuda-12.8/bin:$PATH
  export LD_LIBRARY_PATH=/usr/local/cuda-12.8/lib64:$LD_LIBRARY_PATH

  echo "✅ CUDA 12.8 ready."
}

# ====================== 2. BUILD LLAMA.CPP ONLY WHEN NEEDED ======================
build_llama() {
  cd /home/"$USER" || exit

  # Clone if not exists
  if [[ ! -d "$LLAMA_DIR" ]]; then
    echo "→ Cloning llama.cpp..."
    git clone https://github.com/ggerganov/llama.cpp.git "$LLAMA_DIR"
    cd "$LLAMA_DIR"
    NEED_BUILD=1
  else
    cd "$LLAMA_DIR"
    # Check for updates
    echo "→ Checking for llama.cpp updates..."
    OLD_COMMIT=$(git rev-parse HEAD)
    git pull --ff-only
    NEW_COMMIT=$(git rev-parse HEAD)

    if [[ "$OLD_COMMIT" == "$NEW_COMMIT" ]] && [[ -f "build/bin/llama-server" ]]; then
      echo "✅ llama.cpp already up-to-date (${NEW_COMMIT:0:7}). Skipping rebuild."
      return 0
    else
      echo "→ Update detected (${OLD_COMMIT:0:7} → ${NEW_COMMIT:0:7}). Rebuilding..."
      NEED_BUILD=1
    fi
  fi

  # Only rebuild if needed
  if [[ -n "${NEED_BUILD:-}" ]]; then
    rm -rf build

    # Prevent Windows host CUDA from interfering (temporarily sanitize PATH)
    SAVED_PATH="$PATH"
    # Keep only essential Linux paths + our CUDA, remove any Windows directories
    export PATH="/usr/local/cuda-12.8/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    cmake -B build \
      -DGGML_CUDA=ON \
      -DGGML_CUDA_FA=ON \
      -DGGML_CUDA_FA_ALL_QUANTS=ON \
      -DGGML_CUDA_MMQ=ON \
      -DGGML_CUDA_GRAPHS=ON \
      -DGGML_NATIVE=ON \
      -DCMAKE_CUDA_ARCHITECTURES="86" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCUDAToolkit_ROOT=/usr/local/cuda-12.8 \
      -DCMAKE_CUDA_COMPILER=/usr/local/cuda-12.8/bin/nvcc \
      -DCMAKE_CUDA_FLAGS="-allow-unsupported-compiler"

    echo "→ Building llama.cpp (8-15 minutes)..."
    cmake --build build --config Release -j "$(nproc)"

    # Restore original PATH
    export PATH="$SAVED_PATH"
    echo "✅ Build completed!"
  fi
}

# ====================== 3. CREATE OPTIMISED START SCRIPT ======================
create_start_script() {
  cat > "$START_SCRIPT" << 'EOF'
#!/usr/bin/env bash
cd ~/llama.cpp

echo "🚀 Starting Carnice-9B Agent (128k context | tuned for RTX 3060)"

./build/bin/llama-server \
  -m ~/llm-models/Carnice-9b-Q6_K.gguf \
  -ngl 94 \
  -c 131072 \
  -b 1024 \
  -ub 512 \
  --cache-type-k q8_0 \
  --cache-type-v q4_0 \
  --temp 0.7 \
  --top-p 0.95 \
  --repeat-penalty 1.05 \
  --host 0.0.0.0 \
  --port 8082 \
  --jinja \
  --fa 1 \
  --no-mmap \
  --defrag-thold 0.1
EOF

  chmod +x "$START_SCRIPT"
  echo "✅ Start script created: ~/start-carnice.sh"
}

# ====================== 4. DOWNLOAD MODEL (ONE-LINER PROVIDED) ======================
download_model() {
  if [[ -f "$MODELS_DIR/Carnice-9b-Q6_K.gguf" ]]; then
    echo "✅ Model already exists at $MODELS_DIR/Carnice-9b-Q6_K.gguf"
  else
    echo "→ Model not found. Please download it manually with this command:"
    echo ""
    echo "mkdir -p $MODELS_DIR && wget -c 'https://huggingface.co/kai-os/Carnice-9b-GGUF/resolve/main/Carnice-9b-Q6_K.gguf?download=true' -O $MODELS_DIR/Carnice-9b-Q6_K.gguf"
    echo ""
    read -rp "Press Enter after downloading (or Ctrl+C to exit)..."
  fi
}

# ====================== 5. MAIN EXECUTION ======================
setup_fresh_system
mkdir -p "$MODELS_DIR"
build_llama
create_start_script
download_model

echo ""
echo "========================================"
echo "✅ Installation Ready!"
echo ""
echo "Next steps:"
echo "  1. Download the model if not done yet (see above)"
echo "  2. Start the server:   ~/start-carnice.sh"
echo "  3. API endpoint:       http://localhost:${PORT}/v1"
echo ""
echo "To stop the server: Press Ctrl+C"
echo "========================================"
