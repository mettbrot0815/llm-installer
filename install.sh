#!/usr/bin/env bash
# =============================================================================
#  install.sh  –  Ubuntu WSL2  ·  llama.cpp + Hermes WebAPI (no workspace)
#
#  Based on llm-installer/install.sh – workspace removed, all known bugs fixed.
#  Added: custom HuggingFace model option (choice 0)
# =============================================================================
set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
export RED='\033[0;31m' GRN='\033[0;32m' YLW='\033[1;33m'
export CYN='\033[0;36m' BLD='\033[1m' RST='\033[0m'
step() { echo -e "\n${CYN}[*] $*${RST}"; }
ok()   { echo -e "${GRN}[+] $*${RST}"; }
info() { ok "$*"; }
warn() { echo -e "${YLW}[!] $*${RST}"; }
die()  { echo -e "${RED}[ERROR] $*${RST}"; exit 1; }

# ── Temp file cleanup ──────────────────────────────────────────────────────────
TMPFILES=()
cleanup() {
    local f
    for f in "${TMPFILES[@]+"${TMPFILES[@]}"}"; do
        [[ -n "$f" && -f "$f" ]] && rm -f "$f"
    done
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
    echo -e "  ${CYN}(Click 'New token' → give it a name → copy the token)${RST}"
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
VRAM_MiB=0
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
#  4. CUDA toolkit (GPU only)
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
#  5. Model selection (predefined + custom)
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
        else                           echo "F"; fi
    elif [[ $min_vram -gt 0 ]]; then
        if   [[ $ram_h -ge 8 ]]; then echo "B"
        elif [[ $ram_h -ge 0 ]]; then echo "C"
        else                          echo "F"; fi
    else
        if   [[ $ram_h -ge 8 ]]; then echo "S"
        elif [[ $ram_h -ge 4 ]]; then echo "A"
        elif [[ $ram_h -ge 0 ]]; then echo "B"
        else                          echo "F"; fi
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
echo -e "  ${BLD}0) Enter custom HuggingFace model URL${RST}"
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
        read -rp "$(echo -e "  ${BLD}Enter model number or 0 for custom:${RST} ")" CHOICE
    else
        warn "Non-interactive – defaulting to model 5 (Qwen 3.5 9B)"
        CHOICE=5
        break
    fi
    if [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 0 && CHOICE <= NUM_MODELS )); then
        break
    fi
    warn "Please enter a number between 0 and ${NUM_MODELS}."
done

# ── Handle custom model ─────────────────────────────────────────────────────────
if [[ "$CHOICE" == "0" ]]; then
    echo ""
    step "Custom HuggingFace model"
    echo -e "  ${BLD}You can provide a HuggingFace repository and GGUF filename.${RST}"
    echo -e "  Examples:"
    echo -e "    • Repo: ${CYN}unsloth/Qwen3.5-9B-GGUF${RST}  File: ${CYN}Qwen3.5-9B-Q4_K_M.gguf${RST}"
    echo -e "    • Full URL: ${CYN}https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/blob/main/Qwen3.5-9B-Q4_K_M.gguf${RST}"
    echo ""
    read -rp "  HuggingFace repo or full URL: " CUSTOM_INPUT
    CUSTOM_INPUT="${CUSTOM_INPUT// /}"

    # Parse full URL if given
    if [[ "$CUSTOM_INPUT" =~ ^https?://huggingface\.co/([^/]+/[^/]+)/blob/(main|refs/heads/main)/(.+)\.gguf$ ]]; then
        SEL_HF_REPO="${BASH_REMATCH[1]}"
        SEL_GGUF="${BASH_REMATCH[3]}.gguf"
    elif [[ "$CUSTOM_INPUT" =~ ^([^/]+/[^/]+)$ ]]; then
        SEL_HF_REPO="$CUSTOM_INPUT"
        read -rp "  GGUF filename (e.g., model-Q4_K_M.gguf): " SEL_GGUF
        SEL_GGUF="${SEL_GGUF// /}"
    else
        die "Invalid input. Please provide repo (user/model) or full HuggingFace URL."
    fi

    [[ -z "$SEL_GGUF" ]] && die "GGUF filename is required."
    SEL_NAME="${SEL_GGUF%.gguf}"
    SEL_NAME="${SEL_NAME##*/}"
    ok "Custom model: ${SEL_NAME} (${SEL_HF_REPO}/${SEL_GGUF})"

    # For custom models, set safe defaults (no hardware restrictions)
    SEL_MIN_RAM=0
    SEL_MIN_VRAM=0
    # Grade will be computed with these zeros → always at least 'B' unless hardware extremely weak
    GRADE_SEL=$(grade_model "$SEL_MIN_RAM" "$SEL_MIN_VRAM" "$RAM_GiB" "$VRAM_GiB" "$HAS_NVIDIA")
    echo -e "  ${BLD}Hardware grade:${RST} $(grade_label "$GRADE_SEL")"
    if [[ "$GRADE_SEL" == "F" ]]; then
        warn "Grade F — this model may be too heavy for your system."
        if [[ -t 0 ]]; then
            read -rp "  Continue anyway? [y/N]: " go_anyway
            [[ "$go_anyway" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
        else
            warn "Non-interactive – continuing anyway (use with caution)."
        fi
    elif [[ "$GRADE_SEL" == "C" ]]; then
        warn "Grade C — tight fit, expect slow responses."
    fi

    # Context window detection based on filename patterns (same as built‑in)
    case "$SEL_GGUF" in
        *Qwen3.5*)
            SAFE_CTX=262144
            USE_JINJA="--jinja"
            ok "Qwen3.5 detected: enabling full 256K context window"
            ;;
        *Llama-3.1*|*Llama-3.3*|*Qwen3-30B*)
            SAFE_CTX=131072
            USE_JINJA="--jinja"
            ;;
        *google_gemma-3*)
            SAFE_CTX=131072
            USE_JINJA="--no-jinja"
            ok "Gemma 3 detected: disabling Jinja template (strict role enforcement)"
            ;;
        *)
            SAFE_CTX=32768
            USE_JINJA="--jinja"
            warn "Unknown model type – using default 32K context and --jinja"
            ;;
    esac
    ok "Context window: ${SAFE_CTX} tokens"
else
    # ── Predefined model selection (unchanged) ─────────────────────────────────────
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

    if ! [[ "$SEL_MIN_RAM" =~ ^[0-9]+$ ]]; then
        die "Model parse failed: SEL_MIN_RAM='$SEL_MIN_RAM' is not numeric."
    fi
    if ! [[ "$SEL_MIN_VRAM" =~ ^[0-9]+$ ]]; then
        die "Model parse failed: SEL_MIN_VRAM='$SEL_MIN_VRAM' is not numeric."
    fi

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

    # Context window and Jinja template settings – UNCHANGED
    case "$SEL_GGUF" in
        *Qwen3.5*)
            SAFE_CTX=262144
            USE_JINJA="--jinja"
            ok "Qwen3.5 detected: enabling full 256K context window"
            ;;
        *Llama-3.1*|*Llama-3.3*|*Qwen3-30B*)
            SAFE_CTX=131072
            USE_JINJA="--jinja"
            ;;
        *google_gemma-3*)
            SAFE_CTX=131072
            USE_JINJA="--no-jinja"
            ok "Gemma 3 detected: disabling Jinja template (strict role enforcement)"
            ;;
        *)
            SAFE_CTX=32768
            USE_JINJA="--jinja"
            ;;
    esac
    ok "Context window: ${SAFE_CTX} tokens"
fi

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

step "Updating HuggingFace CLI to latest version..."
pip3 install --quiet --user --break-system-packages --upgrade huggingface_hub 2>&1 | tail -3

if [[ -x "$HF_CLI" ]]; then
    HF_CLI_USED="$HF_CLI"; HF_CLI_NAME="hf"
elif [[ -x "$HF_CLI_LEGACY" ]]; then
    HF_CLI_USED="$HF_CLI_LEGACY"; HF_CLI_NAME="huggingface-cli"
else
    die "Neither 'hf' nor 'huggingface-cli' found after install."
fi

if ! "$HF_CLI_USED" version &>/dev/null; then
    die "'$HF_CLI_NAME' found at $HF_CLI_USED but fails to run."
fi
ok "$HF_CLI_NAME ready: $( "$HF_CLI_USED" version 2>/dev/null || echo 'ok' )"

HF_CLI="$HF_CLI_USED"

if [[ -n "${HF_TOKEN:-}" ]]; then
    if "$HF_CLI" auth login --token "$HF_TOKEN" 2>/dev/null; then
        ok "HF login completed."
    elif "$HF_CLI" login --token "$HF_TOKEN" 2>/dev/null; then
        ok "HF login completed (legacy CLI)."
    else
        ok "HF token ready (may be cached)."
    fi
    if "$HF_CLI" auth whoami &>/dev/null 2>&1; then
        ok "HF login verified."
    else
        warn "HF login could not be verified — downloads will be unauthenticated."
    fi
fi

GGUF_PATH="${MODEL_DIR}/${SEL_GGUF}"

if [[ -f "$GGUF_PATH" ]]; then
    ok "Model already on disk: ${GGUF_PATH} — skipping download."
else
    step "Downloading ${SEL_NAME} from HuggingFace..."
    warn "This may take several minutes depending on model size and connection."

    AVAIL_KB=$(df -k "${MODEL_DIR}" | awk 'NR==2 {print $4}')
    AVAIL_GB=$((AVAIL_KB / 1024 / 1024))

    # Estimate required space (custom models: we don't know size, assume at least 3GB)
    REQ_GB=3
    if (( AVAIL_GB < REQ_GB )); then
        die "Insufficient disk space: need at least ${REQ_GB}GB, have ${AVAIL_GB}GB."
    fi
    ok "Disk space OK: ${AVAIL_GB}GB available."

    echo "  → Starting download from HuggingFace..."
    if [[ -n "${HF_TOKEN:-}" ]]; then
        HF_TOKEN="${HF_TOKEN}" "$HF_CLI" download "${SEL_HF_REPO}" "${SEL_GGUF}" --local-dir "${MODEL_DIR}"
    else
        "$HF_CLI" download "${SEL_HF_REPO}" "${SEL_GGUF}" --local-dir "${MODEL_DIR}"
    fi
    [[ -f "$GGUF_PATH" ]] || die "Download completed but file not found."

    FILE_SIZE=$(stat -c%s "$GGUF_PATH" 2>/dev/null || echo 0)
    if (( FILE_SIZE < 104857600 )); then
        die "Downloaded file suspiciously small (${FILE_SIZE} bytes)."
    fi
    if command -v numfmt &>/dev/null; then
        ok "Model downloaded: ${GGUF_PATH} ($(numfmt --to=iec-i --suffix=B "${FILE_SIZE}"))"
    else
        ok "Model downloaded: ${GGUF_PATH} (size: ${FILE_SIZE} bytes)"
    fi
fi

# =============================================================================
#  7. Build llama.cpp (unchanged)
# =============================================================================
step "Checking llama.cpp..."

find_llama_server() {
    local p version_output
    for p in /usr/local/bin/llama-server /usr/bin/llama-server \
              "${HOME}/.local/bin/llama-server" \
              "${HOME}/llama.cpp/build/bin/llama-server"; do
        if [[ -x "$p" ]]; then
            version_output=$("$p" --version 2>&1) || continue
            if echo "$version_output" | grep -qiE 'llama|ggml|llama\.cpp'; then
                echo "$p"
                return 0
            fi
        fi
    done
    local found
    found=$(find "${HOME}/llama.cpp" -name "llama-server" -type f -executable 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then
        version_output=$("$found" --version 2>&1) || true
        if echo "$version_output" | grep -qiE 'llama|ggml'; then
            echo "$found"
            return 0
        fi
    fi
    return 1
}

LLAMA_SERVER_BIN=$(find_llama_server || true)

if [[ -n "$LLAMA_SERVER_BIN" ]]; then
    ok "llama-server: ${LLAMA_SERVER_BIN} — skipping build."
    ok "To force rebuild: rm ${LLAMA_SERVER_BIN} and rerun."
else
    step "Building llama.cpp from source (5–15 min first time, ~1 min with ccache)..."

    if command -v ccache &>/dev/null; then
        ok "ccache found: $(ccache --version | head -1)"
        export CC="ccache gcc" CXX="ccache g++"
    else
        warn "ccache not found — building without cache (slower recompilation)"
        export CC="gcc" CXX="g++"
    fi

    LLAMA_DIR="${HOME}/llama.cpp"

    if [[ -d "$LLAMA_DIR/.git" ]]; then
        step "Updating llama.cpp repo..."
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

    if command -v ccache &>/dev/null; then
        ok "ccache stats:"
        ccache -s 2>/dev/null | grep -E "cache (hit|miss)|cache size|max size" || true
    fi

    LLAMA_SERVER_BIN=$(find_llama_server || true)
    [[ -n "$LLAMA_SERVER_BIN" ]] || die "llama-server not found after build."
    ok "llama-server: ${LLAMA_SERVER_BIN}"
fi

# =============================================================================
#  8. Hermes Agent (WebAPI only – unchanged)
# =============================================================================
step "Setting up Hermes Agent..."
HERMES_AGENT_DIR="${HOME}/hermes-agent"
HERMES_VENV="${HERMES_AGENT_DIR}/.venv"
HERMES_BIN="${HOME}/.local/bin/hermes"
export PATH="${HOME}/.local/bin:${PATH}"

if [[ -d "${HERMES_AGENT_DIR}/.git" ]]; then
    ok "Hermes Agent (outsourc-e fork) already cloned — updating..."
    cd "${HERMES_AGENT_DIR}"
    git fetch origin 2>/dev/null && git reset --hard origin/main 2>/dev/null || \
        warn "Hermes git update failed (continuing with existing code)"
    cd - >/dev/null
else
    step "Cloning outsourc-e/hermes-agent (WebAPI fork)..."
    git clone https://github.com/outsourc-e/hermes-agent.git "${HERMES_AGENT_DIR}" 2>&1 | tail -3
    ok "Hermes Agent cloned."
fi

if [[ ! -d "${HERMES_VENV}" ]]; then
    step "Creating Python 3.11 virtual environment..."
    python3.11 -m venv "${HERMES_VENV}"
    ok "Venv created at ${HERMES_VENV}"
else
    ok "Venv already exists at ${HERMES_VENV}"
fi

if ! "${HERMES_VENV}/bin/python" -c "import fastapi" &>/dev/null; then
    step "Installing Hermes Agent dependencies (first time ~2-5 min)..."
    "${HERMES_VENV}/bin/pip" install -e "${HERMES_AGENT_DIR}[all]"
    ok "Hermes Agent dependencies installed."
    touch "${HERMES_VENV}/installed_marker"
else
    ok "Hermes Agent dependencies already installed."
fi

HERMES_VENV_BIN="${HERMES_VENV}/bin/hermes"
if [[ -x "$HERMES_VENV_BIN" ]]; then
    mkdir -p "${HOME}/.local/bin"
    ln -sf "$HERMES_VENV_BIN" "$HERMES_BIN"
    ok "Symlinked hermes → ${HERMES_BIN}"
else
    warn "hermes binary not found in venv — WebAPI will use 'python -m webapi' directly"
fi

# ── Configure Hermes → llama-server ──────────────────────────────────────────
step "Configuring Hermes for local llama-server..."

HERMES_DIR="${HOME}/.hermes"
mkdir -p "${HERMES_DIR}"/{cron,sessions,logs,memories,skills}

CONFIG_FILE="${HERMES_DIR}/config.yaml"
ENV_FILE="${HERMES_DIR}/.env"

cat > "$ENV_FILE" <<ENV
OPENAI_API_KEY=llama
OPENAI_BASE_URL=http://localhost:8080/v1
LLM_MODEL=${SEL_NAME}
HERMES_WEBAPI_HOST=0.0.0.0
HERMES_WEBAPI_PORT=8642
ENV
ok "~/.hermes/.env written."

cat > "$CONFIG_FILE" <<CONFIG
# Hermes Agent Configuration
# Generated by install.sh for ${SEL_NAME}

model:
  default: "${SEL_NAME}"
  provider: custom
  base_url: http://localhost:8080/v1
  api_key: llama
CONFIG
ok "config.yaml written."
ok "Hermes configured → llama-server (${SEL_NAME} at http://localhost:8080/v1)"

# ── Hermes WebAPI systemd service ────────────────────────────────────────────
step "Configuring Hermes WebAPI systemd service..."
mkdir -p "${HOME}/.config/systemd/user"
cat > "${HOME}/.config/systemd/user/hermes-webapi.service" <<WEBAPI_SERVICE
[Unit]
Description=Hermes Agent WebAPI
After=llama-server.service network.target
Wants=llama-server.service

[Service]
Type=simple
WorkingDirectory=${HERMES_AGENT_DIR}
ExecStart=${HERMES_VENV}/bin/python -m webapi
Restart=on-failure
RestartSec=5
Environment=HOME=${HOME}
Environment=PATH=${HERMES_VENV}/bin:${HOME}/.local/bin:/usr/local/cuda/bin:/usr/bin:/bin
EnvironmentFile=-${HERMES_DIR}/.env

[Install]
WantedBy=default.target
WEBAPI_SERVICE

if systemctl --user daemon-reload 2>/dev/null; then
    systemctl --user enable hermes-webapi.service 2>/dev/null || true
    ok "Hermes WebAPI systemd service enabled."
else
    warn "systemd --user unavailable — WebAPI must be started manually."
fi

# =============================================================================
#  9. Create ~/start-llm.sh (without workspace – unchanged)
# =============================================================================
step "Creating launch script..."
LAUNCH_SCRIPT="${HOME}/start-llm.sh"

cat > "${LAUNCH_SCRIPT}.template" <<'LAUNCH_TEMPLATE'
#!/usr/bin/env bash
# start-llm.sh – generated by install.sh
# Starts: llama-server (8080) + Hermes WebAPI (8642)

GGUF="${GGUF_PATH}"
MODEL_NAME="${SEL_NAME}"
LLAMA_BIN="${LLAMA_SERVER_BIN}"
SAFE_CTX="${SAFE_CTX}"
USE_JINJA="${USE_JINJA}"
HERMES_AGENT_DIR="${HERMES_AGENT_DIR}"
HERMES_VENV="${HERMES_VENV}"

# Check for running services
LLAMA_PID=$(pgrep -f "llama-server" 2>/dev/null || true)
WEBAPI_PID=$(pgrep -f "python -m webapi" 2>/dev/null || true)

if [[ -n "$LLAMA_PID" || -n "$WEBAPI_PID" ]]; then
    echo -e "\n  Services already running:"
    [[ -n "$LLAMA_PID" ]] && echo "   llama-server:  $LLAMA_PID"
    [[ -n "$WEBAPI_PID" ]] && echo "   Hermes WebAPI: $WEBAPI_PID"
    echo ""
    if [[ -t 0 ]]; then
        read -rp "Terminate and start fresh? [y/N]: " kill_choice
    else
        kill_choice="n"
    fi
    if [[ "$kill_choice" =~ ^[Yy]$ ]]; then
        pkill -f "llama-server" 2>/dev/null || true
        pkill -f "python -m webapi" 2>/dev/null || true
        sleep 2
        echo "All services stopped."
    else
        echo "Keeping existing instances. Exiting."; exit 0
    fi
fi

echo ""
echo "Starting LLM Stack"
echo "  Model     : ${MODEL_NAME}"
echo "  Context   : ${SAFE_CTX} tokens"
echo "  Jinja     : ${USE_JINJA}"
echo ""
echo "  Endpoints:"
echo "  llama-server   → http://localhost:8080"
echo "  Hermes WebAPI  → http://localhost:8642"
echo ""
echo "  Press Ctrl+C to stop all services."
echo ""

# 1/2 llama-server
echo "[1/2] Starting llama-server..."
"${LLAMA_BIN}" -m "${GGUF}" -ngl 99 -fa on -c "${SAFE_CTX}" -np 1 \
    --cache-type-k q4_0 --cache-type-v q4_0 --host 0.0.0.0 --port 8080 ${USE_JINJA} &
LLAMA_PID=$!
for idx in {1..15}; do
    if curl -sf http://localhost:8080/v1/models &>/dev/null; then
        echo "  llama-server ready (PID: $LLAMA_PID)"
        break
    fi
    sleep 1
done

# 2/2 Hermes WebAPI
echo "[2/2] Starting Hermes WebAPI..."
cd "${HERMES_AGENT_DIR}"
"${HERMES_VENV}/bin/python" -m webapi &
WEBAPI_PID=$!
sleep 2
for idx in {1..20}; do
    if curl -sf http://localhost:8642/health &>/dev/null 2>&1; then
        echo "  Hermes WebAPI ready at http://localhost:8642"
        break
    elif curl -sf http://localhost:8642/docs &>/dev/null 2>&1; then
        echo "  Hermes WebAPI ready at http://localhost:8642 (via /docs)"
        break
    fi
    sleep 1
done

echo ""
echo "All services started! Hermes WebAPI available at http://localhost:8642"
echo "OpenAI-compatible endpoint: http://localhost:8080/v1"
echo ""

wait
LAUNCH_TEMPLATE

export GGUF_PATH SEL_NAME LLAMA_SERVER_BIN SAFE_CTX USE_JINJA HERMES_AGENT_DIR HERMES_VENV

envsubst '${GGUF_PATH} ${SEL_NAME} ${LLAMA_SERVER_BIN} ${SAFE_CTX} ${USE_JINJA} ${HERMES_AGENT_DIR} ${HERMES_VENV}' \
    < "${LAUNCH_SCRIPT}.template" > "$LAUNCH_SCRIPT"

rm -f "${LAUNCH_SCRIPT}.template"
chmod +x "$LAUNCH_SCRIPT"
ok "Launch script: ~/start-llm.sh"

# =============================================================================
#  10. systemd user service for llama-server (unchanged)
# =============================================================================
step "Creating systemd user service for llama-server..."
mkdir -p "${HOME}/.config/systemd/user"
cat > "${HOME}/.config/systemd/user/llama-server.service" <<SERVICE
[Unit]
Description=llama-server LLM inference
After=network.target

[Service]
Type=simple
ExecStart="${LLAMA_SERVER_BIN}" -m "${GGUF_PATH}" -ngl 99 -fa on -c ${SAFE_CTX} -np 1 --cache-type-k q4_0 --cache-type-v q4_0 --host 0.0.0.0 --port 8080 ${USE_JINJA}
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
    echo "  To start automatically on login: sudo loginctl enable-linger $USER"
else
    warn "systemd --user unavailable — use start-llm.sh to start services."
fi

# Start services now
step "Starting all services..."
nohup bash "$LAUNCH_SCRIPT" < /dev/null > /tmp/llama-server.log 2>&1 &
ok "Services starting (log: tail -f /tmp/llama-server.log)"

READY=false
for i in {1..30}; do
    if curl -sf http://localhost:8080/v1/models &>/dev/null; then
        ok "llama-server ready at http://localhost:8080"
        READY=true
        break
    fi
    sleep 1
done
[[ "$READY" == "false" ]] && warn "llama-server not responding in 30s — check: tail -f /tmp/llama-server.log"

# =============================================================================
#  11. ~/.bashrc helpers (unchanged, no workspace)
# =============================================================================
step "Adding helpers to ~/.bashrc..."

create_agents_md() {
    local target="${1:-.}/AGENTS.md"
    [[ -f "$target" ]] && { echo "AGENTS.md exists at $target"; return; }
    cat > "$target" <<'AGENTS_CONTENT'
# AGENTS.md
## Project Overview
<!-- Describe project in 2-3 sentences -->

## Architecture
<!-- Key files, modules, and their roles -->

## Coding Conventions
- Language: <!-- e.g. Python 3.11 -->
- Style: <!-- e.g. 2-space indent, no trailing whitespace -->

## Key Commands
```bash
# Run:   python3 -m http.server 8000
# Test:  pytest
Constraints
<!-- What NOT to do — e.g. never commit secrets, no global state -->
Known Issues
<!-- Document bugs and workarounds here -->
AGENTS_CONTENT
echo "Created AGENTS.md at $target"
}

MARKER="# === LLM setup (added by install.sh) ==="
if grep -qF "$MARKER" "${HOME}/.bashrc" 2>/dev/null; then
ok "Helpers already in ~/.bashrc — skipping."
else
cat >> "${HOME}/.bashrc" <<'BASHRC_START'

=== LLM setup (added by install.sh) ===
[[ -n "${__LLM_BASHRC_LOADED:-}" ]] && return 0
export __LLM_BASHRC_LOADED=1

export RED='\033[0;31m' GRN='\033[0;32m' YLW='\033[1;33m'
export CYN='\033[0;36m' BLD='\033[1m' RST='\033[0m'

export PATH="/usr/local/cuda/bin:${PATH}"
export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"
export PATH="/usr/bin:/bin:/usr/local/bin:${HOME}/.local/bin:${PATH}"
BASHRC_START

if [[ -n "${HF_TOKEN:-}" ]] && ! grep -qF "export HF_TOKEN=" "${HOME}/.bashrc" 2>/dev/null; then
echo "export HF_TOKEN="${HF_TOKEN}"" >> "${HOME}/.bashrc"
ok "HF_TOKEN added to ~/.bashrc."
fi

SCRIPT_SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "$0")"
cat >> "${HOME}/.bashrc" <<BASHRC_ALIASES

LLM aliases
alias start-llm='bash ~/start-llm.sh'
alias start-llm-services='systemctl --user start llama-server.service hermes-webapi.service 2>/dev/null && echo "LLM services started via systemd" || bash ~/start-llm.sh'
alias stop-llm='pkill -f llama-server 2>/dev/null; pkill -f "python -m webapi" 2>/dev/null; echo "All LLM services stopped."'
alias restart-llm='stop-llm && sleep 2 && start-llm'
alias llm-log='tail -f /tmp/llama-server.log'
alias switch-model='bash ${SCRIPT_SELF}'
alias hermes-update='${HERMES_VENV}/bin/pip install --upgrade -e ${HERMES_AGENT_DIR}'
alias hermes-doctor='${HERMES_VENV}/bin/hermes doctor 2>/dev/null || echo "hermes doctor not available"'

Hermes WebAPI only
alias start-hermes-api='cd ~/hermes-agent && .venv/bin/python -m webapi'
alias stop-hermes-api='pkill -f "python -m webapi" 2>/dev/null; echo "Hermes WebAPI stopped."'
BASHRC_ALIASES

cat >> "${HOME}/.bashrc" <<'BASHRC_END'

vram() {
nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu
--format=csv,noheader,nounits 2>/dev/null |
awk -F, '{printf "GPU: %s\nVRAM: %s / %s MiB\nUtil: %s%%\n",$1,$2,$3,$4}' ||
echo "nvidia-smi not available"
}
alias vram-watch='watch -n 1 "nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv,noheader"'

llm-models() {
echo -e "\n Downloaded models in ~/llm-models:"
echo " ────────────────────────────────────────────────"
for f in ~/llm-models/*.gguf; do
[[ -f "$f" ]] || continue
local size name active
size=$(du -h "$f" | cut -f1)
name=$(basename "$f")
active=""
grep -q "$name" ~/start-llm.sh 2>/dev/null && active=" ← active"
echo " ${size} ${name}${active}"
done
echo ""
}

llm-status() {
local llama_pid webapi_pid
llama_pid=$(pgrep -f "llama-server" 2>/dev/null || true)
webapi_pid=$(pgrep -f "python -m webapi" 2>/dev/null || true)

echo -e "${BLD}${CYN}╭────────────────────────────────────────────────────────────────╮${RST}"
echo -e "${BLD}${CYN}│${RST} ${BLD}LLM Stack Status${RST}"
echo -e "${BLD}${CYN}│${RST} ──────────────────────────────────────────────────────"
if [[ -n "$llama_pid" ]]; then
echo -e "${GRN} ✓ llama-server → http://localhost:8080 (PID: $llama_pid)${RST}"
else
echo -e "${RED} ✗ llama-server → not running${RST}"
fi
if [[ -n "$webapi_pid" ]]; then
echo -e "${GRN} ✓ Hermes WebAPI → http://localhost:8642 (PID: $webapi_pid)${RST}"
else
echo -e "${YLW} ⚠ Hermes WebAPI → not running${RST}"
fi
echo -e "${BLD}${CYN}│${RST} ──────────────────────────────────────────────────────"
echo -e "${BLD}${CYN}│${RST} ${CYN}start-llm${RST} to start all services"
echo -e "${BLD}${CYN}╰────────────────────────────────────────────────────────────────╯${RST}"
}

show_llm_summary() {
echo -e "${BLD}${CYN}╭────────────────────────────────────────────────────────────────╮${RST}"
echo -e "${BLD}${CYN}│${RST} ${BLD}LLM Quick Commands${RST}"
echo -e "${BLD}${CYN}│${RST} ──────────────────────────────────────────────────────"
echo -e "${BLD}${CYN}│${RST} ${CYN}start-llm${RST} Start full stack"
echo -e "${BLD}${CYN}│${RST} ${CYN}stop-llm${RST} Stop all services"
echo -e "${BLD}${CYN}│${RST} ${CYN}llm-status${RST} Check service status"
echo -e "${BLD}${CYN}│${RST} ${CYN}llm-log${RST} View llama-server logs"
echo -e "${BLD}${CYN}│${RST} ${CYN}llm-models${RST} List downloaded models"
echo -e "${BLD}${CYN}│${RST} ${CYN}vram${RST} GPU/VRAM usage"
echo -e "${BLD}${CYN}│${RST} ──────────────────────────────────────────────────────"
echo -e "${BLD}${CYN}│${RST} ${CYN}http://localhost:8080${RST} → llama-server (OpenAI endpoint)"
echo -e "${BLD}${CYN}│${RST} ${CYN}http://localhost:8642${RST} → Hermes WebAPI (docs at /docs)"
echo -e "${BLD}${CYN}╰────────────────────────────────────────────────────────────────╯${RST}"
echo ""
}

[[ $- == *i* && ! -f "${HOME}/.llm_summary_shown" ]] && { show_llm_summary; touch "${HOME}/.llm_summary_shown"; }
BASHRC_END
ok "Helpers written to ~/.bashrc."
fi

#=============================================================================
#12. .wslconfig RAM hint (unchanged)
#=============================================================================
WIN_USER=$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r\n' || echo "")
WSLCONFIG=""
WSLCONFIG_DIR=""

if [[ -n "$WIN_USER" ]]; then
for drive in c d e f; do
[[ -d "/mnt/${drive}/Users/${WIN_USER}" ]] && {
WSLCONFIG_DIR="/mnt/${drive}/Users/${WIN_USER}"
WSLCONFIG="${WSLCONFIG_DIR}/.wslconfig"
break
}
[[ -d "/mnt/${drive}/home/${WIN_USER}" ]] && {
WSLCONFIG_DIR="/mnt/${drive}/home/${WIN_USER}"
WSLCONFIG="${WSLCONFIG_DIR}/.wslconfig"
break
}
done
fi

if [[ -n "$WSLCONFIG" && ! -f "$WSLCONFIG" && -n "$WSLCONFIG_DIR" ]]; then
step "Writing .wslconfig..."
WSL_RAM=$(( RAM_GiB * 3 / 4 ))
(( WSL_RAM < 4 )) && WSL_RAM=4
(( WSL_RAM > 64 )) && WSL_RAM=64
WSL_SWAP=$(( WSL_RAM / 4 ))
(( WSL_SWAP < 2 )) && WSL_SWAP=2

cat > "$WSLCONFIG" <<WSLCFG
; Generated by install.sh
[wsl2]
memory=${WSL_RAM}GB
swap=${WSL_SWAP}GB
processors=${CPUS}
localhostForwarding=true
[experimental]
autoMemoryReclaim=dropcache
sparseVhd=true
WSLCFG
ok ".wslconfig written (${WSL_RAM}GB RAM). Run 'wsl --shutdown' to apply."
elif [[ -n "$WSLCONFIG" && -f "$WSLCONFIG" ]]; then
ok ".wslconfig already exists — skipping."
else
warn "Could not locate Windows user profile — skipping .wslconfig."
fi

#=============================================================================
#Create AGENTS.md (if not present)
#=============================================================================
create_agents_md "${HOME}" 2>/dev/null || true

#=============================================================================
#Done
#=============================================================================
echo ""
echo -e "${GRN}${BLD}"
cat <<'EOF'
╔══════════════════════════════════════════════════════════╗
║ Setup Complete! ║
╚══════════════════════════════════════════════════════════╝
EOF
echo -e "${RST}"
echo -e " ${BLD}Versions Installed:${RST}"
echo -e " Python → $(python3 --version 2>/dev/null || echo 'Not found')"
echo -e " llama.cpp → $(${LLAMA_SERVER_BIN} --version 2>&1 | head -1 || echo 'Latest')"
echo ""
echo -e " ${BLD}Services:${RST}"
echo -e " llama-server → http://localhost:8080/v1"
echo -e " llama.cpp Web UI → http://localhost:8080"
echo -e " Hermes WebAPI → http://localhost:8642"
echo -e " Model → ${SEL_NAME} (context: ${SAFE_CTX})"
echo ""
echo -e " ${BLD}Usage:${RST}"
echo -e " ${CYN}start-llm${RST} start full stack (llama-server + Hermes WebAPI)"
echo -e " ${CYN}stop-llm${RST} stop all services"
echo -e " ${CYN}restart-llm${RST} restart all services"
echo -e " ${CYN}llm-status${RST} check service status"
echo -e " ${CYN}llm-log${RST} tail llama-server logs"
echo -e " ${CYN}llm-models${RST} list downloaded models"
echo -e " ${CYN}switch-model${RST} change model (re-run installer)"
echo -e " ${CYN}vram${RST} GPU/VRAM usage"
echo ""
echo -e " ${BLD}Open in Browser:${RST}"
echo -e " ${CYN}http://localhost:8080${RST} → llama.cpp Web UI (basic)"
echo -e " ${CYN}http://localhost:8642/docs${RST} → Hermes WebAPI documentation"
echo ""
echo -e " ${YLW}Note:${RST} Run 'source ~/.bashrc' or open a new terminal."
echo -e " ${GRN}Auto-start:${RST} Enable linger for auto-start on login:"
echo -e " ${CYN}sudo loginctl enable-linger $USER${RST}"
echo ""
