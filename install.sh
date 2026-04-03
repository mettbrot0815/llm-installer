#!/usr/bin/env bash
# =============================================================================
#  install.sh  –  Ubuntu WSL2  ·  llama.cpp + Hermes Agent
#
#  What this installs:
#    - llama.cpp (CUDA or CPU) → http://localhost:8080
#    - Hermes Agent (CLI)      → configured to use local llama-server
#
#  Model selector features:
#    - Shows ALL catalogue models with hardware grade (even grade F)
#    - Scans ~/llm-models for any .gguf (downloaded OR manually copied) → marks ↓
#    - 'u' option: download any model by HuggingFace URL or repo path
#    - switch-model alias re-runs this script (re-selects model, regenerates
#      start-llm.sh, restarts llama-server) — no full reinstall
#
#  Removed: Hermes Workspace, video generation, pnpm/Node.js, Qwen Code
#
#  Windows npm guard: PATH is sanitised to exclude /mnt/c/ Windows binaries
#  before any node/npm check so Windows-host npm is never picked up.
# =============================================================================
set -euo pipefail

# ── Strip Windows /mnt/* paths from PATH so Windows npm/node are never used ──
#    This must happen before any command -v node/npm check.
CLEAN_PATH=""
IFS=':' read -ra PATH_PARTS <<< "$PATH"
for part in "${PATH_PARTS[@]}"; do
    [[ "$part" == /mnt/* ]] && continue
    CLEAN_PATH="${CLEAN_PATH:+${CLEAN_PATH}:}${part}"
done
export PATH="$CLEAN_PATH"
unset CLEAN_PATH PATH_PARTS part

# ── Colour helpers ─────────────────────────────────────────────────────────────
export RED='\033[0;31m' GRN='\033[0;32m' YLW='\033[1;33m'
export CYN='\033[0;36m' BLD='\033[1m' RST='\033[0m'
step() { echo -e "\n${CYN}[*] $*${RST}"; }
ok()   { echo -e "${GRN}[+] $*${RST}"; }
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
    HF_TOKEN=$(cat "${HOME}/.cache/huggingface/token" 2>/dev/null || true)
    [[ -n "$HF_TOKEN" ]] && ok "HF_TOKEN found in ~/.cache/huggingface/token."
elif grep -qF "export HF_TOKEN=" "${HOME}/.bashrc" 2>/dev/null; then
    HF_TOKEN=$(grep "export HF_TOKEN=" "${HOME}/.bashrc" | head -1 | \
        sed 's/.*export HF_TOKEN=//' | sed "s/^[\"']//" | sed "s/[\"']$//")
    [[ -n "$HF_TOKEN" ]] && ok "HF_TOKEN found in ~/.bashrc."
fi

if [[ -z "$HF_TOKEN" ]]; then
    echo ""
    echo -e "  ${BLD}Why add a HuggingFace token?${RST}"
    echo -e "  • Faster downloads · higher rate limits · gated model access"
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
                warn "Token doesn't start with 'hf_' — using anyway, double-check it."
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
#  2. System packages
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
#  5. Model selection
#
#  Catalogue: idx|hf_repo|gguf_file|display_name|size_gb|ctx|min_ram|min_vram|tier|tags|desc
#
#  ALL models are shown regardless of grade — grade F just means "too heavy",
#  but the user can still choose it (they'll get a warning).
#
#  ~/llm-models is scanned for any .gguf on disk (downloaded OR copied there).
#  Files found there show ↓ even if they're not in the catalogue.
#
#  Entering 'u' lets the user supply a HuggingFace URL or repo+filename.
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

# ── Grade helpers ─────────────────────────────────────────────────────────────
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

# ── Infer ctx/jinja from filename (used for both catalogue and URL downloads) ─
apply_model_settings() {
    local gguf="$1"
    case "$gguf" in
        *Qwen3.5*)
            SAFE_CTX=262144; USE_JINJA="--jinja"
            ok "Qwen3.5 detected: enabling full 256K context window" ;;
        *Llama-3.1*|*Llama-3.3*|*Qwen3-30B*)
            SAFE_CTX=131072; USE_JINJA="--jinja" ;;
        *google_gemma-3*)
            SAFE_CTX=131072; USE_JINJA="--no-jinja"
            ok "Gemma 3 detected: Jinja disabled (strict role enforcement)" ;;
        *)
            SAFE_CTX=32768; USE_JINJA="--jinja" ;;
    esac
    ok "Context window: ${SAFE_CTX} tokens"
}

# ── Draw model table ──────────────────────────────────────────────────────────
show_model_table() {
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

    local last_tier=""
    local idx hf_repo gguf_file dname size_gb ctx min_ram min_vram tier tags desc
    while IFS='|' read -r idx hf_repo gguf_file dname size_gb ctx min_ram min_vram tier tags desc; do
        idx="${idx// /}"; dname="${dname# }"; dname="${dname% }"
        size_gb="${size_gb// /}"; ctx="${ctx// /}"
        min_ram="${min_ram// /}"; min_vram="${min_vram// /}"
        tier="${tier// /}"; tags="${tags// /}"; gguf_file="${gguf_file// /}"

        if [[ "$tier" != "$last_tier" ]]; then
            case $tier in
                tiny)  echo -e "\n  ${BLD}▸ TINY   (< 1 GB · instant · edge/test)${RST}" ;;
                small) echo -e "\n  ${BLD}▸ SMALL  (1–2 GB · fast CPU · everyday use)${RST}" ;;
                mid)   echo -e "\n  ${BLD}▸ MID    (4–17 GB · quality/speed balance)${RST}" ;;
                large) echo -e "\n  ${BLD}▸ LARGE  (15 GB+ · high-end GPU or lots of RAM)${RST}" ;;
            esac
            last_tier="$tier"
        fi

        local GRADE GC GL cached tag_display
        GRADE=$(grade_model "$min_ram" "$min_vram" "$RAM_GiB" "$VRAM_GiB" "$HAS_NVIDIA")
        GC=$(grade_color "$GRADE")
        GL=$(grade_label "$GRADE")

        # Mark as present if the file exists in MODEL_DIR regardless of how it got there
        if [[ -f "${MODEL_DIR}/${gguf_file}" ]]; then
            cached=" ${CYN}↓${RST}"
        else
            cached=""
        fi

        tag_display="${tags//,/ }"
        echo -e "  ${BLD}$(printf '%2s' "$idx")${RST}  $(printf '%-26s' "$dname")  $(printf '%5s' "$size_gb") GB  $(printf '%-7s' "$ctx")  ${GC}$(printf '%-13s' "$GL")${RST}  $(printf '%-24s' "$tag_display") $cached"

    done < <(printf '%s\n' "${MODELS[@]}")

    # Show any .gguf files in MODEL_DIR not in the catalogue (manually copied)
    local extra_count=0 f fname
    for f in "${MODEL_DIR}"/*.gguf; do
        [[ -f "$f" ]] || continue
        fname=$(basename "$f")
        local in_cat=false
        local _idx _repo cat_gguf _rest
        while IFS='|' read -r _idx _repo cat_gguf _rest; do
            [[ "${cat_gguf// /}" == "$fname" ]] && { in_cat=true; break; }
        done < <(printf '%s\n' "${MODELS[@]}")
        if [[ "$in_cat" == "false" ]]; then
            (( extra_count++ ))
            if (( extra_count == 1 )); then
                echo -e "\n  ${BLD}▸ LOCAL  (in ~/llm-models, not in catalogue)${RST}"
            fi
            local sz; sz=$(du -h "$f" 2>/dev/null | cut -f1)
            echo -e "  ${CYN}↓${RST}  ${fname}  (${sz})"
        fi
    done

    echo ""
    echo    "  ─────────────────────────────────────────────────────────────────────────────"
    echo -e "  ${GRN}S/A${RST} Runs great/well   ${YLW}B/C${RST} Tight fit   ${RED}F${RST} Too heavy   ${CYN}↓${RST} Already on disk"
    echo ""
    echo -e "  ${YLW}Tip:${RST} @sudoingX used model 5 (Qwen 3.5 9B) on RTX 3060 12GB"
    echo -e "  Enter a number, or ${BLD}u${RST} to download via HuggingFace URL."
    echo ""
}

# ── HuggingFace URL / repo download ──────────────────────────────────────────
# Sets: SEL_GGUF  SEL_NAME  GGUF_PATH  SAFE_CTX  USE_JINJA
# Requires: HF_CLI already set
download_from_hf_url() {
    echo ""
    echo -e "  ${BLD}Download a model via HuggingFace${RST}"
    echo -e "  Accepted formats:"
    echo -e "    https://huggingface.co/bartowski/Llama-3.1-8B.../resolve/main/file.gguf"
    echo -e "    bartowski/Llama-3.1-8B-Instruct-GGUF  (repo — you pick the file)"
    echo ""
    read -rp "  Paste URL or repo (owner/name): " HF_INPUT
    HF_INPUT="${HF_INPUT//[[:space:]]/}"
    [[ -z "$HF_INPUT" ]] && die "No input provided."

    if [[ "$HF_INPUT" =~ ^https?:// ]]; then
        # ── Direct URL ──────────────────────────────────────────────────────
        SEL_GGUF=$(basename "$HF_INPUT")
        SEL_GGUF="${SEL_GGUF%%\?*}"    # strip query string
        [[ "$SEL_GGUF" != *.gguf ]] && die "URL does not point to a .gguf file: $SEL_GGUF"
        SEL_NAME="${SEL_GGUF%.gguf}"
        GGUF_PATH="${MODEL_DIR}/${SEL_GGUF}"
        SEL_HF_REPO=""

        if [[ -f "$GGUF_PATH" ]]; then
            ok "Already on disk: ${GGUF_PATH}"
        else
            step "Downloading ${SEL_GGUF}..."
            local curl_args=(-fL --progress-bar -o "$GGUF_PATH")
            [[ -n "${HF_TOKEN:-}" ]] && curl_args+=(-H "Authorization: Bearer ${HF_TOKEN}")
            curl "${curl_args[@]}" "$HF_INPUT" || die "curl download failed."
            [[ -f "$GGUF_PATH" ]] || die "File not found after download."
            local fsize; fsize=$(stat -c%s "$GGUF_PATH" 2>/dev/null || echo 0)
            (( fsize < 104857600 )) && die "Downloaded file too small (${fsize} bytes) — check URL."
            ok "Downloaded: ${GGUF_PATH}"
        fi
    else
        # ── Repo path (owner/repo) ───────────────────────────────────────────
        SEL_HF_REPO="$HF_INPUT"
        step "Listing GGUF files in ${SEL_HF_REPO}..."

        # Try --dry-run to list files (not all CLI versions support it)
        local list_output="" gf_choice
        if list_output=$(HF_TOKEN="${HF_TOKEN:-}" "$HF_CLI" download "$SEL_HF_REPO" \
                --include "*.gguf" --dry-run 2>/dev/null); then
            mapfile -t GGUF_FILES < <(echo "$list_output" | grep -i '\.gguf$' | \
                awk '{print $NF}' | xargs -I{} basename {} | sort)
        else
            GGUF_FILES=()
        fi

        if [[ ${#GGUF_FILES[@]} -eq 0 ]]; then
            warn "Could not auto-list files. Enter the exact GGUF filename manually."
            read -rp "  Filename (e.g. model-Q4_K_M.gguf): " SEL_GGUF
            SEL_GGUF="${SEL_GGUF//[[:space:]]/}"
            [[ -z "$SEL_GGUF" ]] && die "No filename provided."
        elif [[ ${#GGUF_FILES[@]} -eq 1 ]]; then
            SEL_GGUF="${GGUF_FILES[0]}"
            ok "Only one GGUF found: ${SEL_GGUF}"
        else
            echo ""
            echo -e "  ${BLD}Available GGUF files in ${SEL_HF_REPO}:${RST}"
            local fi=1
            for gf in "${GGUF_FILES[@]}"; do
                printf "  %2d  %s\n" "$fi" "$gf"
                (( fi++ ))
            done
            echo ""
            while true; do
                read -rp "  Enter number [1-${#GGUF_FILES[@]}]: " gf_choice
                [[ "$gf_choice" =~ ^[0-9]+$ ]] && \
                    (( gf_choice >= 1 && gf_choice <= ${#GGUF_FILES[@]} )) && break
                warn "Invalid choice."
            done
            SEL_GGUF="${GGUF_FILES[$((gf_choice-1))]}"
        fi

        SEL_NAME="${SEL_GGUF%.gguf}"
        GGUF_PATH="${MODEL_DIR}/${SEL_GGUF}"

        if [[ -f "$GGUF_PATH" ]]; then
            ok "Already on disk: ${GGUF_PATH}"
        else
            step "Downloading ${SEL_GGUF} from ${SEL_HF_REPO}..."
            if [[ -n "${HF_TOKEN:-}" ]]; then
                HF_TOKEN="${HF_TOKEN}" "$HF_CLI" download "$SEL_HF_REPO" "$SEL_GGUF" \
                    --local-dir "$MODEL_DIR"
            else
                "$HF_CLI" download "$SEL_HF_REPO" "$SEL_GGUF" --local-dir "$MODEL_DIR"
            fi
            [[ -f "$GGUF_PATH" ]] || die "Download completed but file not found."
            local fsize; fsize=$(stat -c%s "$GGUF_PATH" 2>/dev/null || echo 0)
            (( fsize < 104857600 )) && die "Downloaded file too small (${fsize} bytes)."
            ok "Downloaded: ${GGUF_PATH}"
        fi
    fi

    apply_model_settings "$SEL_GGUF"
}

# =============================================================================
#  6. HuggingFace CLI setup (needed before model selection for URL option)
# =============================================================================
step "Setting up HuggingFace CLI..."
export PATH="${HOME}/.local/bin:${PATH}"

HF_CLI_PATH="${HOME}/.local/bin/hf"
HF_CLI_LEGACY="${HOME}/.local/bin/huggingface-cli"

if [[ ! -x "$HF_CLI_PATH" && ! -x "$HF_CLI_LEGACY" ]]; then
    pip3 install --quiet --user --break-system-packages huggingface_hub
fi

# Keep HF CLI up to date
pip3 install --quiet --user --break-system-packages --upgrade huggingface_hub 2>&1 | tail -2

if [[ -x "$HF_CLI_PATH" ]]; then
    HF_CLI="$HF_CLI_PATH"; HF_CLI_NAME="hf"
elif [[ -x "$HF_CLI_LEGACY" ]]; then
    HF_CLI="$HF_CLI_LEGACY"; HF_CLI_NAME="huggingface-cli"
else
    die "Neither 'hf' nor 'huggingface-cli' found after install."
fi
"$HF_CLI" version &>/dev/null || die "'$HF_CLI_NAME' found but fails to run."
ok "$HF_CLI_NAME ready: $("$HF_CLI" version 2>/dev/null || echo 'ok')"

if [[ -n "${HF_TOKEN:-}" ]]; then
    if "$HF_CLI" auth login --token "$HF_TOKEN" 2>/dev/null; then
        ok "HF login completed."
    elif "$HF_CLI" login --token "$HF_TOKEN" 2>/dev/null; then
        ok "HF login completed (legacy CLI)."
    else
        ok "HF token ready (may be cached)."
    fi
    "$HF_CLI" auth whoami &>/dev/null 2>&1 && ok "HF login verified." || \
        warn "HF login could not be verified — downloads will be unauthenticated."
fi

# =============================================================================
#  5 (continued). Run model selector
# =============================================================================
NUM_MODELS=${#MODELS[@]}
SEL_IDX="" SEL_HF_REPO="" SEL_GGUF="" SEL_NAME="" SEL_MIN_RAM="0" SEL_MIN_VRAM="0"
SAFE_CTX=32768
USE_JINJA="--jinja"
GGUF_PATH=""
CHOICE=""

show_model_table

while true; do
    if [[ ! -t 0 ]]; then
        warn "Non-interactive – defaulting to model 5 (Qwen 3.5 9B)"
        CHOICE="5"
        break
    fi
    read -rp "$(echo -e "  ${BLD}Enter model number [1-${NUM_MODELS}] or 'u' for URL:${RST} ")" CHOICE
    if [[ "$CHOICE" == "u" || "$CHOICE" == "U" ]]; then
        download_from_hf_url
        break
    elif [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= NUM_MODELS )); then
        break
    fi
    warn "Please enter a number between 1 and ${NUM_MODELS}, or 'u'."
done

# Parse catalogue selection
if [[ "$CHOICE" != "u" && "$CHOICE" != "U" ]]; then
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
            [[ "$go_anyway" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
        else
            warn "Non-interactive – continuing anyway."
        fi
    elif [[ "$GRADE_SEL" == "C" ]]; then
        warn "Grade C — tight fit, expect slow responses."
    fi

    apply_model_settings "$SEL_GGUF"
    GGUF_PATH="${MODEL_DIR}/${SEL_GGUF}"
fi

# =============================================================================
#  7. Download model from catalogue (if not already present)
# =============================================================================
if [[ -f "$GGUF_PATH" ]]; then
    ok "Model already on disk: ${GGUF_PATH} — skipping download."
elif [[ "$CHOICE" != "u" && "$CHOICE" != "U" ]]; then
    step "Downloading ${SEL_NAME} from HuggingFace..."
    warn "This may take several minutes depending on model size and connection."

    AVAIL_KB=$(df -k "${MODEL_DIR}" | awk 'NR==2 {print $4}')
    AVAIL_GB=$(( AVAIL_KB / 1024 / 1024 ))

    # Exact index match to get size (avoids "1" matching "11" or "12")
    REQ_GB=""
    while IFS='|' read -r idx _ _ _ size_gb _ _ _ _ _ _; do
        [[ "${idx// /}" == "$CHOICE" ]] && { REQ_GB="${size_gb// /}"; break; }
    done < <(printf '%s\n' "${MODELS[@]}")

    REQ_GB_INT=${REQ_GB%.*}
    [[ "$REQ_GB" == *"."* ]] && REQ_GB_INT=$(( REQ_GB_INT + 1 ))
    REQ_GB_INT=$(( REQ_GB_INT + 2 ))
    (( REQ_GB_INT < 3 )) && REQ_GB_INT=3
    (( AVAIL_GB < REQ_GB_INT )) && die "Insufficient disk: need ~${REQ_GB_INT}GB, have ${AVAIL_GB}GB."
    ok "Disk space OK: ${AVAIL_GB}GB available, ~${REQ_GB_INT}GB needed."

    if [[ -n "${HF_TOKEN:-}" ]]; then
        HF_TOKEN="${HF_TOKEN}" "$HF_CLI" download "${SEL_HF_REPO}" "${SEL_GGUF}" --local-dir "${MODEL_DIR}"
    else
        "$HF_CLI" download "${SEL_HF_REPO}" "${SEL_GGUF}" --local-dir "${MODEL_DIR}"
    fi

    [[ -f "$GGUF_PATH" ]] || die "Download completed but file not found."
    FILE_SIZE=$(stat -c%s "$GGUF_PATH" 2>/dev/null || echo 0)
    (( FILE_SIZE < 104857600 )) && die "Downloaded file suspiciously small (${FILE_SIZE} bytes)."
    if command -v numfmt &>/dev/null; then
        ok "Model downloaded: ${GGUF_PATH} ($(numfmt --to=iec-i --suffix=B "${FILE_SIZE}"))"
    else
        ok "Model downloaded: ${GGUF_PATH} (${FILE_SIZE} bytes)"
    fi
fi

# =============================================================================
#  8. Build llama.cpp (skip if binary already exists)
# =============================================================================
step "Checking llama.cpp..."

find_llama_server() {
    local p version_output
    for p in /usr/local/bin/llama-server /usr/bin/llama-server \
              "${HOME}/.local/bin/llama-server" \
              "${HOME}/llama.cpp/build/bin/llama-server"; do
        if [[ -x "$p" ]]; then
            version_output=$("$p" --version 2>&1) || continue
            echo "$version_output" | grep -qiE 'llama|ggml' && { echo "$p"; return 0; }
        fi
    done
    # Generic search under build dir
    local found
    found=$(find "${HOME}/llama.cpp" -name "llama-server" -type f -executable 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then
        version_output=$("$found" --version 2>&1) || true
        echo "$version_output" | grep -qiE 'llama|ggml' && { echo "$found"; return 0; }
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
        warn "ccache not found — building without cache"
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
#  9. Hermes Agent (outsourc-e fork with WebAPI)
# =============================================================================
step "Setting up Hermes Agent..."
HERMES_AGENT_DIR="${HOME}/hermes-agent"
HERMES_VENV="${HERMES_AGENT_DIR}/.venv"
HERMES_BIN="${HOME}/.local/bin/hermes"
export PATH="${HOME}/.local/bin:${PATH}"

# Clone or update
if [[ -d "${HERMES_AGENT_DIR}/.git" ]]; then
    ok "Hermes Agent already cloned — updating..."
    cd "${HERMES_AGENT_DIR}"
    git fetch origin 2>/dev/null && git reset --hard origin/main 2>/dev/null || \
        warn "Hermes git update failed (continuing with existing code)"
    cd - >/dev/null
else
    step "Cloning outsourc-e/hermes-agent..."
    git clone https://github.com/outsourc-e/hermes-agent.git "${HERMES_AGENT_DIR}" 2>&1 | tail -3
    ok "Hermes Agent cloned."
fi

# Create Python 3.11 venv
if [[ ! -d "${HERMES_VENV}" ]]; then
    step "Creating Python 3.11 virtual environment..."
    python3.11 -m venv "${HERMES_VENV}"
    ok "Venv created at ${HERMES_VENV}"
else
    ok "Venv already exists at ${HERMES_VENV}"
fi

# Install dependencies
if ! "${HERMES_VENV}/bin/python" -c "import fastapi" &>/dev/null; then
    step "Installing Hermes Agent dependencies (~2-5 min first time)..."
    "${HERMES_VENV}/bin/pip" install -e "${HERMES_AGENT_DIR}[all]"
    ok "Hermes Agent dependencies installed."
else
    ok "Hermes Agent dependencies already installed."
fi

# Symlink hermes binary
HERMES_VENV_BIN="${HERMES_VENV}/bin/hermes"
if [[ -x "$HERMES_VENV_BIN" ]]; then
    mkdir -p "${HOME}/.local/bin"
    ln -sf "$HERMES_VENV_BIN" "$HERMES_BIN"
    ok "Symlinked hermes → ${HERMES_BIN}"
else
    warn "hermes binary not found in venv — WebAPI will use 'python -m webapi' directly"
fi

# Configure ~/.hermes
HERMES_DIR="${HOME}/.hermes"
mkdir -p "${HERMES_DIR}"/{cron,sessions,logs,memories,skills}

cat > "${HERMES_DIR}/.env" <<ENV
OPENAI_API_KEY=llama
OPENAI_BASE_URL=http://localhost:8080/v1
LLM_MODEL=${SEL_NAME}
HERMES_WEBAPI_HOST=0.0.0.0
HERMES_WEBAPI_PORT=8642
ENV
ok "~/.hermes/.env written."

cat > "${HERMES_DIR}/config.yaml" <<CONFIG
# Hermes Agent Configuration — generated by install.sh
model:
  default: "${SEL_NAME}"
  provider: custom
  base_url: http://localhost:8080/v1
  api_key: llama
CONFIG
ok "config.yaml written — Hermes → llama-server (${SEL_NAME})"

# Hermes WebAPI systemd service
# Wants= instead of Requires= so cascade failure in WSL2 doesn't block startup
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
    warn "systemd --user unavailable — start WebAPI manually."
fi

# =============================================================================
#  10. Update pip
# =============================================================================
step "Updating pip..."
pip3 install --user --break-system-packages --upgrade pip setuptools wheel 2>/dev/null || true
ok "pip updated."

# =============================================================================
#  11. Create ~/start-llm.sh
#
#  Starts llama-server + Hermes WebAPI.
#
#  envsubst allowlist ensures only installer-time variables are substituted.
#  Runtime variables ($LLAMA_PID, $kill_choice, $idx etc.) stay as literals.
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

# Check for already-running services
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
echo "  Model  : ${MODEL_NAME}"
echo "  Context: ${SAFE_CTX} tokens"
echo "  Jinja  : ${USE_JINJA}"
echo ""
echo "  llama-server  → http://localhost:8080/v1"
echo "  Hermes WebAPI → http://localhost:8642"
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
        echo "  Hermes WebAPI ready at http://localhost:8642"
        break
    fi
    sleep 1
done

echo ""
echo "All services started."
echo "  llama-server API : http://localhost:8080/v1"
echo "  llama.cpp Web UI : http://localhost:8080"
echo "  Hermes WebAPI    : http://localhost:8642"
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
#  12. systemd user service — llama-server (direct, not via start-llm.sh)
#      ExecStart paths are quoted to handle spaces in home dir paths.
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
    echo "  Auto-start on login: sudo loginctl enable-linger $USER"
else
    warn "systemd --user unavailable — use 'start-llm' to start services."
fi

# Start services now
step "Starting services..."
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
[[ "$READY" == "false" ]] && \
    warn "llama-server not responding in 30s — check: tail -f /tmp/llama-server.log"

# =============================================================================
#  13. ~/.bashrc helpers
#
#  Key alias: switch-model
#    Re-runs this script (shows model selector, downloads if needed, regenerates
#    start-llm.sh, restarts llama-server with the new model).
#    This is a true model switch — not just a display.
#
#  llm-models scans ~/llm-models for ALL .gguf files (downloaded or copied).
#
#  PATH in bashrc explicitly excludes /mnt/* Windows paths at the top so that
#  Windows npm/node are never picked up in future shells either.
# =============================================================================
step "Adding helpers to ~/.bashrc..."

# Resolve own path so switch-model keeps working after install
SCRIPT_SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"

MARKER="# === LLM setup (added by install.sh) ==="
if grep -qF "$MARKER" "${HOME}/.bashrc" 2>/dev/null; then
    ok "Helpers already in ~/.bashrc — skipping."
else
    # Static section — expanded now so installer-time paths go in
    cat >> "${HOME}/.bashrc" <<BASHRC_EXPANDED

${MARKER}
[[ -n "\${__LLM_BASHRC_LOADED:-}" ]] && return 0
export __LLM_BASHRC_LOADED=1

# Strip Windows /mnt/* from PATH so Windows npm/node are never used
_clean_path=""
IFS=':' read -ra _parts <<< "\$PATH"
for _p in "\${_parts[@]}"; do
    [[ "\$_p" == /mnt/* ]] && continue
    _clean_path="\${_clean_path:+\${_clean_path}:}\${_p}"
done
export PATH="\$_clean_path"
unset _clean_path _parts _p

export RED='\033[0;31m' GRN='\033[0;32m' YLW='\033[1;33m'
export CYN='\033[0;36m' BLD='\033[1m' RST='\033[0m'
export PATH="/usr/local/cuda/bin:\${PATH}"
export LD_LIBRARY_PATH="/usr/local/cuda/lib64:\${LD_LIBRARY_PATH:-}"
export PATH="\${HOME}/.local/bin:\${PATH}"

alias start-llm='bash ~/start-llm.sh'
alias stop-llm='pkill -f llama-server 2>/dev/null; pkill -f "python -m webapi" 2>/dev/null; echo "All LLM services stopped."'
alias restart-llm='stop-llm; sleep 2; start-llm'
alias llm-log='tail -f /tmp/llama-server.log'

# switch-model: re-runs the installer (model selector only), regenerates
# start-llm.sh with the new model, and restarts llama-server.
alias switch-model='bash ${SCRIPT_SELF}'

alias start-hermes-api='cd ${HERMES_AGENT_DIR} && ${HERMES_VENV}/bin/python -m webapi'
alias stop-hermes-api='pkill -f "python -m webapi" 2>/dev/null; echo "Hermes WebAPI stopped."'
BASHRC_EXPANDED

    # Write HF_TOKEN if present
    if [[ -n "${HF_TOKEN:-}" ]] && ! grep -qF "export HF_TOKEN=" "${HOME}/.bashrc" 2>/dev/null; then
        echo "export HF_TOKEN=\"${HF_TOKEN}\"" >> "${HOME}/.bashrc"
        ok "HF_TOKEN added to ~/.bashrc."
    fi

    # Pure functions — single-quoted so they go in verbatim (no expansion here)
    cat >> "${HOME}/.bashrc" <<'BASHRC_FUNCTIONS'

vram() {
    nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu \
        --format=csv,noheader,nounits 2>/dev/null | \
        awk -F, '{printf "GPU: %s\nVRAM: %s / %s MiB\nUtil: %s%%\n",$1,$2,$3,$4}' || \
        echo "nvidia-smi not available"
}

# llm-models: scan ~/llm-models for ALL .gguf files (downloaded OR manually copied)
llm-models() {
    local active_model=""
    if [[ -f ~/start-llm.sh ]]; then
        active_model=$(grep '^GGUF=' ~/start-llm.sh 2>/dev/null | head -1 | \
            sed 's/GGUF="//;s/".*//' | xargs basename 2>/dev/null || true)
    fi
    echo -e "\n  ${BLD}Models in ~/llm-models:${RST}"
    echo "  ────────────────────────────────────────────────"
    local found=0
    for f in ~/llm-models/*.gguf; do
        [[ -f "$f" ]] || continue
        (( found++ ))
        local size name tag
        size=$(du -h "$f" | cut -f1)
        name=$(basename "$f")
        tag=""
        [[ "$name" == "$active_model" ]] && tag=" ${GRN}← active${RST}"
        echo -e "  ${size}  ${name}${tag}"
    done
    [[ $found -eq 0 ]] && echo "  (no .gguf files found)"
    echo ""
}

llm-status() {
    local llama_pid webapi_pid
    llama_pid=$(pgrep -f "llama-server" 2>/dev/null || true)
    webapi_pid=$(pgrep -f "python -m webapi" 2>/dev/null || true)
    local active_model=""
    [[ -f ~/start-llm.sh ]] && \
        active_model=$(grep '^MODEL_NAME=' ~/start-llm.sh 2>/dev/null | head -1 | \
            sed 's/MODEL_NAME="//;s/".*//' || true)

    echo -e "${BLD}${CYN}╭────────────────────────────────────────────────────────────────╮${RST}"
    echo -e "${BLD}${CYN}│${RST}  ${BLD}LLM Stack Status${RST}"
    echo -e "${BLD}${CYN}│${RST}  ──────────────────────────────────────────────────────"
    [[ -n "$active_model" ]] && \
        echo -e "${BLD}${CYN}│${RST}  Model : ${CYN}${active_model}${RST}"
    if [[ -n "$llama_pid" ]]; then
        echo -e "${GRN}  ✓ llama-server   → http://localhost:8080  (PID: $llama_pid)${RST}"
    else
        echo -e "${RED}  ✗ llama-server   → not running${RST}"
    fi
    if [[ -n "$webapi_pid" ]]; then
        echo -e "${GRN}  ✓ Hermes WebAPI  → http://localhost:8642  (PID: $webapi_pid)${RST}"
    else
        echo -e "${YLW}  ⚠ Hermes WebAPI  → not running${RST}"
    fi
    echo -e "${BLD}${CYN}│${RST}  ──────────────────────────────────────────────────────"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}start-llm${RST} · ${CYN}stop-llm${RST} · ${CYN}switch-model${RST} · ${CYN}llm-models${RST}"
    echo -e "${BLD}${CYN}╰────────────────────────────────────────────────────────────────╯${RST}"
}

show_llm_summary() {
    echo -e "${BLD}${CYN}╭────────────────────────────────────────────────────────────────╮${RST}"
    echo -e "${BLD}${CYN}│${RST}  ${BLD}LLM Quick Commands${RST}"
    echo -e "${BLD}${CYN}│${RST}  ──────────────────────────────────────────────────────"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}start-llm${RST}       Start llama-server + Hermes WebAPI"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}stop-llm${RST}        Stop all services"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}restart-llm${RST}     Restart all services"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}switch-model${RST}    Pick a different model & restart"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}llm-status${RST}      Check running services + active model"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}llm-log${RST}         Tail llama-server log"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}llm-models${RST}      List all models in ~/llm-models"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}vram${RST}            GPU/VRAM usage"
    echo -e "${BLD}${CYN}│${RST}  ──────────────────────────────────────────────────────"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}http://localhost:8080${RST}  → llama-server + Web UI"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}http://localhost:8642${RST}  → Hermes WebAPI"
    echo -e "${BLD}${CYN}╰────────────────────────────────────────────────────────────────╯${RST}"
    echo ""
}

[[ $- == *i* && ! -f "${HOME}/.llm_summary_shown" ]] && { show_llm_summary; touch "${HOME}/.llm_summary_shown"; }
BASHRC_FUNCTIONS

    ok "Helpers written to ~/.bashrc."
fi

# =============================================================================
#  14. .wslconfig RAM hint
# =============================================================================
WIN_USER=$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r\n' || echo "")
WSLCONFIG="" WSLCONFIG_DIR=""

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
echo -e " ${BLD}Installed:${RST}"
echo -e "  llama-server  →  http://localhost:8080/v1"
echo -e "  llama.cpp UI  →  http://localhost:8080"
echo -e "  Hermes WebAPI →  http://localhost:8642"
echo -e "  Model         →  ${SEL_NAME}  (context: ${SAFE_CTX} tokens)"
echo ""
echo -e " ${BLD}Usage:${RST}"
echo -e "  ${CYN}start-llm${RST}      Start llama-server + Hermes WebAPI"
echo -e "  ${CYN}stop-llm${RST}       Stop all services"
echo -e "  ${CYN}restart-llm${RST}    Restart all services"
echo -e "  ${CYN}switch-model${RST}   Pick a different model & restart"
echo -e "  ${CYN}llm-status${RST}     Check running services + active model"
echo -e "  ${CYN}llm-log${RST}        Tail llama-server log"
echo -e "  ${CYN}llm-models${RST}     List all models in ~/llm-models"
echo -e "  ${CYN}vram${RST}           GPU/VRAM usage"
echo ""
echo -e " ${YLW}Note:${RST} Run 'source ~/.bashrc' or open a new terminal."
echo -e " ${GRN}Auto-start:${RST} sudo loginctl enable-linger $USER"
echo ""
