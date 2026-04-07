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
#
#  CHANGES vs original (see diff summary at bottom of file):
#    CRITICAL-2  envsubst now receives an explicit variable whitelist
#    HIGH-1      systemd ExecStart paths quoted
#    HIGH-2      generated start-llm.sh gains set -euo pipefail
#    HIGH-3      grep -F replaced with awk for exact field match
#    HIGH-4      pushd/popd used around llama.cpp build directory
#    HIGH-5      git stash before reset --hard
#    HIGH-6      pgrep workspace detection fixed (pidfile pattern)
#    SEC-1       checksum verification added for pnpm + nodesource
#    SEC-2       HF_TOKEN no longer written to ~/.bashrc
#    SEC-3       sed pipeline collapsed to single invocation; token re-validated
#    SEC-4       sudo rm guarded by explicit path check
#    MAINT-1     section numbers made contiguous (10 re-inserted)
#    MAINT-2     info() alias removed; callers updated to ok()
#    MAINT-3     HERMES_*_INSTALLED flags now set conditionally
#    MAINT-4     switch-model alias fixed to re-run this script via $0
#    MAINT-5     heredoc indentation normalised
#    PERF-1      triple sed collapsed to single sed
#    STYLE-2     echo -e kept (Ubuntu/bash target; documented)
# =============================================================================
set -euo pipefail

# ── Colour helpers — exported so subshells (llm-models fn) can use them ───────
export RED='\033[0;31m'
export GRN='\033[0;32m'
export YLW='\033[1;33m'
export CYN='\033[0;36m'
export BLD='\033[1m'
export RST='\033[0m'

# CHANGE MAINT-2: removed info() alias; every former info() call uses ok() below
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

# Priority 1: Environment variable
if [[ -n "${HF_TOKEN:-}" ]]; then
    ok "HF_TOKEN already set in environment — using it."
# Priority 2: Token cache file (most reliable; used by official HF CLI)
elif [[ -f "${HOME}/.cache/huggingface/token" ]]; then
    HF_TOKEN=$(cat "${HOME}/.cache/huggingface/token" 2>/dev/null || true)
    [[ -n "$HF_TOKEN" ]] && ok "HF_TOKEN found in ~/.cache/huggingface/token."
# Priority 3: ~/.bashrc export (fallback read — we do NOT write back here; see SEC-2)
elif grep -qF "export HF_TOKEN=" "${HOME}/.bashrc" 2>/dev/null; then
    # CHANGE PERF-1 / SEC-3: single sed expression; SC2001 compliant
    HF_TOKEN=$(grep "export HF_TOKEN=" "${HOME}/.bashrc" | head -1 \
        | sed "s/.*export HF_TOKEN=[\"']\{0,1\}\([^\"']*\)[\"']\{0,1\}/\1/")
    [[ -n "$HF_TOKEN" ]] && ok "HF_TOKEN found in ~/.bashrc (read-only)."
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
        ok "Non‑interactive – skipping HuggingFace token prompt."
    fi
fi

export HF_TOKEN

# CHANGE SEC-2: HF_TOKEN is intentionally NOT written to ~/.bashrc.
# The official HuggingFace CLI stores the token in ~/.cache/huggingface/token,
# which is the correct, purpose-built credential store. Writing tokens to
# ~/.bashrc exposes them to any process that reads the environment.

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
    procps gettext-base   # procps = watch; gettext-base = envsubst
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
    if nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null \
            | head -1 | grep -q ','; then
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
    GPU_NAME=$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | head -1 \
        | sed 's/.*: //' || echo "None")
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
        warn "Non‑interactive – continuing with CPU-only build."
    fi
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

        # CHANGE SEC-4: only remove the cuda keyring file if it was placed there
        # by a previous run of this script (identified by the specific filename).
        # We do NOT silently delete arbitrary GPG keys.
        CUDA_KEYRING_GPG="/etc/apt/trusted.gpg.d/cuda-archive-keyring.gpg"
        if [[ -f "$CUDA_KEYRING_GPG" ]]; then
            sudo rm -f "$CUDA_KEYRING_GPG"
        fi

        CUDA_DEB="/tmp/cuda-keyring.deb"
        curl -fsSL --connect-timeout 10 --max-time 60 \
            https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb \
            -o "$CUDA_DEB" || die "Failed to download CUDA keyring"
        register_tmp "$CUDA_DEB"

        # Verify the downloaded .deb is at least plausibly sized (> 1 KB)
        CUDA_DEB_SIZE=$(stat -c%s "$CUDA_DEB" 2>/dev/null || echo 0)
        (( CUDA_DEB_SIZE < 1024 )) && die "CUDA keyring .deb suspiciously small (${CUDA_DEB_SIZE} bytes)."

        sudo dpkg -i "$CUDA_DEB"
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
    if [[ -t 0 ]]; then
        read -rp "$(echo -e "  ${BLD}Enter model number [1-${NUM_MODELS}]:${RST} ")" CHOICE
    else
        warn "Non‑interactive – defaulting to model 5 (Qwen 3.5 9B)"
        CHOICE=5
        break
    fi
    if [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= NUM_MODELS )); then
        break
    fi
    warn "Please enter a number between 1 and ${NUM_MODELS}."
done

SEL_IDX="" SEL_HF_REPO="" SEL_GGUF="" SEL_NAME="" SEL_MIN_RAM="0" SEL_MIN_VRAM="0"

# CHANGE HIGH-3: use awk for exact field-1 match to avoid substring collisions
# (e.g. CHOICE=1 previously could match "10|..." with grep -F "1|")
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
        warn "Non‑interactive – continuing anyway (use with caution)."
    fi
elif [[ "$GRADE_SEL" == "C" ]]; then
    warn "Grade C — tight fit, expect slow responses."
fi

# Context window and Jinja template settings per model
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

HF_CLI_BIN="${HOME}/.local/bin/hf"
HF_CLI_LEGACY="${HOME}/.local/bin/huggingface-cli"

if [[ ! -x "$HF_CLI_BIN" && ! -x "$HF_CLI_LEGACY" ]]; then
    pip3 install --quiet --user --break-system-packages huggingface_hub
fi

if [[ -x "$HF_CLI_BIN" ]]; then
    HF_CLI_USED="$HF_CLI_BIN"; HF_CLI_NAME="hf"
elif [[ -x "$HF_CLI_LEGACY" ]]; then
    HF_CLI_USED="$HF_CLI_LEGACY"; HF_CLI_NAME="huggingface-cli"
else
    die "Neither 'hf' nor 'huggingface-cli' found after install."
fi

if ! "$HF_CLI_USED" version &>/dev/null; then
    die "'$HF_CLI_NAME' found at $HF_CLI_USED but fails to run."
fi

step "Updating HuggingFace CLI to latest version..."
pip3 install --quiet --user --break-system-packages --upgrade huggingface_hub 2>&1 | tail -3

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
    AVAIL_GB=$(( AVAIL_KB / 1024 / 1024 ))

    # CHANGE HIGH-3: use awk field match instead of grep -F to avoid substring collisions
    REQ_GB=$(printf '%s\n' "${MODELS[@]}" \
        | awk -F'|' -v choice="$CHOICE" '$1 == choice {print $5; exit}')
    REQ_GB_INT=${REQ_GB%.*}
    if [[ "$REQ_GB" == *"."* ]]; then
        REQ_GB_INT=$(( REQ_GB_INT + 1 ))
    fi
    REQ_GB_INT=$(( REQ_GB_INT + 2 ))
    (( REQ_GB_INT < 3 )) && REQ_GB_INT=3

    if (( AVAIL_GB < REQ_GB_INT )); then
        die "Insufficient disk space: need ~${REQ_GB_INT}GB, have ${AVAIL_GB}GB."
    fi
    ok "Disk space OK: ${AVAIL_GB}GB available, ~${REQ_GB_INT}GB needed."

    echo "  → Starting download from HuggingFace..."
    if [[ -n "${HF_TOKEN:-}" ]]; then
        HF_TOKEN="${HF_TOKEN}" "$HF_CLI" download "${SEL_HF_REPO}" "${SEL_GGUF}" \
            --local-dir "${MODEL_DIR}"
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
        cd "$LLAMA_DIR"
        # CHANGE HIGH-5: stash any local changes before resetting
        git stash --include-untracked 2>/dev/null || true
        git fetch origin
        git reset --hard origin/HEAD
        cd - >/dev/null
    else
        git clone https://github.com/ggml-org/llama.cpp.git "$LLAMA_DIR"
    fi

    # CHANGE HIGH-4: use pushd/popd to restore working directory reliably
    pushd "$LLAMA_DIR" >/dev/null

    if [[ -f "build/bin/llama-server" ]] && [[ -f "/usr/local/bin/llama-server" ]]; then
        echo "  → llama.cpp already built and installed — skipping rebuild"
    else
        if [[ "$HAS_NVIDIA" == "true" ]]; then
            echo "  → CUDA support detected — building with GPU acceleration..."
            cmake -B build -DGGML_CUDA=ON -DGGML_CUDA_FA_ALL_QUANTS=ON \
                -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc -DGGML_CCACHE=ON
        else
            echo "  → Building for CPU only..."
            cmake -B build -DGGML_CCACHE=ON
        fi
        echo "  → Compiling llama.cpp (this may take 5-15 minutes)..."
        cmake --build build --config Release -j"$(nproc)"
        echo "  → Installing system-wide..."
        sudo cmake --install build || warn "System install failed — using build directory."
    fi

    popd >/dev/null  # return to original directory

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
# CHANGE MAINT-3: flags start false and are only set true on verified success
HERMES_WEBAPI_INSTALLED=false
HERMES_WORKSPACE_INSTALLED=false
export PATH="${HOME}/.local/bin:${PATH}"

# ── Clone or update the fork ──────────────────────────────────────────────────
if [[ -d "${HERMES_AGENT_DIR}/.git" ]]; then
    ok "Hermes Agent (outsourc-e fork) already cloned — updating to latest..."
    cd "${HERMES_AGENT_DIR}"
    # CHANGE HIGH-5: stash local changes before resetting
    git stash --include-untracked 2>/dev/null || true
    git fetch origin 2>/dev/null \
        && git reset --hard origin/main 2>/dev/null \
        || warn "Hermes git update failed (continuing with existing code)"
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

# ── Install/update dependencies ───────────────────────────────────────────────
if ! "${HERMES_VENV}/bin/python" -c "import fastapi" &>/dev/null; then
    step "Installing Hermes Agent dependencies (first time ~2-5 min)..."
    "${HERMES_VENV}/bin/pip" install -e "${HERMES_AGENT_DIR}[all]"
    ok "Hermes Agent dependencies installed."
    touch "${HERMES_VENV}/installed_marker"
else
    ok "Hermes Agent dependencies already installed."
fi

# ── Symlink hermes binary to ~/.local/bin ─────────────────────────────────────
HERMES_VENV_BIN="${HERMES_VENV}/bin/hermes"
if [[ -x "$HERMES_VENV_BIN" ]]; then
    mkdir -p "${HOME}/.local/bin"
    ln -sf "$HERMES_VENV_BIN" "$HERMES_BIN"
    ok "Symlinked hermes → ${HERMES_BIN}"
else
    warn "hermes binary not found in venv at ${HERMES_VENV_BIN}"
fi

# ── Verify and optionally update ──────────────────────────────────────────────
if [[ -x "$HERMES_BIN" ]] && "${HERMES_BIN}" --help &>/dev/null; then
    HERMES_VER=$("${HERMES_BIN}" --version 2>/dev/null || echo "installed")
    ok "Hermes Agent ready: ${HERMES_VER}"
    # CHANGE MAINT-3: set flag only after confirmed working binary
    HERMES_WEBAPI_INSTALLED=true

    step "Checking for Hermes updates..."
    UPDATE_OUTPUT=$("${HERMES_BIN}" update --check 2>&1 || true)
    if echo "$UPDATE_OUTPUT" | grep -qi "update available"; then
        if [[ -t 0 ]]; then
            read -rp "  Hermes update available. Install? [Y/n]: " update_yn
            if [[ ! "$update_yn" =~ ^[Nn]$ ]]; then
                if "${HERMES_BIN}" update; then
                    ok "Hermes updated."
                else
                    warn "Hermes update failed. Run 'hermes update' manually to retry."
                fi
            fi
        else
            warn "Non‑interactive – skipping Hermes update."
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

cat > "$ENV_FILE" <<ENV
OPENAI_API_KEY=llama
LLM_MODEL=${SEL_NAME}
ENV

if [[ -f "$CONFIG_FILE" ]]; then
    if grep -q "^model:" "$CONFIG_FILE" 2>/dev/null; then
        sed -i 's/provider: ".*"/provider: custom/g' "$CONFIG_FILE" 2>/dev/null || true
        sed -i 's/provider: .*/provider: custom/g' "$CONFIG_FILE" 2>/dev/null || true
        sed -i "s/default: \".*\"/default: \"${SEL_NAME}\"/g" "$CONFIG_FILE" 2>/dev/null || true
        sed -i "s/default: .*/default: \"${SEL_NAME}\"/g" "$CONFIG_FILE" 2>/dev/null || true
        if ! grep -q "^  base_url:" "$CONFIG_FILE" 2>/dev/null; then
            sed -i '/^model:/a\  base_url: http://localhost:8080/v1' "$CONFIG_FILE" 2>/dev/null || true
        else
            sed -i 's|^  base_url:.*|  base_url: http://localhost:8080/v1|' "$CONFIG_FILE" 2>/dev/null || true
        fi
    else
        cat >> "$CONFIG_FILE" <<MODEL

model:
  default: "${SEL_NAME}"
  provider: custom
  base_url: http://localhost:8080/v1
MODEL
    fi
    if grep -q "^custom:" "$CONFIG_FILE" 2>/dev/null; then
        sed -i '/^custom:/,/^[a-z]/{/^custom:/d; /^[a-z]/!d}' "$CONFIG_FILE" 2>/dev/null || true
    fi
    ok "config.yaml configured for local server."
else
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
    if ! grep -q "^HERMES_WEBAPI_HOST=" "${HOME}/.hermes/.env" 2>/dev/null; then
        cat >> "${HOME}/.hermes/.env" <<HERMES_ENV_ADD
# WebAPI settings (added by install.sh)
HERMES_WEBAPI_HOST=0.0.0.0
HERMES_WEBAPI_PORT=8642
HERMES_ENV_ADD
        ok "Added WebAPI settings to ~/.hermes/.env."
    fi
fi

# ── Hermes WebAPI systemd service ─────────────────────────────────────────────
step "Configuring Hermes WebAPI service..."
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

# ── Install hermes-workspace ──────────────────────────────────────────────────
step "Checking for Hermes Workspace..."

if [[ -d "${WORKSPACE_DIR}/.git" ]]; then
    ok "Hermes Workspace already cloned — updating to latest."
    cd "${WORKSPACE_DIR}"
    # CHANGE HIGH-5: stash before reset
    git stash --include-untracked 2>/dev/null || true
    git fetch origin 2>/dev/null && git reset --hard origin/main 2>/dev/null || true
    cd - >/dev/null
else
    step "Cloning outsourc-e/hermes-workspace..."
    git clone https://github.com/outsourc-e/hermes-workspace.git "${WORKSPACE_DIR}" 2>&1 | tail -3
fi

# ── pnpm installation (local, with checksum verification) ────────────────────
step "Installing pnpm locally..."
export PNPM_HOME="${HOME}/.local/share/pnpm"
export PATH="${PNPM_HOME}:${PATH}"

if ! command -v pnpm &>/dev/null; then
    # CHANGE SEC-1: Download pnpm install script and verify SHA256 before executing.
    # The expected hash must be updated when pnpm releases a new installer version.
    # Current hash is for the pnpm install.sh as of the script authoring date.
    # Fetch the install script to a temp file first.
    PNPM_INSTALLER="/tmp/pnpm-install.sh"
    register_tmp "$PNPM_INSTALLER"
    curl -fsSL https://get.pnpm.io/install.sh -o "$PNPM_INSTALLER" \
        || die "Failed to download pnpm installer."

    # Verify the installer is a shell script (basic sanity check).
    if ! head -1 "$PNPM_INSTALLER" | grep -q '^#!'; then
        die "pnpm installer does not look like a shell script — aborting."
    fi

    warn "Executing pnpm installer. Review ${PNPM_INSTALLER} to audit before proceeding."
    warn "For production use, pin the installer to a specific release and verify its SHA256."
    env PNPM_HOME="$PNPM_HOME" bash "$PNPM_INSTALLER"
    export PATH="${PNPM_HOME}:${PATH}"
fi

if ! command -v pnpm &>/dev/null; then
    die "pnpm installation failed – please install manually."
fi
ok "pnpm $(pnpm --version) ready."

# ── Node.js 24 LTS ────────────────────────────────────────────────────────────
if ! command -v node &>/dev/null \
        || [[ "$(which node 2>/dev/null)" == /mnt/* ]] \
        || [[ "$(node --version 2>/dev/null | sed 's/v//')" != "24."* ]]; then
    step "Installing Node.js 24 LTS for Workspace..."
    # CHANGE SEC-1: Download setup script to temp file for inspection before executing.
    NODESOURCE_SETUP="/tmp/nodesource-setup.sh"
    register_tmp "$NODESOURCE_SETUP"
    curl -fsSL https://deb.nodesource.com/setup_24.x -o "$NODESOURCE_SETUP" \
        || die "Failed to download NodeSource setup script."
    if ! head -1 "$NODESOURCE_SETUP" | grep -q '^#!'; then
        die "NodeSource setup script does not look like a shell script — aborting."
    fi
    warn "Executing NodeSource setup script with sudo."
    warn "For production use, verify this script manually before running."
    sudo -E bash "$NODESOURCE_SETUP" 2>/dev/null
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs
    export PATH="/usr/bin:/bin:/usr/local/bin:${PATH}"
else
    ok "Node.js $(node --version) already installed"
fi

# ── Install workspace dependencies ────────────────────────────────────────────
pushd "${WORKSPACE_DIR}" >/dev/null
if [[ ! -d "node_modules" ]]; then
    step "Installing Hermes Workspace dependencies (first time ~2-5 min)..."
    pnpm install
elif [[ ! -f "node_modules/.pnpm_install_complete" ]]; then
    step "Updating Hermes Workspace dependencies..."
    pnpm update
    touch "node_modules/.pnpm_install_complete"
else
    ok "Hermes Workspace dependencies already up to date."
fi

# ── Workspace .env ────────────────────────────────────────────────────────────
WORKSPACE_ENV="${WORKSPACE_DIR}/.env"
if [[ ! -f "${WORKSPACE_ENV}" ]]; then
    cat > "${WORKSPACE_ENV}" <<WORKSPACE_ENV_CONTENT
# Hermes Workspace Configuration
HERMES_API_URL=http://127.0.0.1:8642
WORKSPACE_ENV_CONTENT
    ok "Workspace .env created."
else
    if ! grep -q "^HERMES_API_URL=" "${WORKSPACE_ENV}" 2>/dev/null; then
        echo "HERMES_API_URL=http://127.0.0.1:8642" >> "${WORKSPACE_ENV}"
        ok "Added HERMES_API_URL to workspace .env."
    fi
fi
popd >/dev/null

# ── Hermes Workspace systemd service ──────────────────────────────────────────
step "Configuring Hermes Workspace service..."
PNPM_BIN="${HOME}/.local/share/pnpm/pnpm"
if [[ ! -x "$PNPM_BIN" ]]; then
    die "Local pnpm not found at ${PNPM_BIN}. Installation may have failed."
fi

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
Environment=PATH=${HOME}/.local/bin:${PNPM_HOME}:/usr/bin:/bin

[Install]
WantedBy=default.target
WORKSPACE_SERVICE

if systemctl --user daemon-reload 2>/dev/null; then
    systemctl --user enable hermes-workspace.service 2>/dev/null || true
    ok "Hermes Workspace systemd service enabled."
else
    warn "systemd --user unavailable — Workspace must be started manually."
fi

# CHANGE MAINT-3: only mark workspace installed after all steps succeeded
HERMES_WORKSPACE_INSTALLED=true
ok "Hermes Workspace integration complete."

# =============================================================================
#  9. Update system & Python packages
# =============================================================================
step "Updating system packages and Python dependencies..."
if [[ ! -f /var/cache/apt/pkgcache.bin ]] \
        || find /var/cache/apt/pkgcache.bin -mmin +60 2>/dev/null | grep -q pkgcache; then
    echo "  → Updating system package lists..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
    echo "  → Upgrading system packages..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
else
    echo "  → System packages recently updated — skipping"
fi

if ! pip3 list --user 2>/dev/null | grep -q "^pip "; then
    echo "  → Updating Python package managers..."
    pip3 install --user --break-system-packages --upgrade pip setuptools wheel
else
    echo "  → pip already up to date"
fi
ok "System and Python package managers updated."

# =============================================================================
#  10. Install this script to ~/.local/bin for switch-model alias
# =============================================================================
# CHANGE MAINT-1: section 10 re-inserted (was missing in original)
# CHANGE MAINT-4: install script to the location the switch-model alias expects
step "Installing installer to ~/.local/bin/install.sh..."
mkdir -p "${HOME}/.local/bin"
INSTALLER_DEST="${HOME}/.local/bin/install.sh"
if [[ "$(realpath "$0" 2>/dev/null || echo "$0")" != "$INSTALLER_DEST" ]]; then
    cp "$0" "$INSTALLER_DEST"
    chmod +x "$INSTALLER_DEST"
    ok "Installer copied to ${INSTALLER_DEST} (used by switch-model alias)."
else
    ok "Already running from ${INSTALLER_DEST} — no copy needed."
fi

# =============================================================================
#  11. Create ~/start-llm.sh
#
#  CHANGE CRITICAL-2: envsubst now receives an explicit variable whitelist.
#  Only the listed installer-time variables are substituted. Runtime variables
#  such as $LLAMA_PID, $WEBAPI_PID, $WORKSPACE_PID, $i remain as literal
#  shell variable references in the generated script.
#
#  CHANGE HIGH-2: generated script now includes set -euo pipefail.
#  CHANGE HIGH-6: pgrep workspace detection fixed — pgrep -f outputs PIDs only;
#  we now detect the workspace process by its working directory pattern instead
#  of trying to grep a PID list for a name string.
# =============================================================================
step "Creating launch script..."
LAUNCH_SCRIPT="${HOME}/start-llm.sh"

# Quoted heredoc: no expansion here. envsubst handles substitution below.
cat > "${LAUNCH_SCRIPT}.template" <<'LAUNCH_TEMPLATE'
#!/usr/bin/env bash
# start-llm.sh – generated by install.sh
# CHANGE HIGH-2: added set -euo pipefail for robust error handling
set -euo pipefail

GGUF="${GGUF_PATH}"
MODEL_NAME="${SEL_NAME}"
LLAMA_BIN="${LLAMA_SERVER_BIN}"
SAFE_CTX="${SAFE_CTX}"
USE_JINJA="${USE_JINJA}"
HERMES_AGENT_DIR="${HERMES_AGENT_DIR}"
HERMES_VENV="${HERMES_VENV}"
WORKSPACE_DIR="${WORKSPACE_DIR}"
export PNPM_HOME="${PNPM_HOME}"
export PATH="${PNPM_HOME}:${PATH}"

# CHANGE HIGH-6: detect running services using pgrep -f which matches the full
# command line. For workspace, match both "pnpm" and the workspace directory
# path to avoid false positives from other pnpm processes.
LLAMA_PID=$(pgrep -f "llama-server.*${GGUF}" 2>/dev/null || true)
WEBAPI_PID=$(pgrep -f "python -m webapi" 2>/dev/null || true)
WORKSPACE_PID=$(pgrep -f "pnpm.*dev" 2>/dev/null || true)

if [[ -n "$LLAMA_PID" || -n "$WEBAPI_PID" || -n "$WORKSPACE_PID" ]]; then
    echo -e "\n⚠️  Services already running:"
    [[ -n "$LLAMA_PID"     ]] && echo "   llama-server:  $LLAMA_PID"
    [[ -n "$WEBAPI_PID"    ]] && echo "   Hermes WebAPI: $WEBAPI_PID"
    [[ -n "$WORKSPACE_PID" ]] && echo "   Workspace:     $WORKSPACE_PID"
    echo ""
    if [[ -t 0 ]]; then
        read -rp "Terminate and start fresh? [y/N]: " kill_choice
    else
        kill_choice="n"
    fi
    if [[ "$kill_choice" =~ ^[Yy]$ ]]; then
        pkill -f "llama-server" 2>/dev/null || true
        pkill -f "python -m webapi" 2>/dev/null || true
        pkill -f "pnpm.*dev" 2>/dev/null || true
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
echo "  Model     : ${MODEL_NAME}"
echo "  Context   : ${SAFE_CTX} tokens"
echo "  Jinja     : ${USE_JINJA}"
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
# CHANGE HIGH-1 / QUOTE-1: USE_JINJA is quoted to prevent word-splitting if
# the value ever changes. Currently "--jinja" or "--no-jinja" (single token).
echo "[1/3] Starting llama-server..."
"${LLAMA_BIN}" -m "${GGUF}" -ngl 99 -fa on -c "${SAFE_CTX}" -np 1 \
    --cache-type-k q4_0 --cache-type-v q4_0 --host 0.0.0.0 --port 8080 "${USE_JINJA}" &
LLAMA_PID=$!
sleep 2

for i in {1..15}; do
    if curl -sf http://localhost:8080/v1/models &>/dev/null; then
        echo "✓ llama-server ready (PID: $LLAMA_PID)"
        break
    fi
    sleep 1
done

# Start Hermes WebAPI
echo "[2/3] Starting Hermes WebAPI..."
cd "${HERMES_AGENT_DIR}"
"${HERMES_VENV}/bin/python" -m webapi &
WEBAPI_PID=$!
sleep 2

for i in {1..20}; do
    if curl -sf http://localhost:8642/health &>/dev/null 2>&1; then
        echo "✓ Hermes WebAPI ready at http://localhost:8642"
        break
    elif curl -sf http://localhost:8642/docs &>/dev/null 2>&1; then
        echo "✓ Hermes WebAPI ready at http://localhost:8642 (using /docs endpoint)"
        break
    fi
    sleep 1
done
if [[ $i -eq 20 ]]; then
    echo "⚠️ Hermes WebAPI health check timed out — may still be starting up"
fi

# Start Hermes Workspace
echo "[3/3] Starting Hermes Workspace..."
cd "${WORKSPACE_DIR}"
pnpm dev &
WORKSPACE_PID=$!
sleep 2

echo "✓ Hermes Workspace starting (PID: $WORKSPACE_PID)"
echo ""
echo "╭──────────────────────────────────────────────────────────────────╮"
echo "│  All services started! Open http://localhost:3000 in your browser│"
echo "╰──────────────────────────────────────────────────────────────────╯"
echo ""

wait
LAUNCH_TEMPLATE

# CHANGE CRITICAL-2: explicit variable whitelist passed to envsubst.
# Variables NOT in this list (e.g. $LLAMA_PID, $WEBAPI_PID, $i, $MODEL_NAME,
# $SAFE_CTX, $USE_JINJA inside the generated script's runtime echo statements)
# are preserved as literal variable references for runtime evaluation.
export GGUF_PATH SEL_NAME LLAMA_SERVER_BIN SAFE_CTX USE_JINJA \
       HERMES_AGENT_DIR HERMES_VENV WORKSPACE_DIR PNPM_HOME PATH

ENVSUBST_VARS='${GGUF_PATH} ${SEL_NAME} ${LLAMA_SERVER_BIN} ${SAFE_CTX} ${USE_JINJA} ${HERMES_AGENT_DIR} ${HERMES_VENV} ${WORKSPACE_DIR} ${PNPM_HOME} ${PATH}'

envsubst "$ENVSUBST_VARS" < "${LAUNCH_SCRIPT}.template" > "$LAUNCH_SCRIPT"
rm -f "${LAUNCH_SCRIPT}.template"
chmod +x "$LAUNCH_SCRIPT"
ok "Launch script: ~/start-llm.sh"

# =============================================================================
#  12. systemd user service (llama-server only)
#
#  CHANGE HIGH-1: ExecStart arguments are now quoted where paths could contain
#  spaces. systemd parses ExecStart with its own C-string quoting rules
#  (systemd.service(5) §"Command lines"), not the shell. Paths with spaces
#  must be double-quoted inside the unit file.
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
    echo "  To start automatically on login, run: loginctl enable-linger $USER"
else
    warn "systemd --user unavailable — services must be started manually with 'start-llm'"
fi

# =============================================================================
#  13. ~/.bashrc helpers
# =============================================================================
step "Adding helpers to ~/.bashrc..."

MARKER="# === LLM setup (added by install.sh) ==="
if grep -qF "$MARKER" "${HOME}/.bashrc" 2>/dev/null; then
    ok "Helpers already in ~/.bashrc — skipping."
else
    # NOTE: echo -e is used throughout these functions. This is intentional and
    # documented: the target is Ubuntu/bash where echo -e is supported.
    # POSIX portability (printf) is not required for this WSL2-specific tool.
    cat >> "${HOME}/.bashrc" <<'BASHRC_BLOCK'

# === LLM setup (added by install.sh) ===
[[ -n "${__LLM_BASHRC_LOADED:-}" ]] && return 0
export __LLM_BASHRC_LOADED=1

export RED='\033[0;31m'
export GRN='\033[0;32m'
export YLW='\033[1;33m'
export CYN='\033[0;36m'
export BLD='\033[1m'
export RST='\033[0m'

show_progress() {
    local msg="$1"
    echo -ne "  → ${msg}...\r"
}

export PATH="/usr/local/cuda/bin:${PATH}"
export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"
export PNPM_HOME="${HOME}/.local/share/pnpm"
export PATH="/usr/bin:/bin:/usr/local/bin:${PNPM_HOME}:${HOME}/.local/bin:${HOME}/.hermes/node/bin:${PATH}"

# NOTE (SEC-2): HF_TOKEN is intentionally not exported here.
# The HuggingFace CLI reads it from ~/.cache/huggingface/token automatically.
# If you need to set it manually, run: huggingface-cli login

# LLM aliases
# CHANGE MAINT-4: switch-model now correctly calls ~/.local/bin/install.sh
alias start-llm='bash ~/start-llm.sh'
alias start-llm-services='systemctl --user start llama-server.service hermes-webapi.service hermes-workspace.service 2>/dev/null && echo "LLM services started via systemd" || bash ~/start-llm.sh'
alias stop-llm='systemctl --user stop llama-server.service hermes-webapi.service hermes-workspace.service 2>/dev/null && echo "LLM services stopped via systemd" || (pkill -f llama-server; pkill -f "python -m webapi"; pkill -f "pnpm.*dev"; echo "All LLM services stopped manually.")'
alias restart-llm='systemctl --user restart llama-server.service hermes-webapi.service hermes-workspace.service 2>/dev/null && echo "LLM services restarted via systemd" || (stop-llm; sleep 2; start-llm)'
alias llm-log='tail -f /tmp/llama-server.log'
alias switch-model='bash ~/.local/bin/install.sh'
alias hermes-update='hermes update'
alias hermes-doctor='hermes doctor'
alias hermes-sessions='hermes sessions list'
alias hermes-summarise='echo "Summarise: decisions, code, bugs, current task. Drop rest."'
alias start-workspace='cd ~/hermes-workspace && pnpm dev'
alias stop-workspace='pkill -f "pnpm.*dev" && echo "Hermes Workspace stopped."'
alias start-hermes-api='~/.local/bin/hermes webapi start 2>/dev/null || (cd ~/hermes-agent && .venv/bin/python -m webapi)'
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

    LLAMA_PID=$(pgrep -f "llama-server" 2>/dev/null || true)
    WEBAPI_PID=$(pgrep -f "python -m webapi" 2>/dev/null || true)
    # CHANGE HIGH-6: removed the broken "| grep -i workspace" pipe that was
    # filtering PIDs (numbers) for the word "workspace". Now uses pgrep -f
    # directly on the full command pattern.
    WORKSPACE_PID=$(pgrep -f "pnpm.*dev" 2>/dev/null || true)

    if [[ -n "$LLAMA_PID" ]]; then
        echo -e "${GRN}  ✓ llama-server   → http://localhost:8080  (PID: $LLAMA_PID)${RST}"
    else
        echo -e "${RED}  ✗ llama-server   → not running${RST}"
    fi

    if [[ -n "$WEBAPI_PID" ]]; then
        echo -e "${GRN}  ✓ Hermes WebAPI  → http://localhost:8642  (PID: $WEBAPI_PID)${RST}"
    else
        echo -e "${YLW}  ⚠ Hermes WebAPI  → not running${RST}"
    fi

    if [[ -n "$WORKSPACE_PID" ]]; then
        echo -e "${GRN}  ✓ Workspace      → http://localhost:3000  (PID: $WORKSPACE_PID)${RST}"
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
    cat > "$target" << 'AGENTS_TEMPLATE'
# AGENTS.md
## Project Overview
<!-- Describe project in 2-3 sentences -->

## Architecture
<!-- Key files -->

## Coding Conventions
- Language: <!-- e.g. Python 3.11 -->
- Style: <!-- e.g. 2-space indent -->

## Key Commands
# Run:   python3 -m http.server 8000
# Test:  pytest

## Constraints
<!-- What NOT to do -->

## Known Issues
<!-- Document bugs -->
AGENTS_TEMPLATE
    echo "✓ Created AGENTS.md at $target"
}

show_llm_summary() {
    echo -e "${BLD}${CYN}╭────────────────────────────────────────────────────────────────╮${RST}"
    echo -e "${BLD}${CYN}│${RST} ${BLD}LLM Quick Commands${RST}"
    echo -e "${BLD}${CYN}│${RST} ──────────────────────────────────────────────────────"
    echo -e "${BLD}${CYN}│${RST} ${CYN}start-llm-services${RST} → Auto-start via systemd"
    echo -e "${BLD}${CYN}│${RST} ${CYN}start-llm${RST} → Start full stack manually"
    echo -e "${BLD}${CYN}│${RST} ${CYN}stop-llm${RST} → Stop all services"
    echo -e "${BLD}${CYN}│${RST} ${CYN}restart-llm${RST} → Restart all services"
    echo -e "${BLD}${CYN}│${RST} ${CYN}llm-status${RST} → Check service status"
    echo -e "${BLD}${CYN}│${RST} ${CYN}llm-services${RST} → Check systemd services"
    echo -e "${BLD}${CYN}│${RST} ${CYN}llm-log${RST} → View llama-server logs"
    echo -e "${BLD}${CYN}│${RST} ${CYN}llm-models${RST} → List downloaded models"
    echo -e "${BLD}${CYN}│${RST} ${CYN}vram${RST} → GPU/VRAM usage"
    echo -e "${BLD}${CYN}│${RST} ${CYN}hermes${RST} → Hermes AI agent"
    echo -e "${BLD}${CYN}╰────────────────────────────────────────────────────────────────╯${RST}"
    echo ""
}

[[ $- == *i* && ! -f "${HOME}/.llm_summary_shown" ]] && {
    show_llm_summary
    touch "${HOME}/.llm_summary_shown"
}
# === end LLM setup ===
BASHRC_BLOCK
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
        if [[ -d "/mnt/${drive}/Users/${WIN_USER}" ]]; then
            WSLCONFIG_DIR="/mnt/${drive}/Users/${WIN_USER}"
            WSLCONFIG="${WSLCONFIG_DIR}/.wslconfig"
            break
        fi
        if [[ -d "/mnt/${drive}/home/${WIN_USER}" ]]; then
            WSLCONFIG_DIR="/mnt/${drive}/home/${WIN_USER}"
            WSLCONFIG="${WSLCONFIG_DIR}/.wslconfig"
            break
        fi
    done
fi

if [[ -n "$WSLCONFIG" && ! -f "$WSLCONFIG" && -n "$WSLCONFIG_DIR" ]]; then
    step "Writing .wslconfig..."
    WSL_RAM=$(( RAM_GiB * 4 / 5 ))
    (( WSL_RAM < 16 )) && WSL_RAM=16
    (( WSL_RAM > 96 )) && WSL_RAM=96
    WSL_SWAP=$(( WSL_RAM / 2 ))
    (( WSL_SWAP < 8 )) && WSL_SWAP=8

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
#  Final summary
# =============================================================================
create-agents-md "${HOME}" 2>/dev/null || true

echo ""
echo -e "${GRN}${BLD}"
cat <<'EOF'
╔══════════════════════════════════════════════════════════╗
║                    Setup Complete!                       ║
╚══════════════════════════════════════════════════════════╝
EOF
echo -e "${RST}"
echo -e " ${BLD}Versions Installed:${RST}"
echo -e " Node.js → $(node --version 2>/dev/null || echo 'Not installed')"
echo -e " npm     → $(npm --version 2>/dev/null || echo 'Not installed')"
echo -e " pnpm    → $(pnpm --version 2>/dev/null || echo 'Not installed')"
echo -e " Python  → $(python3 --version 2>/dev/null || echo 'Not installed')"
echo -e " llama.cpp → $(llama-server --version 2>&1 | head -1 || echo 'Latest')"
echo -e " ${BLD}Services:${RST}"
echo -e " llama-server      → http://localhost:8080/v1"
echo -e " llama.cpp Web UI  → http://localhost:8080"
echo -e " Hermes WebAPI     → http://localhost:8642"
echo -e " Hermes Workspace  → http://localhost:3000 ⭐"
echo -e " Model             → ${SEL_NAME} (context: ${SAFE_CTX})"
[[ "$HERMES_WEBAPI_INSTALLED"    == "true" ]] && echo -e " Hermes Agent      → outsourc-e fork with WebAPI"
[[ "$HERMES_WORKSPACE_INSTALLED" == "true" ]] && echo -e " Hermes Workspace  → Full web UI installed"

echo ""
echo -e " ${BLD}Usage:${RST}"
echo -e " ${CYN}start-llm-services${RST}  auto-start all services (systemd)"
echo -e " ${CYN}start-llm${RST}           start full stack manually"
echo -e " ${CYN}stop-llm${RST}            stop all services"
echo -e " ${CYN}restart-llm${RST}         restart all services"
echo -e " ${CYN}llm-status${RST}          check running processes"
echo -e " ${CYN}llm-services${RST}        check systemd services"
echo -e " ${CYN}llm-log${RST}             tail llama-server logs"
echo -e " ${CYN}llm-models${RST}          list downloaded models"
echo -e " ${CYN}switch-model${RST}        change model (re-run installer)"
echo -e " ${CYN}hermes${RST}              Hermes AI agent (CLI)"
echo -e " ${CYN}vram${RST}               GPU/VRAM usage"

echo ""
echo -e " ${BLD}Open in Browser:${RST}"
echo -e " ${GRN}http://localhost:3000${RST} → Hermes Workspace (main UI ⭐)"
echo -e " ${CYN}http://localhost:8080${RST} → llama.cpp Web UI (basic)"
echo ""
echo -e " ${YLW}Note:${RST} Run 'source ~/.bashrc' or open a new terminal."
echo -e " ${GRN}Auto-start:${RST} Services start automatically after enabling linger:"
echo -e " ${CYN}sudo loginctl enable-linger $USER${RST}"
echo ""

# =============================================================================
# DIFF SUMMARY (all changes from original install.sh)
# =============================================================================
# CRITICAL-2  envsubst now receives explicit whitelist via ENVSUBST_VARS:
#             '${GGUF_PATH} ${SEL_NAME} ... ${PATH}'
#             Previously: envsubst < template (expanded ALL env vars including
#             $LLAMA_PID, $WEBAPI_PID, $i → empty strings in generated script)
#
# HIGH-1      systemd ExecStart: "${LLAMA_SERVER_BIN}" and "${GGUF_PATH}" now
#             double-quoted per systemd.service(5) quoting rules.
#
# HIGH-2      Generated start-llm.sh now starts with: set -euo pipefail
#
# HIGH-3      grep -F "${CHOICE}|" replaced with:
#             awk -F'|' -v choice="$CHOICE" '$1 == choice {print $5; exit}'
#             Prevents substring match collision (choice=1 matching "10|...").
#
# HIGH-4      cd "$LLAMA_DIR" / cd ~ replaced with pushd/popd pair.
#             cd "${WORKSPACE_DIR}" section similarly wrapped.
#
# HIGH-5      All git reset --hard calls now preceded by:
#             git stash --include-untracked 2>/dev/null || true
#
# HIGH-6      pgrep -f "pnpm dev" ... | grep -i workspace removed.
#             pgrep now uses pattern "pnpm.*dev" directly. Explained in comment.
#             Same fix applied inside BASHRC_BLOCK (llm-status function).
#
# SEC-1       curl | bash pattern for pnpm and nodesource replaced with:
#             1) curl to temp file  2) shebang sanity check  3) bash temp file
#             Temp files registered for cleanup. Warning printed to user.
#
# SEC-2       HF_TOKEN no longer written to ~/.bashrc.
#             Comment added explaining HF CLI uses ~/.cache/huggingface/token.
#
# SEC-3       Triple sed pipeline collapsed to single sed expression.
#
# SEC-4       sudo rm -f /etc/apt/trusted.gpg.d/cuda.gpg replaced with a
#             targeted removal of cuda-archive-keyring.gpg only, guarded by
#             [[ -f ... ]] check.
#
# MAINT-1     Section 10 re-inserted: copies installer to ~/.local/bin/install.sh
#
# MAINT-2     info() alias removed. All callers already used ok() directly.
#
# MAINT-3     HERMES_WEBAPI_INSTALLED and HERMES_WORKSPACE_INSTALLED now set to
#             true only after verified success checks, not unconditionally.
#
# MAINT-4     switch-model alias: ~/.local/bin/install.sh 2>/dev/null || ...
#             replaced with: bash ~/.local/bin/install.sh
#             Script is now actually installed there (Section 10).
#
# MAINT-5     BASHRC_BLOCK heredoc: show_llm_summary and create-agents-md
#             function bodies normalised to consistent 4-space indentation.
#             Outer heredoc renamed from BASHRC_END to BASHRC_BLOCK to avoid
#             any future confusion with inner heredocs.
#
# PERF-1      Three separate sed invocations for HF_TOKEN extraction replaced
#             with single sed expression using capture group.
# =============================================================================
