#!/usr/bin/env bash
# =============================================================================
# llm-installer - Updated for llama.cpp (CMake era, April 2026)
# Optimized for Ubuntu 24.04+ / WSL2 with RTX 3060 12GB
# Hybrid: Modern build + model selection + agent integration
# =============================================================================

set -euo pipefail

echo "🚀 Starting LLM Installer (2026 edition)..."

# ----------------------------- Config -----------------------------
LLAMA_DIR="$HOME/llama.cpp"
MODELS_DIR="$HOME/llm-models"
INSTALL_DIR="$HOME/.local/bin"
PORT="8080"
VERSION_FILE="$HOME/.llm-versions"

# Hardware detection
RAM_GiB=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024/1024)}')
CPUS=$(nproc)
HAS_NVIDIA=false
VRAM_GiB=0

if command -v nvidia-smi &>/dev/null; then
    VRAM_MiB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 || echo "0")
    VRAM_GiB=$((VRAM_MiB / 1024))
    HAS_NVIDIA=true
fi

echo "Hardware: ${RAM_GiB}GB RAM, ${CPUS} CPUs, ${VRAM_GiB}GB VRAM, CUDA: $HAS_NVIDIA"

# Model catalog
MODELS=(
  "1|unsloth/Qwen3.5-9B-GGUF|Qwen3.5-9B-Q4_K_M.gguf|Qwen 3.5 9B|5.3|256K|8|6|mid|chat,code,reasoning|Fast general purpose"
  "2|bartowski/Qwen2.5-Coder-14B-Instruct-GGUF|Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf|Qwen2.5 Coder 14B|8.99|131K|12|10|mid|code|#1 coding performance"
  "3|KyleHessling1/Qwopus-GLM-18B-Merged-GGUF|Qwopus-GLM-18B-Healed-Q4_K_M.gguf|Qwopus-GLM 18B|10.5|64K|12|10|mid|chat,code,reasoning|Merged GLM · optimized"
  "4|bartowski/google_gemma-4-12b-it-GGUF|google_gemma-4-12b-it-Q4_K_M.gguf|Gemma 4 12B|7.3|128K|12|10|mid|chat,code|Google · 128K context"
  "5|unsloth/Qwen3.5-35B-A3B-GGUF|Qwen3.5-35B-A3B-MXFP4_MOE.gguf|Qwen 3.5 35B MoE|22.0|128K|20|16|large|chat,code,reasoning|MoE · 3B active"
)

# ----------------------------- Model Selection -----------------------------
select_model() {
    echo ""
    echo "Available Models:"
    echo "─────────────────────────────────────"
    local idx hf_repo gguf_file dname size_gb ctx min_ram min_vram tier tags desc
    while IFS='|' read -r idx hf_repo gguf_file dname size_gb ctx min_ram min_vram tier tags desc; do
        echo "$idx) $dname ($size_gb GB, $ctx ctx)"
        echo "   $desc"
        echo ""
    done < <(printf '%s\n' "${MODELS[@]}")

    read -rp "Select model [1-${#MODELS[@]}]: " choice
    while IFS='|' read -r idx hf_repo gguf_file dname size_gb ctx min_ram min_vram tier tags desc; do
        if [[ "$idx" == "$choice" ]]; then
            SELECTED_REPO="$hf_repo"
            SELECTED_GGUF="$gguf_file"
            SELECTED_NAME="$dname"
            break
        fi
    done < <(printf '%s\n' "${MODELS[@]}")
}

# ----------------------------- System Setup -----------------------------
echo "Updating system packages..."
sudo apt update && sudo apt upgrade -y

echo "Installing dependencies..."
sudo apt install -y \
    build-essential cmake git python3 python3-pip python3-venv \
    curl wget libcurl4-openssl-dev libopenblas-dev \
    ccache

# Install CUDA if NVIDIA GPU detected
if [[ "$HAS_NVIDIA" == "true" ]] && ! command -v nvcc &>/dev/null; then
    echo "Installing CUDA toolkit..."
    wget https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb
    sudo dpkg -i cuda-keyring_1.1-1_all.deb
    sudo apt update
    sudo apt install -y cuda-toolkit-12-6
    rm cuda-keyring_1.1-1_all.deb
fi

# Create directories
mkdir -p "$MODELS_DIR" "$INSTALL_DIR" "$LLAMA_DIR"

# ----------------------------- llama.cpp Build (CMake) -----------------------------
cd "$LLAMA_DIR" || exit 1

if [[ ! -d ".git" ]]; then
    echo "Cloning llama.cpp..."
    git clone https://github.com/ggml-org/llama.cpp.git .
else
    echo "Updating llama.cpp..."
    git pull
fi

echo "Building llama.cpp with CUDA support (RTX 3060 optimized)..."
rm -rf build

cmake -B build \
    -DGGML_CUDA=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CUDA_ARCHITECTURES="86" \   # Ampere = RTX 30-series
    -DLLAMA_CURL=ON \
    -DGGML_CCACHE=ON

cmake --build build --config Release -j8   # Use 6-8 on WSL2 to avoid issues

# Create symlinks / wrappers
sudo ln -sf "$LLAMA_DIR/build/bin/llama-server" "$INSTALL_DIR/llama-server"
sudo ln -sf "$LLAMA_DIR/build/bin/llama-cli"    "$INSTALL_DIR/llama-cli"

echo "✅ llama.cpp built successfully"
_set_installed_version

# Model selection
select_model

# Setup HuggingFace
setup_hf

# Download selected model
download_model

# Create wrapper scripts
create_start_script
chmod +x "$INSTALL_DIR/start-llm"
chmod +x "$INSTALL_DIR/stop-llm"
chmod +x "$INSTALL_DIR/llm-status"

# Setup Hermes agent
read -rp "Install Hermes Agent? [Y/n]: " install_hermes
if [[ ! "$install_hermes" =~ ^[Nn]$ ]]; then
    setup_hermes
fi

echo ""
echo "✅ Installation completed!"
echo ""
echo "Commands available:"
echo "   start-llm          # Start server with selected model"
echo "   stop-llm           # Stop server"
echo "   llm-status         # Show server status"
if command -v hermes &>/dev/null; then
    echo "   hermes             # Run Hermes Agent"
fi
echo ""
echo "Add to ~/.bashrc: export PATH=\"\$HOME/.local/bin:\$PATH\""
echo ""
echo "To rebuild llama.cpp: cd ~/llama.cpp && git pull && rm -rf build && cmake -B build -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES=86 -DLLAMA_CURL=ON && cmake --build build --config Release -j8"