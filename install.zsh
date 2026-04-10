#!/usr/bin/env zsh
# =============================================================================
#  install.zsh  –  Ubuntu WSL2  ·  llama.cpp + Hermes + optional tools
#  Version: production-hardened (CLEAN) – all debug prints removed
# =============================================================================
emulate -L zsh -o extendedglob -o errreturn -o pipefail -o no_unset

# ── SWITCH_MODEL_ONLY sentinel ─────────────────────────────────────────────────
_SMO="${SWITCH_MODEL_ONLY:-}"
unset SWITCH_MODEL_ONLY

# ── Strip Windows /mnt/* from PATH ────────────────────────────────────────────
path=( ${path:#/mnt/*} )

# ── Colour helpers ─────────────────────────────────────────────────────────────
readonly RED='%F{red}' GRN='%F{green}' YLW='%F{yellow}'
readonly CYN='%F{cyan}' BLD='%B' RST='%f%b'
export RED GRN YLW CYN BLD RST

step() { print -P "${CYN}[*] $*${RST}"; }
ok()   { print -P "${GRN}[+] $*${RST}"; }
warn() { print -P "${YLW}[!] $*${RST}"; }
die()  { print -P "${RED}[ERROR] $*${RST}"; exit 1; }

# ── Temp file cleanup ──────────────────────────────────────────────────────────
typeset -a TMPFILES=()
cleanup() {
    local f
    for f in "${TMPFILES[@]}"; do
        [[ -n "$f" && -f "$f" ]] && rm -f "$f"
    done
}
TRAPEXIT() { cleanup }
register_tmp() { TMPFILES+=("$1"); }

# ── Banner ─────────────────────────────────────────────────────────────────────
print -P "${BLD}${CYN}"
if [[ -n "$_SMO" ]]; then
    cat <<'BANNER'
╔══════════════════════════════════════════════════════════════╗
║         Model Switcher  ·  Lightweight mode                  ║
╚══════════════════════════════════════════════════════════════╝
BANNER
else
    cat <<'BANNER'
╔══════════════════════════════════════════════════════════════╗
║  Ubuntu WSL2  ·  llama.cpp + Hermes + AutoAgent              ║
╚══════════════════════════════════════════════════════════════╝
BANNER
fi
print -P "${RST}"

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
_HF_ENV="${HF_TOKEN:-}"
HF_TOKEN=""
if [[ -n "$_HF_ENV" ]]; then
    HF_TOKEN="$_HF_ENV"
    ok "HF_TOKEN already set in environment."
elif [[ -f "${HOME}/.cache/huggingface/token" ]]; then
    HF_TOKEN=$(cat "${HOME}/.cache/huggingface/token" 2>/dev/null || true)
    [[ -n "$HF_TOKEN" ]] && ok "HF_TOKEN loaded from cache."
else
    if [[ -f "${HOME}/.zshrc" ]]; then
        extracted=$(zsh -c 'source "$1" 2>/dev/null && print -rn "$2"' _ "${HOME}/.zshrc" "HF_TOKEN" || true)
        if [[ -n "$extracted" ]]; then
            HF_TOKEN="$extracted"
            ok "HF_TOKEN loaded from ~/.zshrc (safe extraction)."
        fi
    fi
fi

if [[ -z "$HF_TOKEN" && -z "$_SMO" ]]; then
    print ""
    print -P "  ${BLD}Why add a HuggingFace token?${RST}"
    print -P "  Faster downloads · higher rate limits · gated model access"
    print -P "  ${CYN}https://huggingface.co/settings/tokens${RST}"
    print ""
    if [[ -t 0 ]]; then
        read -r "hf_yn?  Do you have a HuggingFace token to add? [y/N]: "
        if [[ "$hf_yn" =~ ^[Yy]$ ]]; then
            read -r "HF_TOKEN?  Paste your token (starts with hf_): "
            HF_TOKEN="${HF_TOKEN//[[:space:]]/}"
            if [[ "$HF_TOKEN" =~ ^hf_ ]]; then
                ok "Token accepted."
            else
                warn "Token doesn't start with 'hf_' — using anyway."
            fi
            if ! grep -qF "export HF_TOKEN=" "${HOME}/.zshrc" 2>/dev/null; then
                print "export HF_TOKEN=\"${HF_TOKEN}\"" >>"${HOME}/.zshrc"
                ok "HF_TOKEN saved to ~/.zshrc."
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
#  1b. GitHub token – SECURE EXTRACTION
# =============================================================================
_GH_ENV="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
GITHUB_TOKEN=""
if [[ -n "$_GH_ENV" ]]; then
    GITHUB_TOKEN="$_GH_ENV"
    ok "GitHub token already set in environment."
else
    if [[ -f "${HOME}/.zshrc" ]]; then
        extracted=$(zsh -c 'source "$1" 2>/dev/null && print -rn "$2"' _ "${HOME}/.zshrc" "GITHUB_TOKEN" || true)
        if [[ -n "$extracted" ]]; then
            GITHUB_TOKEN="$extracted"
            ok "GitHub token loaded from ~/.zshrc."
        fi
    fi
fi

if [[ -z "$GITHUB_TOKEN" && -z "$_SMO" ]]; then
    print ""
    print -P "  ${BLD}Why add a GitHub token?${RST}"
    print -P "  Higher API rate limits (5,000 vs 60) · access private repositories"
    print -P "  ${CYN}https://github.com/settings/tokens${RST} → Generate new token (classic)"
    print -P "  Required scopes: ${YLW}repo${RST}, ${YLW}read:org${RST} (optional)"
    print ""
    if [[ -t 0 ]]; then
        read -r "gh_yn?  Do you have a GitHub token to add? [y/N]: "
        if [[ "$gh_yn" =~ ^[Yy]$ ]]; then
            read -r "GITHUB_TOKEN?  Paste your token (starts with ghp_): "
            GITHUB_TOKEN="${GITHUB_TOKEN//[[:space:]]/}"
            if [[ "$GITHUB_TOKEN" =~ ^ghp_ ]]; then
                ok "Token accepted."
            else
                warn "Token doesn't start with 'ghp_' — using anyway."
            fi
            if ! grep -qF "export GITHUB_TOKEN=" "${HOME}/.zshrc" 2>/dev/null; then
                print "export GITHUB_TOKEN=\"${GITHUB_TOKEN}\"" >>"${HOME}/.zshrc"
                ok "GITHUB_TOKEN saved to ~/.zshrc."
            fi
        else
            ok "Skipping — unauthenticated GitHub access (rate-limited)."
        fi
    else
        ok "Non-interactive — skipping GitHub token prompt."
    fi
fi

if [[ -n "$GITHUB_TOKEN" ]]; then
    export GITHUB_TOKEN
    if ! git config --global credential.helper '!f() { print "username=${GITHUB_TOKEN}"; print "password=x-oauth-basic"; }; f' 2>/dev/null; then
        warn "Could not set git credential helper. GitHub operations may be unauthenticated."
    else
        ok "Git configured to use GitHub token via credential helper."
    fi
fi

# =============================================================================
#  6. HF CLI setup – MOVED EARLY (fix CE-1)
# =============================================================================
step "Setting up HuggingFace CLI..."
export PATH="${HOME}/.local/bin:${PATH}"

HF_CLI_A="${HOME}/.local/bin/hf"
HF_CLI_B="${HOME}/.local/bin/huggingface-cli"

if [[ ! -x "$HF_CLI_A" && ! -x "$HF_CLI_B" ]]; then
    pip3 install --quiet --user --break-system-packages huggingface_hub
fi
if [[ -z "$_SMO" ]]; then
    pip3 install --quiet --user --break-system-packages --upgrade huggingface_hub 2>&1 | tail -2
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
ok "$HF_CLI_NAME ready: $("$HF_CLI" version 2>/dev/null || print 'ok')"

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
#  Zsh Environment Bootstrapping (only in full install)
# =============================================================================
if [[ -z "$_SMO" ]]; then
    step "Bootstrapping Zsh environment..."

    if ! command -v zsh &>/dev/null; then
        step "Installing Zsh..."
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zsh
        ok "Zsh installed."
    else
        ok "Zsh already installed."
    fi

    CURRENT_SHELL=$(getent passwd "$USER" | cut -d: -f7)
    if [[ "$CURRENT_SHELL" != "$(which zsh)" ]]; then
        print ""
        print -P "  ${BLD}Zsh is not your default shell.${RST}"
        if [[ -t 0 ]]; then
            read -r "set_zsh_default?  Set Zsh as default shell? [y/N]: "
            if [[ "$set_zsh_default" =~ ^[Yy]$ ]]; then
                sudo chsh -s "$(which zsh)" "$USER"
                ok "Zsh set as default shell. Run 'zsh' to start."
            else
                ok "Keeping current shell. Run 'zsh' to use Zsh."
            fi
        else
            ok "Non-interactive — keeping current shell."
        fi
    else
        ok "Zsh is already the default shell."
    fi

    step "Installing Zsh tools and configuring ~/.zshrc..."

    mkdir -p "${HOME}/.zsh/plugins"

    if [[ ! -d "${HOME}/.zsh/plugins/zsh-syntax-highlighting" ]]; then
        git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "${HOME}/.zsh/plugins/zsh-syntax-highlighting" 2>/dev/null || warn "Failed to clone zsh-syntax-highlighting"
    fi

    if [[ ! -d "${HOME}/.zsh/plugins/zsh-autosuggestions" ]]; then
        git clone https://github.com/zsh-users/zsh-autosuggestions.git "${HOME}/.zsh/plugins/zsh-autosuggestions" 2>/dev/null || warn "Failed to clone zsh-autosuggestions"
    fi

    if ! command -v fzf &>/dev/null; then
        if [[ ! -d "${HOME}/.zsh/fzf" ]]; then
            git clone --depth 1 https://github.com/junegunn/fzf.git "${HOME}/.zsh/fzf" 2>/dev/null || warn "Failed to clone fzf"
        fi
        if [[ -x "${HOME}/.zsh/fzf/install" ]]; then
            "${HOME}/.zsh/fzf/install" --bin >/dev/null 2>&1 || warn "fzf install failed"
        fi
    fi

    if [[ ! -d "${HOME}/.zsh/plugins/powerlevel10k" ]]; then
        git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "${HOME}/.zsh/plugins/powerlevel10k" 2>/dev/null || warn "Failed to clone powerlevel10k"
    fi

    ZSHRC_MARKER="# >>> LLM Stack Auto-Generated Zsh Config >>>"
    ZSHRC_END_MARKER="# <<< LLM Stack Auto-Generated Zsh Config <<<"

    if [[ -f "${HOME}/.zshrc" ]]; then
        cp "${HOME}/.zshrc" "${HOME}/.zshrc.backup.$(date +%Y%m%d%H%M%S)"
        ok "Backed up existing ~/.zshrc"
    fi

    if ! grep -qF "$ZSHRC_MARKER" "${HOME}/.zshrc" 2>/dev/null; then
        print ""
        print -P "  ${BLD}Configure Zsh with modern tools?${RST}"
        print -P "  This will add syntax highlighting, autosuggestions, fzf, and Powerlevel10k to ~/.zshrc"
        if [[ -t 0 ]]; then
            read -r "configure_zsh?  Configure Zsh with modern tools? [y/N]: "
        else
            configure_zsh="n"
        fi

        if [[ "$configure_zsh" =~ ^[Yy]$ ]]; then
            cat >>"${HOME}/.zshrc" <<ZSH_CONFIG

$ZSHRC_MARKER
# Modern Zsh Configuration for LLM Stack

# History settings
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt APPEND_HISTORY
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_SAVE_NO_DUPS
setopt SHARE_HISTORY
setopt INC_APPEND_HISTORY

# Completion system
autoload -Uz compinit && compinit
zstyle ':completion:*' menu yes select
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
zstyle ':completion:*' format '%F{cyan}-- %d --%f'
zstyle ':completion:*' group-name ''

# Key bindings
bindkey -e

# Useful options
setopt AUTO_CD
setopt EXTENDED_GLOB
setopt NO_BEEP
setopt CORRECT

# Syntax highlighting
if [[ -f ~/.zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]]; then
    source ~/.zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
fi

# Autosuggestions
if [[ -f ~/.zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh ]]; then
    source ~/.zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
    ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=8'
fi

# fzf
if [[ -f ~/.zsh/fzf/shell/key-bindings.zsh ]]; then
    source ~/.zsh/fzf/shell/key-bindings.zsh
fi
if [[ -f ~/.zsh/fzf/shell/completion.zsh ]]; then
    source ~/.zsh/fzf/shell/completion.zsh
fi

# Powerlevel10k theme
if [[ -f ~/.zsh/plugins/powerlevel10k/powerlevel10k.zsh-theme ]]; then
    source ~/.zsh/plugins/powerlevel10k/powerlevel10k.zsh-theme
fi

$ZSHRC_END_MARKER
ZSH_CONFIG
            ok "Zsh configuration added to ~/.zshrc"
            print -P "  ${YLW}Tip:${RST} Run 'p10k configure' in Zsh to customize the prompt."
        else
            ok "Skipping Zsh tool configuration."
        fi
    else
        ok "Zsh configuration already present in ~/.zshrc"
    fi
fi

# =============================================================================
#  2. System packages [SKIPPED by switch-model]
# =============================================================================
if [[ -z "$_SMO" ]]; then
    step "Updating system packages..."
    if sudo -n true 2>/dev/null; then
        sudo apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            build-essential cmake git ccache \
            libcurl4-openssl-dev software-properties-common \
            python3 python3-pip python3-venv \
            pciutils wget curl ca-certificates zstd \
            procps gettext-base
    else
        warn "sudo requires password. Please run manually: apt-get update && apt-get install ..."
        die "Cannot proceed without sudo."
    fi
    ok "System packages ready."

    step "Checking Python 3.11..."
    if python3.11 --version &>/dev/null; then
        ok "Python 3.11: $(python3.11 --version)"
    else
        if sudo -n true 2>/dev/null; then
            sudo add-apt-repository -y ppa:deadsnakes/ppa
            sudo apt-get update -qq
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
                python3.11 python3.11-venv
            ok "Python 3.11 installed: $(python3.11 --version)"
        else
            warn "Cannot install Python 3.11 without sudo."
        fi
    fi
fi

# =============================================================================
#  3. Hardware detection (always runs)
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
    if nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null |
        head -1 | grep -q ','; then
        GPU_LINE=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader \
            2>/dev/null | head -1)
        GPU_NAME=$(print "$GPU_LINE" | cut -d',' -f1 | xargs)
        VRAM_MiB=$(print "$GPU_LINE" | cut -d',' -f2 | awk '{print $1}')
        VRAM_GiB=$((VRAM_MiB / 1024))
        HAS_NVIDIA=true
        ok "GPU: ${GPU_NAME}  (${VRAM_GiB} GiB VRAM) — CUDA OK"
    else
        warn "nvidia-smi present but returned no GPU data — CPU-only."
    fi
else
    GPU_NAME=$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | head -1 |
        sed 's/.*: //' || print "None")
    warn "nvidia-smi not found — CPU-only mode. GPU (lspci): ${GPU_NAME}"
fi

print "\n  ${BLD}Hardware${RST}"
print "  RAM  : ${RAM_GiB} GiB   CPUs: ${CPUS}"
print "  GPU  : ${GPU_NAME}   VRAM: ${VRAM_GiB} GiB   CUDA: ${HAS_NVIDIA}"

if [[ -z "$_SMO" && "$HAS_NVIDIA" != "true" ]]; then
    warn "No NVIDIA GPU — llama.cpp will be CPU-only (much slower)."
    if [[ -t 0 ]]; then
        read -r "cpu_ok?  Continue with CPU-only build? [y/N]: "
        if [[ ! "$cpu_ok" =~ ^[Yy]$ ]]; then
            print "Aborted."
            exit 0
        fi
    else
        warn "Non-interactive — continuing with CPU-only build."
    fi
fi

# =============================================================================
#  4. CUDA toolkit [SKIPPED by switch-model; paths re-exported if GPU present]
# =============================================================================
if [[ -z "$_SMO" && "$HAS_NVIDIA" == "true" ]]; then
    step "Checking CUDA toolkit..."
    if command -v nvcc &>/dev/null; then
        ok "CUDA already installed: $(nvcc --version 2>/dev/null | head -1)"
    else
        step "Installing CUDA toolkit 12.6 for WSL2..."
        cuda_deb=$(mktemp /tmp/cuda-keyring.XXXXXX.deb)
        register_tmp "$cuda_deb"
        curl -fsSL --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 \
            https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb \
            -o "$cuda_deb" || die "Failed to download CUDA keyring"
        if sudo -n true 2>/dev/null; then
            sudo dpkg -i "$cuda_deb"
            sudo apt-get update -qq
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cuda-toolkit-12-6
            ok "CUDA toolkit 12.6 installed."
        else
            warn "Sudo required for CUDA installation. Skipping."
        fi
    fi
fi
if [[ "$HAS_NVIDIA" == "true" ]]; then
    export PATH="/usr/local/cuda/bin:${PATH}"
    export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"
fi

# =============================================================================
#  5. Model catalogue
# =============================================================================
readonly MODEL_DIR="${HOME}/llm-models"
mkdir -p "$MODEL_DIR"

typeset -A MODELS
MODELS=(
    1 "unsloth/Qwen3.5-0.8B-GGUF|Qwen3.5-0.8B-Q4_K_M.gguf|Qwen 3.5 0.8B|0.5|256K|2|0|tiny|chat,edge|Alibaba · instant · smoke-test"
    2 "unsloth/Qwen3.5-2B-GGUF|Qwen3.5-2B-Q4_K_M.gguf|Qwen 3.5 2B|1.0|256K|3|0|tiny|chat,multilingual|Alibaba · ultra-fast"
    3 "unsloth/Qwen3.5-4B-GGUF|Qwen3.5-4B-Q4_K_M.gguf|Qwen 3.5 4B|2.0|256K|4|0|small|chat,code|Alibaba · capable on CPU"
    4 "bartowski/microsoft_Phi-4-mini-instruct-GGUF|microsoft_Phi-4-mini-instruct-Q4_K_M.gguf|Phi-4 Mini 3.8B|2.0|16K|4|0|small|reasoning,code|Microsoft · strong reasoning"
    5 "unsloth/Qwen3.5-9B-GGUF|Qwen3.5-9B-Q4_K_M.gguf|Qwen 3.5 9B|5.3|256K|8|6|mid|chat,code,reasoning|@sudoingX pick · 50 tok/s on RTX 3060"
    6 "kai-os/Carnice-9b-GGUF|Carnice-9b-Q6_K.gguf|Carnice-9b (Hermes)|6.9|256K|8|6|mid|hermes,agent,tool-use|Qwen3.5-9B tuned for Hermes Agent harness"
    7 "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF|Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf|Llama 3.1 8B|4.1|128K|8|6|mid|chat,code,reasoning|Meta · excellent instruction"
    8 "bartowski/Qwen2.5-Coder-14B-Instruct-GGUF|Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf|Qwen2.5 Coder 14B|8.99|32K|12|10|mid|code|#1 coding on 3060"
    9 "unsloth/Qwen3-14B-GGUF|Qwen3-14B-Q4_K_M.gguf|Qwen 3 14B|9.0|32K|14|10|mid|chat,code,reasoning|Strong planning"
    10 "bartowski/google_gemma-3-12b-it-GGUF|google_gemma-3-12b-it-Q4_K_M.gguf|Gemma 3 12B|7.3|128K|12|10|mid|chat,code|Google Gemma 3 · strict roles"
    11 "bartowski/google_gemma-4-12b-it-GGUF|google_gemma-4-12b-it-Q4_K_M.gguf|Gemma 4 12B|7.3|132K|12|10|mid|chat,code|Google Gemma 4 · 132K ctx"
    12 "unsloth/Qwen3-30B-A3B-GGUF|Qwen3-30B-A3B-Q4_K_M.gguf|Qwen 3 30B MoE|17.0|128K|20|16|large|chat,code,reasoning|MoE · 3B active params"
    13 "bartowski/DeepSeek-R1-Distill-Qwen-32B-GGUF|DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf|DeepSeek R1 32B|17.0|64K|32|20|large|reasoning|R1 distill"
    14 "unsloth/Llama-3.3-70B-Instruct-GGUF|Llama-3.3-70B-Instruct-Q4_K_M.gguf|Llama 3.3 70B|39.0|128K|48|40|large|chat,reasoning,code|Meta · 24GB+ VRAM"
)

grade_color() {
    case "$1" in
    S | A) print "${GRN}" ;;
    B | C) print "${YLW}" ;;
    *) print "${RED}" ;;
    esac
}

grade_model() {
    local min_ram="${1:?}" min_vram="${2:?}"
    local ram_gib="${3:?}" vram_gib="${4:?}" has_nvidia="${5:?}"
    if [[ ! "$min_ram" =~ ^[0-9]+$ || ! "$min_vram" =~ ^[0-9]+$ ]]; then
        print "F"
        return 1
    fi
    local ram_h=$((ram_gib - min_ram))
    if ((min_vram > 0)) && [[ "$has_nvidia" == "true" ]]; then
        local vram_h=$((vram_gib - min_vram))
        if ((vram_h >= 4)); then
            print "S"
        elif ((vram_h >= 0)); then
            print "A"
        elif ((ram_h >= 4)); then
            print "B"
        elif ((ram_h >= 0)); then
            print "C"
        else
            print "F"
        fi
    elif ((min_vram > 0)); then
        if ((ram_h >= 8)); then
            print "B"
        elif ((ram_h >= 0)); then
            print "C"
        else
            print "F"
        fi
    else
        if ((ram_h >= 8)); then
            print "S"
        elif ((ram_h >= 4)); then
            print "A"
        elif ((ram_h >= 0)); then
            print "B"
        else
            print "F"
        fi
    fi
}

grade_label() {
    case "$1" in
    S) print "S  Runs great " ;;
    A) print "A  Runs well  " ;;
    B) print "B  Decent     " ;;
    C) print "C  Tight fit  " ;;
    F) print "F  Too heavy  " ;;
    *) print "?  Unknown    " ;;
    esac
}

apply_model_settings() {
    local gguf="$1"
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

# ── Draw model table (CLEAN – no debug prints) ─────────────────────────────────
show_model_table() {
    /usr/bin/clear 2>/dev/null || true
    print -P "${BLD}${CYN}"
    cat <<'HDR'
╔══════════════════════════════════════════════════════════════════════════════╗
║                        Model Selection                                      ║
╚══════════════════════════════════════════════════════════════════════════════╝
HDR
    print -P "${RST}"
    printf "  GPU: %-28s  RAM: %s GiB   VRAM: %s GiB   CUDA: %s\n\n" \
        "${GPU_NAME:0:28}" "$RAM_GiB" "$VRAM_GiB" "$HAS_NVIDIA"
    print "  ${BLD} #   Model                    Size    Ctx     Grade              Tags${RST}"
    print "  ─────────────────────────────────────────────────────────────────────────────"

    local last_tier="" idx
    for idx in ${(k)MODELS}; do
        local hf_repo gguf_file dname size_gb ctx min_ram min_vram tier tags desc
        IFS='|' read -r hf_repo gguf_file dname size_gb ctx \
            min_ram min_vram tier tags desc <<< "$MODELS[$idx]"
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
            tiny) print "\n  ${BLD}▸ TINY   (< 1 GB · instant · edge/test)${RST}" ;;
            small) print "\n  ${BLD}▸ SMALL  (1–2 GB · fast CPU · everyday use)${RST}" ;;
            mid) print "\n  ${BLD}▸ MID    (4–17 GB · quality/speed balance)${RST}" ;;
            large) print "\n  ${BLD}▸ LARGE  (15 GB+ · high-end GPU or lots of RAM)${RST}" ;;
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
        print "  ${BLD}$(printf '%2s' "$idx")${RST}  $(printf '%-26s' "$dname")" \
            " $(printf '%5s' "$size_gb") GB  $(printf '%-7s' "$ctx")" \
            "  ${GC}$(printf '%-13s' "$GL")${RST}  $(printf '%-24s' "$tag_display") $cached"
    done

    typeset -A catalogued
    for idx in ${(k)MODELS}; do
        local gguf_file
        IFS='|' read -r _ gguf_file _ <<< "$MODELS[$idx]"
        catalogued["${gguf_file// /}"]=1
    done

    local extra_count=0 f fname
    for f in "${MODEL_DIR}"/*.gguf; do
        [[ -f "$f" ]] || continue
        fname=$(basename "$f")
        if [[ -z "${catalogued[$fname]:-}" ]]; then
            extra_count=$((extra_count + 1))
            if ((extra_count == 1)); then
                print "\n  ${BLD}▸ LOCAL  (in ~/llm-models, not in catalogue)${RST}"
            fi
            local sz_bytes sz
            sz_bytes=$(wc -c <"$f" 2>/dev/null || print 0)
            if ((sz_bytes > 1073741824)); then
                sz="$(($sz_bytes / 1073741824))G"
            elif ((sz_bytes > 1048576)); then
                sz="$(($sz_bytes / 1048576))M"
            elif ((sz_bytes > 1024)); then
                sz="$(($sz_bytes / 1024))K"
            else
                sz="${sz_bytes}B"
            fi
            print "  ${CYN}↓${RST}  ${fname}  (${sz})"
        fi
    done

    print ""
    print "  ─────────────────────────────────────────────────────────────────────────────"
    print "  ${GRN}S/A${RST} Runs great/well   ${YLW}B/C${RST} Tight fit   ${RED}F${RST} Too heavy   ${CYN}↓${RST} Already on disk"
    print ""
    print "  ${YLW}Tip:${RST} Model 5 (Qwen3.5-9B) = general · Model 6 (Carnice-9b) = Hermes-tuned"
    print "  Enter a number, or ${BLD}u${RST} to download via HuggingFace URL."
    print ""
}

# ── HF URL / repo download – with apply_model_settings ────────────────────────
download_from_hf_url() {
    print ""
    print -P "  ${BLD}Download via HuggingFace${RST}"
    print -P "  Accepted:"
    print -P "    https://huggingface.co/owner/repo/resolve/main/file.gguf"
    print -P "    owner/repo-name  (lists files, you pick)"
    print ""
    read -r "HF_INPUT?  Paste URL or repo (owner/name): "
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
            local -a ca=(-fL --progress-bar -o "$GGUF_PATH")
            [[ -n "${HF_TOKEN:-}" ]] && ca+=(-H "Authorization: Bearer ${HF_TOKEN}")
            curl "${ca[@]}" "$HF_INPUT" || die "curl download failed."
            [[ -f "$GGUF_PATH" ]] || die "File not found after download."
            local fs
            fs=$(wc -c <"$GGUF_PATH" 2>/dev/null || print 0)
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
            read -r "SEL_GGUF?  Filename (e.g. model-Q4_K_M.gguf): "
            SEL_GGUF="${SEL_GGUF//[[:space:]]/}"
            [[ -z "$SEL_GGUF" ]] && die "No filename."
        else
            mapfile -t GGUF_FILES <<<"$py_out"
            if [[ ${#GGUF_FILES[@]} -eq 1 ]]; then
                SEL_GGUF="${GGUF_FILES[0]}"
                ok "Only one GGUF found: ${SEL_GGUF}"
            else
                print ""
                print -P "  ${BLD}Available GGUFs:${RST}"
                local fnum=1 gf
                for gf in "${GGUF_FILES[@]}"; do
                    printf "  %2d  %s\n" "$fnum" "$gf"
                    fnum=$((fnum + 1))
                done
                print ""
                local gf_choice
                while true; do
                    read -r "gf_choice?  Enter number [1-${#GGUF_FILES[@]}]: "
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
            fs=$(wc -c <"$GGUF_PATH" 2>/dev/null || print 0)
            ((fs < 104857600)) && die "File too small (${fs} bytes)."
            ok "Downloaded: ${GGUF_PATH}"
        fi
    fi
    apply_model_settings "$SEL_GGUF"
}

# =============================================================================
#  5 (continued). Model selector (always runs)
# =============================================================================
NUM_MODELS=${#MODELS}
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
    read -r "CHOICE?$(print "  ${BLD}Enter number [1-${NUM_MODELS}] or 'u' for URL:${RST} ")" || {
        print ""
        warn "EOF detected. Exiting."
        exit 0
    }
    if [[ "$CHOICE" == "u" || "$CHOICE" == "U" ]]; then
        download_from_hf_url
        break
    elif [[ "$CHOICE" =~ ^[0-9]+$ ]] && ((CHOICE >= 1 && CHOICE <= NUM_MODELS)); then
        break
    fi
    warn "Enter a number between 1 and ${NUM_MODELS}, or 'u'."
done

if [[ "$CHOICE" != "u" && "$CHOICE" != "U" ]]; then
    local hf_repo gguf_file dname size_gb ctx \
        min_ram min_vram tier tags desc
    IFS='|' read -r hf_repo gguf_file dname size_gb ctx \
        min_ram min_vram tier tags desc <<< "$MODELS[$CHOICE]"

    SEL_IDX="$CHOICE"
    SEL_HF_REPO="${hf_repo// /}"
    SEL_GGUF="${gguf_file// /}"
    SEL_NAME="${dname# }"
    SEL_NAME="${SEL_NAME% }"
    SEL_MIN_RAM="${min_ram// /}"
    SEL_MIN_VRAM="${min_vram// /}"
    [[ -z "$SEL_GGUF" ]] && die "Model parse failed: SEL_GGUF empty."
    [[ -z "$SEL_MIN_RAM" ]] && die "Model parse failed: SEL_MIN_RAM empty."
    [[ "$SEL_MIN_RAM" =~ ^[0-9]+$ ]] || die "SEL_MIN_RAM='$SEL_MIN_RAM' not numeric."
    [[ "$SEL_MIN_VRAM" =~ ^[0-9]+$ ]] || die "SEL_MIN_VRAM='$SEL_MIN_VRAM' not numeric."
    ok "Selected: ${SEL_NAME}  (${SEL_GGUF})"

    GRADE_SEL=$(grade_model "$SEL_MIN_RAM" "$SEL_MIN_VRAM" "$RAM_GiB" "$VRAM_GiB" "$HAS_NVIDIA")
    if [[ "$GRADE_SEL" == "F" ]]; then
        warn "Grade F — this model will likely OOM on your hardware."
        if [[ -t 0 ]]; then
            read -r "go_anyway?  Continue anyway? [y/N]: "
            if [[ ! "$go_anyway" =~ ^[Yy]$ ]]; then
                print "Aborted."
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

    local size_gb
    IFS='|' read -r _ _ _ size_gb _ _ _ _ _ _ <<< "$MODELS[$CHOICE]"
    REQ_GB="${size_gb// /}"
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
    FILE_SIZE=$(wc -c <"$GGUF_PATH" 2>/dev/null || print 0)
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
#  Helper: Check if a Git repository has updates (using ls-remote, no fetch)
# =============================================================================
git_has_updates() {
    local repo_dir="$1"
    local branch="${2:-main}"
    if [[ ! -d "$repo_dir/.git" ]]; then
        return 0
    fi
    local remote_head local_head
    remote_head=$(git ls-remote --heads "$repo_dir" "refs/heads/${branch}" 2>/dev/null | awk '{print $1}')
    local_head=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || print "")
    [[ -n "$local_head" && -n "$remote_head" && "$local_head" != "$remote_head" ]]
}

# =============================================================================
#  8. Build llama.cpp [SKIPPED by switch-model]
# =============================================================================
find_llama_server() {
    local p vo
    for p in /usr/local/bin/llama-server /usr/bin/llama-server \
        "${HOME}/.local/bin/llama-server" \
        "${HOME}/llama.cpp/build/bin/llama-server"; do
        if [[ -x "$p" ]]; then
            vo=$("$p" --version 2>&1) || continue
            if print "$vo" | grep -qiE 'llama|ggml'; then
                print "$p"
                return 0
            fi
        fi
    done
    local found
    found=( ${HOME}/llama.cpp/**/llama-server(-*N) )[1]
    if [[ -n "$found" ]]; then
        vo=$("$found" --version 2>&1) || true
        if print "$vo" | grep -qiE 'llama|ggml'; then
            print "$found"
            return 0
        fi
    fi
    return 1
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
            if sudo -n true 2>/dev/null; then
                sudo cmake --install build || warn "System install failed — using build directory."
            else
                warn "Sudo requires password; skipping system install. Using build directory."
            fi
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
#  9. Hermes Agent install [SKIPPED by switch-model] – Manual install (no wizard)
# =============================================================================
HERMES_AGENT_DIR="${HOME}/hermes-agent"
HERMES_DIR="${HOME}/.hermes"
export PATH="${HOME}/.local/bin:${PATH}"

if [[ -z "$_SMO" ]]; then
    step "Installing Hermes Agent (manual, wizard‑free)..."

    if git_has_updates "$HERMES_AGENT_DIR" "main"; then
        if [[ ! -d "${HERMES_AGENT_DIR}/.git" ]]; then
            git clone https://github.com/NousResearch/hermes-agent.git "${HERMES_AGENT_DIR}"
        else
            ok "Updates available — pulling Hermes Agent..."
            git -C "$HERMES_AGENT_DIR" fetch origin
            git -C "$HERMES_AGENT_DIR" reset --hard origin/main
        fi
    else
        ok "Hermes Agent already up‑to‑date."
    fi

    if ! command -v uv &>/dev/null; then
        step "Installing uv..."
        uv_installer=$(mktemp /tmp/uv-install.XXXXXX.sh)
        register_tmp "$uv_installer"
        curl -fsSL --connect-timeout 15 --max-time 60 --retry 3 --retry-delay 2 \
            https://astral.sh/uv/install.sh -o "$uv_installer" || die "Failed to download uv installer"
        bash "$uv_installer" || die "uv installation failed"
        [[ -f "${HOME}/.cargo/env" ]] && source "${HOME}/.cargo/env" 2>/dev/null || true
        export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:${PATH}"
    fi

    cd "${HERMES_AGENT_DIR}"

    if [[ ! -d "venv" ]]; then
        uv venv venv --python 3.11
    fi

    source venv/bin/activate
    uv pip install -e ".[all]"

    mkdir -p "${HOME}/.local/bin"
    ln -sf "${HERMES_AGENT_DIR}/venv/bin/hermes" "${HOME}/.local/bin/hermes"
    cd ~

    export PATH="${HOME}/.local/bin:${PATH}"
    command -v hermes &>/dev/null || die "hermes not found after install."
    ok "Hermes Agent installed (wizard skipped)."
fi

# =============================================================================
#  9b. Configure Hermes for local llama-server – clean YAML overwrite
# =============================================================================
step "Configuring Hermes for local llama-server..."

mkdir -p "${HERMES_DIR}"/{cron,sessions,logs,memories,skills}

if [[ -f "${HERMES_DIR}/.env" && ! -L "${HERMES_DIR}/.env" ]]; then
    cp "${HERMES_DIR}/.env" "${HERMES_DIR}/.env.backup.$(date +%Y%m%d%H%M%S)"
    ok "Backed up existing ~/.hermes/.env"
fi
cat >"${HERMES_DIR}/.env" <<'ENV'
OPENAI_API_KEY=sk-no-key-needed
OPENAI_BASE_URL=http://localhost:8080/v1
ENV
ok "~/.hermes/.env written."

CONFIG_FILE="${HERMES_DIR}/config.yaml"

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

ok "Hermes configured → llama-server (${SEL_NAME}, ctx=${SAFE_CTX})"
ok "setup_complete: true written → setup wizard will not fire"
ok "Hermes ready with local backend"

# =============================================================================
#  Optional components selection (multi‑select menu)
# =============================================================================
select_optional_components() {
    [[ ! -t 0 ]] && return 1

    if ! command -v whiptail &>/dev/null; then
        warn "whiptail not found – using simple yes/no prompts (install 'whiptail' for better menu)."
        return 1
    fi

    local choices
    choices=$(whiptail --title "Optional Components" --checklist \
        "Select additional components to install (use SPACE to toggle, ENTER to confirm):" \
        20 80 5 \
        "goose" "Goose AI Agent (Rust CLI, 30k+ stars)" OFF \
        "opencode" "OpenCode (Terminal TUI coding agent)" OFF \
        "autoagent" "AutoAgent (Deep research multi-agent)" OFF \
        "openclaude" "OpenClaude (Claude-compatible CLI)" OFF \
        "webui" "Hermes WebUI (Browser interface for Hermes)" OFF \
        3>&1 1>&2 2>&3)

    if [[ $? -ne 0 ]]; then
        print ""
        ok "No optional components selected."
        return 1
    fi

    local -a selected=( ${(Q)${(z)choices}} )

    INSTALL_GOOSE=false
    INSTALL_OPENCODE=false
    INSTALL_AUTOAGENT=false
    INSTALL_OPENCLAUDE=false
    INSTALL_WEBUI=false

    for item in "${selected[@]}"; do
        case "$item" in
            goose) INSTALL_GOOSE=true ;;
            opencode) INSTALL_OPENCODE=true ;;
            autoagent) INSTALL_AUTOAGENT=true ;;
            openclaude) INSTALL_OPENCLAUDE=true ;;
            webui) INSTALL_WEBUI=true ;;
        esac
    done

    print ""
    local count=0
    $INSTALL_GOOSE && { print "  ✓ Goose"; count=$((count+1)); }
    $INSTALL_OPENCODE && { print "  ✓ OpenCode"; count=$((count+1)); }
    $INSTALL_AUTOAGENT && { print "  ✓ AutoAgent"; count=$((count+1)); }
    $INSTALL_OPENCLAUDE && { print "  ✓ OpenClaude"; count=$((count+1)); }
    $INSTALL_WEBUI && { print "  ✓ Hermes WebUI"; count=$((count+1)); }

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
    if ! select_optional_components; then
        print ""
        print -P "  ${BLD}Optional: Goose AI Agent (block/goose)${RST}"
        read -r "ans?  Install Goose? [y/N]: " && [[ "$ans" =~ ^[Yy]$ ]] && INSTALL_GOOSE=true
        print -P "  ${BLD}Optional: OpenCode (anomalyco/opencode)${RST}"
        read -r "ans?  Install OpenCode? [y/N]: " && [[ "$ans" =~ ^[Yy]$ ]] && INSTALL_OPENCODE=true
        print -P "  ${BLD}Optional: AutoAgent (HKUDS)${RST}"
        read -r "ans?  Install AutoAgent? [y/N]: " && [[ "$ans" =~ ^[Yy]$ ]] && INSTALL_AUTOAGENT=true
        print -P "  ${BLD}Optional: OpenClaude (@gitlawb/openclaude)${RST}"
        read -r "ans?  Install OpenClaude? [y/N]: " && [[ "$ans" =~ ^[Yy]$ ]] && INSTALL_OPENCLAUDE=true
        print -P "  ${BLD}Optional: Hermes WebUI${RST}"
        read -r "ans?  Install Hermes WebUI? [y/N]: " && [[ "$ans" =~ ^[Yy]$ ]] && INSTALL_WEBUI=true
    fi
fi

# =============================================================================
#  13a. Goose
# =============================================================================
if $INSTALL_GOOSE; then
    step "Installing Goose CLI..."
    if command -v goose &>/dev/null; then
        ok "Goose: $(goose --version 2>/dev/null || print 'installed')"
    else
        goose_script=$(mktemp /tmp/goose-install.XXXXXX.sh)
        register_tmp "$goose_script"
        if curl -fsSL --connect-timeout 15 --max-time 120 --retry 3 --retry-delay 2 \
            https://github.com/block/goose/releases/download/stable/download_cli.sh \
            -o "$goose_script" 2>/dev/null; then
            bash "$goose_script" && export PATH="${HOME}/.local/bin:${PATH}" ||
                warn "Goose install script failed."
        else
            warn "Failed to download Goose install script — skipping."
        fi
    fi

    if command -v goose &>/dev/null; then
        step "Configuring Goose for local llama-server..."
        mkdir -p "${HOME}/.config/goose"
        cat >"${HOME}/.config/goose/config.yaml" <<GOOSECONF
models:
  - name: local
    provider: openai
    base_url: http://localhost:8080/v1
    api_key: sk-local
    default: true
GOOSECONF
        ok "Goose configured."
    fi
fi

# =============================================================================
#  13b. OpenCode
# =============================================================================
if $INSTALL_OPENCODE; then
    step "Installing OpenCode..."
    if command -v opencode &>/dev/null; then
        ok "OpenCode: $(opencode --version 2>/dev/null || print 'installed')"
    else
        opencode_installer=$(mktemp /tmp/opencode-install.XXXXXX.sh)
        register_tmp "$opencode_installer"
        if curl -fsSL --connect-timeout 15 --max-time 120 --retry 3 --retry-delay 2 \
            https://opencode.ai/install -o "$opencode_installer" 2>/dev/null; then
            XDG_BIN_DIR="${HOME}/.local/bin" bash "$opencode_installer" 2>/dev/null &&
                export PATH="${HOME}/.local/bin:${PATH}"
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
#  13c. AutoAgent
# =============================================================================
AUTOAGENT_DIR="${HOME}/autoagent"
AUTOAGENT_VENV="${AUTOAGENT_DIR}/.venv"

if $INSTALL_AUTOAGENT; then
    step "Installing AutoAgent..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-tk 2>/dev/null || true

    if ! command -v uv &>/dev/null; then
        step "Installing uv..."
        uv_installer=$(mktemp /tmp/uv-install.XXXXXX.sh)
        register_tmp "$uv_installer"
        curl -fsSL --connect-timeout 15 --max-time 60 --retry 3 --retry-delay 2 \
            https://astral.sh/uv/install.sh -o "$uv_installer" || die "Failed to download uv installer"
        bash "$uv_installer" || die "uv installation failed"
        [[ -f "${HOME}/.cargo/env" ]] && source "${HOME}/.cargo/env" 2>/dev/null || true
        export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:${PATH}"
    fi

    if [[ ! -d "${AUTOAGENT_DIR}/.git" ]]; then
        git clone https://github.com/HKUDS/AutoAgent.git "${AUTOAGENT_DIR}"
    else
        git -C "$AUTOAGENT_DIR" fetch origin
        git -C "$AUTOAGENT_DIR" reset --hard origin/main
    fi

    sed -i '1s/^/try:\n    import tkinter as tk\n    from tkinter import filedialog\n    TKINTER_AVAILABLE = True\nexcept ImportError:\n    TKINTER_AVAILABLE = False\n\n/' "${AUTOAGENT_DIR}/autoagent/cli_utils/file_select.py" 2>/dev/null || true

    if [[ ! -d "$AUTOAGENT_VENV" ]]; then
        uv venv "${AUTOAGENT_VENV}" --python 3.11 --system-site-packages
    fi

    (
        export VIRTUAL_ENV="${AUTOAGENT_VENV}"
        export PATH="${AUTOAGENT_VENV}/bin:${PATH}"
        cd "${AUTOAGENT_DIR}"
        uv pip install -e "." 2>&1 | tail -5
    ) && ok "AutoAgent installed." || die "AutoAgent install failed."

    cat >"${HOME}/start-autoagent.sh" <<AUTOAGENT_LAUNCHER
#!/usr/bin/env bash
AUTOAGENT_VENV="${AUTOAGENT_VENV}"
AUTOAGENT_DIR="${AUTOAGENT_DIR}"
if ! curl -sf http://localhost:8080/v1/models &>/dev/null; then
    print "llama-server not running. Start with: start-llm"
    exit 1
fi
source "\${AUTOAGENT_VENV}/bin/activate"
cd "\${AUTOAGENT_DIR}"
set -a; source "${HOME}/.autoagent/.env" 2>/dev/null || true; set +a
auto deep-research
AUTOAGENT_LAUNCHER
    chmod +x "${HOME}/start-autoagent.sh"
    ok "Created ~/start-autoagent.sh"
fi

# =============================================================================
#  13d. OpenClaude
# =============================================================================
if $INSTALL_OPENCLAUDE; then
    step "Installing OpenClaude..."
    if ! command -v node &>/dev/null || [[ $(node -v | cut -d. -f1 | tr -d 'v') -lt 20 ]]; then
        curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
        sudo apt-get install -y -qq nodejs
    fi
    sudo npm install -g @gitlawb/openclaude@latest

    if command -v openclaude &>/dev/null; then
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
        ok "OpenClaude configured."
    fi
fi

# =============================================================================
#  13e. Hermes WebUI (Python-based)
# =============================================================================
HERMES_WEBUI_DIR="${HOME}/hermes-webui"

if $INSTALL_WEBUI; then
    step "Installing Hermes WebUI..."

    if [[ ! -d "${HERMES_WEBUI_DIR}/.git" ]]; then
        git clone https://github.com/nesquena/hermes-webui.git "${HERMES_WEBUI_DIR}"
    else
        git -C "$HERMES_WEBUI_DIR" pull --quiet
    fi

    HERMES_VENV="${HOME}/hermes-agent/venv"
    if [[ ! -d "$HERMES_VENV" ]]; then
        warn "Hermes agent venv not found – WebUI may not function correctly."
    fi

    if [[ -f "${HERMES_WEBUI_DIR}/requirements.txt" ]]; then
        if [[ -x "${HERMES_VENV}/bin/pip" ]]; then
            "${HERMES_VENV}/bin/pip" install -r "${HERMES_WEBUI_DIR}/requirements.txt" --quiet
        else
            pip3 install --user --break-system-packages -r "${HERMES_WEBUI_DIR}/requirements.txt" --quiet
        fi
    fi

    cat >"${HOME}/start-webui.sh" <<WEBUISTART
#!/usr/bin/env bash
cd "${HERMES_WEBUI_DIR}"
if [[ -x "${HERMES_VENV}/bin/python" ]]; then
    export PATH="${HERMES_VENV}/bin:\${PATH}"
fi
print "Starting Hermes WebUI on http://localhost:8787"
./start.sh
WEBUISTART
    chmod +x "${HOME}/start-webui.sh"

    if systemctl --user daemon-reload 2>/dev/null; then
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
StandardOutput=file:/tmp/hermes-webui.log
StandardError=file:/tmp/hermes-webui.log

[Install]
WantedBy=default.target
WEBUISERVICE
        systemctl --user enable hermes-webui.service 2>/dev/null || true
        ok "WebUI systemd service enabled (starts on login)."
    fi

    ok "Hermes WebUI installed. Start with: ~/start-webui.sh  →  http://localhost:8787"
fi

# =============================================================================
#  11. Create ~/start-llm.sh – SAFE substitution (envsubst or manual escape)
# =============================================================================
step "Generating ~/start-llm.sh..."
LAUNCH_SCRIPT="${HOME}/start-llm.sh"

cat >"${LAUNCH_SCRIPT}.template" <<'LAUNCH_TEMPLATE'
#!/usr/bin/env bash
GGUF="${GGUF_PATH}"
MODEL_NAME="${SEL_NAME}"
LLAMA_BIN="${LLAMA_SERVER_BIN}"
SAFE_CTX="${SAFE_CTX}"
USE_JINJA="${USE_JINJA}"
PIDFILE="/tmp/llama-server.pid"

LLAMA_PID=$(pgrep -f "llama-server.*-m.*${GGUF}" 2>/dev/null || true)
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
for i in {1..30}; do
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

if command -v envsubst &>/dev/null; then
    export GGUF_PATH SEL_NAME LLAMA_SERVER_BIN SAFE_CTX USE_JINJA
    envsubst < "${LAUNCH_SCRIPT}.template" > "$LAUNCH_SCRIPT"
else
    local esc_gguf_path="${GGUF_PATH//\\/\\\\}"
    esc_gguf_path="${esc_gguf_path//\"/\\\"}"
    local esc_sel_name="${SEL_NAME//\\/\\\\}"
    esc_sel_name="${esc_sel_name//\"/\\\"}"
    local esc_llama_bin="${LLAMA_SERVER_BIN//\\/\\\\}"
    esc_llama_bin="${esc_llama_bin//\"/\\\"}"
    local esc_safe_ctx="${SAFE_CTX//\\/\\\\}"
    local esc_use_jinja="${USE_JINJA//\\/\\\\}"
    sed -e "s|\${GGUF_PATH}|${esc_gguf_path}|g" \
        -e "s|\${SEL_NAME}|${esc_sel_name}|g" \
        -e "s|\${LLAMA_SERVER_BIN}|${esc_llama_bin}|g" \
        -e "s|\${SAFE_CTX}|${esc_safe_ctx}|g" \
        -e "s|\${USE_JINJA}|${esc_use_jinja}|g" \
        "${LAUNCH_SCRIPT}.template" > "$LAUNCH_SCRIPT"
fi
rm -f "${LAUNCH_SCRIPT}.template"
chmod +x "$LAUNCH_SCRIPT"
ok "Launch script: ~/start-llm.sh"

# =============================================================================
#  12. systemd user service [SKIPPED by switch-model]
# =============================================================================
if [[ -z "$_SMO" ]]; then
    step "Creating systemd user service for llama-server..."
    mkdir -p "${HOME}/.config/systemd/user"
    cat >"${HOME}/.local/bin/llama-server-wrapper" <<'WRAPPER'
#!/usr/bin/env bash
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
StandardOutput=file:/tmp/llama-server.log
StandardError=file:/tmp/llama-server.log

[Install]
WantedBy=default.target
SERVICE

    if systemctl --user daemon-reload 2>/dev/null; then
        systemctl --user enable llama-server.service 2>/dev/null || true
        ok "llama-server systemd service enabled."
        print "  Persistent auto-start: sudo loginctl enable-linger $USER"
    else
        warn "systemd --user unavailable — use 'start-llm' to start manually."
    fi
fi

# ── Start llama-server ────────────────────────────────────────────────────────
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

bash "$LAUNCH_SCRIPT" >/tmp/llama-server.log 2>&1 &
sleep 2
if [[ -f "$PIDFILE" ]]; then
    SERVER_PID=$(cat "$PIDFILE")
    if kill -0 "$SERVER_PID" 2>/dev/null; then
        ok "llama-server started (PID: $SERVER_PID, log: tail -f /tmp/llama-server.log)"
    else
        warn "llama-server PID file exists but process is not running. Check log."
    fi
else
    warn "Could not detect llama-server PID. Check log: tail -f /tmp/llama-server.log"
fi

READY=false
for i in {1..30}; do
    if curl -sf http://localhost:8080/v1/models &>/dev/null; then
        ok "llama-server ready at http://localhost:8080"
        READY=true
        break
    fi
    sleep 1
done
[[ "$READY" == "false" ]] && warn "llama-server not responding after 30s — check: tail -f /tmp/llama-server.log"

# =============================================================================
#  12b. Hermes skills (if installed)
# =============================================================================
if [[ -z "$_SMO" ]] && command -v hermes &>/dev/null; then
    step "Installing recommended Hermes skills..."
    SKILLS=("github-pr-workflow" "axolotl" "huggingface-hub")
    for skill in "${SKILLS[@]}"; do
        if command -v timeout &>/dev/null; then
            timeout 30s hermes skills install "official/${skill}" --yes --force 2>/dev/null && ok "Installed skill: ${skill}" || warn "Skill '${skill}' skipped"
        else
            hermes skills install "official/${skill}" --yes --force 2>/dev/null && ok "Installed skill: ${skill}" || warn "Skill '${skill}' skipped"
        fi
    done
    ok "Skills: ~/.hermes/skills/"
fi

# =============================================================================
#  14. ~/.zshrc helpers [SKIPPED by switch-model]
# =============================================================================
if [[ -z "$_SMO" ]]; then
    step "Adding helpers to ~/.zshrc..."
    SCRIPT_SELF="$(readlink -f "${(%):-%N}" 2>/dev/null || realpath "$0" 2>/dev/null || print "")"
    INSTALL_COPY="${HOME}/.local/bin/install-llm.sh"
    if [[ "$SCRIPT_SELF" == "/dev/stdin" || -z "$SCRIPT_SELF" || "$SCRIPT_SELF" == "/proc/"* ]]; then
        warn "Script run via pipe — copying to ${INSTALL_COPY} for switch-model."
        mkdir -p "${HOME}/.local/bin"
        cat >"$INSTALL_COPY" <<'STUB'
#!/usr/bin/env bash
print "Re-running install from GitHub..."
curl -fsSL https://raw.githubusercontent.com/mettbrot0815/llm-installer/refs/heads/main/install.zsh | zsh
STUB
        chmod +x "$INSTALL_COPY"
        SCRIPT_SELF="$INSTALL_COPY"
        warn "switch-model will re-download the installer."
    elif [[ -f "$SCRIPT_SELF" ]]; then
        mkdir -p "${HOME}/.local/bin"
        cp -f "$SCRIPT_SELF" "$INSTALL_COPY" 2>/dev/null && chmod +x "$INSTALL_COPY" && SCRIPT_SELF="$INSTALL_COPY" || true
    fi

    MARKER="# === LLM setup (added by install.zsh) ==="
    if ! grep -qF "$MARKER" "${HOME}/.zshrc" 2>/dev/null; then
        cat >>"${HOME}/.zshrc" <<ZSHRC_EXPANDED

${MARKER}
[[ -n "\${__LLM_ZSHRC_LOADED:-}" ]] && return 0
export __LLM_ZSHRC_LOADED=1

path=( \${path:#/mnt/*} )

export RED='%F{red}' GRN='%F{green}' YLW='%F{yellow}'
export CYN='%F{cyan}' BLD='%B' RST='%f%b'
export PATH="/usr/local/cuda/bin:\${HOME}/.local/bin:\${PATH}"
export LD_LIBRARY_PATH="/usr/local/cuda/lib64:\${LD_LIBRARY_PATH:-}"

alias start-llm='bash ~/start-llm.sh'
alias stop-llm='pkill -f "llama-server.*-m" 2>/dev/null || true; print "llama-server stopped."'
alias restart-llm='stop-llm; sleep 2; start-llm'
alias llm-log='tail -f /tmp/llama-server.log'
alias switch-model='SWITCH_MODEL_ONLY=1 zsh ${INSTALL_COPY}'
ZSHRC_EXPANDED

        [[ -n "${HF_TOKEN:-}" ]] && ! grep -qF "export HF_TOKEN=" "${HOME}/.zshrc" && print "export HF_TOKEN=\"${HF_TOKEN}\"" >>"${HOME}/.zshrc"
        [[ -n "${GITHUB_TOKEN:-}" ]] && ! grep -qF "export GITHUB_TOKEN=" "${HOME}/.zshrc" && print "export GITHUB_TOKEN=\"${GITHUB_TOKEN}\"" >>"${HOME}/.zshrc"

        cat >>"${HOME}/.zshrc" <<'ZSH_FUNCTIONS'

vram() {
    nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits 2>/dev/null | \
        awk -F, '{printf "GPU: %s\nVRAM: %s / %s MiB\nUtil: %s%%\n",$1,$2,$3,$4}' || print "nvidia-smi not available"
}

llm-models() {
    local active_model=""
    [[ -f ~/start-llm.sh ]] && active_model=$(grep '^GGUF=' ~/start-llm.sh 2>/dev/null | head -1 | sed 's/GGUF="//;s/".*//' | xargs basename 2>/dev/null || true)
    print -P "${BLD}${CYN}╭────────────────────────────────────────────────────────────────╮${RST}"
    print -P "${BLD}${CYN}│${RST}  ${BLD}Models in ~/llm-models${RST}"
    print "  ────────────────────────────────────────────────────────"
    local found=0 f sz name tag
    for f in ~/llm-models/*.gguf; do
        [[ -f "$f" ]] || continue
        found=$(( found + 1 ))
        sz=$(du -h "$f" | cut -f1); name=$(basename "$f"); tag=""
        [[ "$name" == "$active_model" ]] && tag=" ${GRN}← active${RST}"
        print "  ${sz}  ${name}${tag}"
    done
    [[ $found -eq 0 ]] && print "  (no .gguf files found)"
    print ""
}

llm-status() {
    local llama_pid active_model=""
    llama_pid=$(pgrep -f "llama-server.*-m" 2>/dev/null || true)
    [[ -f ~/start-llm.sh ]] && active_model=$(grep '^MODEL_NAME=' ~/start-llm.sh 2>/dev/null | head -1 | sed 's/MODEL_NAME="//;s/".*//' || true)
    print -P "${BLD}${CYN}╭────────────────────────────────────────────────────────────────╮${RST}"
    print -P "${BLD}${CYN}│${RST}  ${BLD}LLM Stack Status${RST}"
    print -P "${BLD}${CYN}│${RST}  ──────────────────────────────────────────────────────"
    [[ -n "$active_model" ]] && print -P "${BLD}${CYN}│${RST}  Model : ${CYN}${active_model}${RST}"
    if [[ -n "$llama_pid" ]]; then
        print -P "${GRN}  ✓ llama-server → http://localhost:8080  (PID: $llama_pid)${RST}"
    else
        print -P "${RED}  ✗ llama-server → not running${RST}"
    fi
    print -P "${BLD}${CYN}│${RST}  ──────────────────────────────────────────────────────"
    print -P "${BLD}${CYN}│${RST}  ${CYN}start-llm${RST} · ${CYN}stop-llm${RST} · ${CYN}switch-model${RST} · ${CYN}llm-models${RST}"
    print -P "${BLD}${CYN}╰────────────────────────────────────────────────────────────────╯${RST}"
}

show_llm_summary() {
    print -P "${BLD}${CYN}╭────────────────────────────────────────────────────────────────╮${RST}"
    print -P "${BLD}${CYN}│${RST}  ${BLD}LLM Quick Commands${RST}"
    print -P "${BLD}${CYN}│${RST}  ──────────────────────────────────────────────────────"
    print -P "${BLD}${CYN}│${RST}  ${CYN}hermes${RST}        Chat with Hermes Agent"
    print -P "${BLD}${CYN}│${RST}  ${CYN}goose${RST}         Goose (if installed)"
    print -P "${BLD}${CYN}│${RST}  ${CYN}opencode${RST}      OpenCode coding agent (if installed)"
    print -P "${BLD}${CYN}│${RST}  ${CYN}autoagent${RST}     AutoAgent deep research (if installed)"
    print -P "${BLD}${CYN}│${RST}  ${CYN}openclaude${RST}    OpenClaude CLI (if installed)"
    print -P "${BLD}${CYN}│${RST}  ${CYN}start-llm${RST}     Start llama-server"
    print -P "${BLD}${CYN}│${RST}  ${CYN}stop-llm${RST}      Stop llama-server"
    print -P "${BLD}${CYN}│${RST}  ${CYN}restart-llm${RST}   Restart llama-server"
    print -P "${BLD}${CYN}│${RST}  ${CYN}switch-model${RST}  Pick different model"
    print -P "${BLD}${CYN}│${RST}  ${CYN}llm-status${RST}    Status + active model"
    print -P "${BLD}${CYN}│${RST}  ${CYN}llm-log${RST}       Tail llama-server log"
    print -P "${BLD}${CYN}│${RST}  ${CYN}llm-models${RST}    List all .gguf files"
    print -P "${BLD}${CYN}│${RST}  ${CYN}vram${RST}          GPU/VRAM usage"
    print -P "${BLD}${CYN}│${RST}  ──────────────────────────────────────────────────────"
    print -P "${BLD}${CYN}│${RST}  ${CYN}http://localhost:8080${RST}  → llama-server + Web UI"
    print -P "${BLD}${CYN}╰────────────────────────────────────────────────────────────────╯${RST}"
    print ""
}

if [[ -o interactive ]]; then
    show_llm_summary
fi

_llm_autostart() {
    [[ ! -o interactive ]] && return 0
    pgrep -f "llama-server.*-m" &>/dev/null && return 0
    [[ -f ~/start-llm.sh ]] || return 0

    local lockfile="/tmp/llama_server_autostart.lock"
    local lock_fd
    exec {lock_fd}> "$lockfile"
    if flock -n "$lock_fd"; then
        print -P "${YLW}[LLM] llama-server not running — auto-starting...${RST}"
        nohup bash ~/start-llm.sh < /dev/null >> /tmp/llama-server.log 2>&1 &
        disown
        flock -u "$lock_fd"
    fi
    exec {lock_fd}>&-
}
_llm_autostart

alias clear='show_llm_summary; command clear'
ZSH_FUNCTIONS
        ok "Helpers written to ~/.zshrc."
    else
        ok "Helpers already in ~/.zshrc — skipping."
    fi
fi

# =============================================================================
#  15. .wslconfig RAM hint [SKIPPED by switch-model]
# =============================================================================
if [[ -z "$_SMO" ]]; then
    WIN_USER=$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r\n' || print "")
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
; Generated by install.zsh
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
#  16. Claude Configuration
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
print ""
print -P "${GRN}${BLD}"
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
print -P "${RST}"

print -P " ${BLD}Active model:${RST}  ${SEL_NAME}"
print -P "               ${SEL_GGUF}"
print -P " ${BLD}Context:${RST}       ${SAFE_CTX} tokens   ${BLD}Jinja:${RST} ${USE_JINJA}"
print ""

if [[ -z "$_SMO" ]]; then
    print -P " ${BLD}Installed:${RST}"
    print -P "  llama-server  →  http://localhost:8080/v1"
    print -P "  Hermes Agent  →  hermes"
    $INSTALL_GOOSE && print -P "  Goose         →  goose"
    $INSTALL_OPENCODE && print -P "  OpenCode      →  opencode  (alias: oc)"
    $INSTALL_AUTOAGENT && print -P "  AutoAgent     →  autoagent"
    $INSTALL_OPENCLAUDE && print -P "  OpenClaude    →  openclaude"
    $INSTALL_WEBUI && print -P "  Hermes WebUI  →  start-webui  (http://localhost:8787)"
    print ""
fi

print -P " ${BLD}════ Quick Reference ════${RST}"
print ""

print -P " ${BLD}Server:${RST}"
print -P "  ${CYN}start-llm${RST}       Start llama-server"
print -P "  ${CYN}stop-llm${RST}        Stop llama-server"
print -P "  ${CYN}restart-llm${RST}     Restart llama-server"
print -P "  ${CYN}switch-model${RST}    Pick different model"
print -P "  ${CYN}llm-status${RST}      Status + active model"
print -P "  ${CYN}llm-log${RST}         Tail llama-server log"
print -P "  ${CYN}llm-models${RST}      List all .gguf files"
print -P "  ${CYN}vram${RST}            GPU/VRAM usage"
print ""

print -P " ${BLD}Agents:${RST}"
print -P "  ${CYN}hermes${RST}          Hermes Agent"
$INSTALL_GOOSE && print -P "  ${CYN}goose${RST}           Goose"
$INSTALL_OPENCODE && print -P "  ${CYN}opencode${RST} / ${CYN}oc${RST}  OpenCode"
$INSTALL_AUTOAGENT && print -P "  ${CYN}autoagent${RST}       AutoAgent"
$INSTALL_OPENCLAUDE && print -P "  ${CYN}openclaude${RST}      OpenClaude"
$INSTALL_WEBUI && print -P "  ${CYN}start-webui${RST}     Hermes WebUI"
print ""

print -P " ${YLW}Note:${RST}       source ~/.zshrc or open a new terminal."
print -P " ${YLW}Auto-start:${RST} llama-server starts automatically on new terminal."
print -P " ${GRN}Persistent:${RST} sudo loginctl enable-linger $USER"
print ""

exit 0
