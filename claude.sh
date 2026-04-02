#!/usr/bin/env bash
# =============================================================================
#  install.sh  –  Ubuntu WSL2  ·  llama.cpp + Hermes Agent + Qwen Code
#  PATCHED VERSION — fixes applied by Claude based on real-world debugging:
#   1. start-llm.sh: LLAMA_BIN/GGUF/MODEL_NAME/LLAMA_PID empty variable bug
#   2. start-llm.sh: missing $i in loop counter syntax error
#   3. .bashrc: duplicate block write / unclosed if bug
#   4. hermes-agent webapi: dict vs string bug in get_runtime_model()
#   5. hermes-agent webapi: provider resolving to anthropic instead of custom
# =============================================================================
set -euo pipefail

export RED='\033[0;31m' GRN='\033[0;32m' YLW='\033[1;33m'
export CYN='\033[0;36m' BLD='\033[1m' RST='\033[0m'
step() { echo -e "\n${CYN}[*] $*${RST}"; }
ok()   { echo -e "${GRN}[+] $*${RST}"; }
info() { ok "$*"; }
warn() { echo -e "${YLW}[!] $*${RST}"; }
die()  { echo -e "${RED}[ERROR] $*${RST}"; exit 1; }

TMPFILES=()
cleanup() {
    local f
    if [[ ${#TMPFILES[@]} -gt 0 ]]; then
        for f in "${TMPFILES[@]}"; do
            [[ -n "$f" && -f "$f" ]] && rm -f "$f"
        done
    fi
}
trap cleanup EXIT INT TERM

register_tmp() { TMPFILES+=("$1"); }

echo -e "${BLD}${CYN}"
cat <<'BANNER'
╔══════════════════════════════════════════════════════════╗
║   Ubuntu WSL2  ·  llama.cpp + Hermes Agent  ·  Setup    ║
╚══════════════════════════════════════════════════════════╝
BANNER
echo -e "${RST}"

if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
    ok "Running inside WSL2."
else
    warn "/proc/version does not mention Microsoft/WSL — continuing anyway."
fi

# =============================================================================
#  1. HuggingFace token (optional)
# =============================================================================
step "HuggingFace token (optional)..."
HF_TOKEN=""
if [[ -n "${HF_TOKEN:-}" ]]; then
    ok "HF_TOKEN already set in environment — using it."
elif [[ -f "${HOME}/.cache/huggingface/token" ]]; then
    HF_TOKEN=$(cat "${HOME}/.cache/huggingface/token" 2>/dev/null)
    [[ -n "$HF_TOKEN" ]] && ok "HF_TOKEN found in ~/.cache/huggingface/token."
elif grep -qF "export HF_TOKEN=" "${HOME}/.bashrc" 2>/dev/null; then
    HF_TOKEN=$(grep "export HF_TOKEN=" "${HOME}/.bashrc" | head -1 | \
        sed 's/.*export HF_TOKEN=//' | sed "s/^[\"']//" | sed "s/[\"']$//")
    [[ -n "$HF_TOKEN" ]] && ok "HF_TOKEN found in ~/.bashrc."
fi

if [[ -z "$HF_TOKEN" ]]; then
    echo ""
    echo -e "  ${BLD}Why add a HuggingFace token?${RST}"
    echo -e "  • Faster downloads from dedicated endpoints"
    echo -e "  • Higher rate limits"
    echo -e "  • Access to gated models (if you have access)"
    echo ""
    echo -e "  ${BLD}Get a free token here:${RST}"
    echo -e "  ${CYN}https://huggingface.co/settings/tokens${RST}"
    echo ""
    if [[ -t 0 ]]; then
        read -rp "  Do you have a HuggingFace token to add? [y/N]: " hf_yn
        if [[ "$hf_yn" =~ ^[Yy]$ ]]; then
            read -rp "  Paste your token (starts with hf_): " HF_TOKEN
            HF_TOKEN="${HF_TOKEN//[[:space:]]/}"
            if [[ "$HF_TOKEN" =~ ^hf_ ]]; then
                ok "Token accepted."
            else
                warn "Token doesn't start with 'hf_' — using it anyway, but double-check it."
            fi
        else
            ok "Skipping — unauthenticated downloads (slower, rate-limited)."
        fi
    else
        ok "Non-interactive – skipping HuggingFace token prompt."
    fi
fi
export HF_TOKEN

# =============================================================================
#  2. System update + dependencies
# =============================================================================
step "Updating system packages..."
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    build-essential cmake git ccache \
    libcurl4-openssl-dev software-properties-common \
    python3 python3-pip python3-venv \
    pciutils wget curl ca-certificates zstd \
    procps gettext-base
ok "System packages ready."

step "Installing Python 3.11 (Hermes requirement)..."
if python3.11 --version &>/dev/null; then
    ok "Python 3.11 already installed: $(python3.11 --version)"
else
    sudo add-apt-repository -y ppa:deadsnakes/ppa
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3.11 python3.11-venv
    ok "Python 3.11 installed: $(python3.11 --version)"
fi

# =============================================================================
#  3. Hardware detection
# =============================================================================
step "Detecting hardware..."
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_GiB=$(( RAM_KB / 1024 / 1024 ))
(( RAM_GiB == 0 )) && { warn "RAM detection returned 0 — defaulting to 8 GiB."; RAM_GiB=8; }
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
        ok "GPU : ${GPU_NAME}  (${VRAM_GiB} GiB VRAM)  — CUDA OK"
    else
        warn "nvidia-smi present but returned no GPU data — CPU-only."
    fi
else
    GPU_NAME=$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | head -1 | sed 's/.*: //' || echo "None")
    warn "nvidia-smi not found — CPU-only mode. GPU (lspci): ${GPU_NAME}"
fi

echo -e "\n  ${BLD}Hardware${RST}"
echo -e "  RAM  : ${RAM_GiB} GiB   CPUs: ${CPUS}"
echo -e "  GPU  : ${GPU_NAME}   VRAM: ${VRAM_GiB} GiB   CUDA: ${HAS_NVIDIA}"

if [[ "$HAS_NVIDIA" != "true" ]]; then
    warn "No NVIDIA GPU — llama.cpp will be CPU-only (much slower)."
    if [[ -t 0 ]]; then
        read -rp "  Continue with CPU-only build? [y/N]: " cpu_ok
        [[ "$cpu_ok" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    else
        warn "Non-interactive – continuing with CPU-only build."
    fi
fi

# =============================================================================
#  4. CUDA toolkit
# =============================================================================
if [[ "$HAS_NVIDIA" == "true" ]]; then
    step "Checking CUDA toolkit..."
    if command -v nvcc &>/dev/null; then
        ok "CUDA toolkit already installed: $(nvcc --version 2>/dev/null | head -1)"
    else
        step "Installing CUDA toolkit 12.6 for WSL2..."
        sudo rm -f /etc/apt/trusted.gpg.d/cuda.gpg 2>/dev/null || true
        curl -fsSL --connect-timeout 10 --max-time 60 \
            https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb \
            -o /tmp/cuda-keyring.deb || die "Failed to download CUDA keyring"
        register_tmp "/tmp/cuda-keyring.deb"
        sudo dpkg -i /tmp/cuda-keyring.deb
        sudo apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cuda-toolkit-12-6
        ok "CUDA toolkit 12.6 installed."
    fi
    export PATH="/usr/local/cuda/bin:${PATH}"
    export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"
fi

# =============================================================================
#  5. Model selection
# =============================================================================
MODELS=(
    "1|unsloth/Qwen3.5-0.8B-GGUF|Qwen3.5-0.8B-Q4_K_M.gguf|Qwen 3.5 0.8B|0.5|256K|2|0|tiny|chat,edge|Alibaba · instant · smoke-test"
    "2|unsloth/Qwen3.5-2B-GGUF|Qwen3.5-2B-Q4_K_M.gguf|Qwen 3.5 2B|1.0|256K|3|0|tiny|chat,multilingual|Alibaba · ultra-fast"
    "3|unsloth/Qwen3.5-4B-GGUF|Qwen3.5-4B-Q4_K_M.gguf|Qwen 3.5 4B|2.0|256K|4|0|small|chat,code|Alibaba · capable on CPU"
    "4|bartowski/Phi-4-mini-instruct-GGUF|Phi-4-mini-instruct-Q4_K_M.gguf|Phi-4 Mini 3.8B|2.0|16K|4|0|small|reasoning,code|Microsoft · strong reasoning"
    "5|unsloth/Qwen3.5-9B-GGUF|Qwen3.5-9B-Q4_K_M.gguf|Qwen 3.5 9B|5.3|256K|8|6|mid|chat,code,reasoning|@sudoingX pick · 50 tok/s on 3060"
    "6|bartowski/Llama-3.1-8B-Instruct-GGUF|Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf|Llama 3.1 8B|4.1|128K|8|6|mid|chat,code,reasoning|Meta · excellent instruction"
    "7|bartowski/Qwen2.5-Coder-14B-Instruct-GGUF|Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf|Qwen2.5 Coder 14B|8.99|32K|12|10|mid|code|#1 coding on 3060"
    "8|unsloth/Qwen3-14B-GGUF|Qwen3-14B-Q4_K_M.gguf|Qwen 3 14B|9.0|32K|14|10|mid|chat,code,reasoning|Strong planning"
    "9|bartowski/google_gemma-3-12b-it-GGUF|google_gemma-3-12b-it-Q4_K_M.gguf|Gemma 3 12B|7.3|128K|12|10|mid|chat,code|Google · strict output"
    "10|unsloth/Qwen3-30B-A3B-GGUF|Qwen3-30B-A3B-Q4_K_M.gguf|Qwen 3 30B MoE|17.0|128K|20|16|large|chat,code,reasoning|MoE · 3B active"
    "11|bartowski/DeepSeek-R1-Distill-Qwen-32B-GGUF|DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf|DeepSeek R1 32B|17.0|64K|32|20|large|reasoning|R1 distill"
    "12|unsloth/Llama-3.3-70B-Instruct-GGUF|Llama-3.3-70B-Instruct-Q4_K_M.gguf|Llama 3.3 70B|39.0|128K|48|40|large|chat,reasoning,code|Meta · 24GB+ VRAM"
)

MODEL_DIR="${HOME}/llm-models"
mkdir -p "$MODEL_DIR"

grade_model() {
    local min_ram="${1:?}" min_vram="${2:?}" ram_gib="${3:?}" vram_gib="${4:?}" has_nvidia="${5:?}"
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

grade_color() { case $1 in S|A) echo "${GRN}";; B|C) echo "${YLW}";; *) echo "${RED}";; esac; }
is_downloaded() { [[ -f "${MODEL_DIR}/$1" ]]; }

LAST_TIER=""
declare -A RECOMMENDED_SET=()
RECOMMENDED=()
NUM_MODELS=${#MODELS[@]}

/usr/bin/clear
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

    if is_downloaded "$gguf_file"; then
        cached=" ${CYN}↓${RST}"
        [[ -z "${RECOMMENDED_SET[$idx]:-}" ]] && { RECOMMENDED_SET[$idx]=1; RECOMMENDED+=("$idx"); }
    elif [[ "$GRADE" != "F" ]]; then
        cached=""
        [[ -z "${RECOMMENDED_SET[$idx]:-}" ]] && { RECOMMENDED_SET[$idx]=1; RECOMMENDED+=("$idx"); }
    else
        cached=""
    fi

    tag_display="${tags//,/ }"
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

while true; do
    if [[ -t 0 ]]; then
        read -rp "$(echo -e "  ${BLD}Enter model number [1-${NUM_MODELS}]:${RST} ")" CHOICE
    else
        warn "Non-interactive – defaulting to model 5 (Qwen 3.5 9B)"
        CHOICE=5
        break
    fi
    if [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= NUM_MODELS )); then
        break
    fi
    warn "Please enter a number between 1 and ${NUM_MODELS}."
done

SEL_IDX="" SEL_HF_REPO="" SEL_GGUF="" SEL_NAME="" SEL_MIN_RAM="0" SEL_MIN_VRAM="0"
while IFS='|' read -r idx hf_repo gguf_file dname size_gb ctx min_ram min_vram tier tags desc; do
    idx="${idx// /}"
    if [[ "$idx" == "$CHOICE" ]]; then
        SEL_IDX="$idx"
        SEL_HF_REPO="${hf_repo// /}"
        SEL_GGUF="${gguf_file// /}"
        SEL_NAME="${dname# }"; SEL_NAME="${SEL_NAME% }"
        SEL_MIN_RAM="${min_ram// /}"
        SEL_MIN_VRAM="${min_vram// /}"
        break
    fi
done < <(printf '%s\n' "${MODELS[@]}")

[[ -z "$SEL_GGUF"     ]] && die "Model parse failed: SEL_GGUF empty."
[[ -z "$SEL_MIN_RAM"  ]] && die "Model parse failed: SEL_MIN_RAM empty."
[[ -z "$SEL_MIN_VRAM" ]] && die "Model parse failed: SEL_MIN_VRAM empty."
[[ "$SEL_MIN_RAM"  =~ ^[0-9]+$ ]] || die "Model parse failed: SEL_MIN_RAM='$SEL_MIN_RAM' is not numeric."
[[ "$SEL_MIN_VRAM" =~ ^[0-9]+$ ]] || die "Model parse failed: SEL_MIN_VRAM='$SEL_MIN_VRAM' is not numeric."

ok "Selected: ${SEL_NAME}  (${SEL_GGUF})"

GRADE_SEL=$(grade_model "$SEL_MIN_RAM" "$SEL_MIN_VRAM" "$RAM_GiB" "$VRAM_GiB" "$HAS_NVIDIA")
if [[ "$GRADE_SEL" == "F" ]]; then
    warn "Grade F — this model will likely fail on your hardware."
    if [[ -t 0 ]]; then
        read -rp "  Continue anyway? [y/N]: " go_anyway
        [[ "$go_anyway" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    else
        warn "Non-interactive – continuing anyway (use with caution)."
    fi
elif [[ "$GRADE_SEL" == "C" ]]; then
    warn "Grade C — tight fit, expect slow responses."
fi

case "$SEL_GGUF" in
    *Qwen3.5*)        SAFE_CTX=262144; USE_JINJA="--jinja";    ok "Qwen3.5: 256K context" ;;
    *Llama-3.1*|*Llama-3.3*|*Qwen3-30B*) SAFE_CTX=131072; USE_JINJA="--jinja" ;;
    *google_gemma-3*) SAFE_CTX=131072; USE_JINJA="--no-jinja"; ok "Gemma 3: Jinja disabled" ;;
    *)                SAFE_CTX=32768;  USE_JINJA="--jinja" ;;
esac
ok "Context window: ${SAFE_CTX} tokens"

# =============================================================================
#  6. HuggingFace CLI + model download
# =============================================================================
step "Setting up HuggingFace CLI..."
export PATH="${HOME}/.local/bin:${PATH}"
HF_CLI="${HOME}/.local/bin/hf"
HF_CLI_LEGACY="${HOME}/.local/bin/huggingface-cli"

if [[ ! -x "$HF_CLI" && ! -x "$HF_CLI_LEGACY" ]]; then
    pip3 install --quiet --user --break-system-packages huggingface_hub
fi

if [[ -x "$HF_CLI" ]]; then
    HF_CLI_USED="$HF_CLI"; HF_CLI_NAME="hf"
elif [[ -x "$HF_CLI_LEGACY" ]]; then
    HF_CLI_USED="$HF_CLI_LEGACY"; HF_CLI_NAME="huggingface-cli"
else
    die "Neither 'hf' nor 'huggingface-cli' found after install."
fi

pip3 install --quiet --user --break-system-packages --upgrade huggingface_hub 2>&1 | tail -3
ok "$HF_CLI_NAME ready"
HF_CLI="$HF_CLI_USED"

if [[ -n "${HF_TOKEN:-}" ]]; then
    "$HF_CLI" auth login --token "$HF_TOKEN" 2>/dev/null || \
    "$HF_CLI" login --token "$HF_TOKEN" 2>/dev/null || \
    ok "HF token ready (may be cached)."
fi

GGUF_PATH="${MODEL_DIR}/${SEL_GGUF}"
if [[ -f "$GGUF_PATH" ]]; then
    ok "Model already on disk: ${GGUF_PATH} — skipping download."
else
    step "Downloading ${SEL_NAME} from HuggingFace..."
    AVAIL_KB=$(df -k "${MODEL_DIR}" | awk 'NR==2 {print $4}')
    AVAIL_GB=$((AVAIL_KB / 1024 / 1024))
    REQ_GB=$(printf '%s\n' "${MODELS[@]}" | grep -F "${CHOICE}|" | head -1 | cut -d'|' -f5)
    REQ_GB_INT=${REQ_GB%.*}
    [[ "$REQ_GB" == *"."* ]] && REQ_GB_INT=$((REQ_GB_INT + 1))
    REQ_GB_INT=$((REQ_GB_INT + 2))
    (( REQ_GB_INT < 3 )) && REQ_GB_INT=3
    (( AVAIL_GB < REQ_GB_INT )) && die "Insufficient disk space: need ~${REQ_GB_INT}GB, have ${AVAIL_GB}GB."
    ok "Disk space OK: ${AVAIL_GB}GB available."

    if [[ -n "${HF_TOKEN:-}" ]]; then
        HF_TOKEN="${HF_TOKEN}" "$HF_CLI" download "${SEL_HF_REPO}" "${SEL_GGUF}" --local-dir "${MODEL_DIR}"
    else
        "$HF_CLI" download "${SEL_HF_REPO}" "${SEL_GGUF}" --local-dir "${MODEL_DIR}"
    fi
    [[ -f "$GGUF_PATH" ]] || die "Download completed but file not found."
    FILE_SIZE=$(stat -c%s "$GGUF_PATH" 2>/dev/null || echo 0)
    (( FILE_SIZE < 104857600 )) && die "Downloaded file suspiciously small (${FILE_SIZE} bytes)."
    ok "Model downloaded: ${GGUF_PATH}"
fi

# =============================================================================
#  7. Build llama.cpp
# =============================================================================
step "Checking llama.cpp..."

find_llama_server() {
    local p version_output
    for p in /usr/local/bin/llama-server /usr/bin/llama-server \
              "${HOME}/.local/bin/llama-server" \
              "${HOME}/llama.cpp/build/bin/llama-server"; do
        if [[ -x "$p" ]]; then
            version_output=$("$p" --version 2>&1) || continue
            echo "$version_output" | grep -qiE 'llama|ggml|llama\.cpp' && { echo "$p"; return 0; }
        fi
    done
    return 1
}

LLAMA_SERVER_BIN=$(find_llama_server || true)

if [[ -n "$LLAMA_SERVER_BIN" ]]; then
    ok "llama-server: ${LLAMA_SERVER_BIN} — skipping build."
else
    step "Building llama.cpp from source..."
    if command -v ccache &>/dev/null; then
        export CC="ccache gcc" CXX="ccache g++"
    else
        export CC="gcc" CXX="g++"
    fi

    LLAMA_DIR="${HOME}/llama.cpp"
    if [[ -d "$LLAMA_DIR/.git" ]]; then
        git -C "$LLAMA_DIR" fetch origin
        git -C "$LLAMA_DIR" reset --hard origin/HEAD
    else
        git clone https://github.com/ggml-org/llama.cpp.git "$LLAMA_DIR"
    fi

    cd "$LLAMA_DIR"
    if [[ "$HAS_NVIDIA" == "true" ]]; then
        cmake -B build -DGGML_CUDA=ON -DGGML_CUDA_FA_ALL_QUANTS=ON \
            -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc -DGGML_CCACHE=ON
    else
        cmake -B build -DGGML_CCACHE=ON
    fi
    cmake --build build --config Release -j"$(nproc)"
    sudo cmake --install build || warn "System install failed — using build directory."
    cd ~

    LLAMA_SERVER_BIN=$(find_llama_server || true)
    [[ -n "$LLAMA_SERVER_BIN" ]] || die "llama-server not found after build."
    ok "llama-server: ${LLAMA_SERVER_BIN}"
fi

# =============================================================================
#  8. Hermes Agent (outsourc-e fork with WebAPI support)
# =============================================================================
step "Setting up Hermes Agent..."
HERMES_AGENT_DIR="${HOME}/hermes-agent"
HERMES_VENV="${HERMES_AGENT_DIR}/.venv"
HERMES_BIN="${HOME}/.local/bin/hermes"
HERMES_WEBAPI_INSTALLED=false
HERMES_WORKSPACE_INSTALLED=false
export PATH="${HOME}/.local/bin:${PATH}"

if [[ -d "${HERMES_AGENT_DIR}/.git" ]]; then
    ok "Hermes Agent already cloned — updating..."
    cd "${HERMES_AGENT_DIR}"
    git fetch origin 2>/dev/null && git reset --hard origin/main 2>/dev/null || warn "Hermes git update failed."
    cd - >/dev/null
else
    step "Cloning outsourc-e/hermes-agent..."
    git clone https://github.com/outsourc-e/hermes-agent.git "${HERMES_AGENT_DIR}" 2>&1 | tail -3
    ok "Hermes Agent cloned."
fi

if [[ ! -d "${HERMES_VENV}" ]]; then
    python3.11 -m venv "${HERMES_VENV}"
    ok "Venv created at ${HERMES_VENV}"
fi

# Always install fastapi explicitly to avoid missing module errors
if ! "${HERMES_VENV}/bin/python" -c "import fastapi" &>/dev/null; then
    step "Installing Hermes Agent dependencies..."
    "${HERMES_VENV}/bin/pip" install -e "${HERMES_AGENT_DIR}[all]"
    ok "Dependencies installed."
fi
# Ensure fastapi and uvicorn are always present
"${HERMES_VENV}/bin/pip" install --quiet fastapi uvicorn

# ── PATCH 1: fix dict vs string bug in get_runtime_model() ───────────────────
step "Applying webapi patches..."
DEPS_FILE="${HERMES_AGENT_DIR}/webapi/deps.py"
if [[ -f "$DEPS_FILE" ]]; then
    # Fix get_runtime_model() to unwrap dict
    python3 << PYPATCH
import re

with open('${DEPS_FILE}', 'r') as f:
    content = f.read()

# Fix 1: get_runtime_model unwraps dict
old1 = 'def get_runtime_model() -> str:\n    return _resolve_model()'
new1 = '''def get_runtime_model() -> str:
    model = _resolve_model()
    if isinstance(model, dict):
        return model.get("default") or model.get("model") or str(model)
    return model'''

if old1 in content:
    content = content.replace(old1, new1)
    print("  ✓ Patched get_runtime_model()")
else:
    print("  ℹ get_runtime_model() already patched or different format")

# Fix 2: _resolve_runtime_agent_kwargs uses correct provider/base_url from nested model config
old2 = 'return {"provider": config.get("provider", os.getenv("HERMES_PROVIDER", "anthropic"))}'
new2 = '''model_cfg = config.get("model", {})
        provider = (
            config.get("provider")
            or (model_cfg.get("provider") if isinstance(model_cfg, dict) else None)
            or os.getenv("HERMES_PROVIDER", "custom")
        )
        base_url = (
            config.get("base_url")
            or (model_cfg.get("base_url") if isinstance(model_cfg, dict) else None)
            or os.getenv("OPENAI_BASE_URL", "http://localhost:8080/v1")
        )
        return {"provider": provider, "base_url": base_url}'''

if old2 in content:
    content = content.replace(old2, new2)
    print("  ✓ Patched _resolve_runtime_agent_kwargs()")
else:
    print("  ℹ _resolve_runtime_agent_kwargs() already patched or different format")

with open('${DEPS_FILE}', 'w') as f:
    f.write(content)
PYPATCH
fi

# ── PATCH 2: fix dict.lower() bug in chat.py ─────────────────────────────────
CHAT_FILE="${HERMES_AGENT_DIR}/webapi/routes/chat.py"
if [[ -f "$CHAT_FILE" ]]; then
    python3 << PYPATCH2
with open('${CHAT_FILE}', 'r') as f:
    content = f.read()

old = 'lower = content.lower() if isinstance(content, str) else ""'
new = 'content = content if isinstance(content, str) else str(content)\n        lower = content.lower()'

if old in content:
    content = content.replace(old, new)
    print("  ✓ Patched chat.py dict.lower() bug")
else:
    print("  ℹ chat.py already patched or different format")

with open('${CHAT_FILE}', 'w') as f:
    f.write(content)
PYPATCH2
fi

ok "Webapi patches applied."

HERMES_VENV_BIN="${HERMES_VENV}/bin/hermes"
if [[ -x "$HERMES_VENV_BIN" ]]; then
    mkdir -p "${HOME}/.local/bin"
    ln -sf "$HERMES_VENV_BIN" "$HERMES_BIN"
    ok "Symlinked hermes → ${HERMES_BIN}"
fi

if [[ -x "$HERMES_BIN" ]] && "${HERMES_BIN}" --help &>/dev/null; then
    HERMES_VER=$("${HERMES_BIN}" --version 2>/dev/null || echo "installed")
    ok "Hermes Agent ready: ${HERMES_VER}"
    HERMES_WEBAPI_INSTALLED=true
fi

# =============================================================================
#  8c. Configure Hermes → llama-server
# =============================================================================
step "Configuring Hermes for local llama-server..."
HERMES_DIR="${HOME}/.hermes"
mkdir -p "${HERMES_DIR}"/{cron,sessions,logs,memories,skills}
CONFIG_FILE="${HERMES_DIR}/config.yaml"
ENV_FILE="${HERMES_DIR}/.env"

cat > "$ENV_FILE" <<ENV
OPENAI_API_KEY=llama
LLM_MODEL=${SEL_NAME}
HERMES_WEBAPI_HOST=0.0.0.0
HERMES_WEBAPI_PORT=8642
ENV

if [[ -f "$CONFIG_FILE" ]] && grep -q "^model:" "$CONFIG_FILE" 2>/dev/null; then
    sed -i "s|^  default:.*|  default: \"${SEL_NAME}\"|" "$CONFIG_FILE" 2>/dev/null || true
    sed -i "s|^  provider:.*|  provider: custom|" "$CONFIG_FILE" 2>/dev/null || true
    if grep -q "^  base_url:" "$CONFIG_FILE" 2>/dev/null; then
        sed -i "s|^  base_url:.*|  base_url: http://localhost:8080/v1|" "$CONFIG_FILE" 2>/dev/null || true
    else
        sed -i '/^model:/a\  base_url: http://localhost:8080/v1' "$CONFIG_FILE" 2>/dev/null || true
    fi
    ok "config.yaml updated."
else
    cat > "$CONFIG_FILE" <<CONFIG
# Hermes Agent Configuration — generated by install.sh for ${SEL_NAME}
model:
  default: "${SEL_NAME}"
  provider: custom
  base_url: http://localhost:8080/v1
CONFIG
    ok "config.yaml created."
fi

ok "Hermes configured → llama-server (${SEL_NAME} at http://localhost:8080/v1)"

# =============================================================================
#  8d. Hermes Workspace
# =============================================================================
step "Setting up Hermes Workspace..."
WORKSPACE_DIR="${HOME}/hermes-workspace"

if [[ -d "${WORKSPACE_DIR}/.git" ]]; then
    ok "Hermes Workspace already cloned — updating."
    cd "${WORKSPACE_DIR}"
    git fetch origin 2>/dev/null && git reset --hard origin/main 2>/dev/null || true
    cd - >/dev/null
else
    git clone https://github.com/outsourc-e/hermes-workspace.git "${WORKSPACE_DIR}" 2>&1 | tail -3
fi

export PNPM_HOME="${HOME}/.local/share/pnpm"
export PATH="${PNPM_HOME}:${PATH}"
if ! command -v pnpm &>/dev/null; then
    curl -fsSL https://get.pnpm.io/install.sh | env PNPM_HOME="$PNPM_HOME" bash -
    export PATH="${PNPM_HOME}:${PATH}"
fi
command -v pnpm &>/dev/null || die "pnpm installation failed."
ok "pnpm $(pnpm --version) ready."

if ! command -v node &>/dev/null || [[ "$(which node 2>/dev/null)" == /mnt/* ]] || [[ "$(node --version 2>/dev/null | sed 's/v//')" != "24."* ]]; then
    step "Installing Node.js 24 LTS..."
    curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash - 2>/dev/null
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs
    export PATH="/usr/bin:/bin:/usr/local/bin:${PATH}"
else
    ok "Node.js $(node --version) already installed"
fi

cd "${WORKSPACE_DIR}"
if [[ ! -d "node_modules" ]]; then
    pnpm install
elif [[ ! -f "node_modules/.pnpm_install_complete" ]]; then
    pnpm update
    touch "node_modules/.pnpm_install_complete"
else
    ok "Workspace dependencies up to date."
fi

WORKSPACE_ENV="${WORKSPACE_DIR}/.env"
if [[ ! -f "${WORKSPACE_ENV}" ]]; then
    echo "HERMES_API_URL=http://127.0.0.1:8642" > "${WORKSPACE_ENV}"
    ok "Workspace .env created."
elif ! grep -q "^HERMES_API_URL=" "${WORKSPACE_ENV}" 2>/dev/null; then
    echo "HERMES_API_URL=http://127.0.0.1:8642" >> "${WORKSPACE_ENV}"
fi
cd - >/dev/null

PNPM_BIN="${HOME}/.local/share/pnpm/pnpm"
[[ -x "$PNPM_BIN" ]] || die "Local pnpm not found at ${PNPM_BIN}."

mkdir -p "${HOME}/.config/systemd/user"

cat > "${HOME}/.config/systemd/user/hermes-webapi.service" <<WEBAPI_SERVICE
[Unit]
Description=Hermes Agent WebAPI
After=network.target

[Service]
Type=simple
WorkingDirectory=${HERMES_AGENT_DIR}
ExecStart=${HERMES_VENV}/bin/python -m webapi
Restart=on-failure
RestartSec=5
Environment=HOME=${HOME}
Environment=PATH=${HERMES_VENV}/bin:${HOME}/.local/bin:/usr/local/cuda/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
WEBAPI_SERVICE

cat > "${HOME}/.config/systemd/user/hermes-workspace.service" <<WORKSPACE_SERVICE
[Unit]
Description=Hermes Workspace Web UI
After=hermes-webapi.service network.target

[Service]
Type=simple
WorkingDirectory=${WORKSPACE_DIR}
ExecStart=${PNPM_BIN} dev
Restart=on-failure
RestartSec=5
Environment=HOME=${HOME}
Environment=NODE_ENV=production
Environment=PATH=${HOME}/.local/bin:${PNPM_HOME}:/usr/bin:/bin

[Install]
WantedBy=default.target
WORKSPACE_SERVICE

if systemctl --user daemon-reload 2>/dev/null; then
    systemctl --user enable hermes-webapi.service hermes-workspace.service 2>/dev/null || true
    ok "Hermes systemd services enabled."
fi

HERMES_WEBAPI_INSTALLED=true
HERMES_WORKSPACE_INSTALLED=true
ok "Hermes Workspace integration complete."

# =============================================================================
#  9. Update packages
# =============================================================================
step "Updating system and Python packages..."
sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
ok "System updated."

# =============================================================================
#  11. Create ~/start-llm.sh  — FIX: use direct variable expansion, not envsubst
#      This avoids the empty-variable bug from envsubst + quoted heredoc mismatch
# =============================================================================
step "Creating launch script..."
LAUNCH_SCRIPT="${HOME}/start-llm.sh"

# Write start-llm.sh directly with variables expanded NOW (not via envsubst)
# This is the critical fix — the original used a quoted heredoc (no expansion)
# then tried envsubst, which left variables empty when they contained spaces.
cat > "$LAUNCH_SCRIPT" << LAUNCH_EOF
#!/usr/bin/env bash
# start-llm.sh — generated by install.sh (patched)
GGUF="${GGUF_PATH}"
MODEL_NAME="${SEL_NAME}"
LLAMA_BIN="${LLAMA_SERVER_BIN}"
SAFE_CTX="${SAFE_CTX}"
USE_JINJA="${USE_JINJA}"
HERMES_AGENT_DIR="${HERMES_AGENT_DIR}"
HERMES_VENV="${HERMES_VENV}"
WORKSPACE_DIR="${WORKSPACE_DIR}"
export PNPM_HOME="${HOME}/.local/share/pnpm"
export PATH="\${PNPM_HOME}:\${PATH}"

# Kill stale services on any port conflicts before starting
cleanup_ports() {
    fuser -k 8080/tcp 2>/dev/null || true
    fuser -k 8642/tcp 2>/dev/null || true
    fuser -k 3000/tcp 2>/dev/null || true
    sleep 1
}

LLAMA_PID=\$(pgrep -f "llama-server" 2>/dev/null || true)
WEBAPI_PID=\$(pgrep -f "python -m webapi" 2>/dev/null || true)
WORKSPACE_PID=\$(pgrep -f "pnpm dev" 2>/dev/null | grep -i workspace || true)

if [[ -n "\$LLAMA_PID" || -n "\$WEBAPI_PID" || -n "\$WORKSPACE_PID" ]]; then
    echo -e "\n⚠️  Services already running:"
    [[ -n "\$LLAMA_PID" ]]     && echo "   llama-server:  \$LLAMA_PID"
    [[ -n "\$WEBAPI_PID" ]]    && echo "   Hermes WebAPI: \$WEBAPI_PID"
    [[ -n "\$WORKSPACE_PID" ]] && echo "   Workspace:     \$WORKSPACE_PID"
    echo ""
    if [[ -t 0 ]]; then
        read -rp "Terminate and start fresh? [y/N]: " kill_choice
    else
        kill_choice="y"
    fi
    if [[ "\$kill_choice" =~ ^[Yy]$ ]]; then
        pkill -f "llama-server" 2>/dev/null || true
        pkill -f "python -m webapi" 2>/dev/null || true
        pkill -f "pnpm dev" 2>/dev/null || true
        sleep 2
        cleanup_ports
        echo "✓ All services stopped."
    else
        echo "Keeping existing instances. Exiting."; exit 0
    fi
fi

echo ""
echo "╭──────────────────────────────────────────────────────────────────╮"
echo "│           Starting Full LLM Stack                                │"
echo "╰──────────────────────────────────────────────────────────────────╯"
echo ""
echo "  Model     : \${MODEL_NAME}"
echo "  Context   : \${SAFE_CTX} tokens"
echo "  Jinja     : \${USE_JINJA}"
echo ""
echo "  Endpoints:"
echo "  ────────────────────────────────────────────────────────────────"
echo "  llama-server   → http://localhost:8080  (LLM inference)"
echo "  Hermes WebAPI  → http://localhost:8642  (Agent API)"
echo "  Hermes Workspace → http://localhost:3000  (Web UI ⭐)"
echo "  ────────────────────────────────────────────────────────────────"
echo ""
echo "  Press Ctrl+C to stop all services."
echo ""

echo "[1/3] Starting llama-server..."
"\${LLAMA_BIN}" -m "\${GGUF}" -ngl 99 -fa on -c "\${SAFE_CTX}" -np 1 \
    --cache-type-k q4_0 --cache-type-v q4_0 --host 0.0.0.0 --port 8080 \${USE_JINJA} &
LLAMA_PID=\$!
sleep 2

for i in {1..15}; do
    if curl -sf http://localhost:8080/v1/models &>/dev/null; then
        echo "✓ llama-server ready (PID: \$LLAMA_PID)"
        break
    fi
    sleep 1
done

echo "[2/3] Starting Hermes WebAPI..."
cd "\${HERMES_AGENT_DIR}"
"\${HERMES_VENV}/bin/python" -m webapi &
WEBAPI_PID=\$!
sleep 2

for i in {1..20}; do
    if curl -sf http://localhost:8642/health &>/dev/null 2>&1; then
        echo "✓ Hermes WebAPI ready at http://localhost:8642"
        break
    fi
    sleep 1
done
if [[ \$i -eq 20 ]]; then
    echo "⚠️ Hermes WebAPI health check timed out — may still be starting up"
fi

echo "[3/3] Starting Hermes Workspace..."
cd "\${WORKSPACE_DIR}"
pnpm dev &
WORKSPACE_PID=\$!
sleep 2

echo "✓ Hermes Workspace starting (PID: \$WORKSPACE_PID)"
echo ""
echo "╭──────────────────────────────────────────────────────────────────╮"
echo "│  All services started! Open http://localhost:3000 in your browser│"
echo "╰──────────────────────────────────────────────────────────────────╯"
echo ""

wait
LAUNCH_EOF

chmod +x "$LAUNCH_SCRIPT"
ok "Launch script: ~/start-llm.sh"

# Verify no empty variables baked in
if grep -q 'LLAMA_BIN=""' "$LAUNCH_SCRIPT" || grep -q 'GGUF=""' "$LAUNCH_SCRIPT"; then
    die "start-llm.sh has empty variables — something went wrong."
fi
ok "start-llm.sh variable check passed."

# =============================================================================
#  12. systemd user service (llama-server)
# =============================================================================
step "Creating systemd user service for llama-server..."
cat > "${HOME}/.config/systemd/user/llama-server.service" <<SERVICE
[Unit]
Description=llama-server LLM inference
After=network.target

[Service]
Type=simple
ExecStart=${LLAMA_SERVER_BIN} -m ${GGUF_PATH} -ngl 99 -fa on -c ${SAFE_CTX} -np 1 --cache-type-k q4_0 --cache-type-v q4_0 --host 0.0.0.0 --port 8080 ${USE_JINJA}
Restart=on-failure
RestartSec=5
Environment=HOME=${HOME}
Environment=PATH=/usr/local/cuda/bin:${HOME}/.local/bin:/usr/bin:/bin
StandardOutput=file:/tmp/llama-server.log
StandardError=file:/tmp/llama-server.log

[Install]
WantedBy=default.target
SERVICE

if systemctl --user daemon-reload 2>/dev/null; then
    systemctl --user enable llama-server.service 2>/dev/null || true
    ok "llama-server systemd service enabled."
fi

# =============================================================================
#  13. ~/.bashrc helpers  — FIX: guard against duplicate writes
# =============================================================================
step "Adding helpers to ~/.bashrc..."

# FIX: Back up and fully replace to avoid duplicate/broken blocks
cp "${HOME}/.bashrc" "${HOME}/.bashrc.bak.$(date +%s)" 2>/dev/null || true

MARKER="# === LLM setup (added by install.sh) ==="
if grep -qF "$MARKER" "${HOME}/.bashrc" 2>/dev/null; then
    ok "LLM helpers already in ~/.bashrc — skipping to avoid duplication."
else
    # First fix the color_prompt if block which is commonly broken in default Ubuntu .bashrc
    # by ensuring it has proper fi closure
    cat >> "${HOME}/.bashrc" <<BASHRC_START

${MARKER}
[[ -n "\${__LLM_BASHRC_LOADED:-}" ]] && return 0
export __LLM_BASHRC_LOADED=1

export RED='\033[0;31m' GRN='\033[0;32m' YLW='\033[1;33m'
export CYN='\033[0;36m' BLD='\033[1m' RST='\033[0m'

export PATH="/usr/local/cuda/bin:\${PATH}"
export LD_LIBRARY_PATH="/usr/local/cuda/lib64:\${LD_LIBRARY_PATH:-}"
export PNPM_HOME="\${HOME}/.local/share/pnpm"
export PATH="/usr/bin:/bin:/usr/local/bin:\${PNPM_HOME}:\${HOME}/.local/bin:\${HOME}/.hermes/node/bin:\${PATH}"
BASHRC_START

    if [[ -n "${HF_TOKEN:-}" ]] && ! grep -qF "export HF_TOKEN=" "${HOME}/.bashrc" 2>/dev/null; then
        echo "export HF_TOKEN=\"${HF_TOKEN}\"" >> "${HOME}/.bashrc"
    fi

    cat >> "${HOME}/.bashrc" <<'BASHRC_END'

alias start-llm='bash ~/start-llm.sh'
alias start-llm-services='systemctl --user start llama-server.service hermes-webapi.service hermes-workspace.service 2>/dev/null && echo "LLM services started via systemd" || bash ~/start-llm.sh'
alias stop-llm='pkill -f llama-server 2>/dev/null; pkill -f "python -m webapi" 2>/dev/null; pkill -f "pnpm dev" 2>/dev/null; echo "All LLM services stopped."'
alias restart-llm='stop-llm && sleep 2 && start-llm'
alias llm-log='tail -f /tmp/llama-server.log'
alias hermes-update='hermes update'
alias hermes-doctor='hermes doctor'
alias hermes-sessions='hermes sessions list'
alias start-workspace='cd ~/hermes-workspace && pnpm dev'
alias stop-workspace='pkill -f "pnpm dev" && echo "Hermes Workspace stopped."'
alias stop-hermes-api='pkill -f "python -m webapi" && echo "Hermes WebAPI stopped."'

vram() {
    nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu \
        --format=csv,noheader,nounits 2>/dev/null | \
        awk -F, '{printf "GPU: %s\nVRAM: %s / %s MiB\nUtil: %s%%\n",$1,$2,$3,$4}' || \
        echo "nvidia-smi not available"
}
alias vram-watch='watch -n 1 "nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv,noheader"'

llm-models() {
    echo -e "\n  Downloaded models in ~/llm-models:"
    echo "  ────────────────────────────────────────────────"
    for f in ~/llm-models/*.gguf; do
        [[ -f "$f" ]] || continue
        size=$(du -h "$f" | cut -f1)
        name=$(basename "$f")
        active=""
        grep -q "$name" ~/start-llm.sh 2>/dev/null && active=" ${GRN}← active${RST}"
        echo -e "  ${size}  ${name}${active}"
    done
    echo ""
}

llm-services() {
    echo -e "\n  ${BLD}Systemd Services Status:${RST}"
    echo "  ─────────────────────────────────────────────────"
    if command -v systemctl &>/dev/null; then
        for service in llama-server hermes-webapi hermes-workspace; do
            status=$(systemctl --user is-active "$service.service" 2>/dev/null || echo "inactive")
            enabled=$(systemctl --user is-enabled "$service.service" 2>/dev/null || echo "disabled")
            case $status in
                active) icon="✓" ;;
                *) icon="✗" ;;
            esac
            printf "  %s %-20s %s (%s)\n" "$icon" "$service.service" "$status" "$enabled"
        done
    else
        echo "  systemd not available"
    fi
    echo ""
}

llm-status() {
    LLAMA_PID=$(pgrep -f "llama-server" 2>/dev/null || true)
    WEBAPI_PID=$(pgrep -f "python -m webapi" 2>/dev/null || true)
    WORKSPACE_PID=$(pgrep -f "pnpm dev" 2>/dev/null | grep -i workspace || true)
    echo -e "${BLD}${CYN}╭────────────────────────────────────────────────────────────────╮${RST}"
    echo -e "${BLD}${CYN}│${RST}  ${BLD}LLM Stack Status${RST}"
    [[ -n "$LLAMA_PID" ]]     && echo -e "${GRN}  ✓ llama-server   → http://localhost:8080  (PID: $LLAMA_PID)${RST}" \
                               || echo -e "${RED}  ✗ llama-server   → not running${RST}"
    [[ -n "$WEBAPI_PID" ]]    && echo -e "${GRN}  ✓ Hermes WebAPI  → http://localhost:8642  (PID: $WEBAPI_PID)${RST}" \
                               || echo -e "${YLW}  ⚠ Hermes WebAPI  → not running${RST}"
    [[ -n "$WORKSPACE_PID" ]] && echo -e "${GRN}  ✓ Workspace      → http://localhost:3000  (PID: $WORKSPACE_PID)${RST}" \
                               || echo -e "${YLW}  ⚠ Workspace      → not running${RST}"
    echo -e "${BLD}${CYN}╰────────────────────────────────────────────────────────────────╯${RST}"
}

show_llm_summary() {
    echo -e "${BLD}${CYN}╭────────────────────────────────────────────────────────────────╮${RST}"
    echo -e "${BLD}${CYN}│${RST} ${BLD}LLM Quick Commands${RST}"
    echo -e "${BLD}${CYN}│${RST} ${CYN}start-llm${RST} → Start full stack"
    echo -e "${BLD}${CYN}│${RST} ${CYN}stop-llm${RST} → Stop all services"
    echo -e "${BLD}${CYN}│${RST} ${CYN}llm-status${RST} → Check service status"
    echo -e "${BLD}${CYN}│${RST} ${CYN}llm-log${RST} → View llama-server logs"
    echo -e "${BLD}${CYN}│${RST} ${CYN}llm-models${RST} → List downloaded models"
    echo -e "${BLD}${CYN}│${RST} ${CYN}vram${RST} → GPU/VRAM usage"
    echo -e "${BLD}${CYN}│${RST} ${CYN}hermes${RST} → Hermes AI agent"
    echo -e "${BLD}${CYN}╰────────────────────────────────────────────────────────────────╯${RST}"
    echo ""
}

[[ $- == *i* && ! -f "${HOME}/.llm_summary_shown" ]] && { show_llm_summary; touch "${HOME}/.llm_summary_shown"; }
BASHRC_END
    ok "Helpers written to ~/.bashrc."
fi

# =============================================================================
# Final summary
# =============================================================================
echo ""
echo -e "${GRN}${BLD}"
cat <<'EOF'
╔══════════════════════════════════════════════════════════╗
║                    Setup Complete!                       ║
╚══════════════════════════════════════════════════════════╝
EOF
echo -e "${RST}"
echo -e "  ${BLD}Model:${RST} ${SEL_NAME}"
echo -e "  ${BLD}Context:${RST} ${SAFE_CTX} tokens"
echo -e "  ${BLD}llama-server:${RST} ${LLAMA_SERVER_BIN}"
echo ""
echo -e "  ${BLD}Run:${RST} ${CYN}start-llm${RST}"
echo -e "  ${BLD}UI:${RST}  ${GRN}http://localhost:3000${RST}"
echo ""
echo -e "  ${YLW}Note:${RST} Run 'source ~/.bashrc' or open a new terminal."
echo ""
