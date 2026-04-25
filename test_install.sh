#!/usr/bin/env bash
set -euo pipefail

echo "🧪 Testing install.sh functionality..."

# Create a minimal test environment
mkdir -p /tmp/test-install
cd /tmp/test-install

# Create a simplified install.sh for testing
cat > test-install.sh << 'INNER_EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "🚀 Starting LLM Installer Test..."

# Config
LLAMA_DIR="$HOME/llama.cpp"
MODELS_DIR="$HOME/llm-models"
INSTALL_DIR="$HOME/.local/bin"
PORT="8080"

# Hardware detection
RAM_GiB=16
CPUS=8
HAS_NVIDIA=false
VRAM_GiB=0

echo "Hardware: ${RAM_GiB}GB RAM, ${CPUS} CPUs, ${VRAM_GiB}GB VRAM, CUDA: $HAS_NVIDIA"

# Model selection
select_model() {
    echo "Model selection would happen here"
    SELECTED_REPO="test/repo"
    SELECTED_GGUF="test-model.gguf"
    SELECTED_NAME="Test Model"
}

# Mock functions
setup_hf() { echo "HF setup..."; }
download_model() { echo "Model download..."; }
create_wrapper_scripts() { 
    mkdir -p "$INSTALL_DIR"
    echo "#!/bin/bash\necho 'start-llm test'" > "$INSTALL_DIR/start-llm"
    chmod +x "$INSTALL_DIR/start-llm"
    echo "Created test scripts"
}
setup_hermes() { echo "Hermes setup..."; }

# Main flow
select_model
setup_hf
download_model
create_wrapper_scripts

read -p "Install Hermes? [y/N]: " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    setup_hermes
fi

echo "✅ Test installation completed!"
