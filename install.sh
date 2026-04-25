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

# ----------------------------- Version Tracking -----------------------------
_get_llama_version() {
    if [[ -x "$LLAMA_DIR/build/bin/llama-server" ]]; then
        "$LLAMA_DIR/build/bin/llama-server" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "latest"
    fi
}

_set_installed_version() {
    mkdir -p "$(dirname "$VERSION_FILE")"
    echo "llama.cpp=$(_get_llama_version)" > "$VERSION_FILE"
}

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

# ----------------------------- HuggingFace Setup -----------------------------
setup_hf() {
    pip3 install --user huggingface_hub

    # Check for HF token
    HF_TOKEN="${HF_TOKEN:-}"
    if [[ -z "$HF_TOKEN" ]] && [[ -f "$HOME/.cache/huggingface/token" ]]; then
        HF_TOKEN=$(cat "$HOME/.cache/huggingface/token")
    fi

    if [[ -n "$HF_TOKEN" ]]; then
        export HF_TOKEN
        huggingface-cli login --token "$HF_TOKEN"
    else
        echo "No HF_TOKEN found. Downloads may be slower."
    fi
}

# ----------------------------- Model Download -----------------------------
download_model() {
    cd "$MODELS_DIR"

    if [[ -f "$SELECTED_GGUF" ]]; then
        echo "Model already present: $SELECTED_GGUF"
        return
    fi

    echo "Downloading $SELECTED_NAME..."
    if [[ -n "$HF_TOKEN" ]]; then
        huggingface-cli download "$SELECTED_REPO" "$SELECTED_GGUF" --local-dir .
    else
        # Fallback to direct download if available
        echo "huggingface-cli not found. Please download manually."
    fi
}

# ----------------------------- Hermes Agent Setup -----------------------------
setup_hermes() {
    echo "Installing Hermes Agent..."
    curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash

    # Configure for local server
    mkdir -p "$HOME/.hermes"
    cat > "$HOME/.hermes/.env" << EOF
OPENAI_API_KEY=sk-no-key-needed
OPENAI_BASE_URL=http://localhost:8080/v1
EOF

    cat > "$HOME/.hermes/config.yaml" << EOF
setup_complete: true
model:
  provider: custom
  base_url: http://localhost:8080/v1
  default: "$SELECTED_NAME"
  context_length: 65536
terminal:
  backend: local
agent:
  max_turns: 90
memory:
  honcho:
    enabled: true
EOF
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

# ----------------------------- Create Wrapper Scripts -----------------------------
create_wrapper_scripts() {
    # start-llm
    cat > "$INSTALL_DIR/start-llm" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$HOME/.llm-config"

# Load config
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

# Allow override via env vars
GGUF="${1:-${SELECTED_GGUF:-}}"
CTX="${CTX:-65536}"
NGL="${NGL:-99}"
PORT="${PORT:-8080}"
BATCH="${BATCH:-1024}"
UBATCH="${UBATCH:-512}"
CACHE_K="${CACHE_K:-q8_0}"
CACHE_V="${CACHE_V:-q8_0}"
THREADS="${THREADS:-6}"
UNIFIED_MEMORY="${UNIFIED_MEMORY:-false}"

# Default to Qwopus if no model selected
if [[ -z "$GGUF" ]]; then
    GGUF="$HOME/llm-models/Qwopus-GLM-18B-Healed-Q4_K_M.gguf"
fi

LLAMA_BIN="$HOME/llama.cpp/build/bin/llama-server"

if [[ ! -x "$LLAMA_BIN" ]]; then
    echo "ERROR: llama-server not found. Re-run installer."
    exit 1
fi

# Kill existing instance
EXISTING_PID=$(ss -tlnp 2>/dev/null | awk -v p=":$PORT" '$4 ~ p {match($0,/pid=([0-9]+)/,a); print a[1]}' | head -1 || true)
[[ -n "$EXISTING_PID" ]] && kill "$EXISTING_PID" 2>/dev/null && sleep 2

echo "🚀 Starting llama-server (RTX 3060 optimized)"
echo "Model   : $(basename "$GGUF")"
echo "Context : $CTX tokens"
echo "GPU     : $NGL layers"
echo "KV Cache: $CACHE_K / $CACHE_V"
echo "Unified : $UNIFIED_MEMORY"
echo "Threads : $THREADS"

# Build command array
CMD=(
    "$LLAMA_BIN"
    -m "$GGUF"
    -ngl "$NGL"
    --flash-attn on
    -c "$CTX"
    -b "$BATCH"
    -ub "$UBATCH"
    --cache-type-k "$CACHE_K"
    --cache-type-v "$CACHE_V"
    --host 0.0.0.0
    --port "$PORT"
    --jinja
    --threads "$THREADS"
    --threads-batch "$THREADS"
    --no-mmap
)

# Add unified memory if enabled
if [[ "$UNIFIED_MEMORY" == "true" ]]; then
    CMD+=(--unified-memory)
fi

# Aggressive performance flags for RTX 3060
CMD+=(
    --numa distribute
    --prio 1
)

"${CMD[@]}" &

LLAMA_PID=$!
echo "$LLAMA_PID" > /tmp/llama-server.pid

# Readiness check
for i in {1..90}; do
    if curl -sf "http://localhost:$PORT/v1/models" &>/dev/null; then
        echo "✅ Server ready at http://localhost:$PORT/v1"
        echo "💡 Use 'hermes' to chat with your model"
        break
    fi
    sleep 1
done

if [[ $i -eq 90 ]]; then
    echo "❌ Server failed to start within 90 seconds"
    exit 1
fi
EOF

    # switch-model
    cat > "$INSTALL_DIR/switch-model" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="$HOME/llm-models"
CONFIG_FILE="$HOME/.llm-config"

# Model catalog
MODELS=(
  "1|unsloth/Qwen3.5-9B-GGUF|Qwen3.5-9B-Q4_K_M.gguf|Qwen 3.5 9B|5.3|256K|8|6|mid|S|chat,code,reasoning|@sudoingX pick · 50 tok/s on RTX 3060"
  "2|bartowski/Qwen2.5-Coder-14B-Instruct-GGUF|Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf|Qwen2.5 Coder 14B|8.99|131K|12|10|mid|A|code|#1 coding on 3060"
  "3|KyleHessling1/Qwopus-GLM-18B-Merged-GGUF|Qwopus-GLM-18B-Healed-Q4_K_M.gguf|Qwopus-GLM 18B|10.5|64K|12|10|mid|A|chat,code,reasoning|Merged GLM · Q4_K_M · community"
  "4|bartowski/google_gemma-4-12b-it-GGUF|google_gemma-4-12b-it-Q4_K_M.gguf|Gemma 4 12B|7.3|128K|12|10|mid|A|chat,code|Google Gemma 4 · 128K ctx"
  "5|unsloth/Qwen3.5-35B-A3B-GGUF|Qwen3.5-35B-A3B-MXFP4_MOE.gguf|Qwen 3.5 35B MoE|22.0|128K|20|16|large|B|chat,code,reasoning|MoE · 3B active params"
)

grade_label() {
  case "$1" in
    S) echo "S Runs great " ;;
    A) echo "A Runs well " ;;
    B) echo "B Decent " ;;
    C) echo "C Tight fit " ;;
    F) echo "F Too heavy " ;;
    *) echo "? Unknown " ;;
  esac
}

grade_color() {
  case "$1" in
    S | A) echo -e "\033[0;32m" ;;
    B | C) echo -e "\033[1;33m" ;;
    *) echo -e "\033[0;31m" ;;
  esac
}

show_model_menu() {
    clear
    echo -e "\033[1;36m╔══════════════════════════════════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;36m║\033[0m \033[1mModel Selection\033[0m"
    echo -e "\033[1;36m╚══════════════════════════════════════════════════════════════════════════════╝\033[0m"
    echo ""
    echo -e "Hardware: ${RAM_GiB}GB RAM, ${VRAM_GiB}GB VRAM, CUDA: $HAS_NVIDIA"
    echo ""
    echo -e "\033[1m # Model Size Ctx Grade Tags\033[0m"
    echo " ─────────────────────────────────────────────────────────────────────────────"

    local idx hf_repo gguf_file dname size_gb ctx min_ram min_vram tier grade tags desc
    while IFS='|' read -r idx hf_repo gguf_file dname size_gb ctx min_ram min_vram tier grade tags desc; do
        local color
        color=$(grade_color "$grade")
        local label
        label=$(grade_label "$grade")
        local cached=""
        [[ -f "$MODELS_DIR/$gguf_file" ]] && cached=" \033[0;36m↓\033[0m"

        echo -e " \033[1m$(printf '%2s' "$idx")\033[0m $(printf '%-26s' "$dname")" \
          " $(printf '%5s' "$size_gb") GB $(printf '%-7s' "$ctx")" \
          " ${color}$(printf '%-13s' "$label")\033[0m $(printf '%-24s' "$tags") $cached"
    done < <(printf '%s\n' "${MODELS[@]}")

    echo ""
    echo -e " \033[0;32mS/A\033[0m Runs great/well \033[1;33mB/C\033[0m Tight fit \033[0;31mF\033[0m Too heavy \033[0;36m↓\033[0m Already downloaded"
    echo ""
    echo -e " Enter number, or \033[1mu\033[0m for custom HF URL."
    echo ""
}

download_model() {
    local repo="$1" file="$2" name="$3"
    echo "Downloading $name..."

    if command -v huggingface-cli &>/dev/null; then
        cd "$MODELS_DIR"
        huggingface-cli download "$repo" "$file" --local-dir .
    else
        echo "huggingface-cli not found. Please install with: pip install huggingface_hub"
        echo "Manual download: https://huggingface.co/$repo/resolve/main/$file"
    fi
}

# Main logic
show_model_menu

read -rp "Select model [1-${#MODELS[@]}] or 'u' for URL: " choice

if [[ "$choice" =~ ^[Uu]$ ]]; then
    read -rp "HuggingFace URL or repo/name: " custom_input
    # Handle custom URL - simplified
    echo "Custom model selection not fully implemented yet"
    echo "Please manually download and place in $MODELS_DIR"
    exit 0
elif [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#MODELS[@]})); then
    while IFS='|' read -r idx hf_repo gguf_file dname size_gb ctx min_ram min_vram tier grade tags desc; do
        if [[ "$idx" == "$choice" ]]; then
            SELECTED_REPO="$hf_repo"
            SELECTED_GGUF="$gguf_file"
            SELECTED_NAME="$dname"
            SELECTED_GRADE="$grade"
            break
        fi
    done < <(printf '%s\n' "${MODELS[@]}")

    # Download if needed
    if [[ ! -f "$MODELS_DIR/$SELECTED_GGUF" ]]; then
        download_model "$SELECTED_REPO" "$SELECTED_GGUF" "$SELECTED_NAME"
    fi

    # Save config
    cat > "$CONFIG_FILE" << EOF
SELECTED_GGUF="$SELECTED_GGUF"
SELECTED_NAME="$SELECTED_NAME"
EOF

    echo "✅ Switched to $SELECTED_NAME"
    echo "Restart server with: stop-llm && start-llm"
else
    echo "Invalid choice"
    exit 1
fi
EOF

    # vram
    cat > "$INSTALL_DIR/vram" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo -e "\033[1;36mGPU Memory Usage\033[0m"
echo "────────────────"

if command -v nvidia-smi &>/dev/null; then
    nvidia-smi --query-gpu=name,memory.used,memory.total,memory.free,utilization.gpu,temperature.gpu \
        --format=csv,noheader,nounits | \
    awk -F, '{
        printf "GPU: %s\n", $1
        printf "Used: %d MiB / %d MiB (%.1f%%)\n", $2, $3, ($2/$3)*100
        printf "Free: %d MiB\n", $4
        printf "Util: %s%%\n", $5
        printf "Temp: %s°C\n", $6
    }'
else
    echo "nvidia-smi not found"
fi

echo ""
echo -e "\033[1;36mllama-server Status\033[0m"
echo "───────────────────"

PID=$(cat /tmp/llama-server.pid 2>/dev/null || echo "")
if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    echo -e "\033[0;32m● Running\033[0m (PID: $PID)"

    # Get model info from config
    CONFIG_FILE="$HOME/.llm-config"
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        echo "Model: ${SELECTED_NAME:-Unknown}"
    fi

    # Try to get context usage (simplified)
    if command -v curl &>/dev/null; then
        if curl -sf http://localhost:8080/v1/models &>/dev/null; then
            echo "Endpoint: http://localhost:8080/v1"
        fi
    fi
else
    echo -e "\033[0;31m● Stopped\033[0m"
fi
EOF

    # Make all executable
    chmod +x "$INSTALL_DIR/start-llm" "$INSTALL_DIR/switch-model" "$INSTALL_DIR/vram"
}

# ----------------------------- systemd User Service -----------------------------
create_systemd_service() {
    echo "Creating systemd user service..."

    mkdir -p "$HOME/.config/systemd/user"

    cat > "$HOME/.config/systemd/user/llama-server.service" << EOF
[Unit]
Description=llama-server LLM inference (llama.cpp)
After=network.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/start-llm
Restart=on-failure
RestartSec=5
Environment=HOME=$HOME
Environment=PATH=/usr/local/cuda/bin:$HOME/.local/bin:/usr/bin:/bin
StandardOutput=append:/tmp/llama-server.log
StandardError=append:/tmp/llama-server.log

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable llama-server.service

    echo "✅ systemd service created and enabled"
    echo "Start with: systemctl --user start llama-server"
    echo "Stop with: systemctl --user stop llama-server"
    echo "Auto-start on login: loginctl enable-linger \$USER"
}

# ----------------------------- Main Installation Flow -----------------------------
# Model selection
select_model

# Setup HuggingFace
setup_hf

# Download selected model
download_model

# Create wrapper scripts
create_wrapper_scripts

# Create additional helpers
cat > "$INSTALL_DIR/stop-llm" << 'EOF'
#!/usr/bin/env bash
PID=$(cat /tmp/llama-server.pid 2>/dev/null || echo "")
[[ -n "$PID" ]] && kill "$PID" 2>/dev/null && echo "Stopped llama-server"
EOF

cat > "$INSTALL_DIR/llm-status" << 'EOF'
#!/usr/bin/env bash
PID=$(cat /tmp/llama-server.pid 2>/dev/null || echo "")
if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    echo -e "\033[0;32m● Running\033[0m (PID: $PID)"
    echo "Endpoint: http://localhost:8080/v1"
else
    echo -e "\033[0;31m● Stopped\033[0m"
fi
EOF

chmod +x "$INSTALL_DIR/stop-llm" "$INSTALL_DIR/llm-status"

# Setup systemd service
read -rp "Create systemd service for auto-start? [Y/n]: " create_service
if [[ ! "$create_service" =~ ^[Nn]$ ]]; then
    create_systemd_service
fi

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
echo "   switch-model       # Change model"
echo "   vram               # Show GPU memory usage"
if command -v hermes &>/dev/null; then
    echo "   hermes             # Run Hermes Agent"
fi
echo ""
echo "Add to ~/.bashrc: export PATH=\"\$HOME/.local/bin:\$PATH\""
echo ""
echo "To rebuild llama.cpp: cd ~/llama.cpp && git pull && rm -rf build && cmake -B build -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES=86 -DLLAMA_CURL=ON && cmake --build build --config Release -j8"