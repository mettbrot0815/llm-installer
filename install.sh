#!/usr/bin/env bash
# =============================================================================
#  install.sh  –  Ubuntu WSL2  ·  llama.cpp + Hermes + Goose + OpenCode + AutoAgent
#  Version: production-combined
#
#  Stack:
#    llama.cpp server  →  http://localhost:8080          (inference)
#    Hermes Agent CLI  →  NousResearch/hermes-agent      (official)
#    Goose CLI         →  block/goose                    (optional)
#    OpenCode          →  anomalyco/opencode              (optional)
#    AutoAgent         →  HKUDS/AutoAgent                (optional)
#
#  HERMES CONFIG (v0.4+):
#    ~/.hermes/config.yaml:
#      setup_complete: true           ← suppresses wizard on first run
#      model.provider: custom
#      model.base_url: http://localhost:8080/v1   ← WITH /v1
#      model.default: <exact model name>
#      model.context_length: <SAFE_CTX>
#      terminal.backend: local        ← suppresses wizard step 2
#      agent.max_turns: 90            ← suppresses wizard step 3
#      memory.honcho.enabled: true    ← enables self-learning loop
#    ~/.hermes/.env:
#      OPENAI_API_KEY=sk-no-key-needed
#      OPENAI_BASE_URL=http://localhost:8080/v1  (belt-and-suspenders, no OPENROUTER_API_KEY)
#
#  SWITCH_MODEL_ONLY sentinel:
#    SWITCH_MODEL_ONLY=1 bash install.sh  (set by the switch-model alias)
#    Skips: HF token prompt, sys packages, CUDA, llama.cpp build, Hermes install,
#           systemd, bashrc, .wslconfig, optional agent installs.
#    Runs:  HF CLI refresh → model table → selection → download if needed →
#           start-llm.sh regen → Hermes/Goose/OpenCode/AutoAgent config update →
#           llama-server restart.
#
#  agentskills.io — open standard for portable agent skills (Anthropic origin,
#    now community). Hermes compatible. Skills = SKILL.md files the agent loads
#    on demand. Self-improve during use. Installed into ~/.hermes/skills/.
#
#  BUGS FIXED in this version:
#    HIGH: Duplicate HF CLI + model selector block — eliminated in clean rewrite
#    HIGH: switch-model not truly lightweight — _SMO sentinel now gates ALL
#          expensive sections (2,4,8,9,12,13,14,15); only model-switching core runs
#    MED:  Honcho memory disabled by default — now written to config.yaml
#    MED:  Goose/OpenCode curls missing --retry — added --retry 3 --retry-delay 2
#    MED:  No Hermes skills installed — curated set installed post-configure
#    LOW:  HF token prompt on switch-model — now skipped if token already found
#    FIX:  (( found++ )) in llm-models() → found=$(( found + 1 ))
#    FIX:  Carnice-9b missing from MODELS + apply_model_settings() → added
#    FIX:  REQ_GB empty guard → die() added
#    FIX:  pgrep without || true in bashrc → fixed
#
#  CUDA NOTE: GPU driver lives in Windows. NEVER install cuda-drivers inside
#  WSL2 — they overwrite the GPU passthrough stub.
# =============================================================================
set -euo pipefail

# ── SWITCH_MODEL_ONLY sentinel ─────────────────────────────────────────────────
# Captured at the very top, immediately unset so it doesn't leak into subshells.
_SMO="${SWITCH_MODEL_ONLY:-}"
unset SWITCH_MODEL_ONLY

# ── Strip Windows /mnt/* from PATH ────────────────────────────────────────────
_wc=""; IFS=':' read -ra _wp <<< "$PATH"
for _p in "${_wp[@]}"; do [[ "$_p" == /mnt/* ]] && continue; _wc="${_wc:+${_wc}:}${_p}"; done
export PATH="$_wc"; unset _wc _wp _p

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

# Banner — different wording for switch-model vs full install
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
╚══════════════════════════════════════════════════════════════╝
BANNER
fi
echo -e "${RST}"

if [[ -z "$_SMO" ]]; then
    grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null && \
        ok "Running inside WSL2." || \
        warn "/proc/version does not mention Microsoft/WSL — continuing anyway."
fi

# =============================================================================
#  1. HuggingFace token
#     In switch-model mode: only load from existing sources, never prompt.
# =============================================================================
# BUG FIX B1: Capture any pre-existing env value BEFORE overwriting the variable.
# The original code did HF_TOKEN="" then immediately checked -n "${HF_TOKEN:-}",
# which was always false — silently discarding any HF_TOKEN the user had exported.
_HF_ENV="${HF_TOKEN:-}"
HF_TOKEN=""
if [[ -n "$_HF_ENV" ]]; then
    HF_TOKEN="$_HF_ENV"
    ok "HF_TOKEN already set in environment."
elif [[ -f "${HOME}/.cache/huggingface/token" ]]; then
    HF_TOKEN=$(cat "${HOME}/.cache/huggingface/token" 2>/dev/null || true)
    [[ -n "$HF_TOKEN" ]] && ok "HF_TOKEN loaded from cache."
elif grep -qF "export HF_TOKEN=" "${HOME}/.bashrc" 2>/dev/null; then
    HF_TOKEN=$(grep "export HF_TOKEN=" "${HOME}/.bashrc" | head -1 | \
        sed 's/.*export HF_TOKEN=//' | sed "s/^[\"']//" | sed "s/[\"']$//")
    [[ -n "$HF_TOKEN" ]] && ok "HF_TOKEN found in ~/.bashrc."
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
            [[ "$HF_TOKEN" =~ ^hf_ ]] && ok "Token accepted." || \
                warn "Token doesn't start with 'hf_' — using anyway."
        else
            ok "Skipping — unauthenticated downloads (slower, rate-limited)."
        fi
    else
        ok "Non-interactive — skipping HuggingFace token prompt."
    fi
fi
export HF_TOKEN

# =============================================================================
#  2. System packages  [SKIPPED by switch-model]
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
#  3. Hardware detection  (always runs — vars needed by show_model_table)
# =============================================================================
step "Detecting hardware..."
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_GiB=$(( RAM_KB / 1024 / 1024 ))
(( RAM_GiB == 0 )) && { warn "RAM detection returned 0 — defaulting to 8 GiB."; RAM_GiB=8; }
CPUS=$(nproc)
HAS_NVIDIA=false; VRAM_GiB=0; VRAM_MiB=0; GPU_NAME="None detected"

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
    GPU_NAME=$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | head -1 \
        | sed 's/.*: //' || echo "None")
    warn "nvidia-smi not found — CPU-only mode. GPU (lspci): ${GPU_NAME}"
fi

echo -e "\n  ${BLD}Hardware${RST}"
echo -e "  RAM  : ${RAM_GiB} GiB   CPUs: ${CPUS}"
echo -e "  GPU  : ${GPU_NAME}   VRAM: ${VRAM_GiB} GiB   CUDA: ${HAS_NVIDIA}"

if [[ -z "$_SMO" && "$HAS_NVIDIA" != "true" ]]; then
    warn "No NVIDIA GPU — llama.cpp will be CPU-only (much slower)."
    if [[ -t 0 ]]; then
        read -rp "  Continue with CPU-only build? [y/N]: " cpu_ok
        [[ "$cpu_ok" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    else
        warn "Non-interactive — continuing with CPU-only build."
    fi
fi

# =============================================================================
#  4. CUDA toolkit  [SKIPPED by switch-model; paths re-exported if GPU present]
# =============================================================================
if [[ -z "$_SMO" ]] && [[ "$HAS_NVIDIA" == "true" ]]; then
    step "Checking CUDA toolkit..."
    if command -v nvcc &>/dev/null; then
        ok "CUDA already installed: $(nvcc --version 2>/dev/null | head -1)"
    else
        step "Installing CUDA toolkit 12.6 for WSL2..."
        sudo rm -f /etc/apt/trusted.gpg.d/cuda.gpg 2>/dev/null || true
        curl -fsSL --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 \
            https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb \
            -o /tmp/cuda-keyring.deb || die "Failed to download CUDA keyring"
        register_tmp "/tmp/cuda-keyring.deb"
        sudo dpkg -i /tmp/cuda-keyring.deb
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
#  5. Model catalogue
#
#  Format: idx|hf_repo|gguf_file|display_name|size_gb|ctx|min_ram|min_vram|tier|tags|desc
#
#  Carnice-9b (index 6):
#    Qwen3.5-9B fine-tuned for the Hermes Agent harness.
#    Trained on Hermes-native traces: terminal, file, browser, multi-step tool-calling.
#    Q6_K recommended: 6.9 GB, fits RTX 3060 12 GB with context headroom.
#    Identical VRAM footprint to Qwen3.5-9B Q4_K_M but better Hermes behavior.
#    Apache 2.0. Model: kai-os/Carnice-9b-GGUF
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

# ── Grade helpers ──────────────────────────────────────────────────────────────
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

# ── Context + Jinja settings ───────────────────────────────────────────────────
# Carnice-9b is Qwen3.5-9B based → same 256K context, --jinja required.
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

# ── Draw model table ───────────────────────────────────────────────────────────
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
    while IFS='|' read -r idx hf_repo gguf_file dname size_gb ctx \
            min_ram min_vram tier tags desc; do
        idx="${idx// /}"; dname="${dname# }"; dname="${dname% }"
        size_gb="${size_gb// /}"; ctx="${ctx// /}"; min_ram="${min_ram// /}"
        min_vram="${min_vram// /}"; tier="${tier// /}"; tags="${tags// /}"
        gguf_file="${gguf_file// /}"
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
        GC=$(grade_color "$GRADE"); GL=$(grade_label "$GRADE")
        [[ -f "${MODEL_DIR}/${gguf_file}" ]] && cached=" ${CYN}↓${RST}" || cached=""
        tag_display="${tags//,/ }"
        echo -e "  ${BLD}$(printf '%2s' "$idx")${RST}  $(printf '%-26s' "$dname")" \
            " $(printf '%5s' "$size_gb") GB  $(printf '%-7s' "$ctx")" \
            "  ${GC}$(printf '%-13s' "$GL")${RST}  $(printf '%-24s' "$tag_display") $cached"
    done < <(printf '%s\n' "${MODELS[@]}")

    # Show locally present GGUFs not in catalogue (manually copied)
    # NOTE: (( extra_count++ )) exits code 1 when count=0 under set -e.
    # Using arithmetic assignment throughout.
    local extra_count=0 f fname
    for f in "${MODEL_DIR}"/*.gguf; do
        [[ -f "$f" ]] || continue
        fname=$(basename "$f")
        local in_cat=false _i _r cat_g _rest
        while IFS='|' read -r _i _r cat_g _rest; do
            [[ "${cat_g// /}" == "$fname" ]] && { in_cat=true; break; }
        done < <(printf '%s\n' "${MODELS[@]}")
        if [[ "$in_cat" == "false" ]]; then
            extra_count=$(( extra_count + 1 ))
            (( extra_count == 1 )) && \
                echo -e "\n  ${BLD}▸ LOCAL  (in ~/llm-models, not in catalogue)${RST}"
            local sz; sz=$(du -h "$f" 2>/dev/null | cut -f1)
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

# ── HF URL / repo download ─────────────────────────────────────────────────────
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
        SEL_GGUF=$(basename "$HF_INPUT"); SEL_GGUF="${SEL_GGUF%%\?*}"
        [[ "$SEL_GGUF" != *.gguf ]] && die "URL doesn't point to a .gguf file."
        SEL_NAME="${SEL_GGUF%.gguf}"; GGUF_PATH="${MODEL_DIR}/${SEL_GGUF}"; SEL_HF_REPO=""
        if [[ -f "$GGUF_PATH" ]]; then
            ok "Already on disk: ${GGUF_PATH}"
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
        local list_out=""
        list_out=$(HF_TOKEN="${HF_TOKEN:-}" "$HF_CLI" download "$SEL_HF_REPO" \
            --include "*.gguf" --dry-run 2>/dev/null || true)
        mapfile -t GGUF_FILES < <(echo "$list_out" | grep -i '\.gguf$' | \
            awk '{print $NF}' | xargs -I{} basename {} 2>/dev/null | sort)

        if [[ ${#GGUF_FILES[@]} -eq 0 ]]; then
            warn "Could not auto-list files. Enter filename manually."
            read -rp "  Filename (e.g. model-Q4_K_M.gguf): " SEL_GGUF
            SEL_GGUF="${SEL_GGUF//[[:space:]]/}"; [[ -z "$SEL_GGUF" ]] && die "No filename."
        elif [[ ${#GGUF_FILES[@]} -eq 1 ]]; then
            SEL_GGUF="${GGUF_FILES[0]}"; ok "Only one GGUF found: ${SEL_GGUF}"
        else
            echo ""; echo -e "  ${BLD}Available GGUFs:${RST}"
            local fnum=1  # NOTE: 'fi' is a bash keyword — never name a variable 'fi'
            for gf in "${GGUF_FILES[@]}"; do
                printf "  %2d  %s\n" "$fnum" "$gf"
                fnum=$(( fnum + 1 ))
            done
            echo ""
            local gf_choice
            while true; do
                read -rp "  Enter number [1-${#GGUF_FILES[@]}]: " gf_choice
                [[ "$gf_choice" =~ ^[0-9]+$ ]] && \
                    (( gf_choice >= 1 && gf_choice <= ${#GGUF_FILES[@]} )) && break
                warn "Invalid choice."
            done
            SEL_GGUF="${GGUF_FILES[$((gf_choice-1))]}"
        fi

        SEL_NAME="${SEL_GGUF%.gguf}"; GGUF_PATH="${MODEL_DIR}/${SEL_GGUF}"
        if [[ -f "$GGUF_PATH" ]]; then
            ok "Already on disk: ${GGUF_PATH}"
        else
            step "Downloading ${SEL_GGUF}..."
            if [[ -n "${HF_TOKEN:-}" ]]; then
                HF_TOKEN="${HF_TOKEN}" "$HF_CLI" download "$SEL_HF_REPO" "$SEL_GGUF" \
                    --local-dir "$MODEL_DIR"
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
#  6. HF CLI setup  (always runs — needed for model download in switch-model too)
# =============================================================================
step "Setting up HuggingFace CLI..."
export PATH="${HOME}/.local/bin:${PATH}"

HF_CLI_A="${HOME}/.local/bin/hf"
HF_CLI_B="${HOME}/.local/bin/huggingface-cli"

if [[ ! -x "$HF_CLI_A" && ! -x "$HF_CLI_B" ]]; then
    pip3 install --quiet --user --break-system-packages huggingface_hub
fi
# Only upgrade on full install — in switch-model mode this adds 3–8s for no benefit
if [[ -z "$_SMO" ]]; then
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
ok "$HF_CLI_NAME ready: $("$HF_CLI" version 2>/dev/null || echo 'ok')"

if [[ -n "${HF_TOKEN:-}" ]]; then
    if "$HF_CLI" auth login --token "$HF_TOKEN" 2>/dev/null; then
        ok "HF login completed."
    elif "$HF_CLI" login --token "$HF_TOKEN" 2>/dev/null; then
        ok "HF login completed (legacy)."
    else
        ok "HF token ready (may be cached)."
    fi
    "$HF_CLI" auth whoami &>/dev/null 2>&1 && ok "HF login verified." || \
        warn "HF login could not be verified — downloads may be unauthenticated."
fi

# =============================================================================
#  5 (continued). Model selector  (always runs)
# =============================================================================
NUM_MODELS=${#MODELS[@]}
SEL_IDX="" SEL_HF_REPO="" SEL_GGUF="" SEL_NAME="" SEL_MIN_RAM="0" SEL_MIN_VRAM="0"
SAFE_CTX=32768; USE_JINJA="--jinja"; GGUF_PATH=""; CHOICE=""

show_model_table

while true; do
    if [[ ! -t 0 ]]; then
        warn "Non-interactive — defaulting to model 5 (Qwen 3.5 9B)"
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

# Parse catalogue — exact index match (avoids "1" matching "11", "12", etc.)
if [[ "$CHOICE" != "u" && "$CHOICE" != "U" ]]; then
    while IFS='|' read -r idx hf_repo gguf_file dname size_gb ctx \
            min_ram min_vram tier tags desc; do
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
            warn "Non-interactive — continuing anyway."
        fi
    elif [[ "$GRADE_SEL" == "C" ]]; then
        warn "Grade C — tight fit, expect slow responses."
    fi

    apply_model_settings "$SEL_GGUF"
    GGUF_PATH="${MODEL_DIR}/${SEL_GGUF}"
fi

# =============================================================================
#  7. Download model from catalogue if not present  (always runs)
# =============================================================================
if [[ -f "$GGUF_PATH" ]]; then
    ok "Model already on disk: ${GGUF_PATH} — skipping download."
elif [[ "$CHOICE" != "u" && "$CHOICE" != "U" ]]; then
    step "Downloading ${SEL_NAME} from HuggingFace..."
    warn "This may take several minutes."

    AVAIL_KB=$(df -k "${MODEL_DIR}" | awk 'NR==2 {print $4}')
    AVAIL_GB=$(( AVAIL_KB / 1024 / 1024 ))

    REQ_GB=""
    while IFS='|' read -r idx _ _ _ size_gb _ _ _ _ _ _; do
        [[ "${idx// /}" == "$CHOICE" ]] && { REQ_GB="${size_gb// /}"; break; }
    done < <(printf '%s\n' "${MODELS[@]}")
    [[ -z "$REQ_GB" ]] && die "Could not determine model size for index $CHOICE"

    REQ_GB_INT=${REQ_GB%.*}
    [[ "$REQ_GB" == *"."* ]] && REQ_GB_INT=$(( REQ_GB_INT + 1 ))
    REQ_GB_INT=$(( REQ_GB_INT + 2 ))
    (( REQ_GB_INT < 3 )) && REQ_GB_INT=3
    (( AVAIL_GB < REQ_GB_INT )) && \
        die "Insufficient disk: need ~${REQ_GB_INT}GB, have ${AVAIL_GB}GB."
    ok "Disk space OK: ${AVAIL_GB}GB available, ~${REQ_GB_INT}GB needed."

    if [[ -n "${HF_TOKEN:-}" ]]; then
        HF_TOKEN="${HF_TOKEN}" "$HF_CLI" download "${SEL_HF_REPO}" "${SEL_GGUF}" \
            --local-dir "${MODEL_DIR}"
    else
        "$HF_CLI" download "${SEL_HF_REPO}" "${SEL_GGUF}" --local-dir "${MODEL_DIR}"
    fi
    [[ -f "$GGUF_PATH" ]] || die "Download completed but file not found."
    FILE_SIZE=$(stat -c%s "$GGUF_PATH" 2>/dev/null || echo 0)
    (( FILE_SIZE < 104857600 )) && \
        die "Downloaded file suspiciously small (${FILE_SIZE} bytes)."
    if command -v numfmt &>/dev/null; then
        ok "Downloaded: ${GGUF_PATH} ($(numfmt --to=iec-i --suffix=B "${FILE_SIZE}"))"
    else
        ok "Downloaded: ${GGUF_PATH} (${FILE_SIZE} bytes)"
    fi
fi

# =============================================================================
#  8. Build llama.cpp  [SKIPPED by switch-model]
# =============================================================================
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
    found=$(find "${HOME}/llama.cpp" -name "llama-server" -type f \
        -executable 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then
        vo=$("$found" --version 2>&1) || true
        echo "$vo" | grep -qiE 'llama|ggml' && { echo "$found"; return 0; }
    fi
    return 1
}

if [[ -n "$_SMO" ]]; then
    # Lightweight: just locate the existing binary, do not build
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

        command -v ccache &>/dev/null && {
            ok "ccache stats:"
            ccache -s 2>/dev/null | grep -E "cache (hit|miss)|cache size|max size" || true
        }

        LLAMA_SERVER_BIN=$(find_llama_server || true)
        [[ -n "$LLAMA_SERVER_BIN" ]] || die "llama-server not found after build."
        ok "llama-server: ${LLAMA_SERVER_BIN}"
    fi
fi

# =============================================================================
#  9. Hermes Agent install  [SKIPPED by switch-model]
# =============================================================================
HERMES_AGENT_DIR="${HOME}/hermes-agent"
HERMES_DIR="${HOME}/.hermes"
export PATH="${HOME}/.local/bin:${PATH}"

if [[ -z "$_SMO" ]]; then
    step "Installing Hermes Agent (official NousResearch)..."

    # Remove outsourc-e fork if present
    if [[ -d "${HERMES_AGENT_DIR}/.git" ]]; then
        CURRENT_REMOTE=$(git -C "${HERMES_AGENT_DIR}" remote get-url origin 2>/dev/null || echo "")
        if [[ "$CURRENT_REMOTE" == *"outsourc-e"* ]]; then
            warn "outsourc-e fork detected — removing and replacing with official repo."
            rm -rf "${HERMES_AGENT_DIR}"
        fi
    fi

    if ! command -v hermes &>/dev/null || [[ ! -d "${HERMES_AGENT_DIR}/.git" ]]; then
        step "Running official Hermes install script..."
        curl -fsSL --connect-timeout 15 --max-time 300 \
            https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh \
            -o /tmp/hermes-install.sh || die "Failed to download Hermes install script."
        register_tmp "/tmp/hermes-install.sh"
        bash /tmp/hermes-install.sh || {
            warn "Official install script failed — falling back to manual install."
            if ! command -v uv &>/dev/null; then
                curl -LsSf https://astral.sh/uv/install.sh | sh
                source "${HOME}/.cargo/env" 2>/dev/null || true
                export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:${PATH}"
            fi
            if [[ ! -d "${HERMES_AGENT_DIR}/.git" ]]; then
                git clone --recurse-submodules \
                    https://github.com/NousResearch/hermes-agent.git "${HERMES_AGENT_DIR}"
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
            if command -v uv &>/dev/null && [[ -d ".venv" ]]; then
                VIRTUAL_ENV="${HERMES_AGENT_DIR}/.venv" uv pip install -e ".[all]" \
                    --quiet 2>/dev/null || true
            fi
            cd ~
        fi
    fi

    export PATH="${HOME}/.local/bin:${PATH}"
    command -v hermes &>/dev/null || die "hermes not found after install. Check output above."
    ok "Hermes Agent: $(hermes --version 2>/dev/null || echo 'installed')"
fi

# =============================================================================
#  9b. Configure Hermes for local llama-server
# =============================================================================
step "Configuring Hermes for local llama-server..."

mkdir -p "${HERMES_DIR}"/{cron,sessions,logs,memories,skills}

# .env
cat > "${HERMES_DIR}/.env" <<ENV
OPENAI_API_KEY=sk-no-key-needed
OPENAI_BASE_URL=http://localhost:8080/v1
ENV
ok "~/.hermes/.env written."

# config.yaml
CONFIG_FILE="${HERMES_DIR}/config.yaml"
EXAMPLE_CFG="${HERMES_AGENT_DIR}/cli-config.yaml.example"

if [[ ! -f "$CONFIG_FILE" ]] && [[ -f "$EXAMPLE_CFG" ]]; then
    cp "$EXAMPLE_CFG" "$CONFIG_FILE"
    ok "config.yaml initialised from example template."
fi

# Pass variables safely into Python
python3 - <<'PYCONF' "${SEL_NAME}" "${SAFE_CTX}"
import re
import sys

path = "${CONFIG_FILE}"
model_name = sys.argv[1]
base_url   = "http://localhost:8080/v1"
ctx_length = int(sys.argv[2])

try:
    with open(path, "r") as f:
        content = f.read()
except FileNotFoundError:
    content = ""

# Clean old blocks
content = re.sub(r'^model:.*?(?=^\S|\Z)', '', content, flags=re.MULTILINE | re.DOTALL)
content = re.sub(r'^terminal:.*?(?=^\S|\Z)', '', content, flags=re.MULTILINE | re.DOTALL)
content = re.sub(r'^agent:.*?(?=^\S|\Z)', '', content, flags=re.MULTILINE | re.DOTALL)
content = re.sub(r'^setup_complete:.*\n?', '', content, flags=re.MULTILINE)
content = content.rstrip()

# Safe YAML escaping for model name
_YAML_UNSAFE = re.compile(r'[\s:,#\[\]{}|>&*!%\\?@`"\']|^[-?]|^\s|\s$')
if _YAML_UNSAFE.search(model_name) or model_name.lower() in (
        'true','false','null','yes','no','on','off','~'):
    model_name_yaml = "'" + model_name.replace("'", "''") + "'"
else:
    model_name_yaml = model_name

new_block = f"""
setup_complete: true

model:
  provider: custom
  base_url: {base_url}
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

with open(path, "w") as f:
    f.write((content + "\n" if content else "") + new_block + "\n")

print(f"config.yaml: model={model_name}  ctx={ctx_length}")
print("setup_complete: true  → wizard suppressed on first run")
print("memory.honcho.enabled → self-learning active")
PYCONF

ok "Hermes configured → llama-server (${SEL_NAME}, ctx=${SAFE_CTX})"
ok "setup_complete: true written → setup wizard will not fire"
ok "Hermes ready with local backend"
# =============================================================================
#  9c. Install recommended Hermes skills (agentskills.io open standard)
#      [SKIPPED by switch-model — skills persist across model changes]
#      BUG FIX B5: Moved to AFTER llama-server starts (section 12).
#                  Skills install is recorded here for reference but the
#                  actual invocation is at the post-server-start block below.
#
#  agentskills.io is an open standard for portable agent skill files (SKILL.md).
#  Originally developed by Anthropic, now community-maintained.
#  Hermes is fully compatible — skills self-improve during use.
#  Skills live in ~/.hermes/skills/ and are loaded on demand to minimise tokens.
#
#  Curated set for this stack (all official/production-grade):
#    github-pr-workflow — Git + GitHub PR creation workflow
#    axolotl            — Fine-tuning LLMs with Axolotl (local ML)
#    huggingface-hub    — HF Hub CLI: search, download, upload models
# =============================================================================
# (Skills install runs after llama-server starts — see section 12b below)

# =============================================================================
#  10. pip update  [SKIPPED by switch-model]
# =============================================================================
if [[ -z "$_SMO" ]]; then
    pip3 install --user --break-system-packages --upgrade pip setuptools wheel \
        2>/dev/null || true
fi

# =============================================================================
#  11. Create ~/start-llm.sh  (always runs — regenerated on every switch-model)
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
envsubst '${GGUF_PATH} ${SEL_NAME} ${LLAMA_SERVER_BIN} ${SAFE_CTX} ${USE_JINJA}' \
    < "${LAUNCH_SCRIPT}.template" > "$LAUNCH_SCRIPT"
rm -f "${LAUNCH_SCRIPT}.template"
chmod +x "$LAUNCH_SCRIPT"
ok "Launch script: ~/start-llm.sh"

# =============================================================================
#  12. systemd user service  [SKIPPED by switch-model]
# =============================================================================
if [[ -z "$_SMO" ]]; then
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

# Start / restart llama-server (always — key action in both full-install and switch-model)
step "Starting llama-server..."
pkill -f "llama-server" 2>/dev/null || true
sleep 1
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
    warn "llama-server not responding after 30s — check: tail -f /tmp/llama-server.log"

# =============================================================================
#  12b. Install recommended Hermes skills (agentskills.io open standard)
#       [SKIPPED by switch-model — skills persist across model changes]
#       BUG FIX B5: Runs here (after server start) not before, so Hermes
#       has a running endpoint when it attempts skill compatibility checks.
# =============================================================================
if [[ -z "$_SMO" ]] && command -v hermes &>/dev/null; then
    step "Installing recommended Hermes skills (agentskills.io)..."
    for skill in "github-pr-workflow" "axolotl" "huggingface-hub"; do
        hermes skills install "official/${skill}" --yes 2>/dev/null && \
            ok "Installed skill: ${skill}" || \
            warn "Skill '${skill}' not installed — run: hermes skills install official/${skill}"
    done
    ok "Skills: ~/.hermes/skills/  |  hermes skills browse  |  hermes skills search <query>"
fi

# =============================================================================
#  13. Optional agents  [SKIPPED by switch-model]
#      Config update for all installed agents happens in section 13d (always runs).
# =============================================================================
GOOSE_INSTALLED=false
OPENCODE_INSTALLED=false
AUTOAGENT_INSTALLED=false
AUTOAGENT_DIR="${HOME}/autoagent"
AUTOAGENT_VENV="${AUTOAGENT_DIR}/.venv"

if [[ -z "$_SMO" ]]; then

# ── 13a. Goose (block/goose) ──────────────────────────────────────────────────
echo ""
echo -e "  ${BLD}Optional: Goose AI Agent (block/goose)${RST}"
echo -e "  Rust CLI · 30k+ stars · Linux Foundation · MCP · no cloud needed"
echo ""
if [[ -t 0 ]]; then read -rp "  Install Goose? [y/N]: " install_goose
else install_goose="n"; fi

if [[ "$install_goose" =~ ^[Yy]$ ]]; then
    step "Installing Goose CLI..."
    if command -v goose &>/dev/null; then
        ok "Goose: $(goose --version 2>/dev/null || echo 'installed')"
        GOOSE_INSTALLED=true
    else
        if curl -fsSL --connect-timeout 15 --max-time 120 --retry 3 --retry-delay 2 \
            https://github.com/block/goose/releases/download/stable/download_cli.sh \
            -o /tmp/goose-install.sh 2>/dev/null; then
            register_tmp "/tmp/goose-install.sh"
            bash /tmp/goose-install.sh && export PATH="${HOME}/.local/bin:${PATH}" || \
                warn "Goose install script failed."
        else
            warn "Failed to download Goose install script — skipping."
        fi
        command -v goose &>/dev/null && {
            ok "Goose: $(goose --version 2>/dev/null || echo 'installed')"
            GOOSE_INSTALLED=true
        } || warn "Goose not in PATH — may need: export PATH=\"\${HOME}/.local/bin:\${PATH}\""
    fi
else
    ok "Skipping Goose."
    command -v goose &>/dev/null && GOOSE_INSTALLED=true
fi

# ── 13b. OpenCode (anomalyco/opencode) ───────────────────────────────────────
echo ""
echo -e "  ${BLD}Optional: OpenCode (anomalyco/opencode) — AI Coding Agent${RST}"
echo -e "  Terminal TUI · 120k+ stars · 75+ providers · Go binary · no Node.js"
echo ""
if [[ -t 0 ]]; then read -rp "  Install OpenCode? [y/N]: " install_opencode
else install_opencode="n"; fi

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
            command -v opencode &>/dev/null && {
                ok "OpenCode: $(opencode --version 2>/dev/null || echo 'installed')"
                OPENCODE_INSTALLED=true
            } || warn "OpenCode binary not in PATH after install."
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
}
OC_ALIASES
            ok "OpenCode aliases added to ~/.bashrc."
        fi
    fi
else
    ok "Skipping OpenCode."
    command -v opencode &>/dev/null && OPENCODE_INSTALLED=true
fi

# ── 13c. AutoAgent (HKUDS/AutoAgent) ─────────────────────────────────────────
echo ""
echo -e "  ${BLD}Optional: AutoAgent (HKUDS) — Deep Research${RST}"
echo -e "  Zero-code multi-agent · #1 GAIA benchmark · no Docker for CLI mode"
echo -e "  ${YLW}Best with:${RST} model 5 (Qwen3.5-9B) or model 6 (Carnice-9b)"
echo ""
if [[ -t 0 ]]; then read -rp "  Install AutoAgent? [y/N]: " install_autoagent
else install_autoagent="n"; fi

if [[ "$install_autoagent" =~ ^[Yy]$ ]]; then
    # python3-tk: AutoAgent's file_select.py does `import tkinter as tk` at
    # module level — even in headless deep-research mode.
    # Without it, every `auto` invocation crashes with ModuleNotFoundError.
    step "Installing python3-tk (required by AutoAgent file selector)..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-tk 2>/dev/null || \
        warn "python3-tk install failed — AutoAgent may crash on file selection."
    ok "python3-tk ready."

    if ! command -v uv &>/dev/null; then
        step "Installing uv..."
        curl -LsSf https://astral.sh/uv/install.sh | sh
        source "${HOME}/.cargo/env" 2>/dev/null || true
        export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:${PATH}"
        ok "uv: $(uv --version)"
    else
        ok "uv: $(uv --version)"
    fi

    if [[ -d "${AUTOAGENT_DIR}/.git" ]]; then
        ok "AutoAgent already cloned — updating..."
        cd "${AUTOAGENT_DIR}"
        git fetch origin 2>/dev/null && git reset --hard origin/main 2>/dev/null || \
            warn "AutoAgent update failed — continuing with existing code."
        cd - >/dev/null
    else
        step "Cloning HKUDS/AutoAgent..."
        git clone https://github.com/HKUDS/AutoAgent.git "${AUTOAGENT_DIR}" 2>&1 | tail -3
        ok "AutoAgent cloned."
    fi

    if [[ ! -d "$AUTOAGENT_VENV" ]]; then
        step "Creating Python 3.11 venv for AutoAgent..."
        uv venv "${AUTOAGENT_VENV}" --python 3.11
        ok "Venv: ${AUTOAGENT_VENV}"
    fi

    step "Installing AutoAgent dependencies..."
    (
        export VIRTUAL_ENV="${AUTOAGENT_VENV}"
        export PATH="${AUTOAGENT_VENV}/bin:${PATH}"
        cd "${AUTOAGENT_DIR}"
        uv pip install -e "." 2>&1 | tail -5
    ) && ok "AutoAgent installed." || warn "AutoAgent install had warnings."

    cat > "${HOME}/start-autoagent.sh" <<AUTOAGENT_LAUNCHER
#!/usr/bin/env bash
# start-autoagent.sh — generated by install.sh
AUTOAGENT_VENV="${AUTOAGENT_VENV}"
AUTOAGENT_DIR="${AUTOAGENT_DIR}"

if ! curl -sf http://localhost:8080/v1/models &>/dev/null; then
    echo -e "\n  ⚠ llama-server not running. Start with: start-llm"
    if [[ -t 0 ]]; then
        read -rp "  Auto-start llama-server? [Y/n]: " yn
        if [[ ! "\$yn" =~ ^[Nn]\$ ]]; then
            nohup bash ~/start-llm.sh < /dev/null >> /tmp/llama-server.log 2>&1 &
            echo "  Waiting for llama-server..."
            for i in {1..30}; do
                curl -sf http://localhost:8080/v1/models &>/dev/null && break
                sleep 1
            done
            curl -sf http://localhost:8080/v1/models &>/dev/null || {
                echo "  llama-server not ready. Check: tail -f /tmp/llama-server.log"
                exit 1
            }
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

fi  # end [[ -z "$_SMO" ]]

# Detect installed agents when running in switch-model mode
if [[ -n "$_SMO" ]]; then
    command -v goose    &>/dev/null && GOOSE_INSTALLED=true
    command -v opencode &>/dev/null && OPENCODE_INSTALLED=true
    [[ -d "${AUTOAGENT_DIR}/.git" ]] && AUTOAGENT_INSTALLED=true
fi

# =============================================================================
#  13d. Update agent configs to new model  (always runs — core switch-model action)
#       Goose, OpenCode, AutoAgent all updated to SEL_GGUF automatically.
# =============================================================================
step "Updating agent configs for: ${SEL_NAME} (${SEL_GGUF})..."

# Goose config — OPENAI_HOST must NOT have /v1 (path goes in OPENAI_BASE_PATH)
if [[ "$GOOSE_INSTALLED" == "true" ]] || command -v goose &>/dev/null; then
    mkdir -p "${HOME}/.config/goose"
    cat > "${HOME}/.config/goose/config.yaml" <<GOOSE_CFG
# Goose — local llama-server  |  Generated by install.sh
# CRITICAL: OPENAI_HOST has NO /v1 — path goes in OPENAI_BASE_PATH
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
    ok "Goose → model: ${SEL_GGUF}"
fi

# OpenCode config — @ai-sdk/openai-compatible provider pointing at llama-server
if [[ "$OPENCODE_INSTALLED" == "true" ]] || command -v opencode &>/dev/null; then
    mkdir -p "${HOME}/.config/opencode" "${HOME}/.local/share/opencode"
    OPENCODE_AUTH="${HOME}/.local/share/opencode/auth.json"
    [[ -f "$OPENCODE_AUTH" ]] || printf '{\n  "llamacpp": "sk-local"\n}\n' > "$OPENCODE_AUTH"
    cat > "${HOME}/.config/opencode/opencode.json" <<OCODE_CFG
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
          "limit": { "context": ${SAFE_CTX} }
        }
      }
    }
  },
  "model": "llamacpp/${SEL_GGUF}",
  "small_model": "llamacpp/${SEL_GGUF}"
}
OCODE_CFG
    ok "OpenCode → model: ${SEL_GGUF}"
fi

# AutoAgent .env — COMPLETION_MODEL=openai/<filename>
if [[ "$AUTOAGENT_INSTALLED" == "true" ]] || [[ -d "${AUTOAGENT_DIR}/.git" ]]; then
    mkdir -p "${HOME}/.autoagent"
    cat > "${HOME}/.autoagent/.env" <<AUTOAGENT_ENV
# AutoAgent — local llama-server  |  Generated by install.sh
# Format: openai/<model-filename> (litellm convention)
COMPLETION_MODEL=openai/${SEL_GGUF}
API_BASE_URL=http://localhost:8080/v1
OPENAI_API_KEY=sk-no-key-needed
DEBUG=False
AUTOAGENT_ENV
    ok "AutoAgent → model: ${SEL_GGUF}"
fi

# =============================================================================
#  14. ~/.bashrc helpers  [SKIPPED by switch-model]
# =============================================================================
if [[ -z "$_SMO" ]]; then
    step "Adding helpers to ~/.bashrc..."

    SCRIPT_SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || \
        realpath "$0" 2>/dev/null || echo "")"

    # BUG FIX B4: When script is run via `curl | bash`, BASH_SOURCE[0] is
    # /dev/stdin or empty, making SCRIPT_SELF unusable as a switch-model target.
    # Solution: copy the script to a stable location and use that as the target.
    INSTALL_COPY="${HOME}/.local/bin/install-llm.sh"
    if [[ "$SCRIPT_SELF" == "/dev/stdin" || -z "$SCRIPT_SELF" || \
          "$SCRIPT_SELF" == "/proc/"* ]]; then
        warn "Script run via pipe — copying to ${INSTALL_COPY} for switch-model."
        mkdir -p "${HOME}/.local/bin"
        # Can't copy /dev/stdin (already consumed), but we can write a stub that
        # re-downloads. Use the known GitHub URL as fallback.
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
        # Script exists on disk — copy to stable location for switch-model
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
alias stop-llm='pkill -f llama-server 2>/dev/null || true; echo "llama-server stopped."'
alias restart-llm='stop-llm; sleep 2; start-llm'
alias llm-log='tail -f /tmp/llama-server.log'

# switch-model: truly lightweight.
# Skips: HF token prompt, sys packages, CUDA, llama.cpp build, Hermes install,
#        systemd, bashrc helpers, .wslconfig, optional agent install prompts.
# Runs:  HF CLI refresh → model table → pick → download → start-llm.sh regen
#        → Hermes/Goose/OpenCode/AutoAgent config update → restart llama-server.
alias switch-model='SWITCH_MODEL_ONLY=1 bash ${INSTALL_COPY}'
BASHRC_EXPANDED

        if [[ -n "${HF_TOKEN:-}" ]] && \
                ! grep -qF "export HF_TOKEN=" "${HOME}/.bashrc" 2>/dev/null; then
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

llm-models() {
    local active_model=""
    [[ -f ~/start-llm.sh ]] && \
        active_model=$(grep '^GGUF=' ~/start-llm.sh 2>/dev/null | head -1 | \
        sed 's/GGUF="//;s/".*//' | xargs basename 2>/dev/null || true)
    echo -e "\n  ${BLD}Models in ~/llm-models:${RST}"
    echo "  ────────────────────────────────────────────────"
    # NOTE: (( found++ )) exits code 1 when found=0 under set -e.
    local found=0 f sz name tag
    for f in ~/llm-models/*.gguf; do
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
    echo -e "${BLD}${CYN}│${RST}  ${CYN}hermes${RST}        Chat with Hermes Agent"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}goose${RST}         Goose (if installed)"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}opencode${RST}      OpenCode coding agent (if installed)"
    echo -e "${BLD}${CYN}│${RST}  ${CYN}autoagent${RST}     AutoAgent deep research (if installed)"
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

# Auto-start llama-server on first interactive terminal per WSL session.
# /proc/uptime truncated to minutes = per-boot stable key shared across tabs.
# New WSL start clears /tmp → new marker → auto-starts again.
_llm_autostart() {
    [[ $- != *i* ]] && return 0
    pgrep -f "llama-server" &>/dev/null && return 0
    [[ -f ~/start-llm.sh ]] || return 0
    local uptime_min
    uptime_min=$(awk '{print int($1/60)}' /proc/uptime 2>/dev/null || echo "0")
    local session_marker="/tmp/.llm_autostarted_${uptime_min}"
    [[ -f "$session_marker" ]] && return 0
    touch "$session_marker"
    echo -e "${YLW}[LLM] llama-server not running — auto-starting...${RST}"
    nohup bash ~/start-llm.sh < /dev/null >> /tmp/llama-server.log 2>&1 &
    disown
}
_llm_autostart

[[ $- == *i* && ! -f "${HOME}/.llm_summary_shown" ]] && {
    show_llm_summary
    touch "${HOME}/.llm_summary_shown"
}
BASHRC_FUNCTIONS

        ok "Helpers written to ~/.bashrc."
    fi
fi

# =============================================================================
#  15. .wslconfig RAM hint  [SKIPPED by switch-model]
# =============================================================================
if [[ -z "$_SMO" ]]; then
    WIN_USER=$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r\n' || echo "")
    WSLCONFIG="" WSLCONFIG_DIR=""
    if [[ -n "$WIN_USER" ]]; then
        for drive in c d e f; do
            [[ -d "/mnt/${drive}/Users/${WIN_USER}" ]] && {
                WSLCONFIG_DIR="/mnt/${drive}/Users/${WIN_USER}"
                WSLCONFIG="${WSLCONFIG_DIR}/.wslconfig"; break
            }
            [[ -d "/mnt/${drive}/home/${WIN_USER}" ]] && {
                WSLCONFIG_DIR="/mnt/${drive}/home/${WIN_USER}"
                WSLCONFIG="${WSLCONFIG_DIR}/.wslconfig"; break
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
╚══════════════════════════════════════════════════════════════╝
EOF
fi
echo -e "${RST}"

echo -e " ${BLD}Active model:${RST}  ${SEL_NAME}"
echo -e "               ${SEL_GGUF}"
echo -e " ${BLD}Context:${RST}       ${SAFE_CTX} tokens   ${BLD}Jinja:${RST} ${USE_JINJA}"
echo ""

if [[ -z "$_SMO" ]]; then
    echo -e " ${BLD}Installed:${RST}"
    echo -e "  llama-server  →  http://localhost:8080/v1"
    echo -e "  Hermes Agent  →  hermes"
    [[ "$GOOSE_INSTALLED"     == "true" ]] && echo -e "  Goose         →  goose"
    [[ "$OPENCODE_INSTALLED"  == "true" ]] && echo -e "  OpenCode      →  opencode  (alias: oc)"
    [[ "$AUTOAGENT_INSTALLED" == "true" ]] && echo -e "  AutoAgent     →  autoagent"
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
echo ""
echo -e " ${GRN}Honcho memory:${RST}  enabled — Hermes learns your patterns across sessions"
echo -e " ${GRN}Skills:${RST}         hermes skills browse  |  hermes skills search <query>"
echo -e " ${CYN}agentskills.io${RST}  open standard — compatible with Hermes, OpenCode, Claude Code"
echo ""
echo -e " ${YLW}Note:${RST}       source ~/.bashrc or open a new terminal."
echo -e " ${YLW}Auto-start:${RST} llama-server starts automatically on new terminal."
echo -e " ${GRN}Persistent:${RST} sudo loginctl enable-linger $USER"
echo ""
