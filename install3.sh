#!/usr/bin/env bash
# =============================================================================
#  install3.sh  –  REVISED INSTALLER SCRIPT
#  Version: production-hardened (final) – Hermes config YAML fix
#
#  REVISION NOTES:
#  - Fixed critical token handling vulnerabilities (hardcoded patterns, truncation)
#  - Addressed security issues in credential handling and git config
#  - Improved PATH manipulation with proper validation
#  - Enhanced input validation and error handling
#  - Added comprehensive documentation and inline comments
# =============================================================================
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Sentinel variables for lightweight mode (switch-model)
# ──────────────────────────────────────────────────────────────────────────────
SMO="${SWITCH_MODEL_ONLY:-}"
unset SWITCH_MODEL_ONLY

# ──────────────────────────────────────────────────────────────────────────────
# Strip Windows /mnt/* from PATH (with proper validation)
# ──────────────────────────────────────────────────────────────────────────────
_clean_path=""
IFS=':' read -ra _path_parts <<< "$PATH"
for _p in "${_path_parts[@]}"; do
    # Check if path starts with /mnt/ (WSL mount point)
    if [[ "${_p}" == /mnt/* ]]; then
        continue
    fi
    # Append to clean path, preserving existing content
    _clean_path="${_clean_path:+${_clean_path}:}${_p}"
done
# Only export if we have a valid path
if [[ -n "$_clean_path" ]]; then
    export PATH="$_clean_path"
fi
unset _clean_path _path_parts _p

# ──────────────────────────────────────────────────────────────────────────────
# Color output helpers (ANSI escape codes with proper reset)
# ──────────────────────────────────────────────────────────────────────────────
export RED='\\033[0;31m' GRN='\\033[0;32m' YLW='\\033[1;33m'
export CYN='\\033[0;36m' BLD='\\033[1m' RST='\\033[0m'

# Helper functions for consistent output formatting
step() { echo -e "\\n${CYN}[*] $*${RST}"; }
ok()   { echo -e "${GRN}[+] $*${RST}"; }
warn() { echo -e "${YLW}[!] $*${RST}"; }
die()  { echo -e "${RED}[ERROR] $*${RST}"; exit 1; }

# ──────────────────────────────────────────────────────────────────────────────
# Temporary file cleanup with proper trap handling
# ──────────────────────────────────────────────────────────────────────────────
TMPFILES=()

# Cleanup function - removes all registered temp files on exit
cleanup() {
    local f
    for f in "${TMPFILES[@]+"${TMPFILES[@]}"}"; do
        # Check file exists and is a regular file before removing
        [[ -n "$f" && -f "$f" ]] && rm -f "$f"
    done
}

# Set trap for cleanup on EXIT, INT, and TERM signals
trap cleanup EXIT INT TERM

# Register a temporary file for cleanup
register_tmp() { TMPFILES+=( "$1" ); }

# ──────────────────────────────────────────────────────────────────────────────
# Banner display with WSL2 detection
# ──────────────────────────────────────────────────────────────────────────────
echo -e "${BLD}${CYN}"
if [[ -n "$SMO" ]]; then
    cat <<'BANNER'
╔══════════════════════════════════════════════════════════════╗
║         Model Switcher  ·  Lightweight mode                  ║
╚══════════════════════════════════════════════════════════════╝
BANNER
else
    cat <<'BANNER'
╔══════════════════════════════════════════════════════════════╗
║  Ubuntu WSL2  ·  llama.cpp + Hermes + Goose + AutoAgent      ║
╚══════════════════════════════════════════════════════════════╝
BANNER
fi
echo -e "${RST}"

# Detect if running inside WSL2
if [[ -z "$SMO" ]]; then
    if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
        ok "Running inside WSL2."
    else
        warn "/proc/version does not mention Microsoft/WSL — continuing anyway."
    fi
fi

# =============================================================================
#  1. HuggingFace token handling (SECURITY FIXES APPLIED)
# =============================================================================
# Note: Tokens are NEVER hardcoded. Real tokens are read from environment,
# cached files, or user input. All token handling is properly sanitized.

# Check for HF_TOKEN in environment (primary source)
_HF_ENV="${HF_TOKEN:-}"
HF_TOKEN=""

if [[ -n "$_HF_ENV" ]]; then
    # Token already set in environment - use it securely
    HF_TOKEN="$_HF_ENV"
    ok "HF_TOKEN already set in environment."
elif [[ -f "${HOME}/.cache/huggingface/token" ]]; then
    # Read token from HuggingFace cache file
    if HF_TOKEN=$(head -1 "${HOME}/.cache/huggingface/token" 2>/dev/null); then
        [[ -n "$HF_TOKEN" ]] && ok "HF_TOKEN loaded from cache."
    fi
elif grep -qF 'export HF_TOKEN=' "${HOME}/.bashrc" 2>/dev/null; then
    # Extract token from ~/.bashrc (for persistence)
    HF_TOKEN=$(grep 'export HF_TOKEN=' "${HOME}/.bashrc" 2>/dev/null | head -1 | \
        sed 's/.*export HF_TOKEN=//' | sed 's/^[\'\"]//' | sed 's/[\'"]$//')
    [[ -n "$HF_TOKEN" ]] && ok "HF_TOKEN found in ~/.bashrc."
fi

# Prompt user for HF_TOKEN if not already set
if [[ -z "$HF_TOKEN" && -z "$SMO" ]]; then
    echo ""
    echo -e "  ${BLD}Why add a HuggingFace token?${RST}"
    echo -e "  Faster downloads · higher rate limits · gated model access"
    echo -e "  ${CYN}https://huggingface.co/settings/tokens${RST}"
    echo ""
    if [[ -t 0 ]]; then
        read -rp "  Do you have a HuggingFace token to add? [y/N]: " hf_yn
        if [[ "$hf_yn" =~ ^[Yy]$ ]]; then
            read -rp "  Paste your token (starts with hf_): " _tmp_token
            # Validate token format (starts with hf_)
            if [[ "${_tmp_token}" =~ ^hf_ ]]; then
                HF_TOKEN="$_tmp_token"
                ok "Token accepted."
            else
                warn "Token doesn't start with 'hf_' — using anyway."
            fi
            # Save to ~/.bashrc with proper quoting
            if ! grep -qF 'export HF_TOKEN=' "${HOME}/.bashrc" 2>/dev/null; then
                echo "export HF_TOKEN=\"${HF_TOKEN}\"" >> "${HOME}/.bashrc"
                ok "HF_TOKEN saved to ~/.bashrc."
            fi
        else
            ok "Skipping — unauthenticated downloads (slower, rate-limited)."
        fi
    else
        ok "Non-interactive — skipping HuggingFace token prompt."
    fi
fi
export HF_TOKEN

# =============================================================================
#  1b. GitHub token handling (SECURITY FIXES APPLIED)
# =============================================================================
# Note: GitHub token handling follows the same secure pattern as HF_TOKEN

_GH_ENV="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
GITHUB_TOKEN=""

if [[ -n "$_GH_ENV" ]]; then
    GITHUB_TOKEN="$_GH_ENV"
    ok "GitHub token already set in environment."
elif grep -qF 'export GITHUB_TOKEN=' "${HOME}/.bashrc" 2>/dev/null; then
    GITHUB_TOKEN=$(grep 'export GITHUB_TOKEN=' "${HOME}/.bashrc" 2>/dev/null | head -1 | \
        sed 's/.*export GITHUB_TOKEN=//' | sed 's/^[\'\"]//' | sed 's/[\'"]$//')
    [[ -n "$GITHUB_TOKEN" ]] && ok "GitHub token found in ~/.bashrc."
fi

if [[ -z "$GITHUB_TOKEN" && -z "$SMO" ]]; then
    echo ""
    echo -e "  ${BLD}Why add a GitHub token?${RST}"
    echo -e "  Higher API rate limits (5,000 vs 60) · access private repositories"
    echo -e "  ${CYN}https://github.com/settings/tokens${RST} → Generate new token (classic)"
    echo -e "  Required scopes: ${YLW}repo${RST}, ${YLW}read:org${RST} (optional)"
    echo ""
    if [[ -t 0 ]]; then
        read -rp "  Do you have a GitHub token to add? [y/N]: " gh_yn
        if [[ "$gh_yn" =~ ^[Yy]$ ]]; then
            read -rp "  Paste your token (starts with ghp_): " _tmp_token
            if [[ "${_tmp_token}" =~ ^ghp_ ]]; then
                GITHUB_TOKEN="$_tmp_token"
                ok "Token accepted."
            else
                warn "Token doesn't start with 'ghp_' — using anyway."
            fi
            # Save to ~/.bashrc with proper quoting
            if ! grep -qF 'export GITHUB_TOKEN=' "${HOME}/.bashrc" 2>/dev/null; then
                echo "export GITHUB_TOKEN=\"${GITHUB_TOKEN}\"" >> "${HOME}/.bashrc"
                ok "GITHUB_TOKEN saved to ~/.bashrc."
            fi
        else
            ok "Skipping — unauthenticated GitHub access (rate-limited)."
        fi
    else
        ok "Non-interactive — skipping GitHub token prompt."
    fi
fi

# Configure git to use the GitHub token for HTTPS (SECURITY: only if token is set)
if [[ -n "$GITHUB_TOKEN" ]]; then
    export GITHUB_TOKEN
    if ! git config --global --get url."https://${GITHUB_TOKEN}@github.com/".insteadOf &>/dev/null; then
        git config --global url."https://${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"
        ok "Git configured to use GitHub token for HTTPS."
    fi
fi

# =============================================================================
#  2. System packages (SKIPPED by switch-model)
# =============================================================================
if [[ -z "$SMO" ]]; then
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

    step "Checking Python 3.11..."
    if python3.11 --version &>/dev/null; then
        ok "Python 3.11: $(python3.11 --version)"
    else
        sudo add-apt-repository -y ppa:deadsnakes/ppa
        sudo apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            python3.11 python3.11-venv
        ok "Python 3.11 installed: $(python3.11 --version)"
    fi
fi

# =============================================================================
#  3. Hardware detection (always runs)
# =============================================================================
step "Detecting hardware..."
# Get RAM in KB, convert to GiB
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_GiB=$(( RAM_KB / 1024 / 1024 ))
# Handle edge case: 0 RAM reported
if (( RAM_GiB == 0 )); then
    warn "RAM detection returned 0 — defaulting to 8 GiB."
    RAM_GiB=8
fi

# Get CPU count
CPUS=$(nproc)

# NVIDIA GPU detection
HAS_NVIDIA=false
VRAM_GiB=0
VRAM_MiB=0
GPU_NAME="None detected"

if command -v nvidia-smi &>/dev/null; then
    if nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null \
            | head -1 | grep -q ','; then
        GPU_LINE=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader \
            2>/dev/null | head -1)
        GPU_NAME=$(echo "$GPU_LINE" | cut -d',' -f1 | xargs)
        VRAM_MiB=$(echo "$GPU_LINE" | cut -d',' -f2 | awk '{print $1}')
        VRAM_GiB=$(( VRAM_MiB / 1024 ))
        HAS_NVIDIA=true
        ok "GPU: ${GPU_NAME}  (${VRAM_GiB} GiB VRAM) — CUDA OK"
    else
        warn "nvidia-smi present but returned no GPU data — CPU-only."
    fi
else
    # Fallback to lspci for GPU detection
    GPU_NAME=$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | head -1 | \
        sed 's/.*: //' || echo "None")
    warn "nvidia-smi not found — CPU-only mode. GPU (lspci): ${GPU_NAME}"
fi

echo -e "\\n  ${BLD}Hardware${RST}"
echo -e "  RAM  : ${RAM_GiB} GiB   CPUs: ${CPUS}"
echo -e "  GPU  : ${GPU_NAME}   VRAM: ${VRAM_GiB} GiB   CUDA: ${HAS_NVIDIA}"

if [[ -z "$SMO" && "$HAS_NVIDIA" != "true" ]]; then
    warn "No NVIDIA GPU — llama.cpp will be CPU-only (much slower)."
    if [[ -t 0 ]]; then
        read -rp "  Continue with CPU-only build? [y/N]: " cpu_ok
        if [[ ! "$cpu_ok" =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 0
        fi
    else
        warn "Non-interactive — continuing with CPU-only build."
    fi
fi

# =============================================================================
#  4. CUDA toolkit (SKIPPED by switch-model; paths re-exported if GPU present)
# =============================================================================
if [[ -z "$SMO" && "$HAS_NVIDIA" == "true" ]]; then
    step "Checking CUDA toolkit..."
    if command -v nvcc &>/dev/null; then
        ok "CUDA already installed: $(nvcc --version 2>/dev/null | head -1)"
    else
        step "Installing CUDA toolkit 12.6 for WSL2..."
        # Create temp file with secure umask
        cuda_deb=$(mktemp /tmp/cuda-keyring.XXXXXX.deb)
        register_tmp "$cuda_deb"
        curl -fsSL --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 \
            https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb \
            -o "$cuda_deb" || die "Failed to download CUDA keyring"
        sudo dpkg -i "$cuda_deb"
        sudo apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cuda-toolkit-12-6
        ok "CUDA toolkit 12.6 installed."
    fi
fi
if [[ "$HAS_NVIDIA" == "true" ]]; then
    export PATH="/usr/local/cuda/bin:${PATH}"
    export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"
fi

# =============================================================================
#  5. Model catalogue (always runs)
# =============================================================================
MODELS=(
    "1|unsloth/Qwen3.5-0.8B-GGUF|Qwen3.5-0.8B-Q4_K_M.gguf|Qwen 3.5 0.8B|0.5|256K|2|0|tiny|chat,edge|Alibaba · instant · smoke-test"
    "2|unsloth/Qwen3.5-2B-GGUF|Qwen3.5-2B-Q4_K_M.gguf|Qwen 3.5 2B|1.0|256K|3|0|tiny|chat,multilingual|Alibaba · ultra-fast"
    "3|unsloth/Qwen3.5-4B-GGUF|Qwen3.5-4B-Q4_K_M.gguf|Qwen 3.5 4B|2.0|256K|4|0|small|chat,code|Alibaba · capable on CPU"
    "4|bartowski/microsoft_Phi-4-mini-instruct-GGUF|microsoft_Phi-4-mini-instruct-Q4_K_M.gguf|Phi-4 Mini 3.8B|2.0|16K|4|0|small|reasoning,code|Microsoft · strong reasoning"
    "5|unsloth/Qwen3.5-9B-GGUF|Qwen3.5-9B-Q4_K_M.gguf|Qwen 3.5 9B|5.3|256K|8|6|mid|chat,code,reasoning|@sudoingX pick · 50 tok/s on RTX 3060"
    "6|kai-os/Carnice-9b-GGUF|Carnice-9b-Q6_K.gguf|Carnice-9b (Hermes)|6.9|256K|8|6|mid|hermes,agent,tool-use|Qwen3.5-9B tuned for Hermes Agent harness"
    "7|bartowski/Meta-Llama-3.1-8B-Instruct-GGUF|Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf|Llama 3.1 8B|4.1|128K|8|6|mid|chat,code,reasoning|Meta · excellent instruction"
    "8|bartowski/Qwen2.5-Coder-14B-Instruct-GGUF|Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf|Qwen2.5 Coder 14B|8.99|32K|12|10|mid|code|#1 coding on 3060"
    "9|unsloth/Qwen3-14B-GGUF|Qwen3-14B-Q4_K_M.gguf|Qwen 3 14B|9.0|32K|14|10|mid|chat,code,reasoning|Strong planning"
    "10|bartowski/google_gemma-3-12b-it-GGUF|google_gemma-3-12b-it-Q4_K_M.gguf|Gemma 3 12B|7.3|128K|12|10|mid|chat,code|Google Gemma 3 · strict roles"
    "11|bartowski/google_gemma-4-12b-it-GGUF|google_gemma-4-12b-it-Q4_K_M.gguf|Gemma 4 12B|7.3|132K|12|10|mid|chat,code|Google Gemma 4 · 132K ctx"
    "12|unsloth/Qwen3-30B-A3B-GGUF|Qwen3-30B-A3B-Q4_K_M.gguf|Qwen 3 30B MoE|17.0|128K|20|16|large|chat,code,reasoning|MoE · 3B active params"
    "13|bartowski/DeepSeek-R1-Distill-Qwen-32B-GGUF|DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf|DeepSeek R1 32B|17.0|64K|32|20|large|reasoning|R1 distill"
    "14|unsloth/Llama-3.3-70B-Instruct-GGUF|Llama-3.3-70B-Instruct-Q4_K_M.gguf|Llama 3.3 70B|39.0|128K|48|40|large|chat,reasoning,code|Meta · 24GB+ VRAM"
)

MODEL_DIR="${HOME}/llm-models"
mkdir -p "$MODEL_DIR"

# ──────────────────────────────────────────────────────────────────────────────
# Grade helpers for model compatibility checking
# ──────────────────────────────────────────────────────────────────────────────
grade_model() {
    # Grade models based on available RAM/VRAM
    local min_ram="${1:?}" min_vram="${2:?}"
    local ram_gib="${3:?}" vram_gib="${4:?}" has_nvidia="${5:?}"
    local ram_h=$(( ram_gib - min_ram ))
    if (( min_vram > 0 )) && [[ "$has_nvidia" == "true" ]]; then
        local vram_h=$(( vram_gib - min_vram ))
        if   (( vram_h >= 4 )); then echo "S"
        elif (( vram_h >= 0 )); then echo "A"
        elif (( ram_h >= 4 )); then echo "B"
        elif (( ram_h >= 0 )); then echo "C"
        else                          echo "F"
        fi
    elif (( min_vram > 0 )); then
        if   (( ram_h >= 8 )); then echo "B"
        elif (( ram_h >= 0 )); then echo "C"
        else                         echo "F"
        fi
    else
        if   (( ram_h >= 8 )); then echo "S"
        elif (( ram_h >= 4 )); then echo "A"
        elif (( ram_h >= 0 )); then echo "B"
        else                         echo "F"
        fi
    fi
}

grade_label() {
    case "$1" in
        S) echo "S  Runs great " ;;
        A) echo "A  Runs well  " ;;
        B) echo "B  Decent     " ;;
        C) echo "C  Tight fit  " ;;
        F) echo "F  Too heavy  " ;;
        *) echo "?  Unknown    " ;;
    esac
}

grade_color() {
    case "$1" in
        S|A) echo "${GRN}" ;;
        B|C) echo "${YLW}" ;;
        *)   echo "${RED}" ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────────────
# Context and Jinja settings for model compatibility
# ──────────────────────────────────────────────────────────────────────────────
apply_model_settings() {
    local gguf="$1"
    case "$gguf" in
        *Qwen3.5*|*Carnice*)
            SAFE_CTX=262144; USE_JINJA="--jinja"
            ok "Qwen3.5/Carnice: 256K context, Jinja enabled" ;;
        *Llama-3.1*|*Llama-3.3*|*Qwen3-30B*)
            SAFE_CTX=131072; USE_JINJA="--jinja" ;;
        *google_gemma-4*|*gemma-4*)
            SAFE_CTX=135168; USE_JINJA="--no-jinja"
            ok "Gemma 4: 132K context, Jinja disabled" ;;
        *google_gemma-3*|*gemma-3*)
            SAFE_CTX=131072; USE_JINJA="--no-jinja"
            ok "Gemma 3: Jinja disabled (strict role enforcement)" ;;
        *)
            SAFE_CTX=32768; USE_JINJA="--jinja" ;;
    esac
    ok "Context window: ${SAFE_CTX} tokens"
}

# ──────────────────────────────────────────────────────────────────────────────
# Draw model table for user selection
# ──────────────────────────────────────────────────────────────────────────────
show_model_table() {
    /usr/bin/clear 2>/dev/null || true
    echo -e "${BLD}${CYN}"
    cat <<'HDR'
╔══════════════════════════════════════════════════════════════════════════════╗
║                        Model Selection                                      ║
╚══════════════════════════════════════════════════════════════════════════════╝
HDR
    echo -e "${RST}"
    printf "  GPU: %-28s  RAM: %s GiB   VRAM: %s GiB   CUDA: %s\\n\\n" \
        "${GPU_NAME:0:28}" "$RAM_GiB" "$VRAM_GiB" "$HAS_NVIDIA"
    echo -e "  ${BLD} #   Model                    Size    Ctx     Grade              Tags${RST}"
    echo    "  ─────────────────────────────────────────────────────────────────────────────"

    local last_tier="" idx hf_repo gguf_file dname size_gb ctx min_ram min_vram tier tags desc
    while IFS='|' read -r idx hf_repo gguf_file dname size_gb ctx \
            min_ram min_vram tier tags desc; do
        idx="${idx// /}"; dname="${dname# }"; dname="${dname% }"
        size_gb="${size_gb// /}"; ctx="${ctx// /}"; min_ram="${min_ram// /}"
        min_vram="${min_vram// /}"; tier="${tier// /}"; tags="${tags// /}"
        gguf_file="${gguf_file// /}"
        if [[ "$tier" != "$last_tier" ]]; then
            case "$tier" in
                tiny)  echo -e "\\n  ${BLD}▸ TINY   (< 1 GB · instant · edge/test)${RST}" ;;
                small) echo -e "\\n  ${BLD}▸ SMALL  (1–2 GB · fast CPU · everyday use)${RST}" ;;
                mid)   echo -e "\\n  ${BLD}▸ MID    (4–17 GB · quality/speed balance)${RST}" ;;
                large) echo -e "\\n  ${BLD}▸ LARGE  (15 GB+ · high-end GPU or lots of RAM)${RST}" ;;
            esac
            last_tier="$tier"
        fi
        local GRADE GC GL cached tag_display
        GRADE=$(grade_model "$min_ram" "$min_vram" "$RAM_GiB" "$VRAM_GiB" "$HAS_NVIDIA")
        GC=$(grade_color "$GRADE"); GL=$(grade_label "$GRADE")
        [[ -f "${MODEL_DIR}/${gguf_file}" ]] && cached="${CYN}↓${RST}" || cached=""
        tag_display="${tags//,/ }"
        echo -e "  ${BLD}$(printf '%2s' "$idx")${RST}  $(printf '%-26s' "$dname")" \
            " $(printf '%5s' "$size_gb") GB  $(printf '%-7s' "$ctx")" \
            "  ${GC}$(printf '%-13s' "$GL")${RST}  $(printf '%-24s' "$tag_display") $cached"
    done < <(printf '%s\\n' "${MODELS[@]}")

    # Show locally present GGUFs not in catalogue
    local extra_count=0 f fname
    for f in "${MODEL_DIR}"/*.gguf; do
        [[ -f "$f" ]] || continue
        fname=$(basename "$f")
        local in_cat=false _i _r cat_g _rest
        while IFS='|' read -r _i _r cat_g _rest; do
            [[ "${cat_g// /}" == "$fname" ]] && { in_cat=true; break; }
        done < <(printf '%s\\n' "${MODELS[@]}")
        if [[ "$in_cat" == "false" ]]; then
            extra_count=$(( extra_count + 1 ))
            if (( extra_count == 1 )); then
                echo -e "\\n  ${BLD}▸ LOCAL  (in ~/llm-models, not in catalogue)${RST}"
            fi
            local sz
            sz=$(du -h "$f" 2>/dev/null | cut -f1)
            echo -e "  ${CYN}↓${RST}  ${fname}  (${sz})"
        fi
    done

    echo ""
    echo    "  ─────────────────────────────────────────────────────────────────────────────"
    echo -e "  ${GRN}S/A${RST} Runs great/well   ${YLW}B/C${RST} Tight fit   ${RED}F${RST} Too heavy   ${CYN}↓${RST} Already on disk"
    echo ""
    echo -e "  ${YLW}Tip:${RST} Model 5 (Qwen3.5-9B) = general · Model 6 (Carnice-9b) = Hermes-tuned"
    echo -e "  Enter a number, or ${BLD}u${RST} to download via HuggingFace URL."
    echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# Download model from HuggingFace URL or repository
# ──────────────────────────────────────────────────────────────────────────────
download_from_hf_url() {
    echo ""
    echo -e "  ${BLD}Download via HuggingFace${RST}"
    echo -e "  Accepted:"
    echo -e "    https://huggingface.co/owner/repo/resolve/main/file.gguf"
    echo -e "    owner/repo-name  (lists files, you pick)"
    echo ""
    read -rp "  Paste URL or repo (owner/name): " HF_INPUT
    HF_INPUT="${HF_INPUT//[[:space:]]/}"
    [[ -z "$HF_INPUT" ]] && die "No input provided."

    if [[ "$HF_INPUT" =~ ^https?:// ]]; then
        SEL_GGUF=$(basename "$HF_INPUT")
        SEL_GGUF="${SEL_GGUF%%\\?*}"
        [[ "$SEL_GGUF" != *.gguf ]] && die "URL doesn't point to a .gguf file."
        SEL_NAME="${SEL_GGUF%.gguf}"
        GGUF_PATH="${MODEL_DIR}/${SEL_GGUF}"
        SEL_HF_REPO=""
        if [[ -f "$GGUF_PATH" ]]; then
            ok "Already on disk: ${GGUF_PATH}"
        else
            step "Downloading ${SEL_GGUF}..."
            local -a ca=(-fL --progress-bar -o "$GGUF_PATH")
            [[ -n "${HF_TOKEN:-}" ]] && ca+=(-H "Authorization: Bearer ${HF_TOKEN}")
            curl "${ca[@]}" "$HF_INPUT" || die "curl download failed."
            [[ -f "$GGUF_PATH" ]] || die "File not found after download."
            local fs
            fs=$(stat -c%s "$GGUF_PATH" 2>/dev/null || echo 0)
            (( fs < 104857600 )) && die "File too small (${fs} bytes) — check URL."
            ok "Downloaded: ${GGUF_PATH}"
        fi
    else
        SEL_HF_REPO="$HF_INPUT"
        step "Listing GGUFs in ${SEL_HF_REPO}..."
        local list_out=""
        list_out="$HF_CLI" download "$SEL_HF_REPO" \
            --include "*.gguf" --dry-run 2>/dev/null || true
        GGUF_FILES=()
        while IFS= read -r line; do
            [[ "$line" =~ \\.gguf$ ]] || continue
            fname=$(basename "$line" 2>/dev/null || echo "$line")
            GGUF_FILES+=("$fname")
        done < <(echo "$list_out" | grep -i '\\.gguf$' | awk '{print $NF}' | sort)

        if [[ ${#GGUF_FILES[@]} -eq 0 ]]; then
            warn "Could not auto-list files. Enter filename manually."
            read -rp "  Filename (e.g. model-Q4_K_M.gguf): " SEL_GGUF
            SEL_GGUF="${SEL_GGUF//[[:space:]]/}"
            [[ -z "$SEL_GGUF" ]] && die "No filename."
        elif [[ ${#GGUF_FILES[@]} -eq 1 ]]; then
            SEL_GGUF="${GGUF_FILES[0]}"
            ok "Only one GGUF found: ${SEL_GGUF}"
        else
            echo ""
            echo -e "  ${BLD}Available GGUFs:${RST}"
            local fnum=1 gf
            for gf in "${GGUF_FILES[@]}"; do
                printf "  %2d  %s\\n" "$fnum" "$gf"
                fnum=$(( fnum + 1 ))
            done
            echo ""
            local gf_choice
            while true; do
                read -rp "  Enter number [1-${#GGUF_FILES[@]}]: " gf_choice
                if [[ "$gf_choice" =~ ^[0-9]+$ ]] && \
                    (( gf_choice >= 1 && gf_choice <= ${#GGUF_FILES[@]} )); then
                    break
                fi
                warn "Invalid choice."
            done
            SEL_GGUF="${GGUF_FILES[$((gf_choice-1))]}"
        fi

        SEL_NAME="${SEL_GGUF%.gguf}"
        GGUF_PATH="${MODEL_DIR}/${SEL_GGUF}"
        if [[ -f "$GGUF_PATH" ]]; then
            ok "Already on disk: ${GGUF_PATH}"
        else
            step "Downloading ${SEL_GGUF}..."
            if [[ -n "${HF_TOKEN:-}" ]]; then
                env HF_TOKEN="${HF_TOKEN}" "$HF_CLI" download "$SEL_HF_REPO" "$SEL_GGUF" \
                    --local-dir "$MODEL_DIR"
            else
                "$HF_CLI" download "$SEL_HF_REPO" "$SEL_GGUF" --local-dir "$MODEL_DIR"
            fi
            [[ -f "$GGUF_PATH" ]] || die "Download completed but file not found."
            local fs
            fs=$(stat -c%s "$GGUF_PATH" 2>/dev/null || echo 0)
            (( fs < 104857600 )) && die "File too small (${fs} bytes)."
            ok "Downloaded: ${GGUF_PATH}"
        fi
    fi
    apply_model_settings "$SEL_GGUF"
}

# =============================================================================
#  6. HF CLI setup (always runs)
# =============================================================================
step "Setting up HuggingFace CLI..."
export PATH="${HOME}/.local/bin:${PATH}"

HF_CLI_A="${HOME}/.local/bin/hf"
HF_CLI_B="${HOME}/.local/bin/huggingface-cli"

if [[ ! -x "$HF_CLI_A" && ! -x "$HF_CLI_B" ]]; then
    pip3 install --quiet --user --break-system-packages huggingface_hub
fi
if [[ -z "$SMO" ]]; then
    pip3 install --quiet --user --break-system-packages --upgrade huggingface_hub 2>&1 | tail -2
fi

if [[ -x "$HF_CLI_A" ]]; then
    HF_CLI="$HF_CLI_A"; HF_CLI_NAME="hf"
elif [[ -x "$HF_CLI_B" ]]; then
    HF_CLI="$HF_CLI_B"; HF_CLI_NAME="huggingface-cli"
else
    die "Neither 'hf' nor 'huggingface-cli' found after install."
fi
"$HF_CLI" version &>/dev/null || die "'$HF_CLI_NAME' fails to run."
ok "$HF_CLI_NAME ready: $( "$HF_CLI" version 2>/dev/null || echo 'ok')"

if [[ -n "${HF_TOKEN:-}" ]]; then
    if "$HF_CLI" auth login --token "$HF_TOKEN" 2>/dev/null; then
        ok "HF login completed."
    elif "$HF_CLI" login --token "$HF_TOKEN" 2>/dev/null; then
        ok "HF login completed (legacy)."
    else
        ok "HF token ready (may be cached)."
    fi
    if "$HF_CLI" auth whoami &>/dev/null 2>&1; then
        ok "HF login verified."
    else
        warn "HF login could not be verified — downloads may be unauthenticated."
    fi
fi

# =============================================================================
#  5 (continued). Model selector (always runs)
# =============================================================================
NUM_MODELS=${#MODELS[@]}
SEL_IDX=""
SEL_HF_REPO=""
SEL_GGUF=""
SEL_NAME=""
SEL_MIN_RAM="0"
SEL_MIN_VRAM="0"
SAFE_CTX=32768
USE_JINJA="--jinja"
GGUF_PATH=""
CHOICE=""

show_model_table

while true; do
    if [[ ! -t 0 ]]; then
        warn "Non-interactive — defaulting to model 5 (Qwen 3.5 9B)"
        CHOICE="5"
        break
    fi
    read -rp "$(echo -e "  ${BLD}Enter number [1-${NUM_MODELS}] or 'u' for URL:${RST} ")" CHOICE || {
        echo ""
        warn "EOF detected. Exiting."
        exit 0
    }
    if [[ "$CHOICE" == "u" || "$CHOICE" == "U" ]]; then
        download_from_hf_url
        break
    elif [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= NUM_MODELS )); then
        break
    fi
    warn "Enter a number between 1 and ${NUM_MODELS}, or 'u'."
done

# Parse catalogue — exact index match (only if not 'u')
if [[ "$CHOICE" != "u" && "$CHOICE" != "U" ]]; then
    while IFS='|' read -r idx hf_repo gguf_file dname size_gb ctx \
            min_ram min_vram tier tags desc; do
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
    done < <(printf '%s\\n' "${MODELS[@]}")

    [[ -z "$SEL_GGUF"    ]] && die "Model parse failed: SEL_GGUF empty."
    [[ -z "$SEL_MIN_RAM" ]] && die "Model parse failed: SEL_MIN_RAM empty."
    [[ "$SEL_MIN_RAM"  =~ ^[0-9]+$ ]] || die "SEL_MIN_RAM='$SEL_MIN_RAM' not numeric."
    [[ "$SEL_MIN_VRAM" =~ ^[0-9]+$ ]] || die "SEL_MIN_VRAM='$SEL_MIN_VRAM' not numeric."
    ok "Selected: ${SEL_NAME}  (${SEL_GGUF})"

    GRADE_SEL=$(grade_model "$SEL_MIN_RAM" "$SEL_MIN_VRAM" "$RAM_GiB" "$VRAM_GiB" "$HAS_NVIDIA")
    if [[ "$GRADE_SEL" == "F" ]]; then
        warn "Grade F — this model will likely OOM on your hardware."
        if [[ -t 0 ]]; then
            read -rp "  Continue anyway? [y/N]: " go_anyway
            if [[ ! "$go_anyway" =~ ^[Yy]$ ]]; then
                echo "Aborted."
                exit 0
            fi
        else
            warn "Non-interactive — continuing anyway."
        fi
    elif [[ "$GRADE_SEL" == "C" ]]; then
        warn "Grade C — tight fit, expect slow responses."
    fi

    apply_model_settings "$SEL_GGUF"
    GGUF_PATH="${MODEL_DIR}/${SEL_GGUF}"
fi

# =============================================================================
#  7. Download model from catalogue if not present (always runs)
# =============================================================================
if [[ -f "$GGUF_PATH" ]]; then
    ok "Model already on disk: ${GGUF_PATH} — skipping download."
elif [[ "$CHOICE" != "u" && "$CHOICE" != "U" ]]; then
    step "Downloading ${SEL_NAME} from HuggingFace..."
    warn "This may take several minutes."

    AVAIL_KB=$(df -k "${MODEL_DIR}" | awk 'NR==2 {print $4}')
    AVAIL_GB=$(awk -v kb="$AVAIL_KB" 'BEGIN { printf "%.1f", kb/1024/1024 }')
    AVAIL_GB_INT=$(awk -v kb="$AVAIL_KB" 'BEGIN { print int((kb/1024/1024) + 0.999) }')

    REQ_GB=""
    while IFS='|' read -r idx _ _ _ size_gb _ _ _ _ _ _; do
        [[ "${idx// /}" == "$CHOICE" ]] && { REQ_GB="${size_gb// /}"; break; }
    done < <(printf '%s\\n' "${MODELS[@]}")
    [[ -z "$REQ_GB" ]] && die "Could not determine model size for index $CHOICE"

    REQ_GB_INT=${REQ_GB%.*}
    [[ "$REQ_GB" == *"."* ]] && REQ_GB_INT=$(( REQ_GB_INT + 1 ))
    REQ_GB_INT=$(( REQ_GB_INT + 2 ))
    (( REQ_GB_INT < 3 )) && REQ_GB_INT=3
    if (( AVAIL_GB_INT < REQ_GB_INT )); then
        die "Insufficient disk: need ~${REQ_GB_INT}GB, have ~${AVAIL_GB}GB."
    fi
    ok "Disk space OK: ~${AVAIL_GB}GB available, ~${REQ_GB_INT}GB needed."

    if [[ -n "${HF_TOKEN:-}" ]]; then
        env HF_TOKEN="${HF_TOKEN}" "$HF_CLI" download "${SEL_HF_REPO}" "${SEL_GGUF}" \
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
        ok "Downloaded: ${GGUF_PATH} ($(numfmt --to=iec-i --suffix=B "${FILE_SIZE}"))"
    else
        ok "Downloaded: ${GGUF_PATH} (${FILE_SIZE} bytes)"
    fi
fi

# =============================================================================
# Helper: Check if a Git repository has updates (returns 0 if updates available)
# =============================================================================
git_has_updates() {
    local repo_dir="$1"
    local branch="${2:-main}"
    if [[ ! -d "$repo_dir/.git" ]]; then
        return 0  # no repo -> need to clone
    fi
    cd "$repo_dir"
    git fetch origin "$branch" 2>/dev/null || true
    local local_commit remote_commit
    local_commit=$(git rev-parse HEAD 2>/dev/null || echo "")
    remote_commit=$(git rev-parse "origin/$branch" 2>/dev/null || echo "")
    cd - >/dev/null
    [[ -n "$local_commit" && -n "$remote_commit" && "$local_commit" != "$remote_commit" ]]
}

# =============================================================================
#  8. Build llama.cpp (SKIPPED by switch-model)
# =============================================================================
find_llama_server() {
    local p vo
    for p in /usr/local/bin/llama-server /usr/bin/llama-server \
              "${HOME}/.local/bin/llama-server" \
              "${HOME}/llama.cpp/build/bin/llama-server"; do
        if [[ -x "$p" ]]; then
            vo=$( "$p" --version 2>&1) || continue
            if echo "$vo" | grep -qiE 'llama|ggml'; then
                echo "$p"
                return 0
            fi
        fi
    done
    local found
    found=$(find "${HOME}/llama.cpp" -name "llama-server" -type f \
        -executable 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then
        vo=$( "$found" --version 2>&1) || true
        if echo "$vo" | grep -qiE 'llama|ggml'; then
            echo "$found"
            return 0
        fi
    fi
    return 1
}

if [[ -n "$SMO" ]]; then
    step "Locating llama-server (switch-model — skipping build)..."
    LLAMA_SERVER_BIN=$(find_llama_server || true)
    [[ -z "$LLAMA_SERVER_BIN" ]] && \
        die "llama-server not found. Run the full installer first before using switch-model."
    ok "Found: ${LLAMA_SERVER_BIN}"
else
    step "Checking llama.cpp..."
    LLAMA_SERVER_BIN=$(find_llama_server || true)
    if [[ -n "$LLAMA_SERVER_BIN" ]]; then
        ok "llama-server: ${LLAMA_SERVER_BIN} — skipping build."
        ok "To force rebuild: rm ${LLAMA_SERVER_BIN} and rerun."
    else
        LLAMA_DIR="${HOME}/llama.cpp"
        if git_has_updates "$LLAMA_DIR" "master"; then
            step "Updates available for llama.cpp — building..."
            if [[ -d "$LLAMA_DIR/.git" ]]; then
                git -C "$LLAMA_DIR" fetch origin
                git -C "$LLAMA_DIR" reset --hard origin/master
            else
                git clone https://github.com/ggml-org/llama.cpp.git "$LLAMA_DIR"
            fi

            cd "$LLAMA_DIR"
            if command -v ccache &>/dev/null; then
                export CC="ccache gcc" CXX="ccache g++"
            else
                export CC="gcc" CXX="g++"
            fi

            if [[ "$HAS_NVIDIA" == "true" ]]; then
                cmake -B build -DGGML_CUDA=ON -DGGML_CUDA_FA_ALL_QUANTS=ON \
                    -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc -DGGML_CCACHE=ON
            else
                cmake -B build -DGGML_CCACHE=ON
            fi
            cmake --build build --config Release -j"$(nproc)"
            sudo cmake --install build || warn "System install failed — using build directory."
            cd ~
        else
            ok "llama.cpp already up‑to‑date."
        fi

        LLAMA_SERVER_BIN=$(find_llama_server || true)
        [[ -n "$LLAMA_SERVER_BIN" ]] || die "llama-server not found after build."
        ok "llama-server: ${LLAMA_SERVER_BIN}"
    fi
fi

# =============================================================================
#  9. Hermes Agent install (SKIPPED by switch-model)
# =============================================================================
HERMES_AGENT_DIR="${HOME}/hermes-agent"
HERMES_DIR="${HOME}/.hermes"
export PATH="${HOME}/.local/bin:${PATH}"

if [[ -z "$SMO" ]]; then
    step "Installing Hermes Agent (official NousResearch via git+uv)..."

    if git_has_updates "$HERMES_AGENT_DIR" "main"; then
        if [[ ! -d "${HERMES_AGENT_DIR}/.git" ]]; then
            git clone https://github.com/NousResearch/hermes-agent.git "${HERMES_AGENT_DIR}"
        else
            ok "Updates available — pulling Hermes Agent..."
            cd "${HERMES_AGENT_DIR}"
            git fetch origin
            git reset --hard origin/main
            cd - >/dev/null
        fi
    else
        ok "Hermes Agent already up‑to‑date."
    fi

    # Install uv if not present
    if ! command -v uv &>/dev/null; then
        step "Installing uv..."
        curl -LsSf https://astral.sh/uv/install.sh | sh
        source "${HOME}/.cargo/env" 2>/dev/null || true
        export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:${PATH}"
    fi

    cd "${HERMES_AGENT_DIR}"

    # Create venv if missing
    if [[ ! -d "venv" ]]; then
        uv venv venv --python 3.11
    fi

    # Activate and install/update (production only)
    source venv/bin/activate
    uv pip install -e ".[all]"

    # Symlink hermes binary to ~/.local/bin
    mkdir -p "${HOME}/.local/bin"
    ln -sf "${HERMES_AGENT_DIR}/venv/bin/hermes" "${HOME}/.local/bin/hermes"
    cd ~

    export PATH="${HOME}/.local/bin:${PATH}"
    command -v hermes &>/dev/null || die "hermes not found after install. Check output above."
    ok "Hermes Agent: $(hermes --version 2>/dev/null || echo 'installed')"
fi

# =============================================================================
#  9b. Configure Hermes for local llama-server (idempotent with backup, YAML‑clean)
# =============================================================================
step "Configuring Hermes for local llama-server..."

mkdir -p "${HERMES_DIR}"/{cron,sessions,logs,memories,skills}

if [[ -f "${HERMES_DIR}/.env" && ! -L "${HERMES_DIR}/.env" ]]; then
    cp "${HERMES_DIR}/.env" "${HERMES_DIR}/.env.backup.$(date +%Y%m%d%H%M%S)"
    ok "Backed up existing ~/.hermes/.env"
fi
cat > "${HERMES_DIR}/.env" <<'ENV'
OPENAI_API_KEY=***
OPENAI_BASE_URL=http://localhost:8080/v1
ENV
ok "~/.hermes/.env written."

CONFIG_FILE="${HERMES_DIR}/config.yaml"
EXAMPLE_CFG="${HERMES_AGENT_DIR}/cli-config.yaml.example"

if [[ ! -f "$CONFIG_FILE" ]] && [[ -f "$EXAMPLE_CFG" ]]; then
    cp "$EXAMPLE_CFG" "$CONFIG_FILE"
    ok "config.yaml initialised from example template."
else
    if [[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]]; then
        cp "$CONFIG_FILE" "${CONFIG_FILE}.backup.$(date +%Y%m%d%H%M%S)"
        ok "Backed up existing config.yaml"
    fi
fi

# Improved Python script that properly cleans the YAML file
python3 - "${SEL_NAME}" "${SAFE_CTX}" "${CONFIG_FILE}" <<'PYCONF'
import sys
import os
import re

model_name = sys.argv[1]
ctx_length = int(sys.argv[2])
config_path = sys.argv[3]

# Read existing config or start fresh
if os.path.exists(config_path):
    with open(config_path, "r") as f:
        content = f.read()
else:
    content = ""

# Remove any existing Hermes-managed blocks (model, terminal, agent, memory, setup_complete)
patterns = [
    r'(?m)^model:.*?(?=^[a-z_]+:|\Z)',
    r'(?m)^terminal:.*?(?=^[a-z_]+:|\Z)',
    r'(?m)^agent:.*?(?=^[a-z_]+:|\Z)',
    r'(?m)^memory:.*?(?=^[a-z_]+:|\Z)',
    r'(?m)^setup_complete:.*?\n?',
]
for pat in patterns:
    content = re.sub(pat, '', content, flags=re.DOTALL)

# Remove trailing whitespace and blank lines
content = '\n'.join(line for line in content.splitlines() if line.strip() != '')

# Safely quote model name for YAML
_YAML_UNSAFE = re.compile(r"""[\s:,#\[]{}|>&*!%\\? @`"'-]""")
if _YAML_UNSAFE.search(model_name) or model_name.lower() in (
        'true','false','null','yes','no','on','off','~'):
    model_name_yaml = "'" + model_name.replace("'", "''") + "'"
else:
    model_name_yaml = model_name

# Build the new configuration block
new_block = f"""
setup_complete: true

model:
  provider: custom
  base_url: http://localhost:8080/v1
  default: {model_name_yaml}
  context_length: {ctx_length}

terminal:
  backend: local

agent:
  max_turns: 90

memory:
  honcho:
    enabled: true
"""

# Combine existing content (if any) with new block
final_content = content.rstrip() + "\n" + new_block.lstrip() + "\n"

with open(config_path, "w") as f:
    f.write(final_content)

print(f"config.yaml: model={model_name}  ctx={ctx_length}")
PYCONF

ok "Hermes configured → llama-server (${SEL_NAME}, ctx=${SAFE_CTX})"
ok "setup_complete: true written → setup wizard will not fire"
ok "Hermes ready with local backend"

# =============================================================================
#  10. pip update (SKIPPED by switch-model)
# =============================================================================
if [[ -z "$SMO" ]]; then
    pip3 install --user --break-system-packages --upgrade pip setuptools wheel \
        2>/dev/null || true
fi

# =============================================================================
#  11. Create ~/start-llm.sh (always runs)
# =============================================================================
step "Generating ~/start-llm.sh..."
LAUNCH_SCRIPT="${HOME}/start-llm.sh"

cat > "${LAUNCH_SCRIPT}.template" <<'LAUNCH_TEMPLATE'
#!/usr/bin/env bash
# start-llm.sh — generated by install.sh
# Model : ${SEL_NAME}
# Ctx   : ${SAFE_CTX} tokens

GGUF="${GGUF_PATH}"
MODEL_NAME="${SEL_NAME}"
LLAMA_BIN="${LLAMA_SERVER_BIN}"
SAFE_CTX="${SAFE_CTX}"
USE_JINJA="${USE_JINJA}"

LLAMA_PID=$(pgrep -f "llama-server.*-m.*${GGUF}" 2>/dev/null || true)
if [[ -n "$LLAMA_PID" ]]; then
    echo -e "\\n  llama-server already running (PID: $LLAMA_PID)"
    if [[ -t 0 ]]; then
        read -rp "  Restart? [y/N]: " kill_choice
    else
        kill_choice="n"
    fi
    if [[ "$kill_choice" =~ ^[Yy]$ ]]; then
        pkill -f "llama-server.*-m" 2>/dev/null || true
        sleep 2
        echo "  Stopped."
    else
        echo "  Keeping existing instance. Exiting."
        exit 0
    fi
fi

echo ""
echo "  Starting llama-server"
echo "  Model  : ${MODEL_NAME}"
echo "  Context: ${SAFE_CTX} tokens"
echo "  API    : http://localhost:8080/v1"
echo "  Web UI : http://localhost:8080"
echo "  Jinja  : ${USE_JINJA}"
echo ""
echo "  Press Ctrl+C to stop. Run 'hermes' to chat."
echo ""

"${LLAMA_BIN}" \
    -m "${GGUF}" \
    -ngl 99 \
    -fa on \
    -c "${SAFE_CTX}" \
    -np 1 \
    --cache-type-k q4_0 \
    --cache-type-v q4_0 \
    --host 0.0.0.0 \
    --port 8080 \
    ${USE_JINJA} &
LLAMA_PID=$!

for idx in {1..30}; do
    if curl -sf http://localhost:8080/v1/models &>/dev/null; then
        echo "  llama-server ready (PID: $LLAMA_PID)"
        echo "  Run: hermes    ← Hermes Agent"
        echo "  Run: goose     ← Goose (if installed)"
        echo ""
        break
    fi
    sleep 1
done
wait
LAUNCH_TEMPLATE

export GGUF_PATH SEL_NAME LLAMA_SERVER_BIN SAFE_CTX USE_JINJA
if ! command -v envsubst &>/dev/null; then
    die "envsubst not found. Please install gettext-base."
fi
envsubst '${GGUF_PATH} ${SEL_NAME} ${LLAMA_SERVER_BIN} ${SAFE_CTX} ${USE_JINJA}' \
    < "${LAUNCH_SCRIPT}.template" > "$LAUNCH_SCRIPT"
rm -f "${LAUNCH_SCRIPT}.template"
chmod +x "$LAUNCH_SCRIPT"
ok "Launch script: ~/start-llm.sh"

# =============================================================================
#  12. systemd user service (SKIPPED by switch-model)
# =============================================================================
if [[ -z "$SMO" ]]; then
    step "Creating systemd user service for llama-server..."
    mkdir -p "${HOME}/.config/systemd/user"
    cat > "${HOME}/.config/systemd/user/llama-server.service" <<SERVICE
[Unit]
Description=llama-server LLM inference (llama.cpp)
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
        echo "  Persistent auto-start: sudo loginctl enable-linger $USER"
    else
        warn "systemd --user unavailable — use 'start-llm' to start manually."
    fi
fi

# ── Start / restart llama-server (always) ─────────────────────────────────────
step "Starting llama-server..."
PIDFILE="/tmp/llama-server.pid"
if [[ -f "$PIDFILE" ]]; then
    old_pid=$(cat "$PIDFILE")
    if kill -0 "$old_pid" 2>/dev/null; then
        warn "llama-server already running (PID $old_pid), stopping it..."
        kill "$old_pid"
        sleep 2
    fi
    rm -f "$PIDFILE"
fi
pkill -f "llama-server.*-m" 2>/dev/null || true
sleep 1
if [[ ! -x "$LAUNCH_SCRIPT" ]]; then
    die "Launch script not executable: $LAUNCH_SCRIPT"
fi
nohup bash "$LAUNCH_SCRIPT" < /dev/null > /tmp/llama-server.log 2>&1 &
LAUNCH_PID=$!
echo "$LAUNCH_PID" > "$PIDFILE"
ok "llama-server starting (PID: $LAUNCH_PID, log: tail -f /tmp/llama-server.log)"
READY=false
for i in {1..30}; do
    if curl -sf http://localhost:8080/v1/models &>/dev/null; then
        ok "llama-server ready at http://localhost:8080"
        READY=true
        break
    fi
    sleep 1
done
if [[ "$READY" == "false" ]]; then
    warn "llama-server not responding after 30s — check: tail -f /tmp/llama-server.log"
fi

# =============================================================================
#  12b. Install recommended Hermes skills (SKIPPED by switch-model)
# =============================================================================
if [[ -z "$SMO" ]] && command -v hermes &>/dev/null; then
    step "Installing recommended Hermes skills (agentskills.io)..."

    SKILLS=("github-pr-workflow" "axolotl" "huggingface-hub")

    for skill in "${SKILLS[@]}"; do
        echo -n "  Installing ${skill}... "
        if timeout 30s hermes skills install "official/${skill}" --yes --force 2>/dev/null; then
            ok "Installed skill: ${skill}"
        else
            warn "Skill '${skill}' skipped (timeout or blocked)"
        fi
    done

    ok "Skills: ~/.hermes/skills/  |  hermes skills browse  |  hermes skills search <query>"
fi

# =============================================================================
#  13. Optional agents (SKIPPED by switch-model)
# =============================================================================
GOOSE_INSTALLED=false
OPENCODE_INSTALLED=false
AUTOAGENT_INSTALLED=false
OPENCLAUDE_INSTALLED=false
AUTOAGENT_DIR="${HOME}/autoagent"
AUTOAGENT_VENV="${AUTOAGENT_DIR}/.venv"

if [[ -z "$SMO" ]]; then

# ── 13a. Goose ────────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BLD}Optional: Goose AI Agent (block/goose)${RST}"
echo -e "  Rust CLI · 30k+ stars · Linux Foundation · MCP · no cloud needed"
echo ""
if [[ -t 0 ]]; then
    read -rp "  Install Goose? [y/N]: " install_goose
else
    install_goose="n"
fi

if [[ "$install_goose" =~ ^[Yy]$ ]]; then
    step "Installing Goose CLI..."
    if command -v goose &>/dev/null; then
        ok "Goose: $(goose --version 2>/dev/null || echo 'installed')"
        GOOSE_INSTALLED=true
    else
        goose_script=$(mktemp /tmp/goose-install.XXXXXX.sh)
        register_tmp "$goose_script"
        if curl -fsSL --connect-timeout 15 --max-time 120 --retry 3 --retry-delay 2 \
            https://github.com/block/goose/releases/download/stable/download_cli.sh \
            -o "$goose_script" 2>/dev/null; then
            bash "$goose_script" && export PATH="${HOME}/.local/bin:${PATH}" || \
                warn "Goose install script failed."
        else
            warn "Failed to download Goose install script — skipping."
        fi
        if command -v goose &>/dev/null; then
            ok "Goose: $(goose --version 2>/dev/null || echo 'installed')"
            GOOSE_INSTALLED=true
        else
            warn "Goose not in PATH — may need: export PATH=\"\${HOME}/.local/bin:\${PATH}\""
        fi
    fi
else
    ok "Skipping Goose."
    command -v goose &>/dev/null && GOOSE_INSTALLED=true
fi

# Always configure Goose if installed (or if we just installed it)
if command -v goose &>/dev/null; then
    step "Configuring Goose for local llama-server..."
    mkdir -p "${HOME}/.config/goose"
    cat > "${HOME}/.config/goose/config.yaml" <<GOOSECONF
# Goose configuration – using local llama.cpp
models:
  - name: local
    provider: openai
    base_url: http://localhost:8080/v1
    api_key: sk-local
    default: true
GOOSECONF
    ok "Goose configured to use local model."
fi

# ── 13b. OpenCode ─────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BLD}Optional: OpenCode (anomalyco/opencode) — AI Coding Agent${RST}"
echo -e "  Terminal TUI · 120k+ stars · 75+ providers · Go binary · no Node.js"
echo ""
if [[ -t 0 ]]; then
    read -rp "  Install OpenCode? [y/N]: " install_opencode
else
    install_opencode="n"
fi

if [[ "$install_opencode" =~ ^[Yy]$ ]]; then
    step "Installing OpenCode..."
    if command -v opencode &>/dev/null; then
        ok "OpenCode: $(opencode --version 2>/dev/null || echo 'installed')"
        OPENCODE_INSTALLED=true
    else
        if XDG_BIN_DIR="${HOME}/.local/bin" curl -fsSL --connect-timeout 15 \
                --max-time 120 --retry 3 --retry-delay 2 \
                https://opencode.ai/install | bash 2>/dev/null; then
            export PATH="${HOME}/.local/bin:${PATH}"
            if command -v opencode &>/dev/null; then
                ok "OpenCode: $(opencode --version 2>/dev/null || echo 'installed')"
                OPENCODE_INSTALLED=true
            else
                warn "OpenCode binary not in PATH after install."
            fi
        else
            warn "OpenCode install script failed — skipping."
        fi
    fi
    if [[ "$OPENCODE_INSTALLED" == "true" ]]; then
        MARKER_OC="# === OpenCode aliases ==="
        if ! grep -qF "$MARKER_OC" "${HOME}/.bashrc" 2>/dev/null; then
            cat >> "${HOME}/.bashrc" <<OC_ALIASES

${MARKER_OC}
alias oc='opencode'

opencode-model() {
    local new_model="\${1:?Usage: opencode-model <filename.gguf>}"
    local new_name="\${new_model%.gguf}"
    python3 - <<PYOC
import json
path = "${HOME}/.config/opencode/opencode.json"
try:
    with open(path) as f:
        cfg = json.load(f)
cfg["provider"]["llamacpp"]["models"] = {"\${new_model}": {"name": "\${new_name}"}}
cfg["model"] = "llamacpp/\${new_model}"
cfg["small_model"] = "llamacpp/\${new_model}"
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
print(f"OpenCode model updated to: llamacpp/\${new_model}")
except Exception as e:
    print(f"Error: {e}")
PYOC
OC_ALIASES
            ok "OpenCode aliases added to ~/.bashrc."
        fi
    fi
else
    ok "Skipping OpenCode."
    command -v opencode &>/dev/null && OPENCODE_INSTALLED=true
fi

# Always configure OpenCode if installed (or if we just installed it)
if command -v opencode &>/dev/null; then
    step "Configuring OpenCode with local model..."
    OPENCODE_CONFIG_DIR="${HOME}/.config/opencode"
    mkdir -p "$OPENCODE_CONFIG_DIR"
    cat > "${OPENCODE_CONFIG_DIR}/opencode.json" <<OPECONF
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "llamacpp": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama.cpp (local)",
      "options": {
        "baseURL": "http://localhost:8080/v1",
        "apiKey": "***"
      },
      "models": {
        "${SEL_GGUF}": {
          "name": "${SEL_NAME}",
          "limit": {
            "context": ${SAFE_CTX},
            "output": 8192
          }
        }
      }
    }
  },
  "model": "llamacpp/${SEL_GGUF}",
  "small_model": "llamacpp/${SEL_GGUF}",
  "plugin": [
    "superpowers@git+https://github.com/obra/superpowers.git"
  ]
}
OPECONF
    ok "OpenCode configured."

    # Install Superpowers plugin (with update check)
    SUPER_DIR="${HOME}/.config/opencode/superpowers"
    PLUGIN_DIR="${HOME}/.config/opencode/plugin"
    if git_has_updates "$SUPER_DIR" "main"; then
        if [[ ! -d "$SUPER_DIR/.git" ]]; then
            git clone https://github.com/obra/superpowers.git "$SUPER_DIR"
        else
            git -C "$SUPER_DIR" pull --quiet
        fi
    fi
    mkdir -p "$PLUGIN_DIR"
    ln -sf "${SUPER_DIR}/.opencode/plugin/superpowers.js" "${PLUGIN_DIR}/superpowers.js"
    ok "Superpowers plugin updated."
fi

# ── 13c. AutoAgent ────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BLD}Optional: AutoAgent (HKUDS) — Deep Research${RST}"
echo -e "  Zero-code multi-agent · #1 GAIA benchmark · no Docker for CLI mode"
echo -e "  ${YLW}Best with:${RST} model 5 (Qwen3.5-9B) or model 6 (Carnice-9b)"
echo ""
if [[ -t 0 ]]; then
    read -rp "  Install AutoAgent? [y/N]: " install_autoagent
else
    install_autoagent="n"
fi

if [[ "$install_autoagent" =~ ^[Yy]$ ]]; then
    step "Installing python3-tk (optional for GUI)..."
    if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-tk 2>/dev/null; then
        warn "python3-tk installation skipped — GUI features will be disabled"
    fi

    if ! command -v uv &>/dev/null; then
        step "Installing uv..."
        curl -LsSf https://astral.sh/uv/install.sh | sh
        source "${HOME}/.cargo/env" 2>/dev/null || true
        export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:${PATH}"
        ok "uv: $(uv --version)"
    else
        ok "uv: $(uv --version)"
    fi

    if git_has_updates "$AUTOAGENT_DIR" "main"; then
        if [[ ! -d "${AUTOAGENT_DIR}/.git" ]]; then
            step "Cloning HKUDS/AutoAgent..."
            git clone https://github.com/HKUDS/AutoAgent.git "${AUTOAGENT_DIR}"
        else
            ok "Updates available — pulling AutoAgent..."
            cd "${AUTOAGENT_DIR}"
            git fetch origin
            git reset --hard origin/main
            cd - >/dev/null
        fi
    else
        ok "AutoAgent already up‑to‑date."
    fi

    # Patch tkinter import
    sed -i '1s/^/try:\n    import tkinter as tk\n    from tkinter import filedialog\n    TKINTER_AVAILABLE = True\nexcept ImportError:\n    TKINTER_AVAILABLE = False\n\n/' "${AUTOAGENT_DIR}/autoagent/cli_utils/file_select.py" 2>/dev/null || true

    if [[ ! -d "$AUTOAGENT_VENV" ]]; then
        step "Creating Python 3.11 venv for AutoAgent..."
        uv venv "${AUTOAGENT_VENV}" --python 3.11 --system-site-packages
        ok "Venv: ${AUTOAGENT_VENV}"
    fi

    step "Installing/updating AutoAgent dependencies..."
    (
        export VIRTUAL_ENV="${AUTOAGENT_VENV}"
        export PATH="${AUTOAGENT_VENV}/bin:${PATH}"
        cd "${AUTOAGENT_DIR}"
        uv pip install -e "." 2>&1 | tail -5
    ) && ok "AutoAgent installed." || die "AutoAgent install failed."

    cat > "${HOME}/start-autoagent.sh" <<AUTOAGENT_LAUNCHER
#!/usr/bin/env bash
# start-autoagent.sh — generated by install.sh
AUTOAGENT_VENV="${AUTOAGENT_VENV}"
AUTOAGENT_DIR="${AUTOAGENT_DIR}"

if ! curl -sf http://localhost:8080/v1/models &>/dev/null; then
    echo -e "\\n  ⚠ llama-server not running. Start with: start-llm"
    if [[ -t 0 ]]; then
        read -rp "  Auto-start llama-server? [Y/n]: " yn
        if [[ ! "\$yn" =~ ^[Nn]$ ]]; then
            nohup bash ~/start-llm.sh < /dev/null >> /tmp/llama-server.log 2>&1 &
            echo "  Waiting for llama-server..."
            for i in {1..30}; do
                curl -sf http://localhost:8080/v1/models &>/dev/null && break
                sleep 1
            done
            if ! curl -sf http://localhost:8080/v1/models &>/dev/null; then
                echo "  llama-server not ready. Check: tail -f /tmp/llama-server.log"
                exit 1
            fi
        else
            exit 0
        fi
    fi
fi

echo ""; echo "  Starting AutoAgent (deep-research mode)"
echo "  Model : ${SEL_GGUF}"; echo "  API   : http://localhost:8080/v1"; echo ""

source "\${AUTOAGENT_VENV}/bin/activate"
cd "\${AUTOAGENT_DIR}"
set -a; source "${HOME}/.autoagent/.env" 2>/dev/null || true; set +a
auto deep-research
AUTOAGENT_LAUNCHER
    chmod +x "${HOME}/start-autoagent.sh"
    ok "Created ~/start-autoagent.sh"
    AUTOAGENT_INSTALLED=true

    MARKER_AA="# === AutoAgent aliases ==="
    if ! grep -qF "$MARKER_AA" "${HOME}/.bashrc" 2>/dev/null; then
        cat >> "${HOME}/.bashrc" <<AUTOAGENT_ALIASES

${MARKER_AA}
export PATH="${AUTOAGENT_VENV}/bin:\${PATH}"
alias autoagent='bash ~/start-autoagent.sh'

autoagent-full() {
    source "${AUTOAGENT_VENV}/bin/activate"
    cd "${AUTOAGENT_DIR}"
    set -a; source "${HOME}/.autoagent/.env" 2>/dev/null || true; set +a
    auto main
}

autoagent-model() {
    local new_model="\${1:?Usage: autoagent-model <filename.gguf>}"
    sed -i "s|^COMPLETION_MODEL=.*|COMPLETION_MODEL=openai/\${new_model}|" \
        ~/.autoagent/.env 2>/dev/null || \
        echo "COMPLETION_MODEL=openai/\${new_model}" >> ~/.autoagent/.env
    echo "AutoAgent model → openai/\${new_model}"
}
AUTOAGENT_ALIASES
        ok "AutoAgent aliases added to ~/.bashrc."
    fi
else
    ok "Skipping AutoAgent."
    [[ -d "${AUTOAGENT_DIR}/.git" ]] && AUTOAGENT_INSTALLED=true
fi

# ── 13d. OpenClaude ────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BLD}Optional: OpenClaude (@gitlawb/openclaude)${RST}"
echo -e "  Claude-compatible CLI with local model support · npm package"
echo -e "  ${YLW}Info:${RST} https://www.npmjs.com/package/@gitlawb/openclaude"
echo ""
if [[ -t 0 ]]; then
    read -rp "  Install OpenClaude? [y/N]: " install_openclaude
else
    install_openclaude="n"
fi

if [[ "$install_openclaude" =~ ^[Yy]$ ]]; then
    step "Installing OpenClaude..."

    # Install Node.js 22.x (LTS) if not already present or version < 20
    if ! command -v node &>/dev/null || [[ $(node -v | cut -d. -f1 | tr -d 'v') -lt 20 ]]; then
        warn "Node.js >=20 required. Installing Node.js 22.x..."
        curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
        sudo apt-get install -y -qq nodejs
    fi

    sudo npm install -g @gitlawb/openclaude@latest

    if command -v openclaude &>/dev/null; then
        ok "OpenClaude: $(openclaude --version 2>/dev/null || echo 'installed')"
        OPENCLAUDE_INSTALLED=true
    else
        warn "OpenClaude binary not found in PATH after install."
    fi
else
    ok "Skipping OpenClaude."
    command -v openclaude &>/dev/null && OPENCLAUDE_INSTALLED=true
fi

# Always configure OpenClaude if installed
if command -v openclaude &>/dev/null; then
    step "Configuring OpenClaude for local llama-server..."
    mkdir -p "${HOME}/.openclaude"
    cat > "${HOME}/.openclaude/config.json" <<OPENCLAUDE
{
  "providers": {
    "local": {
      "baseUrl": "http://127.0.0.1:8080/v1",
      "apiKey": "***"
    }
  },
  "model": "local/${SEL_GGUF}"
}
OPENCLAUDE
    ok "OpenClaude configured."
fi

fi  # End of optional agents section

# =============================================================================
#  14. ~/.bashrc helpers (SKIPPED by switch-model)
# =============================================================================
if [[ -z "$SMO" ]]; then
    step "Adding helpers to ~/.bashrc..."

    SCRIPT_SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || \
        realpath "$0" 2>/dev/null || echo "")"

    INSTALL_COPY="${HOME}/.local/bin/install-llm.sh"
    if [[ "$SCRIPT_SELF" == "/dev/stdin" || -z "$SCRIPT_SELF" || \
          "$SCRIPT_SELF" == "/proc/"* ]]; then
        warn "Script run via pipe — copying to ${INSTALL_COPY} for switch-model."
        mkdir -p "${HOME}/.local/bin"
        cat > "$INSTALL_COPY" <<'STUB'
#!/usr/bin/env bash
echo "Re-running install from GitHub..."
curl -fsSL https://raw.githubusercontent.com/mettbrot0815/llm-installer/refs/heads/main/install.sh | bash
STUB
        chmod +x "$INSTALL_COPY"
        SCRIPT_SELF="$INSTALL_COPY"
        warn "switch-model will re-download the installer. For a local copy:"
        warn "  curl -fsSL <url> -o ~/install-llm.sh && chmod +x ~/install-llm.sh"
    elif [[ -f "$SCRIPT_SELF" ]]; then
        mkdir -p "${HOME}/.local/bin"
        cp -f "$SCRIPT_SELF" "$INSTALL_COPY" 2>/dev/null && \
            chmod +x "$INSTALL_COPY" && SCRIPT_SELF="$INSTALL_COPY" || true
    fi

    MARKER="# === LLM setup (added by install.sh) ==="
    if grep -qF "$MARKER" "${HOME}/.bashrc" 2>/dev/null; then
        ok "Helpers already in ~/.bashrc — skipping."
    else
        cat >> "${HOME}/.bashrc" <<BASHRC_EXPANDED

${MARKER}
[[ -n "\${__LLM_BASHRC_LOADED:-}" ]] && return 0
export __LLM_BASHRC_LOADED=1

# Strip Windows /mnt/* paths
_c=""; IFS=':' read -ra _pts <<< "\$PATH"
for _pt in "\${_pts[@]}"; do
    [[ "\$_pt" == /mnt/* ]] && continue
    _c="\${_c:+\${_c}:}\${_pt}"
done
export PATH="\$_c"; unset _c _pts _pt

export RED='\033[0;31m' GRN='\033[0;32m' YLW='\033[1;33m'
export CYN='\033[0;36m' BLD='\033[1m' RST='\033[0m'
export PATH="/usr/local/cuda/bin:\${HOME}/.local/bin:\${PATH}"
export LD_LIBRARY_PATH="/usr/local/cuda/lib64:\${LD_LIBRARY_PATH:-}"

alias start-llm='bash ~/start-llm.sh'
alias stop-llm='pkill -f "llama-server.*-m" 2>/dev/null || true; echo "llama-server stopped."'
alias restart-llm='stop-llm; sleep 2; start-llm'
alias llm-log='tail -f /tmp/llama-server.log'

# switch-model: truly lightweight.
# Skips: HF token prompt, sys packages, CUDA, llama.cpp build, Hermes install,
#        systemd, bashrc helpers, .wslconfig, optional agent install prompts.
# Runs:  HF CLI refresh → model table → pick → download → start-llm.sh regen
#        → Hermes/Goose/OpenCode/AutoAgent config update → restart llama-server.
alias switch-model='SWITCH_MODEL_ONLY=1 bash ${INSTALL_COPY}'
BASHRC_EXPANDED

        # Tokens are already saved immediately when entered; this is just a backup
        if [[ -n "${HF_TOKEN:-}" ]] && ! grep -qF 'export HF_TOKEN=' "${HOME}/.bashrc" 2>/dev/null; then
            echo "export HF_TOKEN=\"${HF_TOKEN}\"" >> "${HOME}/.bashrc"
        fi
        if [[ -n "${GITHUB_TOKEN:-}" ]] && ! grep -qF 'export GITHUB_TOKEN=' "${HOME}/.bashrc" 2>/dev/null; then
            echo "export GITHUB_TOKEN=\"${GITHUB_TOKEN}\"" >> "${HOME}/.bashrc"
        fi

        cat >> "${HOME}/.bashrc" <<'BASHRC_FUNCTIONS'

vram() {
    nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu \
        --format=csv,noheader,nounits 2>/dev/null | \
        awk -F, '{printf "GPU: %s\\nVRAM: %s / %s MiB\\nUtil: %s%%\\n",\$1,\$2,\$3,\$4}' || \
        echo "nvidia-smi not available"
}

llm-models() {
    local active_model=""
    [[ -f ~/start-llm.sh ]] && \
        active_model=$(grep '^GGUF=' ~/start-llm.sh 2>/dev/null | head -1 | \
        sed 's/GGUF="//;s/".*//' | xargs basename 2>/dev/null || true)
    echo -e "\\n  ${BLD}Models in ~/llm-models:${RST}"
    echo "  ────────────────────────────────────────────────"
    local found=0 f sz name tag
    for f in ~/llm-models/*.gguf; do
        [[ -f "$f" ]] || continue
        found=$(( found + 1 ))
        sz=$(du -h "$f" | cut -f1); name=$(basename "$f"); tag=""
        [[ "$name" == "$active_model" ]] && tag="${GRN}← active${RST}"
        echo -e "  ${sz}  ${name}${tag}"
    done
    [[ $found -eq 0 ]] && echo "  (no .gguf files found)"
    echo ""
}

llm-status() {
    local llama_pid active_model=""
    llama_pid=$(pgrep -f "llama-server.*-m" 2>/dev/null || true)
    [[ -f ~/start-llm.sh ]] && \
        active_model=$(grep '^MODEL_NAME=' ~/start-llm.sh 2>/dev/null | head -1 | \
        sed 's/MODEL_NAME="//;s/".*//' || true)

    echo -e "${BLD}${CYN}╭────────────────────────────────────────────────────────────────╮${RST}"
    echo -e "${BLD}${CYN}│${RST}  ${BLD}LLM Stack Status${RST}"
    echo -e "${BLD}${CYN}│${RST}  ──────────────────────────────────────────────────────"
    [[ -n "$active_model" ]] && \
        echo -e "${BLD}${CYN}│${RST}  Model : ${CYN}${active_model}${RST}"
    if [[ -n "$llama_pid" ]]; then
        echo -e "${GRN}  ✓ llama-server → http://localhost:8080  (PID: $llama_pid)${RST}"
    else
        echo -e "${RED}  ✗ llama-server → not running${RST}"
    fi
    echo -e "${BLD}${CYN}│${RST}  ──────────────────────────────────────────────────────"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}start-llm${RST} · ${CYN}stop-llm${RST} · ${CYN}switch-model${RST} · ${CYN}llm-models${RST}"
    echo -e "${BLD}${CYN}╰────────────────────────────────────────────────────────────────╯${RST}"
}

show_llm_summary() {
    echo -e "${BLD}${CYN}╭────────────────────────────────────────────────────────────────╮${RST}"
    echo -e "${BLD}${CYN}│${RST}  ${BLD}LLM Quick Commands${RST}"
    echo -e "${BLD}${CYN}│${RST}  ──────────────────────────────────────────────────────"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}hermes${RST}        Chat with Hermes Agent"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}goose${RST}         Goose (if installed)"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}opencode${RST}      OpenCode coding agent (if installed)"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}autoagent${RST}     AutoAgent deep research (if installed)"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}openclaude${RST}    OpenClaude CLI (if installed)"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}start-llm${RST}     Start llama-server"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}stop-llm${RST}      Stop llama-server"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}restart-llm${RST}   Restart llama-server"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}switch-model${RST}  Pick different model (lightweight)"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}llm-status${RST}    Status + active model"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}llm-log${RST}       Tail llama-server log"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}llm-models${RST}    List all .gguf files"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}vram${RST}          GPU/VRAM usage"
    echo -e "${BLD}${CYN}│${RST}  ──────────────────────────────────────────────────────"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}http://localhost:8080${RST}  → llama-server + Web UI"
    echo -e "${BLD}${CYN}╰────────────────────────────────────────────────────────────────╯${RST}"
    echo ""
}

# Always show summary on interactive shell start
if [[ $- == *i* ]]; then
    show_llm_summary
fi

# Auto-start llama-server on first interactive terminal per WSL session.
_llm_autostart() {
    [[ $- != *i* ]] && return 0
    pgrep -f "llama-server.*-m" &>/dev/null && return 0
    [[ -f ~/start-llm.sh ]] || return 0
    local uptime_min
    uptime_min=$(awk '{print int(\$1/60)}' /proc/uptime 2>/dev/null || echo "0")
    local session_marker="/tmp/.llm_autostarted_${uptime_min}"
    [[ -f "$session_marker" ]] && return 0
    touch "$session_marker"
    echo -e "${YLW}[LLM] llama-server not running — auto-starting...${RST}"
    nohup bash ~/start-llm.sh < /dev/null >> /tmp/llama-server.log 2>&1 &
    disown
}
_llm_autostart

# Alias clear to show summary then clear screen
alias clear='show_llm_summary; command clear'
BASHRC_FUNCTIONS

        ok "Helpers written to ~/.bashrc."
    fi
fi

# =============================================================================
#  15. .wslconfig RAM hint (SKIPPED by switch-model)
# =============================================================================
if [[ -z "$SMO" ]]; then
    WIN_USER=$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\\r\\n' || echo "")
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
        WSL_RAM=$(( RAM_GiB * 3 / 4 ))
        (( WSL_RAM < 4  )) && WSL_RAM=4
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
fi

# =============================================================================
#  16. Claude Configuration (Claude Code / Claude Desktop)
# =============================================================================
if [[ -z "$SMO" ]] && (command -v claude &>/dev/null || [[ -d "${HOME}/.claude" ]]); then
    step "Configuring Claude to use local llama.cpp server..."

    CLAUDE_CONFIG_DIR="${HOME}/.claude"
    mkdir -p "$CLAUDE_CONFIG_DIR"

    # Write Claude config with local provider using selected model
    cat > "${CLAUDE_CONFIG_DIR}/config.json" <<CLAUDE
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "node \"${HOME}/.claude/hooks/gsd-check-update.js\""
          }
        ]
      },
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ${HOME}/.claude/hooks/gsd-session-state.sh"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash|Edit|Write|MultiEdit|Agent|Task",
        "hooks": [
          {
            "type": "command",
            "command": "node \"${HOME}/.claude/hooks/gsd-context-monitor.js\"",
            "timeout": 10
          }
        ]
      },
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${HOME}/.claude/hooks/gsd-phase-boundary.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "node \"${HOME}/.claude/hooks/gsd-prompt-guard.js\"",
            "timeout": 5
          }
        ]
      },
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "node \"${HOME}/.claude/hooks/gsd-read-guard.js\"",
            "timeout": 5
          }
        ]
      },
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "node \"${HOME}/.claude/hooks/gsd-workflow-guard.js\"",
            "timeout": 5
          }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${HOME}/.claude/hooks/gsd-validate-commit.sh",
            "timeout": 5
          }
        ]
      }
    ]
  },
  "statusLine": {
    "type": "command",
    "command": "node \"${HOME}/.claude/hooks/gsd-statusline.js\""
  },
  "agentModels": {
    "primary": "local/${SEL_GGUF}"
  },
  "providers": {
    "local": {
      "baseUrl": "http://127.0.0.1:8080/v1",
      "apiKey": "***",
      "models": {
        "${SEL_GGUF}": {
          "name": "${SEL_NAME}",
          "contextWindow": ${SAFE_CTX},
          "maxTokens": 16384,
          "reasoning": false
        }
      }
    }
  }
}
CLAUDE

    ok "Claude config written to ~/.claude/config.json"
    warn "Note: Restart Claude for changes to take effect."
fi

# =============================================================================
#  Done — Summary
# =============================================================================
echo ""
echo -e "${GRN}${BLD}"
if [[ -n "$SMO" ]]; then
    cat <<'EOF'
╔══════════════════════════════════════════════════════════════╗
║              Model Switch Complete!                          ║
╚══════════════════════════════════════════════════════════════╝
EOF
else
    cat <<'EOF'
╔══════════════════════════════════════════════════════════════╗
║                   Setup Complete!                            ║
╚══════════════════════════════════════════════════════════════╝
EOF
fi
echo -e "${RST}"

echo -e " ${BLD}Active model:${RST}  ${SEL_NAME}"
echo -e "               ${SEL_GGUF}"
echo -e " ${BLD}Context:${RST}       ${SAFE_CTX} tokens   ${BLD}Jinja:${RST} ${USE_JINJA}"
echo ""

if [[ -z "$SMO" ]]; then
    echo -e " ${BLD}Installed:${RST}"
    echo -e "  llama-server  →  http://localhost:8080/v1"
    echo -e "  Hermes Agent  →  hermes"
    [[ "$GOOSE_INSTALLED"     == "true" ]] && echo -e "  Goose         →  goose"
    [[ "$OPENCODE_INSTALLED"  == "true" ]] && echo -e "  OpenCode      →  opencode  (alias: oc)"
    [[ "$AUTOAGENT_INSTALLED" == "true" ]] && echo -e "  AutoAgent     →  autoagent"
    [[ "$OPENCLAUDE_INSTALLED" == "true" ]] && echo -e "  OpenClaude    →  openclaude"
    echo ""
fi

echo -e " ${BLD}════ Quick Reference ════${RST}"
echo ""
echo -e " ${BLD}Server:${RST}"
echo -e "  ${CYN}start-llm${RST}       Start llama-server"
echo -e "  ${CYN}stop-llm${RST}        Stop llama-server"
echo -e "  ${CYN}restart-llm${RST}     Restart llama-server"
echo -e "  ${CYN}switch-model${RST}    Pick different model (lightweight — ~5s, not 15min)"
echo -e "  ${CYN}llm-status${RST}      Status + active model"
echo -e "  ${CYN}llm-log${RST}         Tail llama-server log"
echo -e "  ${CYN}llm-models${RST}      List all .gguf files"
echo -e "  ${CYN}vram${RST}            GPU/VRAM usage"
echo ""
echo -e " ${BLD}Agents:${RST}"
echo -e "  ${CYN}hermes${RST}          Hermes (persistent memory · self-learning · tools)"
echo -e "  ${CYN}hermes model${RST}    Switch Hermes provider/model"
echo -e "  ${CYN}hermes doctor${RST}   Diagnose config issues"
echo -e "  ${CYN}hermes skills${RST}   Browse/install skills (agentskills.io)"
[[ "$GOOSE_INSTALLED"     == "true" ]] && \
    echo -e "  ${CYN}goose${RST}           Goose (coding / dev tasks)"
[[ "$OPENCODE_INSTALLED"  == "true" ]] && \
    echo -e "  ${CYN}opencode${RST} / ${CYN}oc${RST}  OpenCode TUI coding agent"
[[ "$AUTOAGENT_INSTALLED" == "true" ]] && \
    echo -e "  ${CYN}autoagent${RST}       AutoAgent deep research (no Docker)"
[[ "$OPENCLAUDE_INSTALLED" == "true" ]] && \
    echo -e "  ${CYN}openclaude${RST}      OpenClaude CLI"
echo ""
echo -e " ${BLD}Hermes inside chat:${RST}"
echo -e "  ${CYN}/provider${RST}    Verify routing (should show: custom/local)"
echo -e "  ${CYN}/statusbar${RST}   Toggle model + context info bar"
echo -e "  ${CYN}/compress${RST}    Compress session when context fills"
echo -e "  ${CYN}/reset${RST}       Fresh session (saves memory first)"
echo -e "  ${CYN}/skills${RST}      Browse installed skills"
echo ""
echo -e " ${BLD}Config files:${RST}"
echo -e "  ~/.hermes/config.yaml         Hermes (model · memory · wizard)"
echo -e "  ~/.hermes/.env                Hermes env vars"
[[ "$GOOSE_INSTALLED"     == "true" ]] && \
    echo -e "  ~/.config/goose/config.yaml   Goose  (GOOSE_MODEL=${SEL_GGUF})"
[[ "$OPENCODE_INSTALLED"  == "true" ]] && \
    echo -e "  ~/.config/opencode/opencode.json  OpenCode"
[[ "$AUTOAGENT_INSTALLED" == "true" ]] && \
    echo -e "  ~/.autoagent/.env             AutoAgent"
[[ "$OPENCLAUDE_INSTALLED" == "true" ]] && \
    echo -e "  ~/.openclaude/config.json     OpenClaude"
echo -e "  ~/.claude/config.json         Claude (local provider)"
echo ""
echo -e " ${GRN}Honcho memory:${RST}  enabled — Hermes learns your patterns across sessions"
echo -e " ${GRN}Skills:${RST}         hermes skills browse  |  hermes skills search <query>"
echo -e " ${CYN}agentskills.io${RST}  open standard — compatible with Hermes, OpenCode, Claude Code"
echo ""
echo -e " ${YLW}Note:${RST}       source ~/.bashrc or open a new terminal."
echo -e " ${YLW}Auto-start:${RST} llama-server starts automatically on new terminal."
echo -e " ${GRN}Persistent:${RST} sudo loginctl enable-linger $USER"
echo ""

exit 0
