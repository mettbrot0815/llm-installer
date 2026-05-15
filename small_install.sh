#!/usr/bin/env bash
# =============================================
# Smart TurboQuant Installer - Optimized Build
# RTX 3060 12GB | Best CUDA Flags 2026
# =============================================

set -euo pipefail

echo "========================================"
echo "🚀 Smart TurboQuant Installer (Optimized)"
echo "   RTX 3060 12GB - Best CUDA Flags"
echo "========================================"

MODELS_DIR="$HOME/llm-models"
LLAMA_DIR="$HOME/turboquant-llama"

mkdir -p "$MODELS_DIR"

# ====================== 1. DEPENDENCIES & CUDA ======================
echo "→ Installing dependencies..."
sudo apt update
sudo apt install -y build-essential cmake git curl wget python3 python3-pip \
    libssl-dev ninja-build linux-headers-generic pipx

# CUDA 12.6
if ! command -v nvcc &> /dev/null; then
    echo "→ Installing CUDA 12.6..."
    wget -q -O /tmp/cuda-keyring_1.1-1_all.deb https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb
    sudo dpkg -i /tmp/cuda-keyring_1.1-1_all.deb && rm /tmp/cuda-keyring_1.1-1_all.deb
    sudo apt update
    sudo apt install -y cuda-toolkit-12-6
fi

cat << EOF | sudo tee /etc/profile.d/cuda.sh > /dev/null
export PATH=/usr/local/cuda-12.6/bin:\$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-12.6/lib64:\$LD_LIBRARY_PATH
EOF

source /etc/profile.d/cuda.sh

# Install hf CLI
echo "→ Installing Hugging Face CLI..."
pipx install huggingface_hub[cli] --force --quiet

# ====================== 2. SMART BUILD WITH OPTIMIZED FLAGS ======================
echo "→ Checking llama.cpp..."

cd "$HOME"
if [ ! -d "$LLAMA_DIR" ]; then
    echo "→ Cloning llama.cpp..."
    git clone https://github.com/ggerganov/llama.cpp.git "$LLAMA_DIR"
    BUILD_NEEDED=1
else
    cd "$LLAMA_DIR"
    git fetch origin
    if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/master)" ] || [ ! -f "build/bin/llama-server" ]; then
        echo "→ Update detected → Rebuilding with optimized flags..."
        git pull
        BUILD_NEEDED=1
    else
        echo "✅ llama.cpp is up to date. Skipping rebuild."
        BUILD_NEEDED=0
    fi
fi

if [ "${BUILD_NEEDED:-1}" = 1 ]; then
    cd "$LLAMA_DIR"
    rm -rf build

    echo "→ Building with Optimized CUDA flags for RTX 3060..."
    
    cmake -B build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DGGML_CUDA=ON \
      -DGGML_CUDA_FA=ON \
      -DGGML_CUDA_FA_ALL_QUANTS=ON \
      -DGGML_NATIVE=ON \
      -DCMAKE_CUDA_ARCHITECTURES="86" \
      -DGGML_CUDA_MMQ=ON \
      -DGGML_CUDA_GRAPHS=ON \
      -DCMAKE_CUDA_FLAGS="-allow-unsupported-compiler -use_fast_math"

    cmake --build build --config Release -j "$(nproc)"
    echo "✅ Optimized build completed!"
fi

# ====================== 3. MODEL DOWNLOAD ======================
download_model() {
    local repo=$1
    local file=$2
    if [ ! -f "$MODELS_DIR/$file" ]; then
        echo "→ Downloading $file ..."
        hf download "$repo" "$file" --local-dir "$MODELS_DIR" --local-dir-use-symlinks False
    else
        echo "✅ $file already exists"
    fi
}

download_model "DJLougen/Harmonic-Hermes-9B-GGUF"      "Harmonic-Hermes-9B-Q5_K_M.gguf"
download_model "Huihui-Qwen3.5-9B-Abliterated-GGUF"   "Huihui-Qwen3.5-9B-abliterated.Q5_K_M.gguf"
download_model "Jackrong/Qwopus-GLM-18B-Merged-GGUF"  "Qwopus-GLM-18B-Healed-Q4_K_M.gguf"

# ====================== 4. CREATE START SCRIPTS ======================
create_script() {
    local name=$1 model=$2 ctx=$3 ngl=$4 desc=$5
    cat > "$HOME/start-$name.sh" << EOF
#!/usr/bin/env bash
pkill -9 -f "llama-server" 2>/dev/null || true
sleep 2
cd ~/turboquant-llama
echo "🚀 [$desc] $model"
./build/bin/llama-server \
  -m ~/llm-models/$model \
  -c $ctx --override-context $ctx \
  -ngl $ngl --flash-attn on -ctk turbo4 -ctv turbo4 \
  -b 512 -ub 256 --jinja --no-mmap --fit on --defrag-thold 0.1 \
  --temp 0.7 --top-p 0.9 --min-p 0.1 --repeat-penalty 1.05 \
  --host 0.0.0.0 --port 8080 -np 2
EOF
    chmod +x "$HOME/start-$name.sh"
}

create_script "harmonic-safe"      "Harmonic-Hermes-9B-Q5_K_M.gguf"      98304  93  "SAFE 96k"
create_script "harmonic-aggressive""Harmonic-Hermes-9B-Q5_K_M.gguf"     131072 88  "AGGRESSIVE 131k"
create_script "huihui"             "Huihui-Qwen3.5-9B-abliterated.Q5_K_M.gguf" 98304 92  "HUIHUI 96k"
create_script "qwopus"             "Qwopus-GLM-18B-Healed-Q4_K_M.gguf"   65536  78  "QWOPUS 18B"

# Menu Launcher
cat > "$HOME/llm-start" << 'EOF'
#!/usr/bin/env bash
echo "========================================"
echo "           LLM Quick Launcher"
echo "========================================"
echo "1) Harmonic-Hermes-9B     → Safe 96k      (Recommended)"
echo "2) Harmonic-Hermes-9B     → Aggressive 131k"
echo "3) Huihui-Qwen3.5 Abliterated → 96k"
echo "4) Qwopus-GLM-18B         → 64k"
echo "5) Exit"
read -rp "Choose [1-5]: " choice
case $choice in
  1) ./start-harmonic-safe.sh ;;
  2) ./start-harmonic-aggressive.sh ;;
  3) ./start-huihui.sh ;;
  4) ./start-qwopus.sh ;;
  5) echo "Goodbye!"; exit 0 ;;
  *) echo "Invalid option" ;;
esac
EOF

chmod +x "$HOME/llm-start"

echo ""
echo "========================================"
echo "✅ Smart Optimized Installation Completed!"
echo ""
echo "Use this command to launch models:"
echo "   ~/llm-start"
echo "========================================"
