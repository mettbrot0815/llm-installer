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

# Model catalog - Optimized for RTX 3060 12GB VRAM (April 2026)
# Format: id|repo|file|display_name|size_gb|ctx|min_ram_gb|min_vram_gb|tier|grade|tags|description
MODELS=(
  "1|unsloth/Qwen3.5-9B-GGUF|Qwen3.5-9B-Q4_K_M.gguf|Qwen 3.5 9B|5.3|262144|8|6|mid|S|chat,code,reasoning|Perfect all-rounder · 45-55 tok/s · Q4_K_M · 256K ctx"
  "2|bartowski/Qwen2.5-Coder-32B-Instruct-GGUF|Qwen2.5-Coder-32B-Instruct-Q4_K_M.gguf|Qwen2.5 Coder 32B|20.0|131072|16|12|large|B|code|Elite coding · 25-35 tok/s · Q4_K_M · 128K ctx"
  "3|bartowski/Qwen2.5-72B-Instruct-GGUF|Qwen2.5-72B-Instruct-Q3_K_XL.gguf|Qwen2.5 72B|45.0|32768|24|16|large|C|chat,reasoning|Heavy reasoning · 8-12 tok/s · Q3_K_XL · 32K ctx"
  "4|bartowski/Qwen2.5-14B-Instruct-GGUF|Qwen2.5-14B-Instruct-Q4_K_M.gguf|Qwen2.5 14B|8.8|131072|12|8|mid|A|chat,code,reasoning|Balanced performer · 35-45 tok/s · Q4_K_M · 128K ctx"
  "5|bartowski/gemma-3-27b-it-GGUF|gemma-3-27b-it-Q4_K_M.gguf|Gemma 3 27B|17.0|8192|16|12|large|B|chat,reasoning|Google quality · 15-25 tok/s · Q4_K_M · 8K ctx"
  "6|bartowski/google_gemma-4-9b-it-GGUF|google_gemma-4-9b-it-Q4_K_M.gguf|Gemma 4 9B|5.6|8192|8|6|mid|S|chat,code|Latest Google · 40-50 tok/s · Q4_K_M · 8K ctx"
  "7|bartowski/google_gemma-4-27b-it-GGUF|google_gemma-4-27b-it-Q4_K_M.gguf|Gemma 4 27B|17.0|8192|16|12|large|B|chat,reasoning|Google flagship · 15-25 tok/s · Q4_K_M · 8K ctx"
  "8|unsloth/Llama-3.3-70B-Instruct-GGUF|Llama-3.3-70B-Instruct-Q3_K_XL.gguf|Llama 3.3 70B|44.0|8192|24|16|large|C|chat,reasoning|Meta's latest · 8-12 tok/s · Q3_K_XL · 8K ctx"
  "9|bartowski/Mistral-Small-Instruct-2501-GGUF|Mistral-Small-Instruct-2501-Q4_K_M.gguf|Mistral Small 24B|15.0|32768|12|10|large|A|chat,code,reasoning|Efficient Mistral · 20-30 tok/s · Q4_K_M · 32K ctx"
  "10|bartowski/Phi-4-GGUF|Phi-4-Q4_K_M.gguf|Phi-4 14B|8.8|16384|12|8|mid|A|chat,code,reasoning|Microsoft Phi · 35-45 tok/s · Q4_K_M · 16K ctx"
  "11|bartowski/deepseek-v3-GGUF|deepseek-v3-Q4_K_M.gguf|DeepSeek V3 671B|421.0|4096|32|20|xl|F|chat,reasoning|Massive MoE · 2-3 tok/s · Q4_K_M · 4K ctx"
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

# Check if llama.cpp needs updating
needs_update() {
    if [[ ! -d "$LLAMA_DIR" ]]; then
        return 0  # Need to clone
    fi

    if [[ ! -d "$LLAMA_DIR/.git" ]]; then
        return 0  # Not a git repo, need to clone
    fi

    cd "$LLAMA_DIR"

    # Check if we can fetch
    if ! git fetch origin master 2>/dev/null; then
        echo "Warning: Could not fetch from remote, assuming update needed"
        return 0
    fi

    local local_commit remote_commit
    local_commit=$(git rev-parse HEAD 2>/dev/null || echo "")
    remote_commit=$(git rev-parse origin/master 2>/dev/null || echo "")

    # If we can't get commits, assume update needed
    if [[ -z "$local_commit" || -z "$remote_commit" ]]; then
        return 0
    fi

    # Return 0 (true) if commits differ, 1 (false) if same
    [[ "$local_commit" != "$remote_commit" ]]
}

# ----------------------------- Model Selection -----------------------------
select_model() {
    echo ""
    echo "Available Models (RTX 3060 12GB optimized):"
    echo "────────────────────────────────────────────"
    local idx hf_repo gguf_file dname size_gb ctx min_ram min_vram tier grade tags desc
    while IFS='|' read -r idx hf_repo gguf_file dname size_gb ctx min_ram min_vram tier grade tags desc; do
        local grade_label
        case "$grade" in
            S) grade_label="Perfect" ;;
            A) grade_label="Excellent" ;;
            B) grade_label="Good" ;;
            C) grade_label="Tight" ;;
            F) grade_label="Too Big" ;;
            *) grade_label="Unknown" ;;
        esac

        echo "$idx) $dname ($size_gb GB, $ctx ctx) - $grade_label"
        echo "   $desc"
        echo ""
    done < <(printf '%s\n' "${MODELS[@]}")

    read -rp "Select model [1-${#MODELS[@]}]: " choice
    while IFS='|' read -r idx hf_repo gguf_file dname size_gb ctx min_ram min_vram tier grade tags desc; do
        if [[ "$idx" == "$choice" ]]; then
            SELECTED_REPO="$hf_repo"
            SELECTED_GGUF="$gguf_file"
            SELECTED_NAME="$dname"
            SELECTED_GRADE="$grade"
            SELECTED_CTX="$ctx"
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

if needs_update || [[ ! -f "$VERSION_FILE" ]]; then
    echo "Updating llama.cpp..."
    if [[ ! -d ".git" ]]; then
        git clone https://github.com/ggml-org/llama.cpp.git .
    else
        git pull
    fi

    echo "Building llama.cpp with CUDA support (RTX 3060 optimized)..."
    rm -rf build

    # Configure with CMake
    echo "Running: cmake -B build -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES=86 -DLLAMA_CURL=ON -DGGML_CCACHE=ON"
    if cmake -B build -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES=86 -DLLAMA_CURL=ON -DGGML_CCACHE=ON; then
        echo "CMake configure succeeded"
    else
        echo "CMake configure failed"
        exit 1
    fi

    echo "Building binaries..."
    if cmake --build build --config Release -j8; then
        echo "CMake build succeeded"
    else
        echo "CMake build failed"
        exit 1
    fi

    # Create symlinks / wrappers
    if command -v sudo >/dev/null 2>&1; then
        sudo ln -sf "$LLAMA_DIR/build/bin/llama-server" "$INSTALL_DIR/llama-server"
        sudo ln -sf "$LLAMA_DIR/build/bin/llama-cli"    "$INSTALL_DIR/llama-cli"
    else
        echo "Warning: sudo not available, skipping system symlinks"
    fi

    echo "✅ llama.cpp built successfully"
    _set_installed_version
else
    echo "✅ llama.cpp already up-to-date"
    if [[ ! -x "$LLAMA_DIR/build/bin/llama-server" ]]; then
        echo "Building missing binaries..."
        if cmake --build build --config Release -j8; then
            echo "Binaries built successfully"
        else
            echo "Binary build failed, will rebuild from source"
            # Force rebuild by returning to the if branch
            cd "$LLAMA_DIR"
            git pull
            rm -rf build
            cmake -B build -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES=86 -DLLAMA_CURL=ON -DGGML_CCACHE=ON
            cmake --build build --config Release -j8
        fi
    fi
fi

# ----------------------------- Create Wrapper Scripts -----------------------------
create_wrapper_scripts() {
    # start-llm
    cat > "$INSTALL_DIR/start-llm" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="$HOME/llm-models"
CONFIG_FILE="$HOME/.llm-config"
RAM_GiB="$RAM_GiB"
VRAM_GiB="$VRAM_GiB"
HAS_NVIDIA="$HAS_NVIDIA"

# Model catalog - optimized for RTX 3060 12GB
# Format: id|repo|file|display_name|size_gb|ctx|min_ram_gb|min_vram_gb|tier|grade|tags|description
MODELS=(
  "1|unsloth/Qwen3.5-9B-GGUF|Qwen3.5-9B-Q4_K_M.gguf|Qwen3.5-9B-Q4_K_M.gguf|5.3|262144|8|6|mid|S|chat,code,reasoning|Qwen 3.5 9B · Perfect all-rounder · 45-55 tok/s"
  "2|bartowski/Qwen2.5-14B-Instruct-GGUF|Qwen2.5-14B-Instruct-Q4_K_M.gguf|Qwen2.5-14B-Instruct-Q4_K_M.gguf|8.8|131072|12|8|mid|A|chat,code,reasoning|Qwen2.5 14B · Balanced performer · 35-45 tok/s"
  "3|bartowski/google_gemma-4-9b-it-GGUF|google_gemma-4-9b-it-Q4_K_M.gguf|google_gemma-4-9b-it-Q4_K_M.gguf|5.6|8192|8|6|mid|S|chat,code|Gemma 4 9B · Latest Google · 40-50 tok/s"
  "4|bartowski/Phi-4-GGUF|Phi-4-Q4_K_M.gguf|Phi-4-Q4_K_M.gguf|8.8|16384|12|8|mid|A|chat,code,reasoning|Phi-4 14B · Microsoft Phi · 35-45 tok/s"
  "5|bartowski/Mistral-Small-Instruct-2501-GGUF|Mistral-Small-Instruct-2501-Q4_K_M.gguf|Mistral-Small-Instruct-2501-Q4_K_M.gguf|15.0|32768|12|10|large|A|chat,code,reasoning|Mistral Small 24B · Efficient · 20-30 tok/s"
  "6|bartowski/Qwen2.5-Coder-32B-Instruct-GGUF|Qwen2.5-Coder-32B-Instruct-Q4_K_M.gguf|Qwen2.5-Coder-32B-Instruct-Q4_K_M.gguf|20.0|131072|16|12|large|B|code|Qwen2.5 Coder 32B · Elite coding · 25-35 tok/s"
  "7|bartowski/gemma-3-27b-it-GGUF|gemma-3-27b-it-Q4_K_M.gguf|gemma-3-27b-it-Q4_K_M.gguf|17.0|8192|16|12|large|B|chat,reasoning|Gemma 3 27B · Google quality · 15-25 tok/s"
  "8|bartowski/google_gemma-4-27b-it-GGUF|google_gemma-4-27b-it-Q4_K_M.gguf|google_gemma-4-27b-it-Q4_K_M.gguf|17.0|8192|16|12|large|B|chat,reasoning|Gemma 4 27B · Google flagship · 15-25 tok/s"
)

    # switch-model - shows actual model files
    cat > "$INSTALL_DIR/switch-model" << 'EOF'
#!/usr/bin/env bash
echo "RTX 3060 12GB Optimized Models:"
echo ""
echo "1) Qwen3.5-9B-Q4_K_M.gguf              (5.3GB) - S Perfect   - 45-55 tok/s"
echo "2) Qwen2.5-14B-Instruct-Q4_K_M.gguf    (8.8GB) - A Excellent - 35-45 tok/s"
echo "3) google_gemma-4-9b-it-Q4_K_M.gguf    (5.6GB) - S Perfect   - 40-50 tok/s"
echo "4) Phi-4-Q4_K_M.gguf                   (8.8GB) - A Excellent - 35-45 tok/s"
echo "5) Mistral-Small-Instruct-2501-Q4_K_M.gguf (15GB) - A Excellent - 20-30 tok/s"
echo "6) Qwen2.5-Coder-32B-Instruct-Q4_K_M.gguf (20GB) - B Good      - 25-35 tok/s"
echo "7) gemma-3-27b-it-Q4_K_M.gguf          (17GB)  - B Good      - 15-25 tok/s"
echo "8) google_gemma-4-27b-it-Q4_K_M.gguf  (17GB)  - B Good      - 15-25 tok/s"
echo ""
echo "To switch: edit ~/.llm-config with SELECTED_GGUF=\"exact-filename.gguf\""
echo "Then restart: stop-llm && start-llm"
echo ""
echo "All models use Q4_K_M quantization optimized for RTX 3060 12GB VRAM"
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