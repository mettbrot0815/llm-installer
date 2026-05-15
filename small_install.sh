#!/usr/bin/env bash
# =============================================
# Full TurboQuant Installer - 3 Models
# RTX 3060 12GB Optimized
# =============================================

set -euo pipefail

echo "========================================"
echo "🚀 TurboQuant + 3 Models Installer"
echo "   Harmonic-Hermes | Huihui Abliterated | Qwopus-18B"
echo "========================================"

MODELS_DIR="$HOME/llm-models"
LLAMA_DIR="$HOME/turboquant-llama"

mkdir -p "$MODELS_DIR"

# ====================== 1. CUDA & SYSTEM SETUP ======================
echo "→ Installing dependencies & CUDA 12.6..."
sudo apt update
sudo apt install -y build-essential cmake git curl wget python3 python3-pip \
    libssl-dev ninja-build linux-headers-generic

wget -q -O /tmp/cuda-keyring_1.1-1_all.deb https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i /tmp/cuda-keyring_1.1-1_all.deb && rm /tmp/cuda-keyring_1.1-1_all.deb

sudo apt update
sudo apt install -y cuda-toolkit-12-6

cat << EOF | sudo tee /etc/profile.d/cuda.sh > /dev/null
export PATH=/usr/local/cuda-12.6/bin:\$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-12.6/lib64:\$LD_LIBRARY_PATH
EOF

source /etc/profile.d/cuda.sh

# ====================== 2. BUILD LLAMA.CPP (TURBOQUANT) ======================
echo "→ Building TurboQuant llama.cpp..."
cd "$HOME"
if [ ! -d "$LLAMA_DIR" ]; then
    git clone https://github.com/ggerganov/llama.cpp.git "$LLAMA_DIR"
fi

cd "$LLAMA_DIR"
git pull

rm -rf build
cmake -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_CUDA=ON \
  -DGGML_CUDA_FA=ON \
  -DGGML_NATIVE=ON \
  -DCMAKE_CUDA_ARCHITECTURES="86"

cmake --build build --config Release -j "$(nproc)"

echo "✅ Build completed!"

# ====================== 3. AUTOMATIC MODEL DOWNLOAD ======================
download_model() {
    local repo=$1
    local file=$2
    if [ ! -f "$MODELS_DIR/$file" ]; then
        echo "→ Downloading $file ..."
        huggingface-cli download "$repo" "$file" --local-dir "$MODELS_DIR" --local-dir-use-symlinks False
    else
        echo "✅ $file already exists"
    fi
}

download_model "DJLougen/Harmonic-Hermes-9B-GGUF" "Harmonic-Hermes-9B-Q5_K_M.gguf"
download_model "Huihui-Qwen3.5-9B-Abliterated-GGUF" "Huihui-Qwen3.5-9B-abliterated.Q5_K_M.gguf"
download_model "Jackrong/Qwopus-GLM-18B-Merged-GGUF" "Qwopus-GLM-18B-Healed-Q4_K_M.gguf"

# ====================== 4. CREATE OPTIMIZED START SCRIPTS ======================
create_script() {
    local name=$1
    local model=$2
    local ctx=$3
    local ngl=$4
    local desc=$5

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

# ====================== 5. MENU LAUNCHER ======================
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
echo "========================================"

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
echo "✅ Full Installation Completed!"
echo ""
echo "Run the menu with:"
echo "   ~/llm-start"
echo ""
echo "Recommended starting point: Option 1 (Harmonic-Hermes Safe 96k)"
echo "========================================"
