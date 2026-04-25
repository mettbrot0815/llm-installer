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
VERSION_FILE="$HOME/.llm-versions"

# ── Colour helpers ─────────────────────────────────────────────────────────────
export RED='\033[0;31m' GRN='\033[0;32m' YLW='\033[1;33m'
export CYN='\033[0;36m' BLD='\033[1m' RST='\033[0m'

# ----------------------------- Hardware Detection -----------------------------
detect_hardware() {
    # FIX bug 12: use rounding (int($2/1024/1024 + 0.5)) instead of truncation
    RAM_GiB=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024/1024 + 0.5)}')
    CPUS=$(nproc)
    HAS_NVIDIA=false
    VRAM_GiB=0
    GPU_NAME="None detected"

    if command -v nvidia-smi &>/dev/null; then
        if nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1 | grep -q ','; then
            GPU_LINE=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1)
            GPU_NAME=$(echo "$GPU_LINE" | cut -d',' -f1 | xargs)
            VRAM_MiB=$(echo "$GPU_LINE" | cut -d',' -f2 | awk '{print $1}')
            VRAM_GiB=$(( VRAM_MiB / 1024 ))
            HAS_NVIDIA=true
        fi
    fi

    echo "Hardware: ${RAM_GiB}GB RAM, ${CPUS} CPUs, ${VRAM_GiB}GB VRAM, CUDA: $HAS_NVIDIA"
}

# =============================================================================
#  Model catalog
#  Format: idx|hf_repo|gguf_file|display_name|size_gb|ctx|min_ram_gb|min_vram_gb|tier|tags|description
# =============================================================================
MODELS=(
    "1|unsloth/Qwen3.5-0.8B-GGUF|Qwen3.5-0.8B-Q4_K_M.gguf|Qwen3.5-0.8B|0.5|256K|2|0|tiny|chat,edge|Alibaba · instant · smoke-test"
    "2|unsloth/Qwen3.5-2B-GGUF|Qwen3.5-2B-Q4_K_M.gguf|Qwen3.5-2B|1.0|256K|3|0|tiny|chat,multilingual|Alibaba · ultra-fast"
    "3|unsloth/Qwen3.5-4B-GGUF|Qwen3.5-4B-Q4_K_M.gguf|Qwen3.5-4B|2.0|256K|4|0|small|chat,code|Alibaba · capable on CPU"
    "4|bartowski/Phi-4-mini-instruct-GGUF|Phi-4-mini-instruct-Q4_K_M.gguf|Phi-4-mini-instruct|2.0|16K|4|0|small|reasoning,code|Microsoft · strong reasoning"
    "5|unsloth/Qwen3.5-9B-GGUF|Qwen3.5-9B-Q4_K_M.gguf|Qwen3.5-9B|5.3|256K|8|6|mid|chat,code,reasoning|@sudoingX pick · 50 tok/s on 3060"
    "6|bartowski/Llama-3.1-8B-Instruct-GGUF|Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf|Meta-Llama-3.1-8B-Instruct|4.1|128K|8|6|mid|chat,code,reasoning|Meta · excellent instruction"
    "7|bartowski/Qwen2.5-Coder-14B-Instruct-GGUF|Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf|Qwen2.5-Coder-14B-Instruct|8.99|32K|12|10|mid|code|#1 coding on 3060"
    "8|unsloth/Qwen3-14B-GGUF|Qwen3-14B-Q4_K_M.gguf|Qwen3-14B|9.0|32K|14|10|mid|chat,code,reasoning|Strong planning"
    "9|bartowski/google_gemma-3-12b-it-GGUF|google_gemma-3-12b-it-Q4_K_M.gguf|google_gemma-3-12b-it|7.3|128K|12|10|mid|chat,code|Google · strict output"
    "10|unsloth/Qwen3-30B-A3B-GGUF|Qwen3-30B-A3B-Q4_K_M.gguf|Qwen3-30B-A3B|17.0|128K|20|16|large|chat,code,reasoning|MoE · 3B active"
    "11|bartowski/DeepSeek-R1-Distill-Qwen-32B-GGUF|DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf|DeepSeek-R1-Distill-Qwen-32B|17.0|64K|32|20|large|reasoning|R1 distill"
    "12|unsloth/Llama-3.3-70B-Instruct-GGUF|Llama-3.3-70B-Instruct-Q4_K_M.gguf|Llama-3.3-70B-Instruct|39.0|128K|48|40|large|chat,reasoning,code|Meta · 24GB+ VRAM"
    "13|kai-os/Carnice-9b-GGUF|Carnice-9b-Q6_K.gguf|Carnice-9b|7.4|256K|8|6|mid|hermes,agent,tool-use|Hermes Agent tuned · Qwen3.5-9B base · Q6_K"
    "14|DJLougen/Harmonic-Hermes-9B-GGUF|Harmonic-Hermes-9B-Q5_K_M.gguf|Harmonic-Hermes-9B|6.5|128K|8|6|mid|hermes,agent,reasoning|Stage 2 agent fine-tune · deep reasoning · Q5_K_M"
    "15|KyleHessling1/Qwopus-GLM-18B-Merged-GGUF|Qwopus-GLM-18B-Healed-Q4_K_M.gguf|Qwopus-GLM-18B-Healed|9.84|64K|12|10|mid|reasoning,code,tool-use|Frankenmerge · healed QLoRA · beats Qwen3.6 35B MoE"
)

# ----------------------------- Grading Helpers -----------------------------
grade_model() {
    local min_ram="${1:?grade_model: min_ram required}"
    local min_vram="${2:?grade_model: min_vram required}"
    local ram_gib="${3:?grade_model: ram_gib required}"
    local vram_gib="${4:?grade_model: vram_gib required}"
    local has_nvidia="${5:?grade_model: has_nvidia required}"
    local ram_h=$(( ram_gib - min_ram ))

    if [[ $min_vram -gt 0 && "$has_nvidia" == "true" ]]; then
        local vram_h=$(( vram_gib - min_vram ))
        if   [[ $vram_h -ge 4 ]]; then echo "S"
        elif [[ $vram_h -ge 0 ]]; then echo "A"
        elif [[ $ram_h  -ge 4 ]]; then echo "B"
        elif [[ $ram_h  -ge 0 ]]; then echo "C"
        else                           echo "F"
        fi
    elif [[ $min_vram -gt 0 ]]; then
        if   [[ $ram_h -ge 8 ]]; then echo "B"
        elif [[ $ram_h -ge 0 ]]; then echo "C"
        else                          echo "F"
        fi
    else
        if   [[ $ram_h -ge 8 ]]; then echo "S"
        elif [[ $ram_h -ge 4 ]]; then echo "A"
        elif [[ $ram_h -ge 0 ]]; then echo "B"
        else                          echo "F"
        fi
    fi
}

grade_label() {
    case $1 in
        S) echo "S  Runs great ";; A) echo "A  Runs well  ";;
        B) echo "B  Decent     ";; C) echo "C  Tight fit  ";;
        F) echo "F  Too heavy  ";; *) echo "?  Unknown    ";;
    esac
}

grade_color() {
    case $1 in S|A) echo "${GRN}";; B|C) echo "${YLW}";; *) echo "${RED}";; esac
}

# FIX bug 10: single variable MODELS_DIR used everywhere; removed MODEL_DIR alias
is_downloaded() { [[ -f "${MODELS_DIR}/$1" ]]; }

# ----------------------------- Model Selection -----------------------------
select_model() {
    local LAST_TIER=""
    declare -A RECOMMENDED_SET=()
    local RECOMMENDED=()
    local NUM_MODELS=${#MODELS[@]}

    /usr/bin/clear 2>/dev/null || clear
    echo -e "${BLD}${CYN}"
    cat <<'HDR'
╔══════════════════════════════════════════════════════════════════════════════╗
║                        Model Selection                                      ║
╚══════════════════════════════════════════════════════════════════════════════╝
HDR
    echo -e "${RST}"

    printf "  GPU: %-28s  RAM: %s GiB   VRAM: %s GiB   CUDA: %s\n\n" \
        "${GPU_NAME:0:28}" "$RAM_GiB" "$VRAM_GiB" "$HAS_NVIDIA"

    echo -e "  ${BLD} #   Model                    Size    Ctx     Grade              Tags${RST}"
    echo    "  ─────────────────────────────────────────────────────────────────────────────"

    while IFS='|' read -r idx hf_repo gguf_file dname size_gb ctx min_ram min_vram tier tags desc; do
        idx="${idx// /}"; dname="${dname# }"; dname="${dname% }"
        size_gb="${size_gb// /}"; ctx="${ctx// /}"
        min_ram="${min_ram// /}"; min_vram="${min_vram// /}"
        tier="${tier// /}"; tags="${tags// /}"; gguf_file="${gguf_file// /}"

        if [[ "$tier" != "$LAST_TIER" ]]; then
            case $tier in
                tiny)  echo -e "\n  ${BLD}▸ TINY   (< 1 GB · instant · edge/test)${RST}" ;;
                small) echo -e "\n  ${BLD}▸ SMALL  (1–2 GB · fast CPU · everyday use)${RST}" ;;
                mid)   echo -e "\n  ${BLD}▸ MID    (4–17 GB · quality/speed balance)${RST}" ;;
                large) echo -e "\n  ${BLD}▸ LARGE  (15 GB+ · high-end GPU or lots of RAM)${RST}" ;;
            esac
            LAST_TIER="$tier"
        fi

        GRADE=$(grade_model "$min_ram" "$min_vram" "$RAM_GiB" "$VRAM_GiB" "$HAS_NVIDIA")
        GC=$(grade_color "$GRADE")
        GL=$(grade_label "$GRADE")

        local cached=""
        if is_downloaded "$gguf_file"; then
            cached=" ${CYN}↓${RST}"
            [[ -z "${RECOMMENDED_SET[$idx]:-}" ]] && { RECOMMENDED_SET[$idx]=1; RECOMMENDED+=("$idx"); }
        elif [[ "$GRADE" != "F" ]]; then
            [[ -z "${RECOMMENDED_SET[$idx]:-}" ]] && { RECOMMENDED_SET[$idx]=1; RECOMMENDED+=("$idx"); }
        fi

        local tag_display="${tags//,/ }"
        echo -e "  ${BLD}$(printf '%2s' "$idx")${RST}  $(printf '%-26s' "$dname")  $(printf '%5s' "$size_gb") GB  $(printf '%-7s' "$ctx")  ${GC}$(printf '%-13s' "$GL")${RST}  $(printf '%-24s' "$tag_display") $cached"

    done < <(printf '%s\n' "${MODELS[@]}")

    echo ""
    echo    "  ─────────────────────────────────────────────────────────────────────────────"
    echo -e "  ${GRN}S/A${RST} Runs great/well   ${YLW}B/C${RST} Tight fit   ${RED}F${RST} Too heavy   ${CYN}↓${RST} Already on disk"
    echo ""

    if [[ ${#RECOMMENDED[@]} -gt 0 ]]; then
        mapfile -t UNIQUE_REC < <(printf '%s\n' "${RECOMMENDED[@]}" | sort -nu)
        echo -e "  ${BLD}Fits your hardware:${RST} ${UNIQUE_REC[*]}"
        echo -e "  ${YLW}Tip:${RST} @sudoingX used model 5 (Qwen 3.5 9B) on RTX 3060 12GB"
    else
        echo -e "  ${RED}No model fits. Models 1–3 still run on CPU.${RST}"
    fi
    echo ""

    local CHOICE
    while true; do
        if [[ -t 0 ]]; then
            read -rp "$(echo -e "  ${BLD}Enter model number [1-${NUM_MODELS}]:${RST} ")" CHOICE
        else
            echo "Non-interactive – defaulting to model 5 (Qwen 3.5 9B)"
            CHOICE=5
            break
        fi
        if [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= NUM_MODELS )); then
            break
        fi
        echo "Please enter a number between 1 and ${NUM_MODELS}."
    done

    SELECTED_REPO="" SELECTED_GGUF="" SELECTED_NAME="" SELECTED_GRADE="" SELECTED_CTX=""
    SEL_MIN_RAM="0" SEL_MIN_VRAM="0"
    while IFS='|' read -r idx hf_repo gguf_file dname size_gb ctx min_ram min_vram tier tags desc; do
        idx="${idx// /}"
        if [[ "$idx" == "$CHOICE" ]]; then
            SELECTED_REPO="${hf_repo// /}"
            SELECTED_GGUF="${gguf_file// /}"
            SELECTED_NAME="${dname# }"; SELECTED_NAME="${SELECTED_NAME% }"
            SELECTED_CTX="${ctx// /}"
            SEL_MIN_RAM="${min_ram// /}"
            SEL_MIN_VRAM="${min_vram// /}"
            SELECTED_GRADE=$(grade_model "$SEL_MIN_RAM" "$SEL_MIN_VRAM" "$RAM_GiB" "$VRAM_GiB" "$HAS_NVIDIA")
            break
        fi
    done < <(printf '%s\n' "${MODELS[@]}")

    [[ -z "$SELECTED_GGUF" ]] && { echo "Model parse failed."; exit 1; }

    echo "Selected: ${SELECTED_NAME}  (${SELECTED_GGUF})"

    if [[ "$SELECTED_GRADE" == "F" ]]; then
        echo "Grade F — this model will likely fail on your hardware."
        if [[ -t 0 ]]; then
            read -rp "  Continue anyway? [y/N]: " go_anyway
            [[ "$go_anyway" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
        fi
    elif [[ "$SELECTED_GRADE" == "C" ]]; then
        echo "Grade C — tight fit, expect slow responses."
    fi
}

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

# FIX bug 5: detect actual default branch instead of hardcoding 'master'
needs_update() {
    if [[ ! -d "$LLAMA_DIR" ]] || [[ ! -d "$LLAMA_DIR/.git" ]]; then
        return 0  # Need to clone
    fi

    # FIX bug 6: run in subshell to avoid cd side effect
    (
        cd "$LLAMA_DIR"
        DEFAULT_BRANCH=$(git remote show origin 2>/dev/null | awk '/HEAD branch/ {print $NF}')
        DEFAULT_BRANCH="${DEFAULT_BRANCH:-master}"

        if ! git fetch origin "$DEFAULT_BRANCH" 2>/dev/null; then
            echo "Warning: Could not fetch from remote, assuming update needed" >&2
            exit 0  # return 0 = update needed
        fi

        local_commit=$(git rev-parse HEAD 2>/dev/null || echo "")
        remote_commit=$(git rev-parse "origin/${DEFAULT_BRANCH}" 2>/dev/null || echo "")

        if [[ -z "$local_commit" || -z "$remote_commit" ]]; then
            exit 0  # assume update needed
        fi

        [[ "$local_commit" != "$remote_commit" ]]
    )
}

# ----------------------------- HuggingFace Setup -----------------------------
setup_hf() {
    pip3 install --user --break-system-packages --quiet huggingface_hub

    # Suppress interactive update prompt
    export HF_HUB_DISABLE_IMPLICIT_TOKEN=1
    export HUGGINGFACE_HUB_VERBOSITY=warning

    # Check for HF token
    HF_TOKEN="${HF_TOKEN:-}"
    if [[ -z "$HF_TOKEN" ]] && [[ -f "$HOME/.cache/huggingface/token" ]]; then
        HF_TOKEN=$(cat "$HOME/.cache/huggingface/token")
    fi

    if [[ -n "$HF_TOKEN" ]]; then
        export HF_TOKEN
        hf auth login --token "$HF_TOKEN" 2>/dev/null || true
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
    # FIX bug 9: pass HF_TOKEN explicitly so it's always available to hf
    HF_HUB_DISABLE_IMPLICIT_TOKEN=1 HF_TOKEN="${HF_TOKEN:-}" \
        hf download "$SELECTED_REPO" "$SELECTED_GGUF" --local-dir .
}

# ----------------------------- Hermes Agent Setup -----------------------------
setup_hermes() {
    echo "Installing Hermes Agent..."
    # FIX bug 8: use outsourc-e fork (matches main branch), not NousResearch
    curl -fsSL https://raw.githubusercontent.com/outsourc-e/hermes-agent/main/scripts/install.sh | bash

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

# ----------------------------- System Dependencies -----------------------------
# FIX bug 1: moved apt/CUDA/build into functions called from main flow,
#            so they run after model selection in the correct order
install_system_deps() {
    echo "Updating system packages..."
    # FIX bug 11: non-interactive to prevent prompts during upgrade
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq

    echo "Installing dependencies..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        build-essential cmake git python3 python3-pip python3-venv \
        curl wget libcurl4-openssl-dev libopenblas-dev \
        ccache

    # Install CUDA if NVIDIA GPU detected
    if [[ "$HAS_NVIDIA" == "true" ]] && ! command -v nvcc &>/dev/null; then
        echo "Installing CUDA toolkit..."
        wget -q https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb
        sudo dpkg -i cuda-keyring_1.1-1_all.deb
        sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y cuda-toolkit-12-6
        rm -f cuda-keyring_1.1-1_all.deb
    fi
}

# ----------------------------- llama.cpp Build -----------------------------
build_llama() {
    mkdir -p "$MODELS_DIR" "$INSTALL_DIR" "$LLAMA_DIR"

    if needs_update || [[ ! -f "$VERSION_FILE" ]]; then
        echo "Updating llama.cpp..."
        if [[ ! -d "$LLAMA_DIR/.git" ]]; then
            git clone https://github.com/ggml-org/llama.cpp.git "$LLAMA_DIR"
        else
            git -C "$LLAMA_DIR" pull
        fi

        echo "Building llama.cpp with CUDA support (RTX 3060 optimized)..."
        rm -rf "$LLAMA_DIR/build"

        if cmake -B "$LLAMA_DIR/build" -S "$LLAMA_DIR" \
            -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_CUDA_ARCHITECTURES=86 -DLLAMA_CURL=ON -DGGML_CCACHE=ON; then
            echo "CMake configure succeeded"
        else
            echo "CMake configure failed"; exit 1
        fi

        if cmake --build "$LLAMA_DIR/build" --config Release -j"$(nproc)"; then
            echo "CMake build succeeded"
        else
            echo "CMake build failed"; exit 1
        fi

        # FIX bug 7: removed sudo — $INSTALL_DIR is a user directory ($HOME/.local/bin)
        ln -sf "$LLAMA_DIR/build/bin/llama-server" "$INSTALL_DIR/llama-server"
        ln -sf "$LLAMA_DIR/build/bin/llama-cli"    "$INSTALL_DIR/llama-cli"

        echo "✅ llama.cpp built successfully"
        _set_installed_version
    else
        echo "✅ llama.cpp already up-to-date"
        if [[ ! -x "$LLAMA_DIR/build/bin/llama-server" ]]; then
            echo "Building missing binaries..."
            cmake --build "$LLAMA_DIR/build" --config Release -j"$(nproc)" || {
                echo "Binary build failed, rebuilding from source"
                git -C "$LLAMA_DIR" pull
                rm -rf "$LLAMA_DIR/build"
                cmake -B "$LLAMA_DIR/build" -S "$LLAMA_DIR" \
                    -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release \
                    -DCMAKE_CUDA_ARCHITECTURES=86 -DLLAMA_CURL=ON -DGGML_CCACHE=ON
                cmake --build "$LLAMA_DIR/build" --config Release -j"$(nproc)"
            }
            ln -sf "$LLAMA_DIR/build/bin/llama-server" "$INSTALL_DIR/llama-server"
            ln -sf "$LLAMA_DIR/build/bin/llama-cli"    "$INSTALL_DIR/llama-cli"
        fi
    fi
}

# ----------------------------- Create Wrapper Scripts -----------------------------
create_wrapper_scripts() {
    mkdir -p "$INSTALL_DIR"

    # FIX bug 2 & 3: start-llm is now a complete working script.
    # Uses unquoted EOF so installer-time variables expand into the script.
    cat > "$INSTALL_DIR/start-llm" << EOF
#!/usr/bin/env bash
set -euo pipefail

MODELS_DIR="\$HOME/llm-models"
LLAMA_SERVER="${INSTALL_DIR}/llama-server"
CONFIG_FILE="\$HOME/.llm-config"

# Load saved model config if present, otherwise use install-time defaults
if [[ -f "\$CONFIG_FILE" ]]; then
    source "\$CONFIG_FILE"
else
    SELECTED_GGUF="${SELECTED_GGUF}"
    SELECTED_NAME="${SELECTED_NAME}"
    SELECTED_CTX="${SELECTED_CTX}"
fi

GGUF_PATH="\${MODELS_DIR}/\${SELECTED_GGUF}"

if [[ ! -f "\$GGUF_PATH" ]]; then
    echo "Model not found: \$GGUF_PATH"
    echo "Run switch-model to download a model first."
    exit 1
fi

# Stop any running instance
PID_FILE="/tmp/llama-server.pid"
if [[ -f "\$PID_FILE" ]]; then
    OLD_PID=\$(cat "\$PID_FILE")
    kill "\$OLD_PID" 2>/dev/null || true
    rm -f "\$PID_FILE"
fi

# Resolve ctx (strip K suffix for llama-server -c flag)
CTX_NUM=\$(echo "\$SELECTED_CTX" | sed 's/K/000/;s/k/000/')

echo "Starting llama-server..."
echo "  Model  : \$SELECTED_NAME"
echo "  File   : \$GGUF_PATH"
echo "  Context: \$CTX_NUM tokens"
echo "  Endpoint: http://localhost:8080/v1"
echo ""

nohup "\$LLAMA_SERVER" \\
    -m "\$GGUF_PATH" \\
    -ngl 99 \\
    --ctx-size "\$CTX_NUM" \\
    --host 0.0.0.0 \\
    --port 8080 \\
    --jinja \\
    > /tmp/llama-server.log 2>&1 &

echo \$! > "\$PID_FILE"
echo "✅ llama-server started (PID: \$(cat \$PID_FILE))"
echo "Logs: tail -f /tmp/llama-server.log"
EOF

    # FIX bug 4: switch-model now actually saves the selection and restarts the server
    cat > "$INSTALL_DIR/switch-model" << 'SWEOF'
#!/usr/bin/env bash
export RED='\033[0;31m' GRN='\033[0;32m' YLW='\033[1;33m'
export CYN='\033[0;36m' BLD='\033[1m' RST='\033[0m'

MODELS=(
    "1|unsloth/Qwen3.5-0.8B-GGUF|Qwen3.5-0.8B-Q4_K_M.gguf|Qwen3.5-0.8B|0.5|256K|2|0|tiny|chat,edge|Alibaba · instant · smoke-test"
    "2|unsloth/Qwen3.5-2B-GGUF|Qwen3.5-2B-Q4_K_M.gguf|Qwen3.5-2B|1.0|256K|3|0|tiny|chat,multilingual|Alibaba · ultra-fast"
    "3|unsloth/Qwen3.5-4B-GGUF|Qwen3.5-4B-Q4_K_M.gguf|Qwen3.5-4B|2.0|256K|4|0|small|chat,code|Alibaba · capable on CPU"
    "4|bartowski/Phi-4-mini-instruct-GGUF|Phi-4-mini-instruct-Q4_K_M.gguf|Phi-4-mini-instruct|2.0|16K|4|0|small|reasoning,code|Microsoft · strong reasoning"
    "5|unsloth/Qwen3.5-9B-GGUF|Qwen3.5-9B-Q4_K_M.gguf|Qwen3.5-9B|5.3|256K|8|6|mid|chat,code,reasoning|@sudoingX pick · 50 tok/s on 3060"
    "6|bartowski/Llama-3.1-8B-Instruct-GGUF|Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf|Meta-Llama-3.1-8B-Instruct|4.1|128K|8|6|mid|chat,code,reasoning|Meta · excellent instruction"
    "7|bartowski/Qwen2.5-Coder-14B-Instruct-GGUF|Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf|Qwen2.5-Coder-14B-Instruct|8.99|32K|12|10|mid|code|#1 coding on 3060"
    "8|unsloth/Qwen3-14B-GGUF|Qwen3-14B-Q4_K_M.gguf|Qwen3-14B|9.0|32K|14|10|mid|chat,code,reasoning|Strong planning"
    "9|bartowski/google_gemma-3-12b-it-GGUF|google_gemma-3-12b-it-Q4_K_M.gguf|google_gemma-3-12b-it|7.3|128K|12|10|mid|chat,code|Google · strict output"
    "10|unsloth/Qwen3-30B-A3B-GGUF|Qwen3-30B-A3B-Q4_K_M.gguf|Qwen3-30B-A3B|17.0|128K|20|16|large|chat,code,reasoning|MoE · 3B active"
    "11|bartowski/DeepSeek-R1-Distill-Qwen-32B-GGUF|DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf|DeepSeek-R1-Distill-Qwen-32B|17.0|64K|32|20|large|reasoning|R1 distill"
    "12|unsloth/Llama-3.3-70B-Instruct-GGUF|Llama-3.3-70B-Instruct-Q4_K_M.gguf|Llama-3.3-70B-Instruct|39.0|128K|48|40|large|chat,reasoning,code|Meta · 24GB+ VRAM"
    "13|kai-os/Carnice-9b-GGUF|Carnice-9b-Q6_K.gguf|Carnice-9b|7.4|256K|8|6|mid|hermes,agent,tool-use|Hermes Agent tuned · Qwen3.5-9B base · Q6_K"
    "14|DJLougen/Harmonic-Hermes-9B-GGUF|Harmonic-Hermes-9B-Q5_K_M.gguf|Harmonic-Hermes-9B|6.5|128K|8|6|mid|hermes,agent,reasoning|Stage 2 agent fine-tune · deep reasoning · Q5_K_M"
    "15|KyleHessling1/Qwopus-GLM-18B-Merged-GGUF|Qwopus-GLM-18B-Healed-Q4_K_M.gguf|Qwopus-GLM-18B-Healed|9.84|64K|12|10|mid|reasoning,code,tool-use|Frankenmerge · healed QLoRA · beats Qwen3.6 35B MoE"
)

LAST_TIER=""
echo -e "${BLD}${CYN}"
cat <<'HDR'
╔══════════════════════════════════════════════════════════════════════════════╗
║                        Switch Model                                         ║
╚══════════════════════════════════════════════════════════════════════════════╝
HDR
echo -e "${RST}"
echo -e "  ${BLD} #   Model                    Size    Ctx     Tags${RST}"
echo    "  ─────────────────────────────────────────────────────────────────────────────"

while IFS='|' read -r idx hf_repo gguf_file dname size_gb ctx min_ram min_vram tier tags desc; do
    idx="${idx// /}"; dname="${dname# }"; dname="${dname% }"
    tier="${tier// /}"; tags="${tags// /}"
    if [[ "$tier" != "$LAST_TIER" ]]; then
        case $tier in
            tiny)  echo -e "\n  ${BLD}▸ TINY   (< 1 GB · instant · edge/test)${RST}" ;;
            small) echo -e "\n  ${BLD}▸ SMALL  (1–2 GB · fast CPU · everyday use)${RST}" ;;
            mid)   echo -e "\n  ${BLD}▸ MID    (4–17 GB · quality/speed balance)${RST}" ;;
            large) echo -e "\n  ${BLD}▸ LARGE  (15 GB+ · high-end GPU or lots of RAM)${RST}" ;;
        esac
        LAST_TIER="$tier"
    fi
    # Mark already-downloaded models
    cached=""
    [[ -f "$HOME/llm-models/$gguf_file" ]] && cached=" ${CYN}↓${RST}"
    tag_display="${tags//,/ }"
    echo -e "  ${BLD}$(printf '%2s' "$idx")${RST}  $(printf '%-26s' "$dname")  $(printf '%5s' "$size_gb") GB  $(printf '%-7s' "$ctx")  $(printf '%-24s' "$tag_display")$cached"
done < <(printf '%s\n' "${MODELS[@]}")

echo ""
echo    "  ─────────────────────────────────────────────────────────────────────────────"
echo -e "  ${YLW}Tip:${RST} @sudoingX used model 5 (Qwen 3.5 9B) on RTX 3060 12GB"
echo ""
read -rp "  Enter model number [1-${#MODELS[@]}]: " choice

# Validate input
if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#MODELS[@]} )); then
    echo "Invalid selection."; exit 1
fi

# Parse selected entry
SEL_REPO="" SEL_GGUF="" SEL_NAME="" SEL_CTX=""
while IFS='|' read -r idx hf_repo gguf_file dname size_gb ctx min_ram min_vram tier tags desc; do
    if [[ "${idx// /}" == "$choice" ]]; then
        SEL_REPO="${hf_repo// /}"
        SEL_GGUF="${gguf_file// /}"
        SEL_NAME="${dname# }"; SEL_NAME="${SEL_NAME% }"
        SEL_CTX="${ctx// /}"
        break
    fi
done < <(printf '%s\n' "${MODELS[@]}")

# Download if not already present
GGUF_PATH="$HOME/llm-models/$SEL_GGUF"
if [[ ! -f "$GGUF_PATH" ]]; then
    echo "Downloading $SEL_NAME..."
    HF_HUB_DISABLE_IMPLICIT_TOKEN=1 hf download "$SEL_REPO" "$SEL_GGUF" \
        --local-dir "$HOME/llm-models"
fi

# Save config
cat > "$HOME/.llm-config" << CONF
SELECTED_GGUF="${SEL_GGUF}"
SELECTED_NAME="${SEL_NAME}"
SELECTED_CTX="${SEL_CTX}"
CONF

echo "✅ Switched to $SEL_NAME"

# Restart server if running
if [[ -f /tmp/llama-server.pid ]]; then
    echo "Restarting llama-server..."
    "$HOME/.local/bin/start-llm"
fi
SWEOF

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
    CONFIG_FILE="$HOME/.llm-config"
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        echo "Model: ${SELECTED_NAME:-Unknown}"
    fi
    if command -v curl &>/dev/null && curl -sf http://localhost:8080/v1/models &>/dev/null; then
        echo "Endpoint: http://localhost:8080/v1"
    fi
else
    echo -e "\033[0;31m● Stopped\033[0m"
fi
EOF

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
ExecStart=${INSTALL_DIR}/start-llm
Restart=on-failure
RestartSec=5
Environment=HOME=${HOME}
Environment=PATH=/usr/local/cuda/bin:${HOME}/.local/bin:/usr/bin:/bin
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

# =============================================================================
#  MAIN FLOW — all functions defined above, executed in correct order below
# =============================================================================

# 1. Detect hardware first so grading works in select_model
detect_hardware

# 2. Let user pick model before doing any heavy work
select_model

# 3. System dependencies and llama.cpp build
install_system_deps
build_llama

# 4. HuggingFace setup and model download
setup_hf
download_model

# 5. Write helper scripts (now SELECTED_* vars are populated)
create_wrapper_scripts

# 6. Additional simple helpers
mkdir -p "$INSTALL_DIR"

cat > "$INSTALL_DIR/stop-llm" << 'EOF'
#!/usr/bin/env bash
PID=$(cat /tmp/llama-server.pid 2>/dev/null || echo "")
if [[ -n "$PID" ]] && kill "$PID" 2>/dev/null; then
    rm -f /tmp/llama-server.pid
    echo "Stopped llama-server"
else
    echo "llama-server not running"
fi
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

# Save active model config for use by start-llm and switch-model
cat > "$HOME/.llm-config" << EOF
SELECTED_GGUF="${SELECTED_GGUF}"
SELECTED_NAME="${SELECTED_NAME}"
SELECTED_CTX="${SELECTED_CTX}"
EOF

# 7. Optional systemd service
if [[ -t 0 ]]; then
    read -rp "Create systemd service for auto-start? [Y/n]: " create_service
    if [[ ! "${create_service:-}" =~ ^[Nn]$ ]]; then
        create_systemd_service
    fi
else
    create_systemd_service
fi

# 8. Optional Hermes agent
if [[ -t 0 ]]; then
    read -rp "Install Hermes Agent? [Y/n]: " install_hermes
    if [[ ! "${install_hermes:-}" =~ ^[Nn]$ ]]; then
        setup_hermes
    fi
fi

echo ""
echo "✅ Installation completed!"
echo ""
echo "Commands available:"
echo "   start-llm          # Start server with selected model"
echo "   stop-llm           # Stop server"
echo "   llm-status         # Show server status"
echo "   switch-model       # Change model (downloads if needed, restarts server)"
echo "   vram               # Show GPU memory usage"
if command -v hermes &>/dev/null; then
    echo "   hermes             # Run Hermes Agent"
fi
echo ""
echo "Add to ~/.bashrc: export PATH=\"\$HOME/.local/bin:\$PATH\""
echo ""
echo "To rebuild llama.cpp: cd ~/llama.cpp && git pull && rm -rf build && cmake -B build -S . -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES=86 -DLLAMA_CURL=ON && cmake --build build --config Release -j\$(nproc)"
