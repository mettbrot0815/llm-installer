#!/usr/bin/env bash
set -euo pipefail

echo "========================================"
echo "🚀 Fresh Ubuntu 24.04 WSL2 + RTX 3060 12GB Installer"
echo "   CUDA 12.8 + Carnice-9B Agent (64k Context)"
echo "========================================"

MODELS_DIR="/home/$USER/llm-models"
LLAMA_DIR="/home/$USER/llama.cpp"
HERMES_SCRIPT="/home/$USER/start-hermes.sh"
PORT="8082"

# ====================== 1. SYSTEM & CUDA 12.8 ======================
setup_fresh_system() {
  echo "→ Updating system..."
  sudo apt-get update

  echo "→ Installing dependencies..."
  sudo apt-get install -y build-essential cmake git curl wget python3 python3-pip linux-headers-generic

  echo "→ Installing CUDA 12.8..."
  wget -q -O /tmp/cuda-keyring_1.1-1_all.deb https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb
  sudo dpkg -i /tmp/cuda-keyring_1.1-1_all.deb
  rm -f /tmp/cuda-keyring_1.1-1_all.deb

  sudo apt-get update -qq
  sudo apt-get install -y cuda-toolkit-12-8

  cat << EOF | sudo tee /etc/profile.d/cuda.sh > /dev/null
export PATH=/usr/local/cuda-12.8/bin\${PATH:+:\${PATH}}
export LD_LIBRARY_PATH=/usr/local/cuda-12.8/lib64\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}
EOF

  source /etc/profile.d/cuda.sh
  echo "✅ CUDA 12.8 ready."
}

# ====================== 2. OPTIMIZED BUILD WITH K-CORES FLAGS ======================
build_llama() {
  cd /home/"$USER" || exit

  if [[ ! -d "$LLAMA_DIR" ]]; then
    git clone https://github.com/ggerganov/llama.cpp.git "$LLAMA_DIR"
  fi

  cd "$LLAMA_DIR"
  git pull

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

  echo "→ Building... (8-15 minutes)"
  cmake --build build --config Release -j "$(nproc)"
  echo "✅ Build completed!"
}

# ====================== 3. CREATE START SCRIPT ======================
create_hermes_script() {
  cat > "$HERMES_SCRIPT" << 'EOF'
#!/usr/bin/env bash
cd ~/llama.cpp

echo "🚀 Starting Carnice-9B Agent (64k context)..."

./build/bin/llama-server \
  -m ~/llm-models/Carnice-9b-Q6_K.gguf \
  -ngl 94 \
  -fa 1 \
  -b 1024 \
  -ub 512 \
  -c 65536 \
  --cache-type-k q8_0 \
  --cache-type-v q4_0 \
  --host 0.0.0.0 \
  --port 8082 \
  --jinja \
  --no-mmap \
  --defrag-thold 0.1
EOF

  chmod +x "$HERMES_SCRIPT"
  echo "✅ Start script created: ~/start-hermes.sh"
}

# ====================== MAIN ======================
setup_fresh_system
mkdir -p "$MODELS_DIR"
build_llama
create_hermes_script

echo ""
echo "========================================"
echo "✅ Installation Finished!"
echo ""
echo "Next Steps:"
echo "   1. Download model (official kai-os Q6_K):"
echo "      wget -c https://huggingface.co/kai-os/Carnice-9b-GGUF/resolve/main/Carnice-9b-Q6_K.gguf?download=true -O ~/llm-models/Carnice-9b-Q6_K.gguf"
echo "   2. Start server:   ~/start-hermes.sh"
echo "   3. Agent API:      http://localhost:8082/v1"
echo "========================================"
