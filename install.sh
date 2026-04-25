#!/usr/bin/env bash
# =============================================================================
# llm-installer - Updated for llama.cpp (CMake era, April 2026)
# Optimized for Ubuntu 24.04+ / WSL2 with RTX 3060 12GB
# =============================================================================

set -euo pipefail

echo "🚀 Starting LLM Installer (2026 edition)..."

# ----------------------------- Config -----------------------------
LLAMA_DIR="$HOME/llama.cpp"
MODELS_DIR="$HOME/llm-models"
INSTALL_DIR="$HOME/.local/bin"
PORT="8080"

# Default model (you can expand this list)
DEFAULT_MODEL="Qwopus-GLM-18B-Healed-Q4_K_M.gguf"
DEFAULT_CTX="65536"
DEFAULT_NGL="99"

# ----------------------------- System Setup -----------------------------
echo "Updating system packages..."
sudo apt update && sudo apt upgrade -y

echo "Installing dependencies..."
sudo apt install -y \
    build-essential cmake git python3 python3-pip python3-venv \
    curl wget libcurl4-openssl-dev libopenblas-dev \
    nvidia-cuda-toolkit nvidia-cuda-toolkit-doc \
    ccache

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

echo "✅ llama.cpp built successfully (latest commit)"

# ----------------------------- Model Download -----------------------------
echo "Downloading default model (Qwopus-GLM-18B-Healed)..."
cd "$MODELS_DIR"

if [[ ! -f "$DEFAULT_MODEL" ]]; then
    # Replace with actual HF link when you have it
    echo "Please download $DEFAULT_MODEL manually from Hugging Face and place it in $MODELS_DIR"
    # Example: huggingface-cli download --local-dir . username/Qwopus-GLM-18B-Healed "$DEFAULT_MODEL"
else
    echo "Model already present: $DEFAULT_MODEL"
fi

# ----------------------------- Create Modern Start Script -----------------------------
cat > "$INSTALL_DIR/start-llm" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Config
GGUF="${1:-$HOME/llm-models/Qwopus-GLM-18B-Healed-Q4_K_M.gguf}"
CTX="${CTX:-65536}"
NGL="${NGL:-99}"
PORT="${PORT:-8080}"
BATCH="1024"
UBATCH="512"
CACHE_K="q8_0"
CACHE_V="q8_0"
THREADS="6"

LLAMA_BIN="$HOME/llama.cpp/build/bin/llama-server"

if [[ ! -x "$LLAMA_BIN" ]]; then
    echo "ERROR: llama-server not found. Re-run installer."
    exit 1
fi

# Kill existing instance
EXISTING_PID=$(ss -tlnp 2>/dev/null | awk -v p=":$PORT" '$4 ~ p {match($0,/pid=([0-9]+)/,a); print a[1]}' | head -1 || true)
[[ -n "$EXISTING_PID" ]] && kill "$EXISTING_PID" 2>/dev/null && sleep 2

echo "🚀 Starting llama-server (latest build)"
echo "Model   : $(basename "$GGUF")"
echo "Context : $CTX"
echo "GPU     : Full offload"

"$LLAMA_BIN" \
    -m "$GGUF" \
    -ngl "$NGL" \
    --flash-attn on \
    -c "$CTX" \
    -b "$BATCH" \
    -ub "$UBATCH" \
    --cache-type-k "$CACHE_K" \
    --cache-type-v "$CACHE_V" \
    --host 0.0.0.0 \
    --port "$PORT" \
    --jinja \
    --threads "$THREADS" \
    --threads-batch "$THREADS" \
    --no-mmap &

LLAMA_PID=$!
echo "$LLAMA_PID" > /tmp/llama-server.pid

# Readiness check
for i in {1..90}; do
    if curl -sf "http://localhost:$PORT/v1/models" &>/dev/null; then
        echo "✅ Server ready at http://localhost:$PORT/v1"
        break
    fi
    sleep 1
done
EOF

chmod +x "$INSTALL_DIR/start-llm"

# Create helper commands (stop, restart, status, etc.)
cat > "$INSTALL_DIR/stop-llm" << 'EOF'
#!/usr/bin/env bash
PID=$(cat /tmp/llama-server.pid 2>/dev/null || echo "")
[[ -n "$PID" ]] && kill "$PID" && echo "Stopped llama-server"
EOF
chmod +x "$INSTALL_DIR/stop-llm"

# Add more helpers: restart-llm, llm-status, vram, switch-model as needed

echo "✅ Wrapper scripts installed to $INSTALL_DIR"
echo ""
echo "Usage examples:"
echo "   start-llm                     # starts default model"
echo "   start-llm /path/to/other.gguf # start different model"
echo "   stop-llm"
echo ""
echo "Don't forget to add $INSTALL_DIR to your PATH in ~/.bashrc:"
echo 'export PATH="$HOME/.local/bin:$PATH"'

echo "Installation completed! Rebuild llama.cpp anytime with: cd ~/llama.cpp && git pull && ./install.sh (or run the cmake steps manually)."