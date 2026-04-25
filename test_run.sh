#!/usr/bin/env bash
set -euo pipefail

echo "🚀 Starting LLM Installer Test Run..."

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

echo "Hardware: ${RAM_GiB}GB RAM, ${CPUS} CPUs, ${VRAM_GiB}GB VRAM, CUDA: $HAS_NVIDIA"

# Model catalog
MODELS=(
  "1|unsloth/Qwen3.5-9B-GGUF|Qwen3.5-9B-Q4_K_M.gguf|Qwen 3.5 9B|5.3|256K|8|6|mid|S|chat,code,reasoning|@sudoingX pick · 50 tok/s on RTX 3060"
)

# ----------------------------- Functions -----------------------------
_get_llama_version() {
    echo "latest"
}

_set_installed_version() {
    mkdir -p "$(dirname "$VERSION_FILE")"
    echo "llama.cpp=$(_get_llama_version)" > "$VERSION_FILE"
}

select_model() {
    echo "Available Models:"
    echo "1) Qwen 3.5 9B (5.3 GB, 256K ctx)"
    echo "   @sudoingX pick · 50 tok/s on RTX 3060"
    SELECTED_REPO="unsloth/Qwen3.5-9B-GGUF"
    SELECTED_GGUF="Qwen3.5-9B-Q4_K_M.gguf"
    SELECTED_NAME="Qwen 3.5 9B"
}

setup_hf() {
    echo "Setting up HuggingFace..."
}

download_model() {
    echo "Would download $SELECTED_NAME..."
}

create_wrapper_scripts() {
    mkdir -p "$INSTALL_DIR"
    
    # start-llm
    cat > "$INSTALL_DIR/start-llm" << 'INNER_EOF'
#!/usr/bin/env bash
echo "start-llm script created"
INNER_EOF
    chmod +x "$INSTALL_DIR/start-llm"
    
    echo "Created start-llm script"
}

# ----------------------------- Test Execution -----------------------------
echo "Testing model selection..."
select_model

echo "Testing HF setup..."
setup_hf

echo "Testing model download..."
download_model

echo "Testing script creation..."
create_wrapper_scripts

echo "✅ Test run completed successfully!"
echo "Scripts created in $INSTALL_DIR"
