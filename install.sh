#!/usr/bin/env bash
# =============================================================================
#  install.sh  –  Ubuntu WSL2  ·  llama.cpp + Hermes Agent + Qwen Code
#
#  Replicates @sudoingX setup (RTX 3060 12GB, Qwen3.5 9B Q4_K_M):
#    - llama.cpp CUDA build: Flash Attention + KV cache quantisation
#    - GGUF model from HuggingFace (optional HF token)
#    - llama-server: -ngl 99 -fa on -c <ctx> -np 1
#      --cache-type-k q4_0 --cache-type-v q4_0
#    - Hermes Agent + Qwen Code → http://localhost:8080/v1
#    - SOUL.md identity, local compression, ccache, AGENTS.md scaffold
#
#  CUDA note: GPU driver lives in Windows. NEVER install cuda-drivers or the
#  cuda meta-package inside WSL2 — they overwrite the GPU passthrough stub.
# =============================================================================
set -euo pipefail

# ── Colour helpers — exported so subshells (llm-models fn) can use them ───────
export RED='\033[0;31m' GRN='\033[0;32m' YLW='\033[1;33m'
export CYN='\033[0;36m' BLD='\033[1m' RST='\033[0m'
step() { echo -e "\n${CYN}[*] $*${RST}"; }
ok()   { echo -e "${GRN}[+] $*${RST}"; }
warn() { echo -e "${YLW}[!] $*${RST}"; }
die()  { echo -e "${RED}[ERROR] $*${RST}"; exit 1; }

# ── Temp file cleanup on exit ──────────────────────────────────────────────────
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

register_tmp() {
    TMPFILES+=("$1")
}

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

# Priority 1: Environment variable
if [[ -n "${HF_TOKEN:-}" ]]; then
    ok "HF_TOKEN already set in environment — using it."
# Priority 2: Token cache file (most reliable)
elif [[ -f "${HOME}/.cache/huggingface/token" ]]; then
    HF_TOKEN=$(cat "${HOME}/.cache/huggingface/token" 2>/dev/null)
    [[ -n "$HF_TOKEN" ]] && ok "HF_TOKEN found in ~/.cache/huggingface/token."
# Priority 3: ~/.bashrc export (fallback)
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
    pciutils wget curl ca-certificates zstd
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
    read -rp "  Continue with CPU-only build? [y/N]: " cpu_ok
    [[ "$cpu_ok" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# =============================================================================
#  4. CUDA toolkit (GPU only — build dependency, runtime from Windows)
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
#  Format: idx|hf_repo|gguf_file|display_name|size_gb|ctx|min_ram|min_vram|tier|tags|desc
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

# Use /usr/bin/clear to avoid broken wrapper in ~/.local/bin
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
    read -rp "$(echo -e "  ${BLD}Enter model number [1-${NUM_MODELS}]:${RST} ")" CHOICE
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
    read -rp "  Continue anyway? [y/N]: " go_anyway
    [[ "$go_anyway" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
elif [[ "$GRADE_SEL" == "C" ]]; then
    warn "Grade C — tight fit, expect slow responses."
fi

# Context window and Jinja template settings per model
# Qwen3.5 supports 256K context - use full capability
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

if ! "$HF_CLI_USED" version &>/dev/null; then
    die "'$HF_CLI_NAME' found at $HF_CLI_USED but fails to run."
fi

# Update HuggingFace CLI to latest version
step "Updating HuggingFace CLI to latest version..."
pip3 install --quiet --user --break-system-packages --upgrade huggingface_hub 2>&1 | tail -3

ok "$HF_CLI_NAME ready: $( "$HF_CLI_USED" version 2>/dev/null || echo 'ok' )"

HF_CLI="$HF_CLI_USED"

if [[ -n "${HF_TOKEN:-}" ]]; then
    # Try hf auth login first (newer versions), fall back to huggingface-cli login (older)
    if "$HF_CLI" auth login --token "$HF_TOKEN" 2>/dev/null; then
        ok "HF login completed."
    elif "$HF_CLI" login --token "$HF_TOKEN" 2>/dev/null; then
        ok "HF login completed (legacy CLI)."
    else
        # Token may already be cached or CLI version differs
        ok "HF token ready (may be cached)."
    fi
    
    if "$HF_CLI" auth whoami &>/dev/null 2>&1; then
        ok "HF login verified."
        STORED_TOKEN=$(cat "${HOME}/.cache/huggingface/token" 2>/dev/null || true)
        if [[ "$STORED_TOKEN" == "$HF_TOKEN" ]]; then
            ok "HF token confirmed on disk."
        else
            ok "HF CLI authenticated (token storage location may vary by version)."
        fi
    else
        warn "HF login could not be verified — downloads will be unauthenticated."
        # Don't fail the entire script for HF auth issues
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
    # Use grep -F for exact match on "CHOICE|" to avoid matching "1" with "11"
    REQ_GB=$(printf '%s\n' "${MODELS[@]}" | grep -F "${CHOICE}|" | head -1 | cut -d'|' -f5)
    # Proper ceiling: add 1 if there's a decimal part, then add 2GB buffer
    REQ_GB_INT=${REQ_GB%.*}
    if [[ "$REQ_GB" == *"."* ]]; then
        REQ_GB_INT=$((REQ_GB_INT + 1))
    fi
    REQ_GB_INT=$((REQ_GB_INT + 2))
    # Ensure minimum 3GB buffer for any model
    (( REQ_GB_INT < 3 )) && REQ_GB_INT=3

    if (( AVAIL_GB < REQ_GB_INT )); then
        die "Insufficient disk space: need ~${REQ_GB_INT}GB, have ${AVAIL_GB}GB."
    fi
    ok "Disk space OK: ${AVAIL_GB}GB available, ~${REQ_GB_INT}GB needed."

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
    ok "Model downloaded: ${GGUF_PATH} ($(numfmt --to=iec-i --suffix=B "${FILE_SIZE}"))"
fi

# =============================================================================
#  7. Build llama.cpp (skip if binary exists)
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
    return 1
}

LLAMA_SERVER_BIN=$(find_llama_server || true)

if [[ -n "$LLAMA_SERVER_BIN" ]]; then
    ok "llama-server: ${LLAMA_SERVER_BIN} — skipping build."
    ok "To force rebuild: rm ${LLAMA_SERVER_BIN} and rerun."
else
    step "Building llama.cpp from source (5–15 min first time, ~1 min with ccache)..."
    
    # Check if ccache is available and working
    if command -v ccache &>/dev/null; then
        ok "ccache found: $(ccache --version | head -1)"
        ccache -s 2>/dev/null | grep -E "cache (hit|miss)" | head -2 || true
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

    # Show ccache stats after build
    if command -v ccache &>/dev/null; then
        echo ""
        ok "ccache stats:"
        ccache -s 2>/dev/null | grep -E "cache (hit|miss)|cache size|max size" || true
        echo ""
    fi

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

# ── Clone or update the fork ──────────────────────────────────────────────────
if [[ -d "${HERMES_AGENT_DIR}/.git" ]]; then
    ok "Hermes Agent (outsourc-e fork) already cloned — updating to latest..."
    cd "${HERMES_AGENT_DIR}"
    git fetch origin 2>/dev/null && git reset --hard origin/main 2>/dev/null || warn "Hermes git update failed (continuing with existing code)"
    cd - >/dev/null
else
    step "Cloning outsourc-e/hermes-agent (WebAPI fork)..."
    git clone https://github.com/outsourc-e/hermes-agent.git "${HERMES_AGENT_DIR}" 2>&1 | tail -3
    ok "Hermes Agent cloned."
fi

# ── Create / verify venv ──────────────────────────────────────────────────────
if [[ ! -d "${HERMES_VENV}" ]]; then
    step "Creating Python virtual environment for Hermes Agent..."
    python3.11 -m venv "${HERMES_VENV}"
    ok "Venv created at ${HERMES_VENV}"
else
    ok "Venv already exists at ${HERMES_VENV}"
fi

# ── Install dependencies ──────────────────────────────────────────────────────
source "${HERMES_VENV}/bin/activate"
if ! python -c "import hermes_agent" &>/dev/null; then
    step "Installing Hermes Agent dependencies (first time ~2-5 min)..."
    pip install --quiet -e "${HERMES_AGENT_DIR}[all]" 2>&1 | tail -3
    ok "Hermes Agent dependencies installed."
else
    ok "Hermes Agent already installed in venv."
fi

# ── Symlink hermes binary to ~/.local/bin ─────────────────────────────────────
HERMES_VENV_BIN="${HERMES_VENV}/bin/hermes"
if [[ -x "$HERMES_VENV_BIN" ]]; then
    mkdir -p "${HOME}/.local/bin"
    ln -sf "$HERMES_VENV_BIN" "$HERMES_BIN"
    ok "Symlinked hermes → ${HERMES_BIN}"
else
    warn "hermes binary not found in venv at ${HERMES_VENV_BIN}"
    warn "You may need to run: source ${HERMES_VENV}/bin/activate && cd ${HERMES_AGENT_DIR} && pip install -e ."
fi

deactivate 2>/dev/null || true

# ── Update check ──────────────────────────────────────────────────────────────
if [[ -x "$HERMES_BIN" ]] && "${HERMES_BIN}" --help &>/dev/null; then
    HERMES_VER=$("${HERMES_BIN}" --version 2>/dev/null || echo "installed")
    ok "Hermes Agent ready: ${HERMES_VER}"
    HERMES_WEBAPI_INSTALLED=true

    step "Checking for Hermes updates..."
    UPDATE_OUTPUT=$("${HERMES_BIN}" update --check 2>&1 || true)
    if echo "$UPDATE_OUTPUT" | grep -qi "update available"; then
        read -rp "  Hermes update available. Install? [Y/n]: " update_yn
        if [[ ! "$update_yn" =~ ^[Nn]$ ]]; then
            if "${HERMES_BIN}" update; then
                ok "Hermes updated."
            else
                warn "Hermes update failed. Run 'hermes update' manually to retry."
            fi
        fi
    else
        ok "Hermes is up to date."
    fi
fi

# =============================================================================
#  8c. Configure Hermes → llama-server (http://localhost:8080/v1)
# =============================================================================
step "Configuring Hermes for local llama-server..."

HERMES_DIR="${HOME}/.hermes"
mkdir -p "${HERMES_DIR}"/{cron,sessions,logs,memories,skills}

CONFIG_FILE="${HERMES_DIR}/config.yaml"
ENV_FILE="${HERMES_DIR}/.env"

# Write .env with API key (secrets belong in .env, not config.yaml)
cat > "$ENV_FILE" <<ENV
OPENAI_API_KEY=llama
LLM_MODEL=${SEL_NAME}
ENV

# Patch config.yaml for local server using modern Hermes Agent format (2026+)
# New format uses model.base_url directly instead of separate custom: block
if [[ -f "$CONFIG_FILE" ]]; then
    # Update model section with provider, default, and base_url
    # First check if model section exists
    if grep -q "^model:" "$CONFIG_FILE" 2>/dev/null; then
        # Update existing model section
        sed -i 's/provider: ".*"/provider: custom/g' "$CONFIG_FILE" 2>/dev/null || true
        sed -i 's/provider: .*/provider: custom/g' "$CONFIG_FILE" 2>/dev/null || true
        sed -i "s/default: \".*\"/default: \"${SEL_NAME}\"/g" "$CONFIG_FILE" 2>/dev/null || true
        sed -i "s/default: .*/default: \"${SEL_NAME}\"/g" "$CONFIG_FILE" 2>/dev/null || true
        
        # Add or update base_url under model section
        if ! grep -q "^  base_url:" "$CONFIG_FILE" 2>/dev/null; then
            sed -i '/^model:/a\  base_url: http://localhost:8080/v1' "$CONFIG_FILE" 2>/dev/null || true
        else
            sed -i 's|^  base_url:.*|  base_url: http://localhost:8080/v1|' "$CONFIG_FILE" 2>/dev/null || true
        fi
    else
        # No model section, add complete model block
        cat >> "$CONFIG_FILE" <<MODEL

model:
  default: "${SEL_NAME}"
  provider: custom
  base_url: http://localhost:8080/v1
MODEL
    fi
    
    # Remove deprecated top-level custom: block if it exists (old format)
    if grep -q "^custom:" "$CONFIG_FILE" 2>/dev/null; then
        # Remove the old custom: block (lines from ^custom: to next top-level key)
        sed -i '/^custom:/,/^[a-z]/{/^custom:/d; /^[a-z]/!d}' "$CONFIG_FILE" 2>/dev/null || true
    fi

    ok "config.yaml configured for local server."
else
    # Create fresh config with modern format
    cat > "$CONFIG_FILE" <<CONFIG
# Hermes Agent Configuration
# Generated by install.sh for ${SEL_NAME}

model:
  default: "${SEL_NAME}"
  provider: custom
  base_url: http://localhost:8080/v1

# API key is stored in .env file (OPENAI_API_KEY=llama)
CONFIG
    ok "config.yaml created."
fi

ok "Hermes configured → llama-server (${SEL_NAME} at http://localhost:8080/v1)"

# =============================================================================
#  8d. Hermes Workspace Integration (Web UI)
# =============================================================================
step "Setting up Hermes Workspace..."
WORKSPACE_DIR="${HOME}/hermes-workspace"
# ── Step 1: Configure .env (Section 8 already installed the fork + venv) ──────
# Section 8c may have created basic .env; ensure WebAPI settings are present
if [[ ! -f "${HOME}/.hermes/.env" ]]; then
    step "Creating Hermes Agent .env..."
    mkdir -p "${HOME}/.hermes"
    cat > "${HOME}/.hermes/.env" <<HERMES_ENV
# Hermes Agent Environment
# Generated by install.sh
OPENAI_API_KEY=llama
LLM_MODEL=${SEL_NAME}
HERMES_WEBAPI_HOST=0.0.0.0
HERMES_WEBAPI_PORT=8642
HERMES_ENV
    ok "Hermes Agent .env created."
else
    # Ensure WebAPI settings are present in existing .env
    if ! grep -q "^HERMES_WEBAPI_HOST=" "${HOME}/.hermes/.env" 2>/dev/null; then
        cat >> "${HOME}/.hermes/.env" <<HERMES_ENV_ADD
# WebAPI settings (added by install.sh)
HERMES_WEBAPI_HOST=0.0.0.0
HERMES_WEBAPI_PORT=8642
HERMES_ENV_ADD
        ok "Added WebAPI settings to ~/.hermes/.env."
    fi
fi
# ── Step 2: Hermes WebAPI systemd service ─────────────────────────────────────
step "Configuring Hermes WebAPI service..."

# Create systemd user service for WebAPI
mkdir -p "${HOME}/.config/systemd/user"
cat > "${HOME}/.config/systemd/user/hermes-webapi.service" <<WEBAPI_SERVICE
[Unit]
Description=Hermes Agent WebAPI
After=llama-server.service network.target
Requires=llama-server.service

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

if systemctl --user daemon-reload 2>/dev/null; then
    systemctl --user enable hermes-webapi.service 2>/dev/null || true
    ok "Hermes WebAPI systemd service enabled."
else
    warn "systemd --user unavailable — WebAPI must be started manually."
fi

# ── Step 3: Install hermes-workspace ──────────────────────────────────────────
step "Checking for Hermes Workspace..."

if [[ -d "${WORKSPACE_DIR}/.git" ]]; then
    ok "Hermes Workspace already cloned — updating to latest."
    cd "${WORKSPACE_DIR}"
    git fetch origin 2>/dev/null && git reset --hard origin/main 2>/dev/null || true
    cd - >/dev/null
else
    step "Cloning outsourc-e/hermes-workspace..."
    git clone https://github.com/outsourc-e/hermes-workspace.git "${WORKSPACE_DIR}" 2>&1 | tail -3
fi

# Clean up any Windows npm installations that might cause conflicts
WINDOWS_USER=$(whoami)
if [[ -d "/mnt/c/Users/${WINDOWS_USER}/.npm-global" ]]; then
    warn "Found Windows npm global installation — removing from PATH to avoid conflicts"
    # Create new PATH without Windows npm-global
    NEW_PATH=""
    IFS=':' read -ra PATH_ARRAY <<< "$PATH"
    for path_entry in "${PATH_ARRAY[@]}"; do
        if [[ "$path_entry" != *"/mnt/c/Users/${WINDOWS_USER}/.npm-global"* ]]; then
            if [[ -z "$NEW_PATH" ]]; then
                NEW_PATH="$path_entry"
            else
                NEW_PATH="$NEW_PATH:$path_entry"
            fi
        fi
    done
    export PATH="$NEW_PATH"
    ok "Windows npm-global removed from PATH"
fi

# Force reinstall pnpm locally to ensure we use the correct version
step "Installing pnpm locally (fresh install)..."

# First, check if we have a working local pnpm
LOCAL_PNPM="${HOME}/.local/share/pnpm/pnpm"
if [[ -x "$LOCAL_PNPM" ]] && ! "$LOCAL_PNPM" --version &>/dev/null; then
    warn "Local pnpm exists but doesn't work — reinstalling"
    rm -rf "${HOME}/.local/share/pnpm" 2>/dev/null || true
fi

# Install pnpm using the standalone installer
if [[ ! -x "$LOCAL_PNPM" ]]; then
    rm -rf "${HOME}/.local/share/pnpm" 2>/dev/null || true

    if curl -fsSL https://get.pnpm.io/install.sh | env PNPM_HOME="${HOME}/.local/share/pnpm" sh -; then
        export PNPM_HOME="${HOME}/.local/share/pnpm"
        export PATH="$PNPM_HOME:$PATH"
        ok "pnpm installed locally to ${PNPM_HOME}"
    else
        warn "pnpm standalone install failed, trying alternative method..."
        # Fallback: try to install via npm but ensure it's local
        mkdir -p "${HOME}/.local/share/pnpm"
        if npm install -g pnpm --prefix="${HOME}/.local" 2>/dev/null; then
            # Move pnpm to the expected location
            mv "${HOME}/.local/lib/node_modules/.bin/pnpm"* "${HOME}/.local/share/pnpm/" 2>/dev/null || true
            export PNPM_HOME="${HOME}/.local/share/pnpm"
            export PATH="$PNPM_HOME:$PATH"
            ok "pnpm installed via npm fallback"
        else
            die "Failed to install pnpm locally"
        fi
    fi
else
    ok "Local pnpm already installed and working"
    export PNPM_HOME="${HOME}/.local/share/pnpm"
    export PATH="$PNPM_HOME:$PATH"
fi

# Ensure Node.js is available and install pnpm locally to avoid Windows npm conflicts
if ! command -v node &>/dev/null || [[ "$(which node 2>/dev/null)" == /mnt/* ]]; then
    # If no node or it's from Windows mount, install latest LTS Node.js
    step "Installing Node.js 24 LTS for Workspace..."
    curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash - 2>/dev/null
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs
    # Ensure system Node.js takes precedence
    export PATH="/usr/bin:/bin:/usr/local/bin:${PATH}"
fi

ok "Node.js: $(node --version)"
ok "pnpm: $(pnpm --version)"

# Verify we're using the local pnpm and not Windows version
if [[ "$(which pnpm)" == /mnt/* ]]; then
    die "Still using Windows pnpm from $(which pnpm). PATH cleanup failed."
fi

# Verify pnpm works correctly
if ! pnpm --version &>/dev/null; then
    die "pnpm installation failed - cannot run pnpm --version"
fi

# Update pnpm to latest version
step "Ensuring pnpm is up to date..."
pnpm add -g pnpm 2>&1 | tail -3 || pnpm install -g pnpm 2>&1 | tail -3 || true
ok "pnpm updated: $(pnpm --version)"

# Install workspace dependencies
cd "${WORKSPACE_DIR}"
if [[ ! -d "node_modules" ]]; then
    step "Installing Hermes Workspace dependencies (first time ~2-5 min)..."
    pnpm install 2>&1 | tail -5
else
    step "Updating Hermes Workspace dependencies to latest versions..."
    pnpm update 2>&1 | tail -3
fi

# Create .env for workspace
WORKSPACE_ENV="${WORKSPACE_DIR}/.env"
if [[ ! -f "${WORKSPACE_ENV}" ]]; then
    cat > "${WORKSPACE_ENV}" <<WORKSPACE_ENV
# Hermes Workspace Configuration
# Generated by install.sh
HERMES_API_URL=http://127.0.0.1:8642
# HERMES_PASSWORD=your_password_here  # Optional: password-protect UI
WORKSPACE_ENV
    ok "Workspace .env created."
else
    # Ensure HERMES_API_URL is set
    if ! grep -q "^HERMES_API_URL=" "${WORKSPACE_ENV}" 2>/dev/null; then
        echo "HERMES_API_URL=http://127.0.0.1:8642" >> "${WORKSPACE_ENV}"
        ok "Added HERMES_API_URL to workspace .env."
    fi
fi
cd - >/dev/null

# ── Step 4: Start Hermes Workspace Service ────────────────────────────────────
step "Configuring Hermes Workspace service..."

# Use the local pnpm installation exclusively
PNPM_BIN="${HOME}/.local/share/pnpm/pnpm"
if [[ ! -x "$PNPM_BIN" ]]; then
    die "Local pnpm not found at ${PNPM_BIN}. Installation may have failed."
fi

# Create systemd user service for Workspace
cat > "${HOME}/.config/systemd/user/hermes-workspace.service" <<WORKSPACE_SERVICE
[Unit]
Description=Hermes Workspace Web UI
After=hermes-webapi.service network.target
Requires=hermes-webapi.service

[Service]
Type=simple
WorkingDirectory=${WORKSPACE_DIR}
ExecStart=${PNPM_BIN} dev
Restart=on-failure
RestartSec=5
Environment=HOME=${HOME}
Environment=NODE_ENV=production
Environment=PATH=${HOME}/.local/bin:${HOME}/.local/share/pnpm:/usr/bin:/bin

[Install]
WantedBy=default.target
WORKSPACE_SERVICE

if systemctl --user daemon-reload 2>/dev/null; then
    systemctl --user enable hermes-workspace.service 2>/dev/null || true
    ok "Hermes Workspace systemd service enabled."
else
    warn "systemd --user unavailable — Workspace must be started manually."
fi

HERMES_WEBAPI_INSTALLED=true
HERMES_WORKSPACE_INSTALLED=true
ok "Hermes Workspace integration complete."

# =============================================================================
#  8e. Text-to-Video Generation Dependencies
# =============================================================================
step "Checking for text-to-video generation support..."
VIDEO_GEN_DIR="${HOME}/llm-video"
mkdir -p "$VIDEO_GEN_DIR"

VIDEO_DEPS_INSTALLED=false
if python3 -c "import diffusers; import transformers; import accelerate; import PIL" &>/dev/null; then
    step "Updating video generation dependencies to latest versions..."
    pip3 install --quiet --user --break-system-packages --upgrade \
        diffusers transformers accelerate pillow safetensors opencv-python imageio imageio-ffmpeg \
        torch torchvision --index-url https://download.pytorch.org/whl/cu121 2>&1 | tail -3
    ok "Video generation dependencies updated."
    VIDEO_DEPS_INSTALLED=true
else
    read -rp "  Install text-to-video generation support? (requires ~2GB disk) [y/N]: " install_video
    if [[ "$install_video" =~ ^[Yy]$ ]]; then
        step "Installing video generation dependencies..."
        if pip3 install --quiet --user --break-system-packages \
            diffusers transformers accelerate pillow safetensors opencv-python imageio imageio-ffmpeg \
            torch torchvision --index-url https://download.pytorch.org/whl/cu121 2>/dev/null; then
            ok "Video dependencies installed with CUDA backend."
        elif pip3 install --quiet --user --break-system-packages \
            "diffusers[torch]" transformers accelerate pillow safetensors opencv-python imageio imageio-ffmpeg torch torchvision 2>/dev/null; then
            ok "Video dependencies installed."
        else
            warn "Video dependencies install failed — install manually with: pip3 install 'diffusers[torch]' transformers accelerate..."
        fi

        if python3 -c "import diffusers; import transformers" &>/dev/null; then
            ok "Video generation dependencies installed."
            VIDEO_DEPS_INSTALLED=true
        else
            warn "Video dependencies not fully installed."
        fi
    else
        ok "Skipping video generation support."
    fi
fi

if [[ "$VIDEO_DEPS_INSTALLED" == "true" ]]; then
    step "Creating video generation script..."
    cat > "${VIDEO_GEN_DIR}/generate_video.py" <<'VIDEO_SCRIPT'
#!/usr/bin/env python3
"""Text-to-Video Generation Script using Stable Video Diffusion."""

import argparse
import os
import sys
import torch
from diffusers import StableVideoDiffusionPipeline
from PIL import Image, ImageDraw, ImageFont


def create_base_image(prompt: str, width: int = 1024, height: int = 576) -> Image.Image:
    """Create a base image from text prompt using gradient background."""
    img = Image.new('RGB', (width, height))
    pixels = img.load()
    prompt_lower = prompt.lower()

    if any(w in prompt_lower for w in ['ocean', 'water', 'blue', 'sky']):
        base_color = (30, 100, 180)
    elif any(w in prompt_lower for w in ['forest', 'nature', 'green', 'tree']):
        base_color = (50, 120, 50)
    elif any(w in prompt_lower for w in ['sunset', 'orange', 'warm', 'fire']):
        base_color = (200, 100, 50)
    elif any(w in prompt_lower for w in ['night', 'dark', 'space', 'star']):
        base_color = (20, 20, 50)
    elif any(w in prompt_lower for w in ['desert', 'sand', 'yellow']):
        base_color = (200, 180, 100)
    else:
        base_color = (80, 80, 100)

    for y in range(height):
        for x in range(width):
            factor = y / height
            pixels[x, y] = (int(base_color[0] * (1 - factor * 0.5)),
                           int(base_color[1] * (1 - factor * 0.5)),
                           int(base_color[2] * (1 - factor * 0.5)))

    draw = ImageDraw.Draw(img)
    font = None
    # Try multiple font paths with fallback to default
    font_paths = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
        "/usr/share/fonts/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/freefont/FreeSans.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
        "/usr/share/fonts/truetype/ubuntu/Ubuntu-R.ttf",
    ]
    # Also check WSL2 Windows font mount points
    if os.path.exists("/mnt/c/Windows/Fonts"):
        font_paths.extend([
            "/mnt/c/Windows/Fonts/arial.ttf",
            "/mnt/c/Windows/Fonts/calibri.ttf",
        ])
    for font_path in font_paths:
        if os.path.exists(font_path):
            try:
                font = ImageFont.truetype(font_path, 24)
                break
            except Exception:
                continue
    if font is None:
        # Try to find any TTF font using fc-list if available
        try:
            import subprocess
            result = subprocess.run(['fc-list', ':family', 'sans', ':file'], 
                                   capture_output=True, text=True, timeout=5)
            if result.stdout:
                for line in result.stdout.strip().split('\n')[:10]:
                    if line.endswith('.ttf') or line.endswith('.ttc'):
                        try:
                            font = ImageFont.truetype(line.split(':')[-1].strip(), 24)
                            break
                        except Exception:
                            continue
        except Exception:
            pass
    if font is None:
        font = ImageFont.load_default()

    words = prompt.split()
    lines = []
    current_line = ""
    for word in words:
        test_line = f"{current_line} {word}" if current_line else word
        bbox = draw.textbbox((0, 0), test_line, font=font)
        if bbox[2] - bbox[0] < width - 40:
            current_line = test_line
        else:
            if current_line:
                lines.append(current_line)
            current_line = word
    if current_line:
        lines.append(current_line)

    text_y = height - 80
    for i, line in enumerate(lines[-3:]):
        line_y = text_y + i * 28
        draw.text((51, line_y + 1), line, font=font, fill=(0, 0, 0))
        draw.text((50, line_y), line, font=font, fill=(255, 255, 255))
    return img


def generate_video(prompt: str, output_path: str, fps: int = 7,
                   num_frames: int = 25, decode_chunk_size: int = 8) -> None:
    """Generate a video from text prompt using Stable Video Diffusion."""
    print(f"Generating video for prompt: '{prompt}'")
    print(f"Output: {output_path}")

    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"Using device: {device}")

    if device == "cuda":
        try:
            vram_total = torch.cuda.get_device_properties(0).total_memory / (1024**3)
            print(f"VRAM: {vram_total:.1f} GiB available")
            if vram_total < 8:
                print(f"Warning: Only {vram_total:.1f}GB VRAM. Consider reducing --frames or --chunk-size.")
        except Exception:
            pass
    else:
        print("Warning: CPU generation is very slow.")

    try:
        print("Loading Stable Video Diffusion model...")
        pipe = StableVideoDiffusionPipeline.from_pretrained(
            "stabilityai/stable-video-diffusion-img2vid-xt",
            torch_dtype=torch.float16 if device == "cuda" else torch.float32,
            variant="fp16" if device == "cuda" else None
        )
        pipe.enable_model_cpu_offload()

        print("Creating base image...")
        base_image = create_base_image(prompt).resize((1024, 576))

        print(f"Generating {num_frames} frames...")
        generator = torch.manual_seed(42) if device == "cpu" else None
        frames = pipe(base_image, decode_chunk_size=decode_chunk_size,
                      generator=generator, num_frames=num_frames).frames[0]

        print(f"Exporting video to {output_path}...")
        if output_path.lower().endswith('.mp4'):
            try:
                import imageio
                with imageio.get_writer(output_path, fps=fps, plugin='ffmpeg') as writer:
                    for frame in frames:
                        writer.append_data(frame)
                print("Exported using imageio-ffmpeg")
            except ImportError:
                from diffusers.utils import export_to_video
                export_to_video(frames, output_path, fps=fps)
                print("Exported using OpenCV")
        else:
            # Convert fps to duration (ms per frame) for Pillow GIF export
            duration_ms = int(1000 / fps)
            frames[0].save(output_path, save_all=True, append_images=frames[1:],
                          duration=duration_ms, loop=0, format="GIF")

        print(f"✓ Video saved: {output_path} ({num_frames/fps:.1f}s)")
    except Exception as e:
        print(f"Error: {e}")
        print("\nTroubleshooting: Check VRAM (8GB+ recommended), reduce --frames or --chunk-size")
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description="Generate video from text using SVD")
    parser.add_argument("prompt", nargs="?", default="a serene ocean sunset",
                       help="Text description of the video")
    parser.add_argument("-o", "--output", default=os.path.expanduser("~/llm-video/output_video.mp4"),
                       help="Output path (use .gif for GIF format)")
    parser.add_argument("--fps", type=int, default=7, help="Frames per second")
    parser.add_argument("--frames", type=int, default=25, help="Number of frames (max 25)")
    parser.add_argument("--chunk-size", type=int, default=8, help="Decode chunk size")

    args = parser.parse_args()
    output_dir = os.path.dirname(args.output)
    if output_dir and not os.path.exists(output_dir):
        os.makedirs(output_dir)

    generate_video(prompt=args.prompt, output_path=args.output,
                   fps=args.fps, num_frames=args.frames, decode_chunk_size=args.chunk_size)


if __name__ == "__main__":
    main()
VIDEO_SCRIPT

    chmod +x "${VIDEO_GEN_DIR}/generate_video.py"

    cat > "${VIDEO_GEN_DIR}/generate-video" <<'VIDEO_WRAPPER'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "${SCRIPT_DIR}/generate_video.py" "$@"
VIDEO_WRAPPER
    chmod +x "${VIDEO_GEN_DIR}/generate-video"
    ok "Video generation script created."

    [[ ! -L "${VIDEO_GEN_DIR}/genvideo" ]] && ln -sf "${VIDEO_GEN_DIR}/generate-video" "${VIDEO_GEN_DIR}/genvideo" && ok "Created genvideo symlink"

    if ! grep -q "llm-video" "${HOME}/.profile" 2>/dev/null; then
        cat >> "${HOME}/.profile" <<'PROFILE_VIDEO'

# Video generation PATH
export PATH="$HOME/llm-video:$PATH"
PROFILE_VIDEO
        ok "Added llm-video to ~/.profile"
    fi

    # Also add to ~/.bashrc for interactive shells
    if ! grep -q "llm-video" "${HOME}/.bashrc" 2>/dev/null; then
        echo "export PATH=\"\$HOME/llm-video:\$PATH\"  # Video generation" >> "${HOME}/.bashrc"
        ok "Added llm-video to ~/.bashrc"
    fi
fi

# =============================================================================
#  0. Update System and Python Packages
# =============================================================================
step "Updating system packages and Python dependencies..."

# Update system packages
sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq 2>&1 | tail -3

# Update pip and key Python packages
pip3 install --quiet --user --break-system-packages --upgrade pip setuptools wheel 2>&1 | tail -3
ok "System and Python package managers updated."

# =============================================================================
#  1. WSL Environment Check
# =============================================================================
step "Checking for Qwen Code..."
QWEN_CODE_INSTALLED=false

# Use Node.js from Hermes installation if available, otherwise install system-wide
if [[ -x "${HOME}/.hermes/node/bin/node" ]]; then
    export PATH="${HOME}/.hermes/node/bin:${PATH}"
    QWEN_NODE_PATH="${HOME}/.hermes/node/bin"
elif [[ -x "${HOME}/.local/bin/node" ]]; then
    QWEN_NODE_PATH="${HOME}/.local/bin"
else
    QWEN_NODE_PATH=""
fi

if ! command -v node &>/dev/null || [[ "$(which node 2>/dev/null)" == /mnt/* ]]; then
    warn "Node.js not found or using Windows Node.js — installing system Node.js 24 LTS..."
    curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash - 2>/dev/null
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs
    QWEN_NODE_PATH="/usr/bin"
    # Ensure system Node.js takes precedence
    export PATH="/usr/bin:/bin:/usr/local/bin:${PATH}"
fi

if command -v node &>/dev/null; then
    ok "Node.js: $(node --version)"

    # Update npm to latest version
    step "Updating npm to latest version..."
    export PATH="/usr/bin:/bin:/usr/local/bin:${PATH}"
    npm install -g npm@latest 2>&1 | tail -3

    ok "npm: $(npm --version)"

    if ! command -v qwen &>/dev/null; then
        step "Installing Qwen Code..."
        npm install -g @qwen-code/cli 2>&1 | tail -3
        NPM_GLOBAL_BIN="$(npm prefix -g 2>/dev/null)/bin"
        export PATH="${NPM_GLOBAL_BIN}:${PATH}"
    fi
    QWEN_CODE_INSTALLED=true

    step "Writing ~/.qwen/settings.json..."
    mkdir -p "${HOME}/.qwen"
    cat > "${HOME}/.qwen/settings.json" <<QWEN_CFG
{
  "modelProviders": {
    "openai": [{
      "id": "${SEL_NAME}",
      "name": "${SEL_NAME}",
      "baseUrl": "http://localhost:8080/v1",
      "description": "Local llama-server",
      "envKey": "LLAMA_API_KEY"
    }]
  },
  "env": { "LLAMA_API_KEY": "llama" },
  "security": { "auth": { "selectedType": "openai" } },
  "model": { "name": "${SEL_NAME}" }
}
QWEN_CFG
    ok "Qwen Code configured."
fi

# =============================================================================
#  10. Create ~/start-llm.sh
# =============================================================================
step "Creating launch script..."
LAUNCH_SCRIPT="${HOME}/start-llm.sh"

# Workspace paths
HERMES_AGENT_DIR="${HOME}/hermes-agent"
HERMES_VENV="${HERMES_AGENT_DIR}/.venv"
WORKSPACE_DIR="${HOME}/hermes-workspace"

if [[ "$HAS_NVIDIA" == "true" ]]; then
    cat > "$LAUNCH_SCRIPT" <<LAUNCH
# Full LLM Stack launcher — generated by install.sh
GGUF="${GGUF_PATH}"
MODEL_NAME="${SEL_NAME}"
LLAMA_BIN="${LLAMA_SERVER_BIN}"
SAFE_CTX=${SAFE_CTX}
USE_JINJA="${USE_JINJA}"
HERMES_AGENT_DIR="${HOME}/hermes-agent"
HERMES_VENV="${HOME}/hermes-agent/.venv"
WORKSPACE_DIR="${HOME}/hermes-workspace"

# Check for running services
LLAMA_PID=\$(pgrep -f "llama-server" 2>/dev/null || true)
WEBAPI_PID=\$(pgrep -f "python -m webapi" 2>/dev/null || true)
WORKSPACE_PID=\$(pgrep -f "pnpm dev" 2>/dev/null | grep -i workspace || true)

if [[ -n "\$LLAMA_PID" || -n "\$WEBAPI_PID" || -n "\$WORKSPACE_PID" ]]; then
    echo -e "\\n⚠️  Services already running:"
    [[ -n "\$LLAMA_PID" ]] && echo "   llama-server:  \$LLAMA_PID"
    [[ -n "\$WEBAPI_PID" ]] && echo "   Hermes WebAPI: \$WEBAPI_PID"
    [[ -n "\$WORKSPACE_PID" ]] && echo "   Workspace:     \$WORKSPACE_PID"
    echo ""
    if [[ -t 0 ]]; then
        read -rp "Terminate and start fresh? [y/N]: " kill_choice
    else
        kill_choice="n"
    fi
    if [[ "\$kill_choice" =~ ^[Yy]\$ ]]; then
        pkill -f "llama-server" 2>/dev/null || true
        pkill -f "python -m webapi" 2>/dev/null || true
        pkill -f "pnpm dev" 2>/dev/null || true
        sleep 2
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

# Start llama-server
echo "[1/3] Starting llama-server..."
"\${LLAMA_BIN}" -m "\${GGUF}" -ngl 99 -fa on -c "\${SAFE_CTX}" -np 1 \\
    --cache-type-k q4_0 --cache-type-v q4_0 --host 0.0.0.0 --port 8080 \${USE_JINJA} &
LLAMA_PID=\$!
sleep 2

# Wait for llama-server to be ready
for i in {1..15}; do
    if curl -sf http://localhost:8080/v1/models &>/dev/null; then
        echo "✓ llama-server ready (PID: \$LLAMA_PID)"
        break
    fi
    sleep 1
done

# Start Hermes WebAPI
echo "[2/3] Starting Hermes WebAPI..."
source "\${HERMES_VENV}/bin/activate"
cd "\${HERMES_AGENT_DIR}"
python -m webapi &
WEBAPI_PID=\$!
deactivate 2>/dev/null || true
sleep 2

# Wait for WebAPI to be ready
for i in {1..15}; do
    if curl -sf http://localhost:8642/health &>/dev/null; then
        echo "✓ Hermes WebAPI ready (PID: \$WEBAPI_PID)"
        break
    fi
    sleep 1
done

# Start Hermes Workspace
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

# Wait for all background processes
wait
LAUNCH
else
    # Use physical cores for better performance, fallback to nproc
    if command -v lscpu &>/dev/null; then
        CPU_THREADS=$(lscpu | grep "^Core(s) per socket:" | awk '{print $4}' 2>/dev/null)
        SOCKETS=$(lscpu | grep "^Socket(s):" | awk '{print $2}' 2>/dev/null)
        if [[ -n "$CPU_THREADS" && -n "$SOCKETS" ]]; then
            CPU_THREADS=$(( CPU_THREADS * SOCKETS ))
        else
            CPU_THREADS=$(nproc)
        fi
    else
        CPU_THREADS=$(nproc)
    fi
    cat > "$LAUNCH_SCRIPT" <<LAUNCH
# Full LLM Stack launcher (CPU) — generated by install.sh
GGUF="${GGUF_PATH}"
MODEL_NAME="${SEL_NAME}"
LLAMA_BIN="${LLAMA_SERVER_BIN}"
SAFE_CTX=${SAFE_CTX}
USE_JINJA="${USE_JINJA}"
HERMES_AGENT_DIR="${HOME}/hermes-agent"
HERMES_VENV="${HOME}/hermes-agent/.venv"
WORKSPACE_DIR="${HOME}/hermes-workspace"

# Check for running services
LLAMA_PID=\$(pgrep -f "llama-server" 2>/dev/null || true)
WEBAPI_PID=\$(pgrep -f "python -m webapi" 2>/dev/null || true)
WORKSPACE_PID=\$(pgrep -f "pnpm dev" 2>/dev/null | grep -i workspace || true)

if [[ -n "\$LLAMA_PID" || -n "\$WEBAPI_PID" || -n "\$WORKSPACE_PID" ]]; then
    echo "⚠️  Services already running:"
    [[ -n "\$LLAMA_PID" ]] && echo "   llama-server:  \$LLAMA_PID"
    [[ -n "\$WEBAPI_PID" ]] && echo "   Hermes WebAPI: \$WEBAPI_PID"
    [[ -n "\$WORKSPACE_PID" ]] && echo "   Workspace:     \$WORKSPACE_PID"
    if [[ -t 0 ]]; then
        read -rp "Terminate and start fresh? [y/N]: " kill_choice
    else
        kill_choice="n"
    fi
    if [[ "\$kill_choice" =~ ^[Yy]\$ ]]; then
        pkill -f "llama-server" 2>/dev/null || true
        pkill -f "python -m webapi" 2>/dev/null || true
        pkill -f "pnpm dev" 2>/dev/null || true
        sleep 2
        echo "✓ All services stopped."
    else
        echo "Keeping existing instances. Exiting."; exit 0
    fi
fi

echo ""
echo "Starting Full LLM Stack (CPU Mode)"
echo ""
echo "  Model     : \${MODEL_NAME}"
echo "  Context   : \${SAFE_CTX} tokens"
echo "  Threads   : ${CPU_THREADS}"
echo ""
echo "  Endpoints:"
echo "  llama-server   → http://localhost:8080"
echo "  Hermes WebAPI  → http://localhost:8642"
echo "  Hermes Workspace → http://localhost:3000"
echo ""
echo "  Press Ctrl+C to stop all services."
echo ""

# Start llama-server
echo "[1/3] Starting llama-server (CPU)..."
"\${LLAMA_BIN}" -m "\${GGUF}" -t ${CPU_THREADS} -c "\${SAFE_CTX}" -np 1 \\
    --host 0.0.0.0 --port 8080 \${USE_JINJA} &
LLAMA_PID=\$!
sleep 2

for i in {1..15}; do
    if curl -sf http://localhost:8080/v1/models &>/dev/null; then
        echo "✓ llama-server ready (PID: \$LLAMA_PID)"
        break
    fi
    sleep 1
done

# Start Hermes WebAPI
echo "[2/3] Starting Hermes WebAPI..."
source "\${HERMES_VENV}/bin/activate"
cd "\${HERMES_AGENT_DIR}"
python -m webapi &
WEBAPI_PID=\$!
deactivate 2>/dev/null || true
sleep 2

for i in {1..15}; do
    if curl -sf http://localhost:8642/health &>/dev/null; then
        echo "✓ Hermes WebAPI ready (PID: \$WEBAPI_PID)"
        break
    fi
    sleep 1
done

# Start Hermes Workspace
echo "[3/3] Starting Hermes Workspace..."
cd "\${WORKSPACE_DIR}"
pnpm dev &
WORKSPACE_PID=\$!
sleep 2

echo "✓ Hermes Workspace starting (PID: \$WORKSPACE_PID)"
echo ""
echo "All services started! Open http://localhost:3000 in your browser."
echo ""

# Wait for all background processes
wait
LAUNCH
fi

chmod +x "$LAUNCH_SCRIPT"
ok "Launch script: ~/start-llm.sh"

# =============================================================================
#  11. Start llama-server in background
# =============================================================================
step "Starting llama-server in background..."
LOG_FILE="/tmp/llama-server.log"
LOG_MAX_SIZE=$((50 * 1024 * 1024))

if [[ -f "$LOG_FILE" ]]; then
    LOG_SIZE=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if (( LOG_SIZE > LOG_MAX_SIZE )); then
        # Use temporary file to avoid race conditions
        TEMP_LOG="${LOG_FILE}.tmp.$(date +%s)"
        mv "$LOG_FILE" "$TEMP_LOG"
        if command -v gzip &>/dev/null; then
            gzip "$TEMP_LOG" 2>/dev/null && mv "${TEMP_LOG}.gz" "${LOG_FILE}.old.gz" || mv "$TEMP_LOG" "${LOG_FILE}.old"
            ok "Rotated log → ${LOG_FILE}.old.gz"
        else
            mv "$TEMP_LOG" "${LOG_FILE}.old"
            ok "Rotated log → ${LOG_FILE}.old"
        fi
    fi
fi

pkill -f "llama-server" 2>/dev/null || true
sleep 1

# Start in background with stdin from /dev/null (launch script auto-detects non-interactive)
nohup bash "$LAUNCH_SCRIPT" < /dev/null > "$LOG_FILE" 2>&1 &
SERVER_PID=$!
ok "llama-server starting (PID: ${SERVER_PID})"

READY=false
for i in {1..30}; do
    if curl -sf http://localhost:8080/v1/models &>/dev/null; then
        ok "llama-server ready at http://localhost:8080"
        READY=true
        break
    fi
    sleep 1
done
[[ "$READY" == "false" ]] && warn "Server not responding in 30s — check logs with: llm-log"

# =============================================================================
#  12. systemd user service
#  Note: Using quoted <<'SERVICE' to prevent any variable expansion issues.
#        Variables are explicitly substituted before the heredoc.
# =============================================================================
step "Creating systemd user service..."
mkdir -p "${HOME}/.config/systemd/user"
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
    ok "systemd services configured for auto-start."
    info "Services will auto-start on next login. Use 'start-llm' for immediate start."
else
    warn "systemd --user unavailable — services must be started manually with 'start-llm'"
fi

# =============================================================================
#  12b. Start all services after installation
# =============================================================================
if [[ "$HERMES_WEBAPI_INSTALLED" == "true" && "$HERMES_WORKSPACE_INSTALLED" == "true" ]]; then
    if systemctl --user daemon-reload 2>/dev/null; then
        info "Services configured for auto-start. Use 'start-llm' to start immediately."
    else
        warn "systemd unavailable — services must be started manually with 'start-llm'"
    fi
fi

# =============================================================================
#  13. ~/.bashrc helpers
# =============================================================================
step "Adding helpers to ~/.bashrc..."

# Skip clear wrapper - use system clear directly to avoid recursion
MARKER="# === LLM setup (added by install.sh) ==="
if grep -qF "$MARKER" "${HOME}/.bashrc" 2>/dev/null; then
    ok "Helpers already in ~/.bashrc — skipping."
else
    cat >> "${HOME}/.bashrc" <<'BASHRC_START'

# === LLM setup (added by install.sh) ===
[[ -n "${__LLM_BASHRC_LOADED:-}" ]] && return 0
export __LLM_BASHRC_LOADED=1

export RED='\033[0;31m' GRN='\033[0;32m' YLW='\033[1;33m'
export CYN='\033[0;36m' BLD='\033[1m' RST='\033[0m'
export PATH="/usr/local/cuda/bin:${PATH}"
export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"
# Prioritize system Node.js and local tools over Windows installations
export PNPM_HOME="${HOME}/.local/share/pnpm"
export PATH="/usr/bin:/bin:/usr/local/bin:${PNPM_HOME}:${HOME}/.local/bin:${HOME}/.hermes/node/bin:${HOME}/llm-video:${PATH}"
BASHRC_START

    if [[ -n "${HF_TOKEN:-}" ]] && ! grep -qF "export HF_TOKEN=" "${HOME}/.bashrc" 2>/dev/null; then
        echo "export HF_TOKEN=\"${HF_TOKEN}\"" >> "${HOME}/.bashrc"
        ok "HF_TOKEN added to ~/.bashrc."
    fi

    cat >> "${HOME}/.bashrc" <<'BASHRC_END'

# LLM aliases
alias start-llm='bash ~/start-llm.sh'
alias start-llm-services='systemctl --user start llama-server.service hermes-webapi.service hermes-workspace.service 2>/dev/null && echo "LLM services started via systemd" || bash ~/start-llm.sh'
alias stop-llm='systemctl --user stop llama-server.service hermes-webapi.service hermes-workspace.service 2>/dev/null && echo "LLM services stopped via systemd" || (pkill -f llama-server && pkill -f "python -m webapi" && pkill -f "pnpm dev" && echo "All LLM services stopped manually.")'
alias restart-llm='systemctl --user restart llama-server.service hermes-webapi.service hermes-workspace.service 2>/dev/null && echo "LLM services restarted via systemd" || (stop-llm && sleep 2 && start-llm)'
alias llm-log='tail -f /tmp/llama-server.log'
alias switch-model='install.sh'
alias hermes-update='hermes update'
alias hermes-doctor='hermes doctor'
alias hermes-sessions='hermes sessions list'
alias hermes-summarise='echo "Summarise: decisions, code, bugs, current task. Drop rest."'

# Hermes Workspace aliases
alias start-workspace='cd ~/hermes-workspace && pnpm dev'
alias stop-workspace='pkill -f "pnpm dev" && echo "Hermes Workspace stopped."'
alias start-hermes-api='source ~/hermes-agent/.venv/bin/activate && cd ~/hermes-agent && python -m webapi'
alias stop-hermes-api='pkill -f "python -m webapi" && echo "Hermes WebAPI stopped."'
alias workspace-log='tail -f ~/hermes-workspace/logs/*.log 2>/dev/null || echo "No workspace logs found."'
alias hermes-api-log='tail -f ~/hermes-agent/logs/*.log 2>/dev/null || echo "No WebAPI logs found."'

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
                active) color=$GRN; icon="✓" ;;
                *) color=$RED; icon="✗" ;;
            esac
            printf "  %s %-20s %s (%s)\n" "$icon" "$service.service" "$status" "$enabled"
        done
    else
        echo "  systemd not available"
    fi
    echo ""
}

llm-status() {
    echo -e "${BLD}${CYN}╭────────────────────────────────────────────────────────────────╮${RST}"
    echo -e "${BLD}${CYN}│${RST}  ${BLD}LLM Stack Status${RST}"
    echo -e "${BLD}${CYN}│${RST}  ──────────────────────────────────────────────────────"
    
    LLAMA_PID=\$(pgrep -f "llama-server" 2>/dev/null || true)
    WEBAPI_PID=\$(pgrep -f "python -m webapi" 2>/dev/null || true)
    WORKSPACE_PID=\$(pgrep -f "pnpm dev" 2>/dev/null | grep -i workspace || true)
    
    if [[ -n "\$LLAMA_PID" ]]; then
        echo -e "${GRN}  ✓ llama-server   → http://localhost:8080  (PID: \$LLAMA_PID)${RST}"
    else
        echo -e "${RED}  ✗ llama-server   → not running${RST}"
    fi
    
    if [[ -n "\$WEBAPI_PID" ]]; then
        echo -e "${GRN}  ✓ Hermes WebAPI  → http://localhost:8642  (PID: \$WEBAPI_PID)${RST}"
    else
        echo -e "${YLW}  ⚠ Hermes WebAPI  → not running${RST}"
    fi
    
    if [[ -n "\$WORKSPACE_PID" ]]; then
        echo -e "${GRN}  ✓ Workspace      → http://localhost:3000  (PID: \$WORKSPACE_PID)${RST}"
    else
        echo -e "${YLW}  ⚠ Workspace      → not running${RST}"
    fi
    
    echo -e "${BLD}${CYN}│${RST}  ──────────────────────────────────────────────────────"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}start-llm${RST} to start all services"
    echo -e "${BLD}${CYN}╰────────────────────────────────────────────────────────────────╯${RST}"
}

create-agents-md() {
    local target="${1:-.}/AGENTS.md"
    [[ -f "$target" ]] && { echo "AGENTS.md exists at $target"; return; }
    cat > "$target" <<'AGENTS'
# AGENTS.md
## Project Overview
<!-- Describe project in 2-3 sentences -->

## Architecture
<!-- Key files -->

## Coding Conventions
- Language: <!-- e.g. Python 3.11 -->
- Style: <!-- e.g. 2-space indent -->

## Key Commands
```bash
# Run:   python3 -m http.server 8000
# Test:  pytest
```

## Constraints
- <!-- What NOT to do -->

## Known Issues
- <!-- Document bugs -->
AGENTS
    echo "✓ Created AGENTS.md at $target"
}

show_llm_summary() {
    echo -e "${BLD}${CYN}╭────────────────────────────────────────────────────────────────╮${RST}"
    echo -e "${BLD}${CYN}│${RST}  ${BLD}LLM Quick Commands${RST}"
    echo -e "${BLD}${CYN}│${RST}  ──────────────────────────────────────────────────────"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}start-llm-services${RST} → Auto-start via systemd"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}start-llm${RST}          → Start full stack manually"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}stop-llm${RST}           → Stop all services"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}restart-llm${RST}        → Restart all services"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}llm-status${RST}         → Check service status"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}llm-services${RST}       → Check systemd services"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}llm-log${RST}            → View llama-server logs"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}llm-models${RST}         → List downloaded models"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}vram${RST}               → GPU/VRAM usage"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}hermes${RST}             → Hermes AI agent"
    echo -e "${BLD}${CYN}╰────────────────────────────────────────────────────────────────╯${RST}"
    echo ""
}

[[ $- == *i* && ! -f "${HOME}/.llm_summary_shown" ]] && { show_llm_summary; touch "${HOME}/.llm_summary_shown"; }
BASHRC_END
    ok "Helpers written to ~/.bashrc."
fi

# =============================================================================
#  14. .wslconfig RAM hint
# =============================================================================
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
    # Allocate 80% of host RAM but cap at reasonable limits for LLM workloads
    WSL_RAM=$(( RAM_GiB * 4 / 5 ))
    (( WSL_RAM < 16 )) && WSL_RAM=16  # Minimum 16GB for LLM workloads
    (( WSL_RAM > 96 )) && WSL_RAM=96  # Cap at 96GB to leave headroom
    WSL_SWAP=$(( WSL_RAM / 2 ))       # 50% of RAM for swap (more generous for LLM workloads)
    (( WSL_SWAP < 8 )) && WSL_SWAP=8  # Minimum 8GB swap

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

# =============================================================================
#  Done
# =============================================================================
echo ""
echo -e "${GRN}${BLD}"
cat <<'EOF'
 ╔══════════════════════════════════════════════════════════╗
 ║                   Setup Complete!                        ║
 ╚══════════════════════════════════════════════════════════╝
EOF
echo -e "${RST}"
echo -e " ${BLD}Versions Installed:${RST}"
echo -e "  Node.js          →  $(node --version 2>/dev/null || echo 'Not installed')"
echo -e "  npm              →  $(npm --version 2>/dev/null || echo 'Not installed')"
echo -e "  pnpm             →  $(pnpm --version 2>/dev/null || echo 'Not installed')"
echo -e "  Python           →  $(python3 --version 2>/dev/null || echo 'Not installed')"
echo -e "  llama.cpp        →  $(llama-server --version 2>&1 | head -1 || echo 'Latest')"
echo -e "  ${BLD}Services:${RST}"
echo -e "  llama-server     →  http://localhost:8080/v1"
echo -e "  llama.cpp Web UI →  http://localhost:8080"
echo -e "  Hermes WebAPI    →  http://localhost:8642"
echo -e "  Hermes Workspace →  http://localhost:3000 ⭐"
echo -e "  Model            →  ${SEL_NAME}  (context: ${SAFE_CTX})"
[[ "$HERMES_WEBAPI_INSTALLED" == "true" ]] && echo -e "  Hermes Agent     →  outsourc-e fork with WebAPI"
[[ "$HERMES_WORKSPACE_INSTALLED" == "true" ]] && echo -e "  Hermes Workspace →  Full web UI installed"
[[ "$QWEN_CODE_INSTALLED" == "true" ]] && echo -e "  Qwen Code        →  coding agent"
[[ "$VIDEO_DEPS_INSTALLED" == "true" ]] && echo -e "  Video Gen        →  Stable Video Diffusion"
echo ""
echo -e " ${BLD}Usage:${RST}"
echo -e "  ${CYN}start-llm-services${RST} auto-start all services (systemd)"
echo -e "  ${CYN}start-llm${RST}          start full stack manually (fallback)"
echo -e "  ${CYN}stop-llm${RST}           stop all services"
echo -e "  ${CYN}restart-llm${RST}        restart all services"
echo -e "  ${CYN}llm-status${RST}         check running processes"
echo -e "  ${CYN}llm-services${RST}       check systemd services"
echo -e "  ${CYN}llm-log${RST}            tail llama-server logs"
echo -e "  ${CYN}llm-models${RST}         list downloaded models"
echo -e "  ${CYN}switch-model${RST}       change model (re-run installer)"
echo -e "  ${CYN}hermes${RST}             Hermes AI agent (CLI)"
echo -e "  ${CYN}qwen${RST}               Qwen Code assistant"
echo -e "  ${CYN}vram${RST}               GPU/VRAM usage"
[[ "$VIDEO_DEPS_INSTALLED" == "true" ]] && echo -e "  ${CYN}generate-video${RST}   text-to-video"
echo ""
echo -e " ${BLD}Open in Browser:${RST}"
echo -e "  ${GRN}http://localhost:3000${RST}  →  Hermes Workspace (main UI ⭐)"
echo -e "  ${CYN}http://localhost:8080${RST}  →  llama.cpp Web UI (basic)"
echo ""
echo -e " ${BLD}Features:${RST}"
echo -e "  • Real-time SSE streaming chat"
echo -e "  • File browser with Monaco editor"
echo -e "  • Memory & skills management"
echo -e "  • Terminal integration"
echo -e "  • 8 themes (light/dark modes)"
echo -e "  • PWA — install as desktop app"
echo -e "  • Auto-start services on boot"
echo -e "  • Proper service dependencies"
echo ""
echo -e " ${BLD}Docs:${RST}"
echo -e "  llama.cpp       →  https://github.com/ggml-org/llama.cpp"
echo -e "  Hermes Agent    →  https://github.com/outsourc-e/hermes-agent"
echo -e "  Hermes Workspace →  https://github.com/outsourc-e/hermes-workspace"
echo -e "  Qwen Code       →  https://github.com/QwenLM/qwen-code"
echo ""
echo -e " ${YLW}Note:${RST} Run 'source ~/.bashrc' or open a new terminal."
echo -e " ${GRN}Auto-start:${RST} Services start automatically on next login."
[[ "$VIDEO_DEPS_INSTALLED" == "true" ]] && echo -e " ${YLW}Video:${RST} Run 'source ~/.profile' for generate-video in PATH."
echo ""
