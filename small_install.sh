#!/usr/bin/env bash
# ============================================================
# TurboQuant Installer – Idempotent, Fast, Smart Rebuild
# Only does work when necessary – no endless apt updates
# ============================================================
set -euo pipefail

echo "============================================================"
echo "🚀 TurboQuant Installer – RTX 3060 12GB (Ubuntu 24.04 WSL2)"
echo "============================================================"

MODELS_DIR="$HOME/llm-models"
LLAMA_DIR="$HOME/turboquant-llama"
BUILD_BIN="$LLAMA_DIR/build/bin/llama-server"
APT_LISTS_FRESH_THRESHOLD=3600  # 1 hour

# ------------------------------------------------------------------
# Helper: run apt update only if lists are stale
# ------------------------------------------------------------------
apt_update_if_needed() {
    local newest=0
    if compgen -G "/var/lib/apt/lists/*_InRelease" > /dev/null 2>&1; then
        newest=$(stat -c %Y /var/lib/apt/lists/*_InRelease 2>/dev/null | sort -rn | head -1)
    fi
    local now
    now=$(date +%s)
    if [ -z "$newest" ] || [ $((now - newest)) -gt $APT_LISTS_FRESH_THRESHOLD ]; then
        echo "→ Apt lists are stale or missing, updating..."
        sudo apt update -o Acquire::ForceIPv4=true
    else
        echo "✅ Apt lists are recent, skipping update."
    fi
}

# ------------------------------------------------------------------
# 1. WSL2 Networking Fixes (only once)
# ------------------------------------------------------------------
if ! grep -q "de.archive.ubuntu.com" /etc/apt/sources.list 2>/dev/null; then
    echo "→ Optimising APT sources for Germany..."
    sudo sed -i 's|http://archive.ubuntu.com|http://de.archive.ubuntu.com|g' /etc/apt/sources.list
    sudo sed -i 's|http://security.ubuntu.com|http://de.archive.ubuntu.com|g' /etc/apt/sources.list
fi

if [ ! -f /etc/apt/apt.conf.d/99wsl-fixes ]; then
    sudo tee /etc/apt/apt.conf.d/99wsl-fixes > /dev/null <<EOF
Acquire::ForceIPv4 "true";
Acquire::http::Timeout "120";
Acquire::ftp::Timeout "120";
Acquire::Retries "4";
EOF
fi

apt_update_if_needed

# ------------------------------------------------------------------
# 2. Install system dependencies (apt skips already installed)
# ------------------------------------------------------------------
echo "→ Ensuring base packages are installed..."
sudo apt install -y build-essential cmake git curl wget python3 python3-pip \
    libssl-dev ninja-build linux-headers-generic pipx ccache

# ------------------------------------------------------------------
# 3. CUDA 12.6 (only if missing)
# ------------------------------------------------------------------
if ! command -v nvcc &> /dev/null; then
    echo "→ Installing CUDA 12.6..."
    wget -q -O /tmp/cuda-keyring.deb https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb
    sudo dpkg -i /tmp/cuda-keyring.deb && rm /tmp/cuda-keyring.deb
    apt_update_if_needed
    sudo apt install -y cuda-toolkit-12-6
    cat << 'EOF' | sudo tee /etc/profile.d/cuda.sh > /dev/null
export PATH=/usr/local/cuda-12.6/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-12.6/lib64:$LD_LIBRARY_PATH
export CUDA_HOME=/usr/local/cuda-12.6
EOF
    source /etc/profile.d/cuda.sh 2>/dev/null || true
    if command -v nvcc &> /dev/null; then
        echo "✅ CUDA 12.6 installed successfully."
    else
        echo "⚠️  CUDA installation may have failed. Please check manually."
    fi
else
    echo "✅ CUDA already installed."
    source /etc/profile.d/cuda.sh 2>/dev/null || true
fi

# ------------------------------------------------------------------
# 4. Hugging Face CLI (only if missing)
# ------------------------------------------------------------------
if ! command -v hf &> /dev/null; then
    echo "→ Installing Hugging Face CLI..."
    pipx install "huggingface_hub[cli]" --force --quiet
else
    echo "✅ hf CLI already installed."
fi
export PATH="$HOME/.local/bin:$PATH"

# ------------------------------------------------------------------
# 5. Secure HF login (only if not already logged in)
# ------------------------------------------------------------------
if [ ! -f "$HOME/.cache/huggingface/token" ]; then
    echo ""
    echo "🔐 Hugging Face login (recommended for higher rate limits)"
    echo "   Get a token at: https://huggingface.co/settings/tokens"
    read -rp "   Log in now? (y/n): " hf_login
    if [[ "$hf_login" =~ ^[Yy]$ ]]; then
        hf auth login
        echo "✅ Token saved securely."
    else
        echo "⚠️  Skipping login – public models only (slower downloads)."
    fi
else
    echo "✅ Already logged into Hugging Face."
fi

# ------------------------------------------------------------------
# 6. Interactive model selection
# ------------------------------------------------------------------
echo ""
echo "📦 Choose which model(s) to download and configure:"
echo "   1) Harmonic-Hermes-9B-Q5_K_M      (Agent-tuned, recommended)"
echo "   2) Huihui-Qwen3.5-9B-abliterated  (Uncensored, strong reasoning)"
echo "   3) Qwopus-GLM-18B-Healed          (Largest, highest quality)"
echo "   4) All three models"
echo "   5) Cancel"
read -rp "   Choose [1-5]: " MODEL_CHOICE

declare -A MODELS
case $MODEL_CHOICE in
    1)
        MODELS["Harmonic-Hermes-9B-Q5_K_M.gguf"]="DJLougen/Harmonic-Hermes-9B-GGUF"
        ;;
    2)
        MODELS["Huihui-Qwen3.5-9B-abliterated.i1-Q4_K_M.gguf"]="mradermacher/Huihui-Qwen3.5-9B-abliterated-i1-GGUF"
        ;;
    3)
        MODELS["Qwopus-GLM-18B-Healed-Q4_K_M.gguf"]="KyleHessling1/Qwopus-GLM-18B-Merged-GGUF"
        ;;
    4)
        MODELS["Harmonic-Hermes-9B-Q5_K_M.gguf"]="DJLougen/Harmonic-Hermes-9B-GGUF"
        MODELS["Huihui-Qwen3.5-9B-abliterated.i1-Q4_K_M.gguf"]="mradermacher/Huihui-Qwen3.5-9B-abliterated-i1-GGUF"
        MODELS["Qwopus-GLM-18B-Healed-Q4_K_M.gguf"]="KyleHessling1/Qwopus-GLM-18B-Merged-GGUF"
        ;;
    5)
        echo "Cancelled."
        exit 0
        ;;
    *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
esac

# ------------------------------------------------------------------
# 7. Clone / update the **REAL** TurboQuant fork with turbo4 support
# ------------------------------------------------------------------
echo ""
echo "→ Setting up the real TurboQuant repository (TheTom/llama-cpp-turboquant)..."

# The only fork known to actually contain turbo4
TURBO_REPO_URL="${TURBO_REPO_URL:-https://github.com/TheTom/llama-cpp-turboquant.git}"
TURBO_REPO_BRANCH="${TURBO_REPO_BRANCH:-feature/turboquant-kv-cache}"

cd "$HOME"
NEED_BUILD=0

if [ ! -d "$LLAMA_DIR" ]; then
    echo "→ Cloning $TURBO_REPO_URL ($TURBO_REPO_BRANCH)..."
    git clone --branch "$TURBO_REPO_BRANCH" "$TURBO_REPO_URL" "$LLAMA_DIR"
    NEED_BUILD=1
else
    cd "$LLAMA_DIR"

    # Ensure the remote points to the correct fork
    CURRENT_REMOTE=$(git remote get-url origin 2>/dev/null || echo "")
    if [ "$CURRENT_REMOTE" != "$TURBO_REPO_URL" ]; then
        echo "→ Switching remote from $CURRENT_REMOTE to $TURBO_REPO_URL..."
        git remote set-url origin "$TURBO_REPO_URL"
    fi

    echo "→ Fetching $TURBO_REPO_BRANCH from $TURBO_REPO_URL..."
    git fetch origin "$TURBO_REPO_BRANCH"

    LOCAL=$(git rev-parse HEAD)
    REMOTE=$(git rev-parse "origin/$TURBO_REPO_BRANCH")
    if [ "$LOCAL" != "$REMOTE" ]; then
        echo "→ Remote has changed. Resetting to match remote (any local changes will be discarded)..."
        git reset --hard "origin/$TURBO_REPO_BRANCH"
        NEED_BUILD=1
    elif [ ! -f "$BUILD_BIN" ]; then
        echo "→ Build binary missing. Will build."
        NEED_BUILD=1
    else
        echo "✅ TurboQuant is up to date and already built. Skipping rebuild."
        NEED_BUILD=0
    fi
fi

if [ "$NEED_BUILD" -eq 1 ]; then
    cd "$LLAMA_DIR"
    rm -rf build
    echo "→ Building TurboQuant with RTX 3060 optimisations..."
    # These flags are exactly what's needed to enable turbo4
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
fi

# ------------------------------------------------------------------
# 8. Download selected models (only if missing)
# ------------------------------------------------------------------
echo ""
mkdir -p "$MODELS_DIR"
for MODEL_FILE in "${!MODELS[@]}"; do
    REPO="${MODELS[$MODEL_FILE]}"
    if [ ! -f "$MODELS_DIR/$MODEL_FILE" ]; then
        echo "→ Downloading $MODEL_FILE ..."
        hf download "$REPO" "$MODEL_FILE" --local-dir "$MODELS_DIR"
    else
        echo "✅ $MODEL_FILE already exists"
    fi
done

# ------------------------------------------------------------------
# 9. Create start scripts (with turbo4 – now guaranteed to work)
# ------------------------------------------------------------------
create_script() {
    local name="$1"
    local model="$2"
    local ctx="$3"
    local ngl="$4"
    local desc="$5"
    cat > "$HOME/start-$name.sh" << EOF
#!/usr/bin/env bash
pkill -9 -f "llama-server" 2>/dev/null || true
sleep 2
cd $LLAMA_DIR
echo "🚀 [$desc] $model"
./build/bin/llama-server \
  -m $MODELS_DIR/$model \
  -c $ctx \
  -ngl $ngl --flash-attn on -ctk turbo4 -ctv turbo4 \
  -b 512 -ub 256 --jinja --no-mmap \
  --temp 0.7 --top-p 0.9 --min-p 0.1 --repeat-penalty 1.05 \
  --host 0.0.0.0 --port 8080 -np 2
EOF
    chmod +x "$HOME/start-$name.sh"
}

# Only remove scripts that this installer is about to recreate
for MODEL_FILE in "${!MODELS[@]}"; do
    case "$MODEL_FILE" in
        *Harmonic*)
            rm -f "$HOME/start-harmonic-safe.sh" "$HOME/start-harmonic-aggressive.sh"
            ;;
        *Huihui*)
            rm -f "$HOME/start-huihui.sh"
            ;;
        *Qwopus*)
            rm -f "$HOME/start-qwopus.sh"
            ;;
    esac
done

for MODEL_FILE in "${!MODELS[@]}"; do
    case "$MODEL_FILE" in
        *Harmonic*)
            create_script "harmonic-safe"       "$MODEL_FILE" 98304  93 "SAFE 96k"
            create_script "harmonic-aggressive" "$MODEL_FILE" 131072 88 "AGGRESSIVE 131k"
            ;;
        *Huihui*)
            create_script "huihui"              "$MODEL_FILE" 98304  92 "HUIHUI 96k"
            ;;
        *Qwopus*)
            create_script "qwopus"              "$MODEL_FILE" 65536  78 "QWOPUS 18B"
            ;;
    esac
done

# ------------------------------------------------------------------
# 10. Dynamic menu launcher
# ------------------------------------------------------------------
cat > "$HOME/llm-start" << 'EOF'
#!/usr/bin/env bash
scripts=( "$HOME"/start-*.sh )
if [ ${#scripts[@]} -eq 0 ]; then
    echo "No start scripts found. Run installer again."
    exit 1
fi
echo "========================================"
echo "           LLM Quick Launcher"
echo "========================================"
i=1
for s in "${scripts[@]}"; do
    name=$(basename "$s" .sh | sed 's/start-//')
    echo "$i) $name"
    ((i++))
done
echo "$i) Exit"
read -rp "Choose [1-$i]: " choice
if [ "$choice" -eq "$i" ]; then
    echo "Goodbye!"
    exit 0
fi
selected="${scripts[$choice-1]}"
if [ -f "$selected" ]; then
    exec "$selected"
else
    echo "Invalid choice"
fi
EOF
chmod +x "$HOME/llm-start"

echo ""
echo "============================================================"
echo "✅ Installation complete!"
echo "   - TurboQuant repo (supports -ctk turbo4)"
echo "   - ccache installed (faster future rebuilds)"
echo "   - Models saved in: $MODELS_DIR"
echo "   - Start menu:       ~/llm-start"
echo "============================================================"
