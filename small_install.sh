#!/usr/bin/env bash
# =============================================
# TurboQuant Fork Installer (with turbo4 support)
# RTX 3060 12GB - Germany Optimized
# =============================================

set -euo pipefail

echo "========================================"
echo "🚀 TurboQuant Fork Installer"
echo "========================================"

MODELS_DIR="$HOME/llm-models"
LLAMA_DIR="$HOME/turboquant-llama"

mkdir -p "$MODELS_DIR"

# ====================== NETWORK & DEPENDENCIES ======================
sudo apt update
sudo apt install -y build-essential cmake git curl wget python3 python3-pip \
    libssl-dev ninja-build linux-headers-generic pipx

# Use German mirror
sudo sed -i 's|http://archive.ubuntu.com|http://de.archive.ubuntu.com|g' /etc/apt/sources.list
sudo apt update -o Acquire::ForceIPv4=true

# CUDA
if ! command -v nvcc &> /dev/null; then
    wget -q -O /tmp/cuda-keyring_1.1-1_all.deb https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb
    sudo dpkg -i /tmp/cuda-keyring_1.1-1_all.deb && rm /tmp/cuda-keyring_1.1-1_all.deb
    sudo apt install -y cuda-toolkit-12-6
fi

cat << EOF | sudo tee /etc/profile.d/cuda.sh > /dev/null
export PATH=/usr/local/cuda-12.6/bin:\$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-12.6/lib64:\$LD_LIBRARY_PATH
EOF

source /etc/profile.d/cuda.sh

pipx install huggingface_hub[cli] --force --quiet

# ====================== CLONE TURBOQUANT FORK ======================
echo "→ Setting up TurboQuant fork..."
cd "$HOME"

if [ ! -d "$LLAMA_DIR" ]; then
    git clone https://github.com/TheBloke/llama.cpp.git "$LLAMA_DIR"   # Most popular TurboQuant fork
    # Alternative: git clone https://github.com/ggerganov/llama.cpp.git "$LLAMA_DIR"
fi

cd "$LLAMA_DIR"
git pull

# ====================== BUILD WITH TURBOQUANT ======================
echo "→ Building TurboQuant version..."
rm -rf build

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

echo "✅ TurboQuant build completed!"

# ====================== DOWNLOAD MODELS ======================
hf download DJLougen/Harmonic-Hermes-9B-GGUF Harmonic-Hermes-9B-Q5_K_M.gguf --local-dir "$MODELS_DIR"
hf download Huihui-Qwen3.5-9B-Abliterated-GGUF Huihui-Qwen3.5-9B-abliterated.Q5_K_M.gguf --local-dir "$MODELS_DIR"
hf download Jackrong/Qwopus-GLM-18B-Merged-GGUF Qwopus-GLM-18B-Healed-Q4_K_M.gguf --local-dir "$MODELS_DIR"

# ====================== CREATE START SCRIPTS ======================
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

# Menu
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
echo "✅ TurboQuant Installation Complete!"
echo "Run: ~/llm-start"
