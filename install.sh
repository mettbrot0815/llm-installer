#!/usr/bin/env bash
# =============================================================================
#  install.sh  –  Ubuntu WSL2  ·  llama.cpp + Hermes Agent (official) + Goose
#
#  What this installs:
#    - llama.cpp (CUDA or CPU)       → http://localhost:8080
#    - Hermes Agent (NousResearch)   → CLI agent, configured for local server
#    - Goose (block/goose)           → optional CLI agent (offered at end)
#
#  Key facts used to write this:
#    • Official Hermes: NousResearch/hermes-agent (uses uv, NOT outsourc-e fork)
#      - No WebAPI, no "python -m webapi" — that was a third-party fork
#      - Config: ~/.hermes/config.yaml  provider: custom + base_url
#      - OPENAI_BASE_URL / LLM_MODEL env vars are DEPRECATED — use config.yaml
#      - Install: official script or uv + venv + pip install -e ".[all]"
#    • Goose (block/goose): OpenAI-compat agent via GOOSE_PROVIDER=openai,
#      OPENAI_HOST=http://localhost:8080, OPENAI_BASE_PATH=v1/chat/completions
#      GOOSE_MODEL=<exact gguf filename>, OPENAI_API_KEY=sk-no-key-needed
#    • Phi-4-mini repo renamed: bartowski/microsoft_Phi-4-mini-instruct-GGUF
#      filename: microsoft_Phi-4-mini-instruct-Q4_K_M.gguf
#    • Gemma 4: context 132K (128K + headroom), --no-jinja
#    • start-llm.sh auto-start: added via ~/.bashrc on first interactive login
#      using a "first-boot" marker file approach
#
#  Removed: outsourc-e WebAPI, Hermes Workspace, pnpm/Node.js, video gen,
#           Qwen Code, all workspace aliases
# =============================================================================
set -euo pipefail

# ── Strip Windows /mnt/* from PATH so Windows npm/node are never used ─────────
_wsl_clean_path=""
IFS=':' read -ra _pp <<< "$PATH"
for _p in "${_pp[@]}"; do [[ "$_p" == /mnt/* ]] && continue; _wsl_clean_path="${_wsl_clean_path:+${_wsl_clean_path}:}${_p}"; done
export PATH="$_wsl_clean_path"; unset _wsl_clean_path _pp _p

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
            [[ "$HF_TOKEN" =~ ^hf_ ]] && ok "Token accepted." || \
                warn "Token doesn't start with 'hf_' — using anyway, double-check it."
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
    build-essential cmake git \
    libcurl4-openssl-dev software-properties-common \
    python3 python3-pip python3-venv \
    pciutils wget curl ca-certificates zstd \
    procps gettext-base ccache
ok "System packages ready."

# Python 3.11 for Hermes Agent
step "Checking Python 3.11..."
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
        ok "GPU: ${GPU_NAME}  (${VRAM_GiB} GiB VRAM) — CUDA OK"
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
#  Changes from previous version:
#    • Phi-4-mini: repo renamed to bartowski/microsoft_Phi-4-mini-instruct-GGUF
#      filename: microsoft_Phi-4-mini-instruct-Q4_K_M.gguf
#    • Gemma 4 (12B it): context 132K, --no-jinja (as before for Gemma)
#    • All models shown regardless of grade (F = too heavy, not hidden)
#    • Local scan: ~/llm-models/*.gguf shown even if not in catalogue
#    • 'u' option: download via HF URL or owner/repo
# =============================================================================
MODELS=(
    "1|unsloth/Qwen3.5-0.8B-GGUF|Qwen3.5-0.8B-Q4_K_M.gguf|Qwen 3.5 0.8B|0.5|256K|2|0|tiny|chat,edge|Alibaba · instant · smoke-test"
    "2|unsloth/Qwen3.5-2B-GGUF|Qwen3.5-2B-Q4_K_M.gguf|Qwen 3.5 2B|1.0|256K|3|0|tiny|chat,multilingual|Alibaba · ultra-fast"
    "3|unsloth/Qwen3.5-4B-GGUF|Qwen3.5-4B-Q4_K_M.gguf|Qwen 3.5 4B|2.0|256K|4|0|small|chat,code|Alibaba · capable on CPU"
    "4|bartowski/microsoft_Phi-4-mini-instruct-GGUF|microsoft_Phi-4-mini-instruct-Q4_K_M.gguf|Phi-4 Mini 3.8B|2.0|16K|4|0|small|reasoning,code|Microsoft · strong reasoning"
    "5|unsloth/Qwen3.5-9B-GGUF|Qwen3.5-9B-Q4_K_M.gguf|Qwen 3.5 9B|5.3|256K|8|6|mid|chat,code,reasoning|@sudoingX pick · 50 tok/s on 3060"
    "6|bartowski/Meta-Llama-3.1-8B-Instruct-GGUF|Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf|Llama 3.1 8B|4.1|128K|8|6|mid|chat,code,reasoning|Meta · excellent instruction"
    "7|bartowski/Qwen2.5-Coder-14B-Instruct-GGUF|Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf|Qwen2.5 Coder 14B|8.99|32K|12|10|mid|code|#1 coding on 3060"
    "8|unsloth/Qwen3-14B-GGUF|Qwen3-14B-Q4_K_M.gguf|Qwen 3 14B|9.0|32K|14|10|mid|chat,code,reasoning|Strong planning"
    "9|bartowski/google_gemma-3-12b-it-GGUF|google_gemma-3-12b-it-Q4_K_M.gguf|Gemma 3 12B|7.3|128K|12|10|mid|chat,code|Google Gemma 3 · strict output"
    "10|bartowski/google_gemma-4-12b-it-GGUF|google_gemma-4-12b-it-Q4_K_M.gguf|Gemma 4 12B|7.3|132K|12|10|mid|chat,code|Google Gemma 4 · strict output"
    "11|unsloth/Qwen3-30B-A3B-GGUF|Qwen3-30B-A3B-Q4_K_M.gguf|Qwen 3 30B MoE|17.0|128K|20|16|large|chat,code,reasoning|MoE · 3B active"
    "12|bartowski/DeepSeek-R1-Distill-Qwen-32B-GGUF|DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf|DeepSeek R1 32B|17.0|64K|32|20|large|reasoning|R1 distill"
    "13|unsloth/Llama-3.3-70B-Instruct-GGUF|Llama-3.3-70B-Instruct-Q4_K_M.gguf|Llama 3.3 70B|39.0|128K|48|40|large|chat,reasoning,code|Meta · 24GB+ VRAM"
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
    case $1 in S) echo "S  Runs great ";; A) echo "A  Runs well  ";;
               B) echo "B  Decent     ";; C) echo "C  Tight fit  ";;
               F) echo "F  Too heavy  ";; *) echo "?  Unknown    ";; esac
}
grade_color() { case $1 in S|A) echo "${GRN}";; B|C) echo "${YLW}";; *) echo "${RED}";; esac; }

# ── Context + Jinja settings (shared by catalogue and URL paths) ──────────────
apply_model_settings() {
    local gguf="$1"
    case "$gguf" in
        *Qwen3.5*)
            SAFE_CTX=262144; USE_JINJA="--jinja"
            ok "Qwen3.5: full 256K context" ;;
        *Llama-3.1*|*Llama-3.3*|*Qwen3-30B*)
            SAFE_CTX=131072; USE_JINJA="--jinja" ;;
        *google_gemma-4*|*gemma-4*)
            # Gemma 4: 132K context, Jinja disabled (strict role enforcement)
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

# ── Draw model table ──────────────────────────────────────────────────────────
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
    echo    "  ─────────────────────────────────────────────────────────────────────────────"

    local last_tier="" idx hf_repo gguf_file dname size_gb ctx min_ram min_vram tier tags desc
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
        # Mark downloaded if file exists in MODEL_DIR (downloaded OR copied there)
        [[ -f "${MODEL_DIR}/${gguf_file}" ]] && cached=" ${CYN}↓${RST}" || cached=""
        tag_display="${tags//,/ }"
        echo -e "  ${BLD}$(printf '%2s' "$idx")${RST}  $(printf '%-26s' "$dname")  $(printf '%5s' "$size_gb") GB  $(printf '%-7s' "$ctx")  ${GC}$(printf '%-13s' "$GL")${RST}  $(printf '%-24s' "$tag_display") $cached"
    done < <(printf '%s\n' "${MODELS[@]}")

    # Show locally present GGUFs not in catalogue (manually copied)
    local extra_count=0 f fname
    for f in "${MODEL_DIR}"/*.gguf; do
        [[ -f "$f" ]] || continue
        fname=$(basename "$f")
        local in_cat=false _i _r cat_g _x
        while IFS='|' read -r _i _r cat_g _x; do
            [[ "${cat_g// /}" == "$fname" ]] && { in_cat=true; break; }
        done < <(printf '%s\n' "${MODELS[@]}")
        if [[ "$in_cat" == "false" ]]; then
            (( extra_count++ ))
            (( extra_count == 1 )) && echo -e "\n  ${BLD}▸ LOCAL  (in ~/llm-models, not in catalogue)${RST}"
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

# ── HF URL / repo download ────────────────────────────────────────────────────
download_from_hf_url() {
    echo ""
    echo -e "  ${BLD}Download via HuggingFace${RST}"
    echo -e "  Accepted:"
    echo -e "    https://huggingface.co/owner/repo/resolve/main/file.gguf"
    echo -e "    owner/repo-name  (repo, you pick the file)"
    echo ""
    read -rp "  Paste URL or repo: " HF_INPUT
    HF_INPUT="${HF_INPUT//[[:space:]]/}"
    [[ -z "$HF_INPUT" ]] && die "No input provided."

    if [[ "$HF_INPUT" =~ ^https?:// ]]; then
        SEL_GGUF=$(basename "$HF_INPUT"); SEL_GGUF="${SEL_GGUF%%\?*}"
        [[ "$SEL_GGUF" != *.gguf ]] && die "URL doesn't point to a .gguf file."
        SEL_NAME="${SEL_GGUF%.gguf}"; GGUF_PATH="${MODEL_DIR}/${SEL_GGUF}"; SEL_HF_REPO=""
        if [[ -f "$GGUF_PATH" ]]; then ok "Already on disk: ${GGUF_PATH}"
        else
            step "Downloading ${SEL_GGUF}..."
            local ca=(-fL --progress-bar -o "$GGUF_PATH")
            [[ -n "${HF_TOKEN:-}" ]] && ca+=(-H "Authorization: Bearer ${HF_TOKEN}")
            curl "${ca[@]}" "$HF_INPUT" || die "curl download failed."
            [[ -f "$GGUF_PATH" ]] || die "File not found after download."
            local fs; fs=$(stat -c%s "$GGUF_PATH" 2>/dev/null || echo 0)
            (( fs < 104857600 )) && die "File too small (${fs} bytes) — check URL."
            ok "Downloaded: ${GGUF_PATH}"
        fi
    else
        SEL_HF_REPO="$HF_INPUT"
        step "Listing GGUFs in ${SEL_HF_REPO}..."
        local list_out="" gf_choice
        list_out=$(HF_TOKEN="${HF_TOKEN:-}" "$HF_CLI" download "$SEL_HF_REPO" \
            --include "*.gguf" --dry-run 2>/dev/null || true)
        mapfile -t GGUF_FILES < <(echo "$list_out" | grep -i '\.gguf$' | \
            awk '{print $NF}' | xargs -I{} basename {} 2>/dev/null | sort)
        if [[ ${#GGUF_FILES[@]} -eq 0 ]]; then
            warn "Could not auto-list files. Enter filename manually."
            read -rp "  Filename (e.g. model-Q4_K_M.gguf): " SEL_GGUF
            SEL_GGUF="${SEL_GGUF//[[:space:]]/}"; [[ -z "$SEL_GGUF" ]] && die "No filename."
        elif [[ ${#GGUF_FILES[@]} -eq 1 ]]; then
            SEL_GGUF="${GGUF_FILES[0]}"; ok "Only one GGUF: ${SEL_GGUF}"
        else
            echo ""; echo -e "  ${BLD}Available GGUFs:${RST}"
            local fi=1; for gf in "${GGUF_FILES[@]}"; do printf "  %2d  %s\n" "$fi" "$gf"; (( fi++ )); done
            echo ""
            while true; do
                read -rp "  Enter number [1-${#GGUF_FILES[@]}]: " gf_choice
                [[ "$gf_choice" =~ ^[0-9]+$ ]] && (( gf_choice >= 1 && gf_choice <= ${#GGUF_FILES[@]} )) && break
                warn "Invalid choice."
            done
            SEL_GGUF="${GGUF_FILES[$((gf_choice-1))]}"
        fi
        SEL_NAME="${SEL_GGUF%.gguf}"; GGUF_PATH="${MODEL_DIR}/${SEL_GGUF}"
        if [[ -f "$GGUF_PATH" ]]; then ok "Already on disk: ${GGUF_PATH}"
        else
            step "Downloading ${SEL_GGUF}..."
            if [[ -n "${HF_TOKEN:-}" ]]; then
                HF_TOKEN="${HF_TOKEN}" "$HF_CLI" download "$SEL_HF_REPO" "$SEL_GGUF" --local-dir "$MODEL_DIR"
            else
                "$HF_CLI" download "$SEL_HF_REPO" "$SEL_GGUF" --local-dir "$MODEL_DIR"
            fi
            [[ -f "$GGUF_PATH" ]] || die "Download completed but file not found."
            local fs; fs=$(stat -c%s "$GGUF_PATH" 2>/dev/null || echo 0)
            (( fs < 104857600 )) && die "File too small (${fs} bytes)."
            ok "Downloaded: ${GGUF_PATH}"
        fi
    fi
    apply_model_settings "$SEL_GGUF"
}

# =============================================================================
#  6. HF CLI setup (must happen before model selection for URL path)
# =============================================================================
step "Setting up HuggingFace CLI..."
export PATH="${HOME}/.local/bin:${PATH}"

HF_CLI_A="${HOME}/.local/bin/hf"
HF_CLI_B="${HOME}/.local/bin/huggingface-cli"

if [[ ! -x "$HF_CLI_A" && ! -x "$HF_CLI_B" ]]; then
    pip3 install --quiet --user --break-system-packages huggingface_hub
fi
pip3 install --quiet --user --break-system-packages --upgrade huggingface_hub 2>&1 | tail -2

if [[ -x "$HF_CLI_A" ]]; then
    HF_CLI="$HF_CLI_A"; HF_CLI_NAME="hf"
elif [[ -x "$HF_CLI_B" ]]; then
    HF_CLI="$HF_CLI_B"; HF_CLI_NAME="huggingface-cli"
else
    die "Neither 'hf' nor 'huggingface-cli' found after install."
fi
"$HF_CLI" version &>/dev/null || die "'$HF_CLI_NAME' fails to run."
ok "$HF_CLI_NAME ready: $("$HF_CLI" version 2>/dev/null || echo 'ok')"

if [[ -n "${HF_TOKEN:-}" ]]; then
    if "$HF_CLI" auth login --token "$HF_TOKEN" 2>/dev/null; then ok "HF login completed."
    elif "$HF_CLI" login --token "$HF_TOKEN" 2>/dev/null; then ok "HF login completed (legacy)."
    else ok "HF token ready (may be cached)."; fi
    "$HF_CLI" auth whoami &>/dev/null 2>&1 && ok "HF login verified." || \
        warn "HF login could not be verified — downloads may be unauthenticated."
fi

# =============================================================================
#  5 (continued). Run model selector
# =============================================================================
NUM_MODELS=${#MODELS[@]}
SEL_IDX="" SEL_HF_REPO="" SEL_GGUF="" SEL_NAME="" SEL_MIN_RAM="0" SEL_MIN_VRAM="0"
SAFE_CTX=32768; USE_JINJA="--jinja"; GGUF_PATH=""; CHOICE=""

show_model_table

while true; do
    if [[ ! -t 0 ]]; then
        warn "Non-interactive – defaulting to model 5 (Qwen 3.5 9B)"
        CHOICE="5"; break
    fi
    read -rp "$(echo -e "  ${BLD}Enter number [1-${NUM_MODELS}] or 'u' for URL:${RST} ")" CHOICE
    if [[ "$CHOICE" == "u" || "$CHOICE" == "U" ]]; then
        download_from_hf_url; break
    elif [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= NUM_MODELS )); then
        break
    fi
    warn "Enter a number between 1 and ${NUM_MODELS}, or 'u'."
done

if [[ "$CHOICE" != "u" && "$CHOICE" != "U" ]]; then
    while IFS='|' read -r idx hf_repo gguf_file dname size_gb ctx min_ram min_vram tier tags desc; do
        idx="${idx// /}"
        if [[ "$idx" == "$CHOICE" ]]; then
            SEL_IDX="$idx"; SEL_HF_REPO="${hf_repo// /}"; SEL_GGUF="${gguf_file// /}"
            SEL_NAME="${dname# }"; SEL_NAME="${SEL_NAME% }"
            SEL_MIN_RAM="${min_ram// /}"; SEL_MIN_VRAM="${min_vram// /}"
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
#  7. Download model from catalogue if not present
# =============================================================================
if [[ -f "$GGUF_PATH" ]]; then
    ok "Model already on disk: ${GGUF_PATH} — skipping download."
elif [[ "$CHOICE" != "u" && "$CHOICE" != "U" ]]; then
    step "Downloading ${SEL_NAME} from HuggingFace..."
    warn "This may take several minutes."

    AVAIL_KB=$(df -k "${MODEL_DIR}" | awk 'NR==2 {print $4}')
    AVAIL_GB=$(( AVAIL_KB / 1024 / 1024 ))

    # Exact index match for size (avoids "1" matching "11")
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
        ok "Downloaded: ${GGUF_PATH} ($(numfmt --to=iec-i --suffix=B "${FILE_SIZE}"))"
    else
        ok "Downloaded: ${GGUF_PATH} (${FILE_SIZE} bytes)"
    fi
fi

# =============================================================================
#  8. Build llama.cpp
# =============================================================================
step "Checking llama.cpp..."

find_llama_server() {
    local p vo
    for p in /usr/local/bin/llama-server /usr/bin/llama-server \
              "${HOME}/.local/bin/llama-server" \
              "${HOME}/llama.cpp/build/bin/llama-server"; do
        if [[ -x "$p" ]]; then
            vo=$("$p" --version 2>&1) || continue
            echo "$vo" | grep -qiE 'llama|ggml' && { echo "$p"; return 0; }
        fi
    done
    local found
    found=$(find "${HOME}/llama.cpp" -name "llama-server" -type f -executable 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then
        vo=$("$found" --version 2>&1) || true
        echo "$vo" | grep -qiE 'llama|ggml' && { echo "$found"; return 0; }
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
        ok "ccache: $(ccache --version | head -1)"
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

    command -v ccache &>/dev/null && { ok "ccache stats:"; ccache -s 2>/dev/null | grep -E "cache (hit|miss)|cache size|max size" || true; }

    LLAMA_SERVER_BIN=$(find_llama_server || true)
    [[ -n "$LLAMA_SERVER_BIN" ]] || die "llama-server not found after build."
    ok "llama-server: ${LLAMA_SERVER_BIN}"
fi

# =============================================================================
#  9. Hermes Agent — official NousResearch repo
#
#  Install method: official install script (handles uv, venv, Node, symlink)
#  Config: ~/.hermes/config.yaml with provider: custom + base_url
#  NOTE: No WebAPI, no "python -m webapi" — that was the outsourc-e fork only.
#  The OPENAI_BASE_URL + LLM_MODEL env vars are DEPRECATED per official docs.
#  Use config.yaml exclusively.
# =============================================================================
step "Installing Hermes Agent (official NousResearch)..."
HERMES_AGENT_DIR="${HOME}/hermes-agent"
HERMES_DIR="${HOME}/.hermes"

export PATH="${HOME}/.local/bin:${PATH}"

# Remove outsourc-e fork if present (different git remote)
if [[ -d "${HERMES_AGENT_DIR}/.git" ]]; then
    CURRENT_REMOTE=$(git -C "${HERMES_AGENT_DIR}" remote get-url origin 2>/dev/null || echo "")
    if [[ "$CURRENT_REMOTE" == *"outsourc-e"* ]]; then
        warn "outsourc-e fork detected — removing and replacing with official repo."
        rm -rf "${HERMES_AGENT_DIR}"
    fi
fi

# Use official install script (handles Python, Node, uv, venv, symlink)
if ! command -v hermes &>/dev/null || [[ ! -d "${HERMES_AGENT_DIR}/.git" ]]; then
    step "Running official Hermes Agent install script..."
    curl -fsSL --connect-timeout 15 --max-time 300 \
        https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh \
        -o /tmp/hermes-install.sh || die "Failed to download Hermes install script."
    register_tmp "/tmp/hermes-install.sh"
    # Run non-interactively — the script handles everything
    bash /tmp/hermes-install.sh || {
        warn "Official install script failed — falling back to manual install."
        # Manual fallback: uv + venv
        if ! command -v uv &>/dev/null; then
            curl -LsSf https://astral.sh/uv/install.sh | sh
            export PATH="${HOME}/.cargo/bin:${HOME}/.local/bin:${PATH}"
        fi
        if [[ ! -d "${HERMES_AGENT_DIR}/.git" ]]; then
            git clone --recurse-submodules https://github.com/NousResearch/hermes-agent.git "${HERMES_AGENT_DIR}"
        fi
        cd "${HERMES_AGENT_DIR}"
        uv venv .venv --python 3.11
        VIRTUAL_ENV="${HERMES_AGENT_DIR}/.venv" uv pip install -e ".[all]"
        mkdir -p "${HOME}/.local/bin"
        ln -sf "${HERMES_AGENT_DIR}/.venv/bin/hermes" "${HOME}/.local/bin/hermes"
        cd ~
    }
else
    ok "Hermes Agent already installed — updating..."
    if [[ -d "${HERMES_AGENT_DIR}/.git" ]]; then
        cd "${HERMES_AGENT_DIR}"
        git fetch origin 2>/dev/null && git reset --hard origin/main 2>/dev/null || \
            warn "Hermes git update failed (continuing with existing code)"
        # Re-install in case deps changed
        if command -v uv &>/dev/null && [[ -d ".venv" ]]; then
            VIRTUAL_ENV="${HERMES_AGENT_DIR}/.venv" uv pip install -e ".[all]" --quiet 2>/dev/null || true
        fi
        cd ~
    fi
fi

# Verify hermes is available
export PATH="${HOME}/.local/bin:${PATH}"
if ! command -v hermes &>/dev/null; then
    die "hermes command not found after install. Check output above for errors."
fi
ok "Hermes Agent: $(hermes --version 2>/dev/null || echo 'installed')"

# =============================================================================
#  9b. Configure Hermes → local llama-server
#
#  Official config format (2025):
#    provider: custom
#    base_url: http://localhost:8080/v1   (with /v1)
#    model name: exact GGUF filename (what llama-server reports as model ID)
#
#  Known issue: provider == "custom" may fall through to OpenRouter in some
#  versions (issue #4172). Workaround: also set OPENAI_BASE_URL + OPENAI_API_KEY
#  in ~/.hermes/.env as belt-and-suspenders. Hermes reads .env on startup.
# =============================================================================
step "Configuring Hermes for local llama-server..."

mkdir -p "${HERMES_DIR}"/{cron,sessions,logs,memories,skills}

# .env: belt-and-suspenders for versions where config.yaml provider routing bugs out
cat > "${HERMES_DIR}/.env" <<ENV
# Hermes Agent — local llama-server configuration
# Generated by install.sh
OPENAI_API_KEY=sk-no-key-needed
OPENAI_BASE_URL=http://localhost:8080/v1
# Note: LLM_MODEL is deprecated in new versions; use config.yaml
ENV
ok "~/.hermes/.env written."

# config.yaml: primary config (overrides .env in current Hermes versions)
# Use cp to preserve any existing user customisations when updating
CONFIG_FILE="${HERMES_DIR}/config.yaml"
EXAMPLE_CFG="${HERMES_AGENT_DIR}/cli-config.yaml.example"

if [[ ! -f "$CONFIG_FILE" ]]; then
    # Use example as base if available, otherwise write from scratch
    if [[ -f "$EXAMPLE_CFG" ]]; then
        cp "$EXAMPLE_CFG" "$CONFIG_FILE"
        ok "config.yaml initialised from example."
    else
        touch "$CONFIG_FILE"
    fi
fi

# Patch / write the model block
python3 - <<PYCONF
import re, sys
path = "${CONFIG_FILE}"
model_name = "${SEL_NAME}"
base_url = "http://localhost:8080/v1"

try:
    with open(path, "r") as f:
        content = f.read()
except FileNotFoundError:
    content = ""

# Remove any existing model: block completely
content = re.sub(r'^model:.*?(?=^\S|\Z)', '', content, flags=re.MULTILINE | re.DOTALL)
content = content.rstrip()

new_block = f"""
model:
  provider: custom
  base_url: {base_url}
  model: {model_name}
"""

with open(path, "w") as f:
    f.write(content + new_block + "\n")
print("config.yaml model block written.")
PYCONF

ok "config.yaml written — Hermes → local llama-server (${SEL_NAME})"
ok "To verify after start: hermes /provider"

# Hermes systemd service (optional — runs hermes in daemon/gateway mode)
# Note: for CLI use, no daemon is needed; service is only if you use gateway.
mkdir -p "${HOME}/.config/systemd/user"
cat > "${HOME}/.config/systemd/user/hermes-agent.service" <<HERMES_SVC
[Unit]
Description=Hermes Agent (NousResearch) — gateway/daemon mode
After=llama-server.service network.target
Wants=llama-server.service

[Service]
Type=simple
WorkingDirectory=${HOME}
ExecStart=${HOME}/.local/bin/hermes gateway
Restart=on-failure
RestartSec=10
Environment=HOME=${HOME}
Environment=PATH=${HOME}/.local/bin:/usr/local/cuda/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
HERMES_SVC

# Don't auto-enable hermes gateway — user should set up gateway manually
ok "Hermes systemd service file created (disabled by default — enable with: systemctl --user enable hermes-agent)"

# =============================================================================
#  10. Update pip
# =============================================================================
pip3 install --user --break-system-packages --upgrade pip setuptools wheel 2>/dev/null || true

# =============================================================================
#  11. Create ~/start-llm.sh
#
#  Starts llama-server only (no WebAPI).
#  envsubst allowlist: only installer-time vars substituted.
#  Runtime vars ($LLAMA_PID, $idx, $kill_choice) stay as literals.
#
#  Auto-start fix: the script includes a "first-boot" check so that when
#  a new WSL terminal opens, it auto-starts llama-server if not running.
#  This is done via ~/.bashrc (added in section 12).
# =============================================================================
step "Creating launch script..."
LAUNCH_SCRIPT="${HOME}/start-llm.sh"

cat > "${LAUNCH_SCRIPT}.template" <<'LAUNCH_TEMPLATE'
#!/usr/bin/env bash
# start-llm.sh – generated by install.sh
# Starts: llama-server (port 8080)
# Model : ${SEL_NAME}

GGUF="${GGUF_PATH}"
MODEL_NAME="${SEL_NAME}"
LLAMA_BIN="${LLAMA_SERVER_BIN}"
SAFE_CTX="${SAFE_CTX}"
USE_JINJA="${USE_JINJA}"

# Check if already running
LLAMA_PID=$(pgrep -f "llama-server" 2>/dev/null || true)

if [[ -n "$LLAMA_PID" ]]; then
    echo -e "\n  llama-server already running (PID: $LLAMA_PID)"
    if [[ -t 0 ]]; then
        read -rp "  Restart? [y/N]: " kill_choice
    else
        kill_choice="n"
    fi
    if [[ "$kill_choice" =~ ^[Yy]$ ]]; then
        pkill -f "llama-server" 2>/dev/null || true
        sleep 2
        echo "  Stopped."
    else
        echo "  Keeping existing instance. Exiting."; exit 0
    fi
fi

echo ""
echo "  Starting llama-server"
echo "  Model  : ${MODEL_NAME}"
echo "  Context: ${SAFE_CTX} tokens"
echo "  Jinja  : ${USE_JINJA}"
echo "  API    : http://localhost:8080/v1"
echo "  Web UI : http://localhost:8080"
echo ""
echo "  Press Ctrl+C to stop."
echo ""

"${LLAMA_BIN}" -m "${GGUF}" -ngl 99 -fa on -c "${SAFE_CTX}" -np 1 \
    --cache-type-k q4_0 --cache-type-v q4_0 --host 0.0.0.0 --port 8080 ${USE_JINJA} &
LLAMA_PID=$!

for idx in {1..30}; do
    if curl -sf http://localhost:8080/v1/models &>/dev/null; then
        echo "  llama-server ready (PID: $LLAMA_PID)"
        echo "  hermes        → start chatting with Hermes Agent"
        echo "  goose         → start chatting with Goose (if installed)"
        echo ""
        break
    fi
    sleep 1
done

wait
LAUNCH_TEMPLATE

export GGUF_PATH SEL_NAME LLAMA_SERVER_BIN SAFE_CTX USE_JINJA
envsubst '${GGUF_PATH} ${SEL_NAME} ${LLAMA_SERVER_BIN} ${SAFE_CTX} ${USE_JINJA}' \
    < "${LAUNCH_SCRIPT}.template" > "$LAUNCH_SCRIPT"
rm -f "${LAUNCH_SCRIPT}.template"
chmod +x "$LAUNCH_SCRIPT"
ok "Launch script: ~/start-llm.sh"

# =============================================================================
#  12. systemd user service — llama-server (direct, quoted paths)
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
    echo "  For auto-start on login: sudo loginctl enable-linger $USER"
else
    warn "systemd --user unavailable — use 'start-llm' to start manually."
fi

# Start llama-server now
step "Starting llama-server..."
nohup bash "$LAUNCH_SCRIPT" < /dev/null > /tmp/llama-server.log 2>&1 &
ok "llama-server starting (log: tail -f /tmp/llama-server.log)"

READY=false
for i in {1..30}; do
    if curl -sf http://localhost:8080/v1/models &>/dev/null; then
        ok "llama-server ready at http://localhost:8080"
        READY=true; break
    fi
    sleep 1
done
[[ "$READY" == "false" ]] && \
    warn "llama-server not responding in 30s — check: tail -f /tmp/llama-server.log"

# =============================================================================
#  13. Optional: Goose (block/goose)
#
#  Goose is a Rust-based extensible agent. It connects to llama-server via
#  the OpenAI-compatible API. Config stored in ~/.config/goose/config.yaml.
#  The model ID for Goose must be the exact filename llama-server reports
#  (i.e. the GGUF filename), because that's what /v1/models returns.
# =============================================================================
GOOSE_INSTALLED=false
echo ""
echo -e "  ${BLD}Optional: Goose AI Agent (block/goose)${RST}"
echo -e "  Rust-based extensible agent · 30k+ stars · Linux Foundation project"
echo -e "  Works with any OpenAI-compatible API · MCP support · developer tools"
echo ""
if [[ -t 0 ]]; then
    read -rp "  Install Goose? [y/N]: " install_goose
else
    install_goose="n"
fi

if [[ "$install_goose" =~ ^[Yy]$ ]]; then
    step "Installing Goose CLI..."
    if command -v goose &>/dev/null; then
        ok "Goose already installed: $(goose --version 2>/dev/null || echo 'installed')"
        GOOSE_INSTALLED=true
    else
        if curl -fsSL --connect-timeout 15 --max-time 120 \
            https://github.com/block/goose/releases/download/stable/download_cli.sh \
            -o /tmp/goose-install.sh 2>/dev/null; then
            register_tmp "/tmp/goose-install.sh"
            bash /tmp/goose-install.sh || warn "Goose install script failed."
            export PATH="${HOME}/.local/bin:${PATH}"
        else
            warn "Could not download Goose install script — skipping."
        fi

        if command -v goose &>/dev/null; then
            ok "Goose installed: $(goose --version 2>/dev/null || echo 'ok')"
            GOOSE_INSTALLED=true
        else
            warn "Goose not found after install — may need PATH update."
        fi
    fi

    if [[ "$GOOSE_INSTALLED" == "true" ]]; then
        step "Configuring Goose for local llama-server..."
        mkdir -p "${HOME}/.config/goose"

        # Goose config: GOOSE_PROVIDER=openai, OPENAI_HOST (no /v1),
        # OPENAI_BASE_PATH=v1/chat/completions, GOOSE_MODEL=exact gguf filename,
        # OPENAI_API_KEY=any non-empty string (local server ignores it)
        cat > "${HOME}/.config/goose/config.yaml" <<GOOSE_CFG
# Goose configuration — local llama-server
# Generated by install.sh
GOOSE_PROVIDER: openai
GOOSE_MODEL: ${SEL_GGUF}
GOOSE_TEMPERATURE: 0.75
GOOSE_MAX_TOKENS: 8192
GOOSE_MODE: auto

OPENAI_HOST: http://localhost:8080
OPENAI_BASE_PATH: v1/chat/completions
OPENAI_API_KEY: sk-no-key-needed

extensions:
  developer:
    enabled: true
    name: developer
    timeout: 300
    type: builtin
GOOSE_CFG
        ok "Goose configured → http://localhost:8080"
        warn "Important: OPENAI_HOST must NOT include /v1 — that goes in OPENAI_BASE_PATH"
        warn "Goose uses the GGUF filename as model ID: ${SEL_GGUF}"
    fi
else
    ok "Skipping Goose install."
fi

# =============================================================================
#  14. ~/.bashrc helpers
#
#  Auto-start fix: adds a check at the bottom of ~/.bashrc that starts
#  llama-server automatically when a new interactive terminal opens,
#  if it's not already running. Uses a marker file to run only once per
#  WSL session (not every terminal tab).
# =============================================================================
step "Adding helpers to ~/.bashrc..."

# Resolve own path so switch-model works after install
SCRIPT_SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"

MARKER="# === LLM setup (added by install.sh) ==="
if grep -qF "$MARKER" "${HOME}/.bashrc" 2>/dev/null; then
    ok "Helpers already in ~/.bashrc — skipping."
else
    # Static section — expanded now
    cat >> "${HOME}/.bashrc" <<BASHRC_EXPANDED

${MARKER}
[[ -n "\${__LLM_BASHRC_LOADED:-}" ]] && return 0
export __LLM_BASHRC_LOADED=1

# Strip Windows /mnt/* from PATH
_cp=""; IFS=':' read -ra _pts <<< "\$PATH"
for _pt in "\${_pts[@]}"; do [[ "\$_pt" == /mnt/* ]] && continue; _cp="\${_cp:+\${_cp}:}\${_pt}"; done
export PATH="\$_cp"; unset _cp _pts _pt

export RED='\033[0;31m' GRN='\033[0;32m' YLW='\033[1;33m'
export CYN='\033[0;36m' BLD='\033[1m' RST='\033[0m'
export PATH="/usr/local/cuda/bin:\${HOME}/.local/bin:\${PATH}"
export LD_LIBRARY_PATH="/usr/local/cuda/lib64:\${LD_LIBRARY_PATH:-}"

alias start-llm='bash ~/start-llm.sh'
alias stop-llm='pkill -f llama-server 2>/dev/null; echo "llama-server stopped."'
alias restart-llm='stop-llm; sleep 2; start-llm'
alias llm-log='tail -f /tmp/llama-server.log'
alias switch-model='bash ${SCRIPT_SELF}'
BASHRC_EXPANDED

    if [[ -n "${HF_TOKEN:-}" ]] && ! grep -qF "export HF_TOKEN=" "${HOME}/.bashrc" 2>/dev/null; then
        echo "export HF_TOKEN=\"${HF_TOKEN}\"" >> "${HOME}/.bashrc"
        ok "HF_TOKEN added to ~/.bashrc."
    fi

    cat >> "${HOME}/.bashrc" <<'BASHRC_FUNCTIONS'

vram() {
    nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu \
        --format=csv,noheader,nounits 2>/dev/null | \
        awk -F, '{printf "GPU: %s\nVRAM: %s / %s MiB\nUtil: %s%%\n",$1,$2,$3,$4}' || \
        echo "nvidia-smi not available"
}

# llm-models: scan ~/llm-models for ALL .gguf files (downloaded or copied)
llm-models() {
    local active_model=""
    [[ -f ~/start-llm.sh ]] && \
        active_model=$(grep '^GGUF=' ~/start-llm.sh 2>/dev/null | head -1 | \
        sed 's/GGUF="//;s/".*//' | xargs basename 2>/dev/null || true)
    echo -e "\n  ${BLD}Models in ~/llm-models:${RST}"
    echo "  ────────────────────────────────────────────────"
    local found=0
    for f in ~/llm-models/*.gguf; do
        [[ -f "$f" ]] || continue
        (( found++ ))
        local sz name tag
        sz=$(du -h "$f" | cut -f1); name=$(basename "$f"); tag=""
        [[ "$name" == "$active_model" ]] && tag=" ${GRN}← active${RST}"
        echo -e "  ${sz}  ${name}${tag}"
    done
    [[ $found -eq 0 ]] && echo "  (no .gguf files found)"
    echo ""
}

llm-status() {
    local llama_pid active_model=""
    llama_pid=$(pgrep -f "llama-server" 2>/dev/null || true)
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
    echo -e "${BLD}${CYN}│${RST}  ${CYN}start-llm${RST}       Start llama-server"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}stop-llm${RST}        Stop llama-server"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}restart-llm${RST}     Restart llama-server"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}switch-model${RST}    Pick a different model & restart"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}llm-status${RST}      Check status + active model"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}llm-log${RST}         Tail llama-server log"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}llm-models${RST}      List all models in ~/llm-models"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}vram${RST}            GPU/VRAM usage"
    echo -e "${BLD}${CYN}│${RST}  ──────────────────────────────────────────────────────"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}hermes${RST}          Chat with Hermes Agent (CLI)"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}goose${RST}           Chat with Goose (if installed)"
    echo -e "${BLD}${CYN}│${RST}  ──────────────────────────────────────────────────────"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}http://localhost:8080${RST}  → llama-server + Web UI"
    echo -e "${BLD}${CYN}╰────────────────────────────────────────────────────────────────╯${RST}"
    echo ""
}

# ── Auto-start llama-server on first interactive terminal per WSL session ──
# Uses a per-session marker in /tmp so it only fires once, not every tab.
_llm_autostart() {
    [[ $- != *i* ]] && return 0  # non-interactive shell — skip
    local marker="/tmp/.llm_autostarted_$$_$(date +%Y%m%d)"
    # Check if any llama-server is already running
    if ! pgrep -f "llama-server" &>/dev/null && [[ ! -f "/tmp/.llm_session_started" ]]; then
        touch /tmp/.llm_session_started
        echo -e "${YLW}[LLM] llama-server not running — starting in background...${RST}"
        nohup bash ~/start-llm.sh < /dev/null >> /tmp/llama-server.log 2>&1 &
        disown
    fi
}
_llm_autostart

[[ $- == *i* && ! -f "${HOME}/.llm_summary_shown" ]] && { show_llm_summary; touch "${HOME}/.llm_summary_shown"; }
BASHRC_FUNCTIONS

    ok "Helpers written to ~/.bashrc."
fi

# =============================================================================
#  15. .wslconfig RAM hint
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
echo -e "  llama-server   →  http://localhost:8080/v1"
echo -e "  llama.cpp UI   →  http://localhost:8080"
echo -e "  Hermes Agent   →  hermes (CLI)"
[[ "$GOOSE_INSTALLED" == "true" ]] && echo -e "  Goose Agent    →  goose (CLI)"
echo -e "  Model          →  ${SEL_NAME}  (context: ${SAFE_CTX} tokens)"
echo ""
echo -e " ${BLD}Usage:${RST}"
echo -e "  ${CYN}hermes${RST}         Chat with Hermes Agent"
echo -e "  ${CYN}hermes model${RST}   Reconfigure model/provider"
echo -e "  ${CYN}hermes doctor${RST}  Diagnose configuration issues"
[[ "$GOOSE_INSTALLED" == "true" ]] && echo -e "  ${CYN}goose${RST}          Chat with Goose"
[[ "$GOOSE_INSTALLED" == "true" ]] && echo -e "  ${CYN}goose configure${RST} Reconfigure Goose"
echo -e "  ${CYN}start-llm${RST}      Start llama-server"
echo -e "  ${CYN}stop-llm${RST}       Stop llama-server"
echo -e "  ${CYN}restart-llm${RST}    Restart llama-server"
echo -e "  ${CYN}switch-model${RST}   Pick a different model & restart"
echo -e "  ${CYN}llm-status${RST}     Check running services"
echo -e "  ${CYN}llm-log${RST}        Tail llama-server log"
echo -e "  ${CYN}llm-models${RST}     List all models in ~/llm-models"
echo -e "  ${CYN}vram${RST}           GPU/VRAM usage"
echo ""
echo -e " ${BLD}Hermes local config:${RST}"
echo -e "  ~/.hermes/config.yaml  — provider/model settings"
echo -e "  Run ${CYN}hermes /provider${RST} inside chat to verify routing"
echo -e "  Run ${CYN}hermes model${RST} to switch model interactively"
echo ""
if [[ "$GOOSE_INSTALLED" == "true" ]]; then
echo -e " ${BLD}Goose local config:${RST}"
echo -e "  ~/.config/goose/config.yaml"
echo -e "  OPENAI_HOST must NOT include /v1 (that's in OPENAI_BASE_PATH)"
echo -e "  GOOSE_MODEL must be the exact GGUF filename: ${SEL_GGUF}"
echo ""
fi
echo -e " ${YLW}Note:${RST} Run 'source ~/.bashrc' or open a new terminal."
echo -e " ${YLW}Auto-start:${RST} llama-server starts automatically on new terminal."
echo -e " ${GRN}Persistent auto-start:${RST} sudo loginctl enable-linger $USER"
echo ""
