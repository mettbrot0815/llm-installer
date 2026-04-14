#!/usr/bin/env bash
# =============================================================================
#  install.sh  –  Ubuntu WSL2  ·  llama.cpp + Hermes + Goose + OpenCode + AutoAgent + OpenClaude + WebUI
#  Version: production-hardened (final clean)
#  Optional components selected via single multi‑select menu (whiptail).
#
#  Features:
#    - Smart version checking - only downloads/installs when outdated
#    - Caches installed versions in ~/.llm-versions
#    - Skips redundant downloads
# =============================================================================

# FIX-H-6: Require Bash 4.0+ for associative arrays (declare -A).
if ((BASH_VERSINFO[0] < 4)); then
    echo "ERROR: Bash 4.0 or later is required (found ${BASH_VERSION})." >&2
    exit 1
fi

set -euo pipefail

# ── SWITCH_MODEL_ONLY sentinel ─────────────────────────────────────────────────
_SMO="${SWITCH_MODEL_ONLY:-}"
unset SWITCH_MODEL_ONLY

# ── Version tracking file ──────────────────────────────────────────────────────
readonly VERSION_FILE="${HOME}/.llm-versions"
mkdir -p "$(dirname "$VERSION_FILE")"
touch "$VERSION_FILE"

_get_installed_version() {
    local component="$1"
    if [[ -f "$VERSION_FILE" ]]; then
        grep "^${component}=" "$VERSION_FILE" 2>/dev/null | head -1 | cut -d'=' -f2-
    fi
}

_set_installed_version() {
    local component="$1" version="$2"
    if [[ -f "$VERSION_FILE" ]] && grep -q "^${component}=" "$VERSION_FILE" 2>/dev/null; then
        local tmp
        tmp=$(mktemp "${VERSION_FILE}.XXXXXX")
        while IFS= read -r line; do
            if [[ "$line" == "${component}="* ]]; then
                echo "${component}=${version}"
            else
                echo "$line"
            fi
        done < "$VERSION_FILE" > "$tmp"
        mv -f "$tmp" "$VERSION_FILE"
    else
        echo "${component}=${version}" >> "$VERSION_FILE"
    fi
    chmod 600 "$VERSION_FILE"
}

_version_compare() {
    # Returns 0 if $1 >= $2, 1 otherwise
    local ver1="$1" ver2="$2"
    if [[ "$ver1" == "$ver2" ]]; then
        return 0
    fi
    local IFS=.
    local i ver1_arr=($ver1) ver2_arr=($ver2)
    for ((i=0; i<${#ver1_arr[@]} || i<${#ver2_arr[@]}; i++)); do
        local v1=${ver1_arr[i]:-0} v2=${ver2_arr[i]:-0}
        if ((10#$v1 > 10#$v2)); then
            return 0
        elif ((10#$v1 < 10#$v2)); then
            return 1
        fi
    done
    return 0
}

# ── Strip Windows /mnt/* from PATH ────────────────────────────────────────────
_clean_path=""
IFS=':' read -ra _path_parts <<<"$PATH"
for _p in "${_path_parts[@]}"; do
    [[ "$_p" == /mnt/* ]] && continue
    _clean_path="${_clean_path:+${_clean_path}:}${_p}"
done
export PATH="$_clean_path"
unset _clean_path _path_parts _p

# ── Colour helpers ─────────────────────────────────────────────────────────────
readonly RED='\033[0;31m' GRN='\033[0;32m' YLW='\033[1;33m'
readonly CYN='\033[0;36m' BLD='\033[1m' RST='\033[0m'

step() { echo -e "\n${CYN}[*] $*${RST}"; }
ok()   { echo -e "${GRN}[+] $*${RST}"; }
warn() { echo -e "${YLW}[!] $*${RST}"; }
die()  { echo -e "${RED}[ERROR] $*${RST}"; exit 1; }
skip() { echo -e "${CYN}[~] $*${RST}"; }

# ── Temp file cleanup ──────────────────────────────────────────────────────────
TMPFILES=()
cleanup() {
    local f
    for f in "${TMPFILES[@]}"; do
        [[ -n "$f" && -f "$f" ]] && rm -f "$f"
    done
}
trap cleanup EXIT INT TERM
register_tmp() { TMPFILES+=("$1"); }

# ── Save original umask so we can restore it on exit ─────────────────
_ORIG_UMASK=$(umask -p)
restore_umask() { eval "$_ORIG_UMASK"; }
trap restore_umask EXIT

# ── Banner ─────────────────────────────────────────────────────────────────────
echo -e "${BLD}${CYN}"
if [[ -n "$_SMO" ]]; then
    cat <<'BANNER'
╔══════════════════════════════════════════════════════════════╗
║         Model Switcher  ·  Lightweight mode                  ║
╚══════════════════════════════════════════════════════════════╝
BANNER
else
    cat <<'BANNER'
╔══════════════════════════════════════════════════════════════╗
║  Ubuntu WSL2  ·  llama.cpp + Hermes + Goose + AutoAgent      ║
║  Smart downloads - only installs outdated components        ║
╚══════════════════════════════════════════════════════════════╝
BANNER
fi
echo -e "${RST}"

if [[ -z "$_SMO" ]]; then
    if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
        ok "Running inside WSL2."
    else
        warn "/proc/version does not mention Microsoft/WSL — continuing anyway."
    fi
fi

# =============================================================================
#  1. HuggingFace token – SAFE EXTRACTION
# =============================================================================
readonly TOKEN_FILE="${HOME}/.llm-tokens"

_load_token_from_file() {
    local key="$1"
    if [[ -f "$TOKEN_FILE" ]]; then
        grep "^${key}=" "$TOKEN_FILE" 2>/dev/null | head -1 | cut -d'=' -f2-
    fi
}

_save_token_to_file() {
    local key="$1" val="$2"
    if [[ -f "$TOKEN_FILE" ]] && grep -qF "${key}=" "$TOKEN_FILE" 2>/dev/null; then
        local tmp
        tmp=$(mktemp "${TOKEN_FILE}.XXXXXX")
        register_tmp "$tmp"
        while IFS= read -r line; do
            if [[ "$line" == "${key}="* ]]; then
                echo "${key}=${val}"
            else
                echo "$line"
            fi
        done < "$TOKEN_FILE" > "$tmp"
        chmod 600 "$tmp"
        mv -f "$tmp" "$TOKEN_FILE"
    else
        echo "${key}=${val}" >> "$TOKEN_FILE"
        chmod 600 "$TOKEN_FILE"
    fi
}

_HF_ENV="${HF_TOKEN:-}"
HF_TOKEN=""
if [[ -n "$_HF_ENV" ]]; then
    HF_TOKEN="$_HF_ENV"
    ok "HF_TOKEN already set in environment."
elif [[ -f "${HOME}/.cache/huggingface/token" ]]; then
    HF_TOKEN=$(cat "${HOME}/.cache/huggingface/token" 2>/dev/null || true)
    [[ -n "$HF_TOKEN" ]] && ok "HF_TOKEN loaded from cache."
elif [[ -f "$TOKEN_FILE" ]]; then
    HF_TOKEN=$(_load_token_from_file "HF_TOKEN")
    [[ -n "$HF_TOKEN" ]] && ok "HF_TOKEN loaded from ${TOKEN_FILE}."
fi

if [[ -z "$HF_TOKEN" && -z "$_SMO" ]]; then
    warn "HF_TOKEN not found in environment, cache, or ${TOKEN_FILE}."
    warn "Please set HF_TOKEN in your environment and re-run, or enter it below."
fi

if [[ -z "$HF_TOKEN" && -z "$_SMO" ]]; then
    echo ""
    echo -e "  ${BLD}Why add a HuggingFace token?${RST}"
    echo -e "  Faster downloads · higher rate limits · gated model access"
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
                warn "Token doesn't start with 'hf_' — using anyway."
            fi
            _save_token_to_file "HF_TOKEN" "$HF_TOKEN"
            ok "HF_TOKEN saved to ${TOKEN_FILE} (mode 600)."
        else
            ok "Skipping — unauthenticated downloads (slower, rate-limited)."
        fi
    else
        ok "Non-interactive — skipping HuggingFace token prompt."
    fi
fi
export HF_TOKEN

# =============================================================================
#  2. GitHub token – SECURE EXTRACTION AND GIT CONFIG
# =============================================================================
_GH_ENV="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
GITHUB_TOKEN=""
if [[ -n "$_GH_ENV" ]]; then
    GITHUB_TOKEN="$_GH_ENV"
    ok "GitHub token already set in environment."
elif [[ -f "$TOKEN_FILE" ]]; then
    GITHUB_TOKEN=$(_load_token_from_file "GITHUB_TOKEN")
    [[ -n "$GITHUB_TOKEN" ]] && ok "GITHUB_TOKEN loaded from ${TOKEN_FILE}."
fi

if [[ -z "$GITHUB_TOKEN" && -z "$_SMO" ]]; then
    warn "GitHub token not found in environment or ${TOKEN_FILE}."
    warn "Please set GITHUB_TOKEN or GH_TOKEN and re-run, or enter it below."
fi

if [[ -z "$GITHUB_TOKEN" && -z "$_SMO" ]]; then
    echo ""
    echo -e "  ${BLD}Why add a GitHub token?${RST}"
    echo -e "  Higher API rate limits (5,000 vs 60) · access private repositories"
    echo -e "  ${CYN}https://github.com/settings/tokens${RST} → Generate new token (classic)"
    echo -e "  Required scopes: ${YLW}repo${RST}, ${YLW}read:org${RST} (optional)"
    echo ""
    if [[ -t 0 ]]; then
        read -rp "  Do you have a GitHub token to add? [y/N]: " gh_yn
        if [[ "$gh_yn" =~ ^[Yy]$ ]]; then
            read -rp "  Paste your token (starts with ghp_): " GITHUB_TOKEN
            GITHUB_TOKEN="${GITHUB_TOKEN//[[:space:]]/}"
            if [[ "$GITHUB_TOKEN" =~ ^ghp_ ]]; then
                ok "Token accepted."
            else
                warn "Token doesn't start with 'ghp_' — using anyway."
            fi
            _save_token_to_file "GITHUB_TOKEN" "$GITHUB_TOKEN"
            ok "GITHUB_TOKEN saved to ${TOKEN_FILE} (mode 600)."
        else
            ok "Skipping — unauthenticated GitHub access (rate-limited)."
        fi
    else
        ok "Non-interactive — skipping GitHub token prompt."
    fi
fi

if [[ -n "$GITHUB_TOKEN" ]]; then
    export GITHUB_TOKEN
    _git_creds="${HOME}/.git-credentials"
    if [[ ! -f "$_git_creds" ]] || ! grep -qF "x-oauth-basic" "$_git_creds" 2>/dev/null; then
        umask 077
        echo "https://${GITHUB_TOKEN}@x-oauth-basic@github.com" >> "$_git_creds"
        git config --global credential.helper store 2>/dev/null || \
            warn "Could not set git credential helper."
        eval "$_ORIG_UMASK"
    fi
    if git config --global credential.helper 2>/dev/null | grep -q store; then
        ok "Git configured to use stored GitHub token."
    else
        warn "Could not verify git credential helper configuration."
    fi
    unset _git_creds
fi

# =============================================================================
#  3. System packages [SKIPPED by switch-model]
# =============================================================================
if [[ -z "$_SMO" ]]; then
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

    step "Checking Python version..."
    if python3 --version 2>&1 | grep -qE '3\.(1[0-9]|[2-9][0-9])'; then
        ok "Python 3.10+ found: $(python3 --version)"
    else
        sudo add-apt-repository -y ppa:deadsnakes/ppa
        sudo apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            python3.11 python3.11-venv
        sudo update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1
        ok "Python 3.11 installed and set as default"
    fi
fi

# =============================================================================
#  4. Hardware detection (always runs)
# =============================================================================
step "Detecting hardware..."
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_GiB=$((RAM_KB / 1024 / 1024))
if ((RAM_GiB == 0)); then
    warn "RAM detection returned 0 — defaulting to 8 GiB."
    RAM_GiB=8
fi
CPUS=$(nproc)
HAS_NVIDIA=false
VRAM_GiB=0
VRAM_MiB=0
GPU_NAME="None detected"

if command -v nvidia-smi &>/dev/null; then
    local_nvsmi_out=""
    local_nvsmi_out=$(nvidia-smi --query-gpu=name,memory.total \
        --format=csv,noheader 2>/dev/null | head -1) || true
    if [[ -n "$local_nvsmi_out" ]] && echo "$local_nvsmi_out" | grep -q ','; then
        GPU_NAME=$(echo "$local_nvsmi_out" | cut -d',' -f1 | xargs)
        VRAM_MiB=$(echo "$local_nvsmi_out" | cut -d',' -f2 | awk '{print $1}')
        VRAM_GiB=$((VRAM_MiB / 1024))
        HAS_NVIDIA=true
        ok "GPU: ${GPU_NAME}  (${VRAM_GiB} GiB VRAM) — CUDA OK"
    else
        warn "nvidia-smi present but returned no GPU data — CPU-only."
    fi
else
    GPU_NAME=$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | head -1 |
        sed 's/.*: //' || echo "None")
    warn "nvidia-smi not found — CPU-only mode. GPU (lspci): ${GPU_NAME}"
fi

echo -e "\n  ${BLD}Hardware${RST}"
echo -e "  RAM  : ${RAM_GiB} GiB   CPUs: ${CPUS}"
echo -e "  GPU  : ${GPU_NAME}   VRAM: ${VRAM_GiB} GiB   CUDA: ${HAS_NVIDIA}"

if [[ -z "$_SMO" && "$HAS_NVIDIA" != "true" ]]; then
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
#  5. CUDA toolkit [SKIPPED by switch-model; paths re-exported if GPU present]
# =============================================================================
if [[ -z "$_SMO" && "$HAS_NVIDIA" == "true" ]]; then
    step "Checking CUDA toolkit..."
    if command -v nvcc &>/dev/null; then
        CUDA_VERSION=$(nvcc --version 2>/dev/null | grep "release" | sed 's/.*release \([0-9.]*\).*/\1/')
        INSTALLED_CUDA=$(_get_installed_version "cuda")
        if _version_compare "$CUDA_VERSION" "12.6" && [[ "$INSTALLED_CUDA" == "12.6" ]]; then
            ok "CUDA 12.6 already installed (${CUDA_VERSION}) — skipping"
        else
            warn "CUDA ${CUDA_VERSION:-none} found, upgrading to 12.6..."
            _install_cuda
        fi
    else
        step "Installing CUDA toolkit 12.6 for WSL2..."
        _install_cuda
    fi
fi

_install_cuda() {
    cuda_deb=$(mktemp /tmp/cuda-keyring.XXXXXX.deb)
    register_tmp "$cuda_deb"
    curl -fsSL --proto '=https' --max-redirs 5 \
        --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 \
        https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb \
        -o "$cuda_deb" || die "Failed to download CUDA keyring"
    sudo dpkg -i "$cuda_deb"
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cuda-toolkit-12-6
    _set_installed_version "cuda" "12.6"
    ok "CUDA toolkit 12.6 installed."
}

if [[ "$HAS_NVIDIA" == "true" ]]; then
    export PATH="/usr/local/cuda/bin:${PATH}"
    export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"
fi

# =============================================================================
#  6. Model catalogue
# =============================================================================
readonly MODEL_DIR="${HOME}/llm-models"
mkdir -p "$MODEL_DIR"

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

grade_model() {
    local min_ram="$1" min_vram="$2"
    local ram_gib="$3" vram_gib="$4" has_nvidia="$5"
    if [[ ! "$min_ram" =~ ^[0-9]+$ || ! "$min_vram" =~ ^[0-9]+$ ]]; then
        echo "F"
        return 1
    fi
    local ram_h vram_h
    ram_h=$((ram_gib - min_ram))
    if ((min_vram > 0)) && [[ "$has_nvidia" == "true" ]]; then
        vram_h=$((vram_gib - min_vram))
        if ((vram_h >= 4)); then
            echo "S"
        elif ((vram_h >= 0)); then
            echo "A"
        elif ((ram_h >= 4)); then
            echo "B"
        elif ((ram_h >= 0)); then
            echo "C"
        else
            echo "F"
        fi
    elif ((min_vram > 0)); then
        if ((ram_h >= 8)); then
            echo "B"
        elif ((ram_h >= 0)); then
            echo "C"
        else
            echo "F"
        fi
    else
        if ((ram_h >= 8)); then
            echo "S"
        elif ((ram_h >= 4)); then
            echo "A"
        elif ((ram_h >= 0)); then
            echo "B"
        else
            echo "F"
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
    S | A) echo "${GRN}" ;;
    B | C) echo "${YLW}" ;;
    *) echo "${RED}" ;;
    esac
}

apply_model_settings() {
    local gguf="$1"
    declare -g SAFE_CTX USE_JINJA
    case "$gguf" in
    *Qwen3.5* | *Carnice*)
        SAFE_CTX=262144
        USE_JINJA="--jinja"
        ok "Qwen3.5/Carnice: 256K context, Jinja enabled"
        ;;
    *Llama-3.1* | *Llama-3.3* | *Qwen3-30B*)
        SAFE_CTX=131072
        USE_JINJA="--jinja"
        ;;
    *google_gemma-4* | *gemma-4*)
        SAFE_CTX=135168
        USE_JINJA="--no-jinja"
        ok "Gemma 4: 132K context, Jinja disabled"
        ;;
    *google_gemma-3* | *gemma-3*)
        SAFE_CTX=131072
        USE_JINJA="--no-jinja"
        ok "Gemma 3: Jinja disabled (strict role enforcement)"
        ;;
    *)
        SAFE_CTX=32768
        USE_JINJA="--jinja"
        ;;
    esac
    ok "Context window: ${SAFE_CTX} tokens"
}

show_model_table() {
    /usr/bin/clear 2>/dev/null || true
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
    echo "  ─────────────────────────────────────────────────────────────────────────────"

    local last_tier="" idx hf_repo gguf_file dname size_gb ctx min_ram min_vram tier tags _desc
    while IFS='|' read -r idx hf_repo gguf_file dname size_gb ctx \
        min_ram min_vram tier tags _desc; do
        idx="${idx// /}"
        dname="${dname# }"
        dname="${dname% }"
        size_gb="${size_gb// /}"
        ctx="${ctx// /}"
        min_ram="${min_ram// /}"
        min_vram="${min_vram// /}"
        tier="${tier// /}"
        tags="${tags// /}"
        gguf_file="${gguf_file// /}"
        if [[ "$tier" != "$last_tier" ]]; then
            case "$tier" in
            tiny) echo -e "\n  ${BLD}▸ TINY   (< 1 GB · instant · edge/test)${RST}" ;;
            small) echo -e "\n  ${BLD}▸ SMALL  (1–2 GB · fast CPU · everyday use)${RST}" ;;
            mid) echo -e "\n  ${BLD}▸ MID    (4–17 GB · quality/speed balance)${RST}" ;;
            large) echo -e "\n  ${BLD}▸ LARGE  (15 GB+ · high-end GPU or lots of RAM)${RST}" ;;
            *) echo -e "\n  ${BLD}▸ UNKNOWN  (tier: ${tier})${RST}" ;;
            esac
            last_tier="$tier"
        fi
        local GRADE GC GL cached tag_display
        GRADE=$(grade_model "$min_ram" "$min_vram" "$RAM_GiB" "$VRAM_GiB" "$HAS_NVIDIA")
        GC=$(grade_color "$GRADE")
        GL=$(grade_label "$GRADE")
        if [[ -f "${MODEL_DIR}/${gguf_file}" ]]; then
            cached=" ${CYN}↓${RST}"
        else
            cached=""
        fi
        tag_display="${tags//,/ }"
        echo -e "  ${BLD}$(printf '%2s' "$idx")${RST}  $(printf '%-26s' "$dname")" \
            " $(printf '%5s' "$size_gb") GB  $(printf '%-7s' "$ctx")" \
            "  ${GC}$(printf '%-13s' "$GL")${RST}  $(printf '%-24s' "$tag_display") $cached"
    done < <(printf '%s\n' "${MODELS[@]}")

    declare -A catalogued
    while IFS='|' read -r _ _ cat_g _; do
        catalogued["${cat_g// /}"]=1
    done < <(printf '%s\n' "${MODELS[@]}")

    local extra_count=0 f fname
    for f in "${MODEL_DIR}"/*.gguf; do
        [[ -f "$f" ]] || continue
        fname=$(basename "$f")
        if [[ -z "${catalogued[$fname]:-}" ]]; then
            extra_count=$((extra_count + 1))
            if ((extra_count == 1)); then
                echo -e "\n  ${BLD}▸ LOCAL  (in $HOME/llm-models, not in catalogue)${RST}"
            fi
            local sz_bytes sz
            sz_bytes=$(wc -c <"$f" 2>/dev/null || echo 0)
            if ((sz_bytes > 1073741824)); then
                sz="$((sz_bytes / 1073741824))G"
            elif ((sz_bytes > 1048576)); then
                sz="$((sz_bytes / 1048576))M"
            elif ((sz_bytes > 1024)); then
                sz="$((sz_bytes / 1024))K"
            else
                sz="${sz_bytes}B"
            fi
            echo -e "  ${CYN}↓${RST}  ${fname}  (${sz})"
        fi
    done

    echo ""
    echo "  ─────────────────────────────────────────────────────────────────────────────"
    echo -e "  ${GRN}S/A${RST} Runs great/well   ${YLW}B/C${RST} Tight fit   ${RED}F${RST} Too heavy   ${CYN}↓${RST} Already on disk"
    echo ""
    echo -e "  ${YLW}Tip:${RST} Model 5 (Qwen3.5-9B) = general · Model 6 (Carnice-9b) = Hermes-tuned"
    echo -e "  Enter a number, or ${BLD}u${RST} to download via HuggingFace URL."
    echo ""
}

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
        SEL_GGUF="${SEL_GGUF%%\?*}"
        [[ "$SEL_GGUF" != *.gguf ]] && die "URL doesn't point to a .gguf file."
        SEL_NAME="${SEL_GGUF%.gguf}"
        GGUF_PATH="${MODEL_DIR}/${SEL_GGUF}"
        SEL_HF_REPO=""
        if [[ -f "$GGUF_PATH" ]]; then
            ok "Already on disk: ${GGUF_PATH}"
        else
            step "Downloading ${SEL_GGUF}..."
            local -a curl_args=(-fSL --proto '=https' --max-redirs 5 \
                --progress-bar -o "$GGUF_PATH")
            [[ -n "${HF_TOKEN:-}" ]] && curl_args+=(-H "Authorization: Bearer ${HF_TOKEN}")
            curl "${curl_args[@]}" "$HF_INPUT" || die "curl download failed."
            [[ -f "$GGUF_PATH" ]] || die "File not found after download."
            local fs
            fs=$(wc -c <"$GGUF_PATH" 2>/dev/null || echo 0)
            ((fs < 104857600)) && die "File too small (${fs} bytes) — check URL."
            ok "Downloaded: ${GGUF_PATH}"
        fi
    else
        SEL_HF_REPO="$HF_INPUT"
        step "Listing GGUFs in ${SEL_HF_REPO}..."
        local list_py
        list_py=$(mktemp /tmp/hf_list.XXXXXX.py)
        register_tmp "$list_py"
        cat >"$list_py" <<'PYLIST'
import sys, os
from huggingface_hub import list_repo_files
repo = sys.argv[1]
token = os.environ.get("HF_TOKEN")
try:
    files = list_repo_files(repo, token=token)
except Exception as e:
    print("ERROR: " + str(e), file=sys.stderr)
    sys.exit(1)
for f in files:
    if f.endswith(".gguf"):
        print(f)
PYLIST
        local py_out
        py_out=$(python3 "$list_py" "$SEL_HF_REPO" 2>/dev/null || true)
        if [[ -z "$py_out" ]]; then
            warn "Could not auto-list files. Enter filename manually."
            read -rp "  Filename (e.g. model-Q4_K_M.gguf): " SEL_GGUF
            SEL_GGUF="${SEL_GGUF//[[:space:]]/}"
            [[ -z "$SEL_GGUF" ]] && die "No filename."
        else
            mapfile -t GGUF_FILES <<<"$py_out"
            if [[ ${#GGUF_FILES[@]} -eq 1 ]]; then
                SEL_GGUF="${GGUF_FILES[0]}"
                ok "Only one GGUF found: ${SEL_GGUF}"
            else
                echo ""
                echo -e "  ${BLD}Available GGUFs:${RST}"
                local fnum=1 gf
                for gf in "${GGUF_FILES[@]}"; do
                    printf "  %2d  %s\n" "$fnum" "$gf"
                    fnum=$((fnum + 1))
                done
                echo ""
                local gf_choice
                while true; do
                    read -rp "  Enter number [1-${#GGUF_FILES[@]}]: " gf_choice
                    if [[ "$gf_choice" =~ ^[0-9]+$ ]] &&
                        ((gf_choice >= 1 && gf_choice <= ${#GGUF_FILES[@]})); then
                        break
                    fi
                    warn "Invalid choice."
                done
                SEL_GGUF="${GGUF_FILES[$((gf_choice - 1))]}"
            fi
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
            fs=$(wc -c <"$GGUF_PATH" 2>/dev/null || echo 0)
            ((fs < 104857600)) && die "File too small (${fs} bytes)."
            ok "Downloaded: ${GGUF_PATH}"
        fi
    fi
    apply_model_settings "$SEL_GGUF"
}

# =============================================================================
#  7. HF CLI setup (always runs)
# =============================================================================
step "Setting up HuggingFace CLI..."
export PATH="${HOME}/.local/bin:${PATH}"

HF_CLI_A="${HOME}/.local/bin/hf"
HF_CLI_B="${HOME}/.local/bin/huggingface-cli"

if [[ ! -x "$HF_CLI_A" && ! -x "$HF_CLI_B" ]]; then
    pip3 install --quiet --user huggingface_hub 2>/dev/null || \
        pip3 install --quiet --user --break-system-packages huggingface_hub || \
        die "Failed to install huggingface_hub"
    _set_installed_version "huggingface_hub" "$(pip3 show huggingface_hub 2>/dev/null | grep Version | awk '{print $2}')"
else
    CURRENT_HF_VER=$(pip3 show huggingface_hub 2>/dev/null | grep Version | awk '{print $2}')
    INSTALLED_HF_VER=$(_get_installed_version "huggingface_hub")
    if [[ -n "$CURRENT_HF_VER" ]] && [[ "$CURRENT_HF_VER" != "$INSTALLED_HF_VER" ]]; then
        warn "huggingface_hub version mismatch (installed: $INSTALLED_HF_VER, current: $CURRENT_HF_VER)"
        step "Upgrading huggingface_hub..."
        pip3 install --quiet --user --upgrade huggingface_hub 2>/dev/null || \
            pip3 install --quiet --user --break-system-packages --upgrade huggingface_hub
        _set_installed_version "huggingface_hub" "$CURRENT_HF_VER"
    else
        skip "huggingface_hub already up to date (${CURRENT_HF_VER})"
    fi
fi

if [[ -x "$HF_CLI_A" ]]; then
    HF_CLI="$HF_CLI_A"
    HF_CLI_NAME="hf"
elif [[ -x "$HF_CLI_B" ]]; then
    HF_CLI="$HF_CLI_B"
    HF_CLI_NAME="huggingface-cli"
else
    die "Neither 'hf' nor 'huggingface-cli' found after install."
fi
"$HF_CLI" version &>/dev/null || die "'$HF_CLI_NAME' fails to run."
ok "$HF_CLI_NAME ready: $("$HF_CLI" version 2>/dev/null || echo 'ok')"

if [[ -n "${HF_TOKEN:-}" ]]; then
    if "$HF_CLI" auth login --token "$HF_TOKEN" 2>/dev/null; then
        ok "HF login completed."
    elif "$HF_CLI" login --token "$HF_TOKEN" 2>/dev/null; then
        ok "HF login completed (legacy)."
    else
        ok "HF token ready (may be cached)."
    fi
    if "$HF_CLI" auth whoami 2>/dev/null | grep -q 'Token:'; then
        ok "HF login verified."
    else
        warn "HF login could not be verified — downloads may be unauthenticated."
    fi
fi

# =============================================================================
#  8. Model selector (always runs)
# =============================================================================
NUM_MODELS=${#MODELS[@]}
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
    
    if [[ -n "${INSTALL_TIMEOUT:-}" ]]; then
        read -rp "$(echo -e "  ${BLD}Enter number [1-${NUM_MODELS}] or 'u' for URL:${RST} ")" -t "$INSTALL_TIMEOUT" CHOICE || {
            warn "Timeout - defaulting to model 5"
            CHOICE="5"
            break
        }
    else
        read -rp "$(echo -e "  ${BLD}Enter number [1-${NUM_MODELS}] or 'u' for URL:${RST} ")" CHOICE || {
            echo ""
            warn "EOF detected. Exiting."
            exit 0
        }
    fi
    
    if [[ "$CHOICE" =~ ^[Uu]$ ]]; then
        download_from_hf_url
        break
    elif [[ "$CHOICE" =~ ^[0-9]+$ ]] && ((CHOICE >= 1 && CHOICE <= NUM_MODELS)); then
        break
    fi
    warn "Invalid choice: '$CHOICE'"
done

if [[ ! "$CHOICE" =~ ^[Uu]$ ]]; then
    while IFS='|' read -r idx hf_repo gguf_file dname size_gb ctx \
        min_ram min_vram tier tags _desc; do
        idx="${idx// /}"
        if [[ "$idx" == "$CHOICE" ]]; then
            SEL_HF_REPO="${hf_repo// /}"
            SEL_GGUF="${gguf_file// /}"
            SEL_NAME="${dname# }"
            SEL_NAME="${SEL_NAME% }"
            SEL_MIN_RAM="${min_ram// /}"
            SEL_MIN_VRAM="${min_vram// /}"
            break
        fi
    done < <(printf '%s\n' "${MODELS[@]}")

    [[ -z "$SEL_GGUF" ]] && die "Model parse failed: SEL_GGUF empty."
    [[ -z "$SEL_MIN_RAM" ]] && die "Model parse failed: SEL_MIN_RAM empty."
    [[ "$SEL_MIN_RAM" =~ ^[0-9]+$ ]] || die "SEL_MIN_RAM='$SEL_MIN_RAM' not numeric."
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
#  9. Download model from catalogue if not present (always runs)
# =============================================================================
if [[ -f "$GGUF_PATH" ]]; then
    ok "Model already on disk: ${GGUF_PATH} — skipping download."
elif [[ ! "$CHOICE" =~ ^[Uu]$ ]]; then
    step "Downloading ${SEL_NAME} from HuggingFace..."
    warn "This may take several minutes."

    AVAIL_KB=$(df -k "${MODEL_DIR}" | awk 'NR==2 {print $4}')
    AVAIL_GB=$(awk -v kb="$AVAIL_KB" 'BEGIN { printf "%.1f", kb/1024/1024 }')
    AVAIL_GB_INT=$(awk -v kb="$AVAIL_KB" 'BEGIN { print int((kb/1024/1024) + 0.999) }')

    REQ_GB=""
    while IFS='|' read -r idx _ _ _ size_gb _ _ _ _ _ _; do
        [[ "${idx// /}" == "$CHOICE" ]] && {
            REQ_GB="${size_gb// /}"
            break
        }
    done < <(printf '%s\n' "${MODELS[@]}")
    [[ -z "$REQ_GB" ]] && die "Could not determine model size for index $CHOICE"

    REQ_GB_INT=${REQ_GB%.*}
    [[ "$REQ_GB" == *"."* ]] && REQ_GB_INT=$((REQ_GB_INT + 1))
    REQ_GB_INT=$((REQ_GB_INT + 2))
    ((REQ_GB_INT < 3)) && REQ_GB_INT=3
    if ((AVAIL_GB_INT < REQ_GB_INT)); then
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
    FILE_SIZE=$(wc -c <"$GGUF_PATH" 2>/dev/null || echo 0)
    if ((FILE_SIZE < 104857600)); then
        die "Downloaded file suspiciously small (${FILE_SIZE} bytes)."
    fi
    if command -v numfmt &>/dev/null; then
        ok "Downloaded: ${GGUF_PATH} ($(numfmt --to=iec-i --suffix=B "${FILE_SIZE}"))"
    else
        ok "Downloaded: ${GGUF_PATH} (${FILE_SIZE} bytes)"
    fi
fi

# =============================================================================
#  Helper: Check if a Git repository has updates
# =============================================================================
needs_update() {
    local repo_dir="$1"
    local branch="${2:-main}"
    if [[ ! -d "$repo_dir/.git" ]]; then
        return 0  # Needs clone
    fi
    git -C "$repo_dir" fetch origin "$branch" 2>/dev/null || true
    local local_commit remote_commit
    local_commit=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || echo "")
    remote_commit=$(git -C "$repo_dir" rev-parse "origin/$branch" 2>/dev/null || echo "")
    [[ -n "$local_commit" && -n "$remote_commit" && "$local_commit" != "$remote_commit" ]]
}

# =============================================================================
#  10. Build llama.cpp [SKIPPED by switch-model]
# =============================================================================
find_llama_server() {
    local p vo
    for p in /usr/local/bin/llama-server /usr/bin/llama-server \
        "${HOME}/.local/bin/llama-server" \
        "${HOME}/llama.cpp/build/bin/llama-server"; do
        if [[ -x "$p" ]]; then
            vo=$("$p" --version 2>&1) || continue
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
        vo=$("$found" --version 2>&1) || true
        if echo "$vo" | grep -qiE 'llama|ggml'; then
            echo "$found"
            return 0
        fi
    fi
    return 1
}

_get_llama_version() {
    local bin="$1"
    if [[ -x "$bin" ]]; then
        "$bin" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
    fi
}

if [[ -n "$_SMO" ]]; then
    step "Locating llama-server (switch-model — skipping build)..."
    LLAMA_SERVER_BIN=$(find_llama_server || true)
    [[ -z "$LLAMA_SERVER_BIN" ]] &&
        die "llama-server not found. Run the full installer first before using switch-model."
    ok "Found: ${LLAMA_SERVER_BIN}"
else
    step "Checking llama.cpp..."
    LLAMA_SERVER_BIN=$(find_llama_server || true)
    if [[ -n "$LLAMA_SERVER_BIN" ]]; then
        CURRENT_VER=$(_get_llama_version "$LLAMA_SERVER_BIN")
        INSTALLED_VER=$(_get_installed_version "llama.cpp")
        if _version_compare "${CURRENT_VER:-0}" "1.0" && [[ "$CURRENT_VER" == "$INSTALLED_VER" ]]; then
            ok "llama-server ${CURRENT_VER} already installed — skipping build"
        else
            warn "llama.cpp version mismatch (installed: ${INSTALLED_VER:-none}, current: ${CURRENT_VER:-none})"
            step "Rebuilding llama.cpp..."
            _rebuild_llama=true
        fi
    else
        _rebuild_llama=true
    fi
    
    if [[ "${_rebuild_llama:-false}" == "true" ]]; then
        LLAMA_DIR="${HOME}/llama.cpp"
        if needs_update "$LLAMA_DIR" "master"; then
            step "Building/updating llama.cpp..."
            if [[ -d "$LLAMA_DIR/.git" ]]; then
                git -C "$LLAMA_DIR" fetch origin
                git -C "$LLAMA_DIR" reset --hard origin/master
            else
                git clone https://github.com/ggml-org/llama.cpp.git "$LLAMA_DIR"
            fi

            cd -- "$LLAMA_DIR"
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
            if sudo -n true 2>/dev/null; then
                sudo cmake --install build || warn "System install failed — using build directory."
            else
                warn "Sudo requires password; skipping system install. Using build directory."
            fi
            cd -- "$HOME"
            
            NEW_VER=$(_get_llama_version "$LLAMA_SERVER_BIN")
            _set_installed_version "llama.cpp" "${NEW_VER:-latest}"
            ok "llama.cpp built successfully"
        else
            skip "llama.cpp already up‑to‑date."
        fi

        LLAMA_SERVER_BIN=$(find_llama_server || true)
        [[ -n "$LLAMA_SERVER_BIN" ]] || die "llama-server not found after build."
        ok "llama-server: ${LLAMA_SERVER_BIN}"
    fi
fi

# =============================================================================
#  11. Hermes Agent install - FIXED VERSION using official installer
# =============================================================================
HERMES_HOME="${HOME}/.hermes"
HERMES_INSTALL_DIR="${HERMES_HOME}/hermes-agent"

_check_hermes_version() {
    if command -v hermes &>/dev/null; then
        hermes --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
    fi
}

_install_hermes_agent() {
    step "Installing Hermes Agent (official method)..."
    
    # Remove old broken installation if exists
    if [[ -d "${HERMES_INSTALL_DIR}" ]]; then
        warn "Removing old Hermes installation..."
        rm -rf "${HERMES_INSTALL_DIR}"
    fi
    
    # Download and run official installer
    local install_script
    install_script=$(mktemp /tmp/hermes-install.XXXXXX.sh)
    register_tmp "$install_script"
    
    curl -fsSL --proto '=https' --max-redirs 5 \
        https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh \
        -o "$install_script" || die "Failed to download Hermes installer"
    
    # Run with skip-setup to avoid wizard
    bash "$install_script" --branch main --skip-setup
    
    # Verify installation
    if [[ -x "${HOME}/.local/bin/hermes" ]]; then
        ok "Hermes Agent installed successfully"
        export PATH="${HOME}/.local/bin:${PATH}"
        NEW_VER=$(_check_hermes_version)
        _set_installed_version "hermes" "${NEW_VER:-latest}"
    elif [[ -x "${HERMES_INSTALL_DIR}/venv/bin/hermes" ]]; then
        ok "Hermes Agent installed (venv mode)"
        mkdir -p "${HOME}/.local/bin"
        ln -sf "${HERMES_INSTALL_DIR}/venv/bin/hermes" "${HOME}/.local/bin/hermes"
        NEW_VER=$(_check_hermes_version)
        _set_installed_version "hermes" "${NEW_VER:-latest}"
    else
        die "Hermes Agent installation failed"
    fi
}

if [[ -z "$_SMO" ]]; then
    CURRENT_HERMES=$(_check_hermes_version)
    INSTALLED_HERMES=$(_get_installed_version "hermes")
    if [[ -n "$CURRENT_HERMES" ]] && [[ "$CURRENT_HERMES" == "$INSTALLED_HERMES" ]]; then
        skip "Hermes Agent already up to date (${CURRENT_HERMES})"
    else
        _install_hermes_agent
    fi
fi

# =============================================================================
#  11b. Configure Hermes for local llama-server – clean YAML overwrite
# =============================================================================
step "Configuring Hermes for local llama-server..."

umask 077
mkdir -p "${HERMES_HOME}"/{cron,sessions,logs,memories,skills}

if [[ -f "${HERMES_HOME}/.env" && ! -L "${HERMES_HOME}/.env" ]]; then
    cp "${HERMES_HOME}/.env" "${HERMES_HOME}/.env.backup.$(date +%Y%m%d%H%M%S)"
    ok "Backed up existing $HOME/.hermes/.env"
fi
cat >"${HERMES_HOME}/.env" <<'ENV'
OPENAI_API_KEY=sk-no-key-needed
OPENAI_BASE_URL=http://localhost:8080/v1
ENV
ok "$HOME/.hermes/.env written."

CONFIG_FILE="${HERMES_HOME}/config.yaml"

if [[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]]; then
    cp "$CONFIG_FILE" "${CONFIG_FILE}.backup.$(date +%Y%m%d%H%M%S)"
    ok "Backed up existing config.yaml"
fi

cat >"$CONFIG_FILE" <<YAML
setup_complete: true

model:
  provider: custom
  base_url: http://localhost:8080/v1
  default: "${SEL_NAME}"
  context_length: ${SAFE_CTX}

terminal:
  backend: local

agent:
  max_turns: 90

memory:
  honcho:
    enabled: true
YAML

umask 022

ok "Hermes configured → llama-server (${SEL_NAME}, ctx=${SAFE_CTX})"
ok "setup_complete: true written → setup wizard will not fire"
ok "Hermes ready with local backend"

# =============================================================================
#  12. Optional components selection (multi‑select menu)
# =============================================================================
select_optional_components() {
    [[ ! -t 0 ]] && return 1

    if ! command -v whiptail &>/dev/null; then
        warn "whiptail not found – using simple yes/no prompts (install 'whiptail' for better menu)."
        return 2
    fi

    local choices
    if ! choices=$(whiptail --title "Optional Components" --checklist \
        "Select additional components to install (use SPACE to toggle, ENTER to confirm):" \
        20 80 5 \
        "goose" "Goose AI Agent (Rust CLI, 30k+ stars)" OFF \
        "opencode" "OpenCode (Terminal TUI coding agent)" OFF \
        "autoagent" "AutoAgent (Deep research multi-agent)" OFF \
        "openclaude" "OpenClaude (Claude-compatible CLI)" OFF \
        "webui" "Hermes WebUI (Browser interface for Hermes)" OFF \
        3>&1 1>&2 2>&3); then
        echo ""
        ok "No optional components selected (user cancelled)."
        return 1
    fi

    local tmpfile
    tmpfile=$(mktemp)
    register_tmp "$tmpfile"
    echo "$choices" | xargs -n1 printf "%s\n" > "$tmpfile"

    local -a selected=()
    while IFS= read -r line; do
        selected+=("$line")
    done < "$tmpfile"

    declare -g INSTALL_GOOSE=false
    declare -g INSTALL_OPENCODE=false
    declare -g INSTALL_AUTOAGENT=false
    declare -g INSTALL_OPENCLAUDE=false
    declare -g INSTALL_WEBUI=false

    for item in "${selected[@]}"; do
        case "$item" in
            goose) INSTALL_GOOSE=true ;;
            opencode) INSTALL_OPENCODE=true ;;
            autoagent) INSTALL_AUTOAGENT=true ;;
            openclaude) INSTALL_OPENCLAUDE=true ;;
            webui) INSTALL_WEBUI=true ;;
            *) warn "Unknown component '$item' — skipped." ;;
        esac
    done

    echo ""
    local count=0
    if $INSTALL_GOOSE; then echo "  ✓ Goose"; count=$((count+1)); fi
    if $INSTALL_OPENCODE; then echo "  ✓ OpenCode"; count=$((count+1)); fi
    if $INSTALL_AUTOAGENT; then echo "  ✓ AutoAgent"; count=$((count+1)); fi
    if $INSTALL_OPENCLAUDE; then echo "  ✓ OpenClaude"; count=$((count+1)); fi
    if $INSTALL_WEBUI; then echo "  ✓ Hermes WebUI"; count=$((count+1)); fi

    if [[ $count -eq 0 ]]; then
        ok "No optional components selected."
        return 1
    else
        ok "$count component(s) selected for installation."
        return 0
    fi
}

INSTALL_GOOSE=false
INSTALL_OPENCODE=false
INSTALL_AUTOAGENT=false
INSTALL_OPENCLAUDE=false
INSTALL_WEBUI=false

if [[ -z "$_SMO" ]]; then
    step "Optional components selection"
    select_optional_components
    ret=$?
    if [[ $ret -eq 2 ]]; then
        echo ""
        echo -e "  ${BLD}Optional: Goose AI Agent (block/goose)${RST}"
        read -rp "  Install Goose? [y/N]: " ans && [[ "$ans" =~ ^[Yy]$ ]] && INSTALL_GOOSE=true
        echo -e "  ${BLD}Optional: OpenCode (anomalyco/opencode)${RST}"
        read -rp "  Install OpenCode? [y/N]: " ans && [[ "$ans" =~ ^[Yy]$ ]] && INSTALL_OPENCODE=true
        echo -e "  ${BLD}Optional: AutoAgent (HKUDS)${RST}"
        read -rp "  Install AutoAgent? [y/N]: " ans && [[ "$ans" =~ ^[Yy]$ ]] && INSTALL_AUTOAGENT=true
        echo -e "  ${BLD}Optional: OpenClaude (@gitlawb/openclaude)${RST}"
        read -rp "  Install OpenClaude? [y/N]: " ans && [[ "$ans" =~ ^[Yy]$ ]] && INSTALL_OPENCLAUDE=true
        echo -e "  ${BLD}Optional: Hermes WebUI${RST}"
        read -rp "  Install Hermes WebUI? [y/N]: " ans && [[ "$ans" =~ ^[Yy]$ ]] && INSTALL_WEBUI=true
    fi
fi

# =============================================================================
#  13a. Goose - with version checking
# =============================================================================
_get_goose_version() {
    if command -v goose &>/dev/null; then
        goose --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
    fi
}

if $INSTALL_GOOSE; then
    step "Checking Goose CLI..."
    CURRENT_GOOSE=$(_get_goose_version)
    INSTALLED_GOOSE=$(_get_installed_version "goose")
    
    if [[ -n "$CURRENT_GOOSE" ]] && [[ "$CURRENT_GOOSE" == "$INSTALLED_GOOSE" ]]; then
        skip "Goose already up to date (${CURRENT_GOOSE})"
    else
        step "Installing/Updating Goose CLI..."
        goose_script=$(mktemp /tmp/goose-install.XXXXXX.sh)
        register_tmp "$goose_script"
        if curl -fsSL --proto '=https' --max-redirs 5 \
            --connect-timeout 15 --max-time 120 --retry 3 --retry-delay 2 \
            https://github.com/block/goose/releases/download/stable/download_cli.sh \
            -o "$goose_script" 2>/dev/null; then
            if bash "$goose_script"; then
                export PATH="${HOME}/.local/bin:${PATH}"
                NEW_GOOSE=$(_get_goose_version)
                _set_installed_version "goose" "${NEW_GOOSE:-latest}"
                ok "Goose installed/updated"
            else
                warn "Goose install script failed."
            fi
        else
            warn "Failed to download Goose install script — skipping."
        fi
    fi

    if command -v goose &>/dev/null; then
        step "Configuring Goose for local llama-server..."
        umask 077
        mkdir -p "${HOME}/.config/goose"
        cat >"${HOME}/.config/goose/config.yaml" <<GOOSECONF
models:
  - name: local
    provider: openai
    base_url: http://localhost:8080/v1
    api_key: sk-local
    default: true
GOOSECONF
        umask 022
        ok "Goose configured."
    fi
fi

# =============================================================================
#  13b. OpenCode - with version checking
# =============================================================================
_get_opencode_version() {
    if command -v opencode &>/dev/null; then
        opencode --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
    fi
}

if $INSTALL_OPENCODE; then
    step "Checking OpenCode..."
    CURRENT_OPENCODE=$(_get_opencode_version)
    INSTALLED_OPENCODE=$(_get_installed_version "opencode")
    
    if [[ -n "$CURRENT_OPENCODE" ]] && [[ "$CURRENT_OPENCODE" == "$INSTALLED_OPENCODE" ]]; then
        skip "OpenCode already up to date (${CURRENT_OPENCODE})"
    else
        step "Installing/Updating OpenCode..."
        opencode_installer=$(mktemp /tmp/opencode-install.XXXXXX.sh)
        register_tmp "$opencode_installer"
        if curl -fsSL --proto '=https' --max-redirs 5 \
            --connect-timeout 15 --max-time 120 --retry 3 --retry-delay 2 \
            https://opencode.ai/install -o "$opencode_installer" 2>/dev/null; then
            if XDG_BIN_DIR="${HOME}/.local/bin" bash "$opencode_installer" 2>/dev/null; then
                export PATH="${HOME}/.local/bin:${PATH}"
                NEW_OPENCODE=$(_get_opencode_version)
                _set_installed_version "opencode" "${NEW_OPENCODE:-latest}"
                ok "OpenCode installed/updated"
            else
                warn "OpenCode install script failed."
            fi
        else
            warn "OpenCode install script download failed — skipping."
        fi
    fi

    if command -v opencode &>/dev/null; then
        step "Configuring OpenCode with local model..."
        mkdir -p "${HOME}/.config/opencode"
        cat >"${HOME}/.config/opencode/opencode.json" <<OPECONF
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "llamacpp": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama.cpp (local)",
      "options": {
        "baseURL": "http://localhost:8080/v1",
        "apiKey": "sk-local"
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
    fi
fi

# =============================================================================
#  13c. AutoAgent - FIXED VERSION with version checking
# =============================================================================
AUTOAGENT_DIR="${HOME}/autoagent"
AUTOAGENT_VENV="${AUTOAGENT_DIR}/.venv"

_get_autoagent_version() {
    if [[ -f "${AUTOAGENT_VENV}/bin/python" ]]; then
        "${AUTOAGENT_VENV}/bin/python" -c "import autoagent; print(autoagent.__version__)" 2>/dev/null || echo ""
    fi
}

_install_autoagent() {
    cd -- "${AUTOAGENT_DIR}"
    "${AUTOAGENT_VENV}/bin/pip" install --upgrade pip setuptools wheel
    if ! "${AUTOAGENT_VENV}/bin/pip" install -e .; then
        return 1
    fi
    return 0
}

if $INSTALL_AUTOAGENT; then
    step "Checking AutoAgent..."
    CURRENT_AUTOAGENT=$(_get_autoagent_version)
    INSTALLED_AUTOAGENT=$(_get_installed_version "autoagent")
    
    if [[ -n "$CURRENT_AUTOAGENT" ]] && [[ "$CURRENT_AUTOAGENT" == "$INSTALLED_AUTOAGENT" ]]; then
        skip "AutoAgent already up to date (${CURRENT_AUTOAGENT})"
    else
        step "Installing/Updating AutoAgent..."
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-tk python3-dev build-essential 2>/dev/null || true

        if [[ ! -d "${AUTOAGENT_DIR}" ]]; then
            git clone https://github.com/HKUDS/AutoAgent.git "${AUTOAGENT_DIR}"
        else
            cd -- "${AUTOAGENT_DIR}"
            git fetch origin
            git reset --hard origin/main
            cd -- "$HOME"
        fi

        # Create venv with system site packages for tkinter
        if [[ ! -d "${AUTOAGENT_VENV}" ]]; then
            python3 -m venv "${AUTOAGENT_VENV}" --system-site-packages
        fi

        if _install_autoagent; then
            NEW_AUTOAGENT=$(_get_autoagent_version)
            _set_installed_version "autoagent" "${NEW_AUTOAGENT:-latest}"
            ok "AutoAgent installed/updated"
        else
            die "AutoAgent install failed"
        fi

        cat >"${HOME}/start-autoagent.sh" <<'AUTOAGENT_LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail
export TKINTER_AVAILABLE=False
AUTOAGENT_VENV="${HOME}/autoagent/.venv"
AUTOAGENT_DIR="${HOME}/autoagent"

if ! curl -sf http://localhost:8080/v1/models &>/dev/null; then
    echo "llama-server not running. Start with: start-llm"
    exit 1
fi

source "${AUTOAGENT_VENV}/bin/activate"
cd -- "${AUTOAGENT_DIR}"
python -m autoagent.cli deep-research
AUTOAGENT_LAUNCHER
        chmod +x "${HOME}/start-autoagent.sh"
    fi
    cd -- "$HOME"
fi

# =============================================================================
#  13d. OpenClaude - with version checking
# =============================================================================
_get_openclaude_version() {
    if command -v openclaude &>/dev/null; then
        openclaude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
    fi
}

if $INSTALL_OPENCLAUDE; then
    step "Checking OpenClaude..."
    CURRENT_OPENCLAUDE=$(_get_openclaude_version)
    INSTALLED_OPENCLAUDE=$(_get_installed_version "openclaude")
    
    if [[ -n "$CURRENT_OPENCLAUDE" ]] && [[ "$CURRENT_OPENCLAUDE" == "$INSTALLED_OPENCLAUDE" ]]; then
        skip "OpenClaude already up to date (${CURRENT_OPENCLAUDE})"
    else
        step "Installing/Updating OpenClaude..."
        _node_major=""
        if command -v node &>/dev/null; then
            _node_major=$(node -v | cut -d. -f1 | tr -d 'v') || _node_major="0"
        fi
        if ! command -v node &>/dev/null || [[ "${_node_major:-0}" -lt 20 ]]; then
            step "Setting up NodeSource repository for Node.js 22..."
            nodesource_key=$(mktemp /tmp/nodesource.gpg.XXXXXX)
            register_tmp "$nodesource_key"
            curl -fsSL --proto '=https' --max-redirs 5 \
                https://deb.nodesource.com/gpgkey/nodesource.gpg.key -o "$nodesource_key"
            sudo gpg --dearmor -o /usr/share/keyrings/nodesource.gpg "$nodesource_key"
            rm -f "$nodesource_key"
            echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" | sudo tee /etc/apt/sources.list.d/nodesource.list
            sudo apt-get update -qq
            sudo apt-get install -y -qq nodejs
            ok "Node.js 22 installed via official repository (verified GPG)."
        fi
        sudo npm install -g @gitlawb/openclaude@latest
        NEW_OPENCLAUDE=$(_get_openclaude_version)
        _set_installed_version "openclaude" "${NEW_OPENCLAUDE:-latest}"
    fi

    if command -v openclaude &>/dev/null; then
        umask 077
        mkdir -p "${HOME}/.openclaude"
        cat >"${HOME}/.openclaude/config.json" <<OPENCLAUDE
{
  "providers": {
    "local": {
      "baseUrl": "http://127.0.0.1:8080/v1",
      "apiKey": "local"
    }
  },
  "model": "local/${SEL_GGUF}"
}
OPENCLAUDE
        umask 022
        ok "OpenClaude configured."
    fi
fi

# =============================================================================
#  13e. Hermes WebUI (Python-based) - with version checking
# =============================================================================
HERMES_WEBUI_DIR="${HOME}/hermes-webui"

_get_webui_version() {
    if [[ -f "${HERMES_WEBUI_DIR}/.git/config" ]]; then
        git -C "${HERMES_WEBUI_DIR}" rev-parse --short HEAD 2>/dev/null || echo ""
    fi
}

if $INSTALL_WEBUI; then
    step "Checking Hermes WebUI..."
    CURRENT_WEBUI=$(_get_webui_version)
    INSTALLED_WEBUI=$(_get_installed_version "webui")
    
    if [[ -n "$CURRENT_WEBUI" ]] && [[ "$CURRENT_WEBUI" == "$INSTALLED_WEBUI" ]]; then
        skip "Hermes WebUI already up to date (${CURRENT_WEBUI})"
    else
        step "Installing/Updating Hermes WebUI..."
        
        if [[ ! -d "${HERMES_WEBUI_DIR}/.git" ]]; then
            git clone https://github.com/nesquena/hermes-webui.git "${HERMES_WEBUI_DIR}"
        else
            git -C "$HERMES_WEBUI_DIR" pull --quiet
        fi

        HERMES_VENV="${HOME}/.hermes/hermes-agent/venv"
        if [[ ! -d "$HERMES_VENV" ]]; then
            warn "Hermes agent venv not found – WebUI may not function correctly."
            HERMES_VENV="${HOME}/hermes-agent/venv"
        fi

        if [[ -f "${HERMES_WEBUI_DIR}/requirements.txt" ]]; then
            if [[ -x "${HERMES_VENV}/bin/pip" ]]; then
                "${HERMES_VENV}/bin/pip" install -r "${HERMES_WEBUI_DIR}/requirements.txt" --quiet
            else
                pip3 install --user -r "${HERMES_WEBUI_DIR}/requirements.txt" --quiet 2>/dev/null || \
                    pip3 install --user --break-system-packages -r "${HERMES_WEBUI_DIR}/requirements.txt" --quiet || \
                    warn "Failed to install WebUI requirements.txt"
            fi
        fi

        cat >"${HOME}/start-webui.sh" <<WEBUISTART
#!/usr/bin/env bash
set -euo pipefail
cd -- "${HERMES_WEBUI_DIR}"
if [[ -x "${HERMES_VENV}/bin/python" ]]; then
    export PATH="${HERMES_VENV}/bin:\${PATH}"
fi
echo "Starting Hermes WebUI on http://localhost:8787"
./start.sh
WEBUISTART
        chmod +x "${HOME}/start-webui.sh"

        if systemctl --user is-system-running &>/dev/null; then
            mkdir -p "${HOME}/.config/systemd/user"
            cat >"${HOME}/.config/systemd/user/hermes-webui.service" <<WEBUISERVICE
[Unit]
Description=Hermes WebUI
After=network.target

[Service]
Type=simple
WorkingDirectory=${HERMES_WEBUI_DIR}
ExecStart=${HOME}/start-webui.sh
Restart=on-failure
RestartSec=5
Environment=HERMES_WEBUI_HOST=127.0.0.1
Environment=HERMES_WEBUI_PORT=8787
StandardOutput=append:/tmp/hermes-webui.log
StandardError=append:/tmp/hermes-webui.log

[Install]
WantedBy=default.target
WEBUISERVICE
            systemctl --user enable hermes-webui.service 2>/dev/null || true
            ok "WebUI systemd service enabled (starts on login)."
        else
            warn "systemd --user unavailable — use '~/start-webui.sh' to start manually."
        fi
        
        NEW_WEBUI=$(_get_webui_version)
        _set_installed_version "webui" "${NEW_WEBUI:-latest}"
        ok "Hermes WebUI installed/updated"
    fi
fi

# =============================================================================
#  14. Create ~/start-llm.sh (always runs)
# =============================================================================
step "Generating ~/start-llm.sh..."
LAUNCH_SCRIPT="${HOME}/start-llm.sh"

cat >"${LAUNCH_SCRIPT}.template" <<'LAUNCH_TEMPLATE'
#!/usr/bin/env bash
set -euo pipefail
GGUF="${GGUF_PATH}"
MODEL_NAME="${SEL_NAME}"
LLAMA_BIN="${LLAMA_SERVER_BIN}"
SAFE_CTX="${SAFE_CTX}"
USE_JINJA="${USE_JINJA}"
PIDFILE="${PIDFILE_PATH}"

if [[ ! -x "$LLAMA_BIN" ]]; then
    echo "ERROR: llama-server binary not found or not executable: $LLAMA_BIN"
    exit 1
fi

# Check for existing process using fixed-string matching
LLAMA_PID=$(pgrep -f "llama-server.*-m" 2>/dev/null | xargs -I{} ps -p {} -o pid=,args= 2>/dev/null | grep -F "$GGUF" | awk '{print $1}' || true)
if [[ -n "$LLAMA_PID" ]]; then
    echo -e "\n  llama-server already running (PID: $LLAMA_PID)"
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
echo "$LLAMA_PID" > "$PIDFILE"

ready=false
for _ in {1..30}; do
    if curl -sf http://localhost:8080/v1/models &>/dev/null; then
        echo "  llama-server ready (PID: $LLAMA_PID)"
        echo "  Run: hermes    ← Hermes Agent"
        echo "  Run: goose     ← Goose (if installed)"
        echo ""
        ready=true
        break
    fi
    if ! kill -0 "$LLAMA_PID" 2>/dev/null; then
        echo "  ERROR: llama-server process died unexpectedly. Check log."
        exit 1
    fi
    sleep 1
done

if [[ "$ready" != "true" ]]; then
    echo "  ERROR: llama-server not responding after 30s."
    kill "$LLAMA_PID" 2>/dev/null || true
    exit 1
fi

wait "$LLAMA_PID"
LAUNCH_TEMPLATE

export GGUF_PATH SEL_NAME LLAMA_SERVER_BIN SAFE_CTX USE_JINJA PIDFILE_PATH
PIDFILE_PATH=$(mktemp /tmp/llama-server.XXXXXX.pid)
register_tmp "$PIDFILE_PATH"
envsubst '${GGUF_PATH} ${SEL_NAME} ${LLAMA_SERVER_BIN} ${SAFE_CTX} ${USE_JINJA} ${PIDFILE_PATH}' \
    <"${LAUNCH_SCRIPT}.template" >"$LAUNCH_SCRIPT"
rm -f "${LAUNCH_SCRIPT}.template"
chmod +x "$LAUNCH_SCRIPT"
ok "Launch script: ~/start-llm.sh"

# =============================================================================
#  15. systemd user service [SKIPPED by switch-model]
# =============================================================================
if [[ -z "$_SMO" ]]; then
    step "Creating systemd user service for llama-server..."
    mkdir -p "${HOME}/.config/systemd/user"
    cat >"${HOME}/.local/bin/llama-server-wrapper" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
exec bash ~/start-llm.sh
WRAPPER
    chmod +x "${HOME}/.local/bin/llama-server-wrapper"

    cat >"${HOME}/.config/systemd/user/llama-server.service" <<SERVICE
[Unit]
Description=llama-server LLM inference (llama.cpp)
After=network.target

[Service]
Type=simple
ExecStart=${HOME}/.local/bin/llama-server-wrapper
Restart=on-failure
RestartSec=5
Environment=HOME=${HOME}
Environment=PATH=/usr/local/cuda/bin:${HOME}/.local/bin:/usr/bin:/bin
StandardOutput=append:/tmp/llama-server.log
StandardError=append:/tmp/llama-server.log

[Install]
WantedBy=default.target
SERVICE

    if systemctl --user is-system-running &>/dev/null; then
        systemctl --user enable llama-server.service 2>/dev/null || true
        ok "llama-server systemd service enabled."
        echo "  Persistent auto-start: sudo loginctl enable-linger $USER"
    else
        warn "systemd --user unavailable — use 'start-llm' to start manually."
    fi
fi

# ── Start llama-server ────────────────────────────────────────────────────────
step "Starting llama-server..."
PIDFILE_MAIN=$(mktemp /tmp/llama-server.XXXXXX.pid)
register_tmp "$PIDFILE_MAIN"
pkill -f "llama-server.*-m" 2>/dev/null || true
sleep 1

nohup bash "$LAUNCH_SCRIPT" >/tmp/llama-server.log 2>&1 &
sleep 3

READY=false
for _ in {1..30}; do
    if curl -sf http://localhost:8080/v1/models &>/dev/null; then
        ok "llama-server ready at http://localhost:8080"
        READY=true
        break
    fi
    sleep 1
done
[[ "$READY" == "false" ]] && warn "llama-server not responding after 30s — check: tail -f /tmp/llama-server.log"

# =============================================================================
#  15b. Hermes skills (if installed)
# =============================================================================
if [[ -z "$_SMO" ]] && command -v hermes &>/dev/null; then
    step "Installing recommended Hermes skills..."
    SKILLS=("github-pr-workflow" "axolotl" "huggingface-hub")
    for skill in "${SKILLS[@]}"; do
        if command -v timeout &>/dev/null; then
            if timeout 30s hermes skills install "official/${skill}" --yes --force 2>/dev/null; then
                ok "Installed skill: ${skill}"
            else
                warn "Skill '${skill}' skipped"
            fi
        else
            if hermes skills install "official/${skill}" --yes --force 2>/dev/null; then
                ok "Installed skill: ${skill}"
            else
                warn "Skill '${skill}' skipped"
            fi
        fi
    done
    ok "Skills: ~/.hermes/skills/"
fi

# =============================================================================
#  16. ~/.bashrc helpers [SKIPPED by switch-model]
# =============================================================================
if [[ -z "$_SMO" ]]; then
    step "Adding helpers to ~/.bashrc..."
    SCRIPT_SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "$0" 2>/dev/null || echo "")"
    INSTALL_COPY="${HOME}/.local/bin/install-llm.sh"
    if [[ "$SCRIPT_SELF" == "/dev/stdin" || -z "$SCRIPT_SELF" || "$SCRIPT_SELF" == "/proc/"* ]]; then
        warn "Script run via pipe — copying to ${INSTALL_COPY} for switch-model."
        mkdir -p "${HOME}/.local/bin"
        cat >"$INSTALL_COPY" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "Downloading updated installer..."
INSTALL_TMP=$(mktemp /tmp/install-llm.XXXXXX.sh)
curl -fsSL --proto '=https' --max-redirs 5 \
    https://raw.githubusercontent.com/mettbrot0815/llm-installer/refs/heads/main/install.sh \
    -o "$INSTALL_TMP" || { echo "Download failed."; rm -f "$INSTALL_TMP"; exit 1; }
chmod +x "$INSTALL_TMP"
bash "$INSTALL_TMP"
rm -f "$INSTALL_TMP"
STUB
        chmod +x "$INSTALL_COPY"
        SCRIPT_SELF="$INSTALL_COPY"
        warn "switch-model will re-download the installer."
    elif [[ -f "$SCRIPT_SELF" ]]; then
        mkdir -p "${HOME}/.local/bin"
        if cp -f "$SCRIPT_SELF" "$INSTALL_COPY" 2>/dev/null; then
            chmod +x "$INSTALL_COPY"
            SCRIPT_SELF="$INSTALL_COPY"
        else
            true
        fi
    fi

    MARKER="# === LLM setup (added by install.sh) ==="
    if ! grep -qF "$MARKER" "${HOME}/.bashrc" 2>/dev/null; then
        cat >>"${HOME}/.bashrc" <<BASHRC_EXPANDED

${MARKER}
[[ -n "\${__LLM_BASHRC_LOADED:-}" ]] && return 0
export __LLM_BASHRC_LOADED=1

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

if [[ -f "${TOKEN_FILE}" ]]; then
    while IFS='=' read -r _key _val; do
        case "\$_key" in
            HF_TOKEN) export HF_TOKEN="\$_val" ;;
            GITHUB_TOKEN) export GITHUB_TOKEN="\$_val" ;;
        esac
    done < "${TOKEN_FILE}"
fi

alias start-llm='bash ~/start-llm.sh'
alias stop-llm='pkill -f "llama-server.*-m" 2>/dev/null || true; echo "llama-server stopped."'
alias restart-llm='stop-llm; sleep 2; start-llm'
alias llm-log='tail -f /tmp/llama-server.log'
alias switch-model='SWITCH_MODEL_ONLY=1 bash ${INSTALL_COPY}'
BASHRC_EXPANDED

        cat >>"${HOME}/.bashrc" <<'BASHRC_FUNCTIONS'

vram() {
    nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits 2>/dev/null | \
        awk -F, '{printf "GPU: %s\nVRAM: %s / %s MiB\nUtil: %s%%\n",$1,$2,$3,$4}' || echo "nvidia-smi not available"
}

llm-models() {
    local active_model=""
    [[ -f ~/start-llm.sh ]] && active_model=$(grep '^GGUF=' ~/start-llm.sh 2>/dev/null | head -1 | sed 's/GGUF="//;s/".*//' | xargs basename 2>/dev/null || true)
    echo -e "\n  ${BLD}Models in $HOME/llm-models:${RST}"
    echo "  ────────────────────────────────────────────────"
    local found=0 f sz name tag
    for f in "$HOME"/llm-models/*.gguf; do
        [[ -f "$f" ]] || continue
        found=$(( found + 1 ))
        sz=$(du -h "$f" | cut -f1); name=$(basename "$f"); tag=""
        [[ "$name" == "$active_model" ]] && tag=" ${GRN}← active${RST}"
        echo -e "  ${sz}  ${name}${tag}"
    done
    [[ $found -eq 0 ]] && echo "  (no .gguf files found)"
    echo ""
}

llm-status() {
    local llama_pid active_model=""
    llama_pid=$(pgrep -f "llama-server.*-m" 2>/dev/null || true)
    [[ -f ~/start-llm.sh ]] && active_model=$(grep '^MODEL_NAME=' ~/start-llm.sh 2>/dev/null | head -1 | sed 's/MODEL_NAME="//;s/".*//' || true)
    echo -e "${BLD}${CYN}╭────────────────────────────────────────────────────────────────╮${RST}"
    echo -e "${BLD}${CYN}│${RST}  ${BLD}LLM Stack Status${RST}"
    echo -e "${BLD}${CYN}│${RST}  ──────────────────────────────────────────────────────"
    [[ -n "$active_model" ]] && echo -e "${BLD}${CYN}│${RST}  Model : ${CYN}${active_model}${RST}"
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
    echo -e "${BLD}${CYN}│${RST}  ${CYN}switch-model${RST}  Pick different model"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}llm-status${RST}    Status + active model"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}llm-log${RST}       Tail llama-server log"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}llm-models${RST}    List all .gguf files"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}vram${RST}          GPU/VRAM usage"
    echo -e "${BLD}${CYN}│${RST}  ──────────────────────────────────────────────────────"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}http://localhost:8080${RST}  → llama-server + Web UI"
    echo -e "${BLD}${CYN}╰────────────────────────────────────────────────────────────────╯${RST}"
    echo ""
}

if [[ $- == *i* ]]; then
    show_llm_summary
fi

_llm_autostart() {
    [[ $- != *i* ]] && return 0
    pgrep -f "llama-server.*-m" &>/dev/null && return 0
    [[ -f ~/start-llm.sh ]] || return 0
    local uptime_min
    uptime_min=$(awk '{print int($1/60)}' /proc/uptime 2>/dev/null || echo "0")
    local session_marker="/tmp/.llm_autostarted_${uptime_min}"
    if mkdir "${session_marker}.lock" 2>/dev/null; then
        echo -e "${YLW}[LLM] llama-server not running — auto-starting...${RST}"
        nohup bash ~/start-llm.sh < /dev/null >> /tmp/llama-server.log 2>&1 &
        disown
        rmdir "${session_marker}.lock" 2>/dev/null
    fi
}
_llm_autostart

alias clear='show_llm_summary; command clear'
BASHRC_FUNCTIONS
        ok "Helpers written to ~/.bashrc."
    else
        ok "Helpers already in ~/.bashrc — skipping."
    fi
fi

# =============================================================================
#  17. .wslconfig RAM hint [SKIPPED by switch-model]
# =============================================================================
if [[ -z "$_SMO" ]]; then
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
        WSL_RAM=$((RAM_GiB * 3 / 4))
        ((WSL_RAM < 4)) && WSL_RAM=4
        ((WSL_RAM > 64)) && WSL_RAM=64
        WSL_SWAP=$((WSL_RAM / 4))
        ((WSL_SWAP < 2)) && WSL_SWAP=2
        cat >"$WSLCONFIG" <<WSLCFG
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
#  18. Claude Configuration
# =============================================================================
if [[ -z "$_SMO" ]] && (command -v claude &>/dev/null || [[ -d "${HOME}/.claude" ]]); then
    step "Configuring Claude to use local llama.cpp server..."
    mkdir -p "${HOME}/.claude"
    cat >"${HOME}/.claude/config.json" <<CLAUDE
{
  "hooks": {},
  "statusLine": {},
  "agentModels": {
    "primary": "local/${SEL_GGUF}"
  },
  "providers": {
    "local": {
      "baseUrl": "http://127.0.0.1:8080/v1",
      "apiKey": "local",
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
if [[ -n "$_SMO" ]]; then
    cat <<'EOF'
╔══════════════════════════════════════════════════════════════╗
║              Model Switch Complete!                          ║
╚══════════════════════════════════════════════════════════════╝
EOF
else
    cat <<'EOF'
╔══════════════════════════════════════════════════════════════╗
║                   Setup Complete!                            ║
║          Smart downloads - only updated when needed          ║
╚══════════════════════════════════════════════════════════════╝
EOF
fi
echo -e "${RST}"

echo -e " ${BLD}Active model:${RST}  ${SEL_NAME}"
echo -e "               ${SEL_GGUF}"
echo -e " ${BLD}Context:${RST}       ${SAFE_CTX} tokens   ${BLD}Jinja:${RST} ${USE_JINJA}"
echo ""

if [[ -z "$_SMO" ]]; then
    echo -e " ${BLD}Installed/Updated:${RST}"
    echo -e "  llama-server  →  http://localhost:8080/v1"
    echo -e "  Hermes Agent  →  hermes"
    $INSTALL_GOOSE && echo -e "  Goose         →  goose"
    $INSTALL_OPENCODE && echo -e "  OpenCode      →  opencode  (alias: oc)"
    $INSTALL_AUTOAGENT && echo -e "  AutoAgent     →  autoagent"
    $INSTALL_OPENCLAUDE && echo -e "  OpenClaude    →  openclaude"
    $INSTALL_WEBUI && echo -e "  Hermes WebUI  →  start-webui  (http://localhost:8787)"
    echo ""
fi

echo -e " ${BLD}════ Quick Reference ════${RST}"
echo ""
echo -e " ${BLD}Server:${RST}"
echo -e "  ${CYN}start-llm${RST}       Start llama-server"
echo -e "  ${CYN}stop-llm${RST}        Stop llama-server"
echo -e "  ${CYN}restart-llm${RST}     Restart llama-server"
echo -e "  ${CYN}switch-model${RST}    Pick different model"
echo -e "  ${CYN}llm-status${RST}      Status + active model"
echo -e "  ${CYN}llm-log${RST}         Tail llama-server log"
echo -e "  ${CYN}llm-models${RST}      List all .gguf files"
echo -e "  ${CYN}vram${RST}            GPU/VRAM usage"
echo ""
echo -e " ${BLD}Agents:${RST}"
echo -e "  ${CYN}hermes${RST}          Hermes Agent"
$INSTALL_GOOSE && echo -e "  ${CYN}goose${RST}           Goose"
$INSTALL_OPENCODE && echo -e "  ${CYN}opencode${RST} / ${CYN}oc${RST}  OpenCode"
$INSTALL_AUTOAGENT && echo -e "  ${CYN}autoagent${RST}       AutoAgent"
$INSTALL_OPENCLAUDE && echo -e "  ${CYN}openclaude${RST}      OpenClaude"
$INSTALL_WEBUI && echo -e "  ${CYN}start-webui${RST}     Hermes WebUI"
echo ""
echo -e " ${YLW}Note:${RST}       source ~/.bashrc or open a new terminal."
echo -e " ${YLW}Auto-start:${RST} llama-server starts automatically on new terminal."
echo -e " ${GRN}Persistent:${RST} sudo loginctl enable-linger $USER"
echo ""

exit 0
