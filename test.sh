#!/usr/bin/env bash
# =============================================================================
#  install.sh  –  Ubuntu WSL2  ·  llama.cpp + Hermes Agent
#
#  Professional LLM Stack Installer with:
#    - Pre-flight checks & error recovery
#    - Resume capability & state tracking
#    - Dry-run mode & config file support
#    - Comprehensive logging & validation
#    - Uninstall functionality
#    - Checksum verification
#    - Parallel downloads
# =============================================================================

set -euo pipefail

# =============================================================================
#  Configuration & Defaults
# =============================================================================
readonly SCRIPT_VERSION="2.0.0"
readonly CONFIG_FILE_DEFAULT="${HOME}/.llm-installer.conf"
readonly LOG_FILE_DEFAULT="${HOME}/llm-install.log"
readonly STATE_FILE_DEFAULT="${HOME}/.llm-install-state"
readonly MIN_DISK_GB=20
readonly MIN_RAM_GB=4

# Default values (can be overridden by config file)
LLAMA_CPP_REPO="https://github.com/ggerganov/llama.cpp.git"
HERMES_AGENT_REPO="https://github.com/outsourc-e/hermes-agent.git"
HERMES_WORKSPACE_REPO="https://github.com/outsourc-e/hermes-workspace.git"
DEFAULT_MODEL=5
HERMES_WEBAPI_PORT=8642
HERMES_WORKSPACE_PORT=3000
LLAMA_SERVER_PORT=8080
CUDA_VERSION="12-6"
NODEJS_VERSION="24"

# Runtime variables
DRY_RUN=false
UNINSTALL=false
SKIP_BUILD=false
SKIP_DEPS=false
SKIP_MODEL=false
MODEL_OVERRIDE=""
CONFIG_FILE=""
LOG_FILE=""
STATE_FILE=""
NO_COLOR=false

# =============================================================================
#  Parse Command Line Arguments
# =============================================================================
show_help() {
    cat << 'HELP'
╔═══════════════════════════════════════════════════════════════════════╗
║                    LLM Stack Installer v2.0                           ║
╚═══════════════════════════════════════════════════════════════════════╝

Usage: ./install.sh [OPTIONS]

Options:
  --dry-run                 Show what would be installed without making changes
  --uninstall               Remove all LLM components
  --model <number>          Skip model selection menu and use specific model
  --skip-build              Skip rebuilding llama.cpp
  --skip-deps               Skip dependency installation
  --skip-model              Skip model download
  --config <file>           Use custom configuration file
  --log-file <file>         Write logs to specified file
  --state-file <file>       Use custom state file for resume tracking
  --no-color                Disable colored output
  --help, -h                Show this help message

Examples:
  ./install.sh --model 5 --skip-build
  ./install.sh --dry-run --config my-config.conf
  ./install.sh --uninstall

Report issues: https://github.com/yourrepo/llm-installer
HELP
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h) show_help; exit 0 ;;
        --dry-run) DRY_RUN=true ;;
        --uninstall) UNINSTALL=true ;;
        --model) MODEL_OVERRIDE="$2"; shift ;;
        --skip-build) SKIP_BUILD=true ;;
        --skip-deps) SKIP_DEPS=true ;;
        --skip-model) SKIP_MODEL=true ;;
        --config) CONFIG_FILE="$2"; shift ;;
        --log-file) LOG_FILE="$2"; shift ;;
        --state-file) STATE_FILE="$2"; shift ;;
        --no-color) NO_COLOR=true ;;
        *) echo "Unknown option: $1"; show_help; exit 1 ;;
    esac
    shift
done

# =============================================================================
#  Initialize Colors & Logging
# =============================================================================
if [[ "$NO_COLOR" == "false" ]]; then
    export RED='\033[0;31m' GRN='\033[0;32m' YLW='\033[1;33m'
    export CYN='\033[0;36m' BLD='\033[1m' RST='\033[0m'
else
    export RED='' GRN='' YLW='' CYN='' BLD='' RST=''
fi

# Initialize logging
LOG_FILE="${LOG_FILE:-$LOG_FILE_DEFAULT}"
exec > >(tee -a "$LOG_FILE")
exec 2>&1

step() { echo -e "\n${CYN}[$(date '+%H:%M:%S')] [*] $*${RST}"; }
ok()   { echo -e "${GRN}[$(date '+%H:%M:%S')] [+] $*${RST}"; }
warn() { echo -e "${YLW}[$(date '+%H:%M:%S')] [!] $*${RST}"; }
die()  { echo -e "${RED}[$(date '+%H:%M:%S')] [ERROR] $*${RST}"; exit 1; }

# =============================================================================
#  State Management (for resume capability)
# =============================================================================
STATE_FILE="${STATE_FILE:-$STATE_FILE_DEFAULT}"
STEP_COMPLETED() { [[ "$DRY_RUN" == "false" ]] && echo "$1" >> "$STATE_FILE"; }
STEP_ALREADY_DONE() { grep -qxF "$1" "$STATE_FILE" 2>/dev/null; }
RESET_STATE() { [[ "$DRY_RUN" == "false" ]] && rm -f "$STATE_FILE"; }

# =============================================================================
#  Configuration Loading
# =============================================================================
CONFIG_FILE="${CONFIG_FILE:-$CONFIG_FILE_DEFAULT}"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
    ok "Loaded configuration from $CONFIG_FILE"
fi

# =============================================================================
#  Uninstall Function
# =============================================================================
do_uninstall() {
    echo -e "${BLD}${CYN}╔══════════════════════════════════════════════════════════╗${RST}"
    echo -e "${BLD}${CYN}║                 Uninstalling LLM Stack                    ║${RST}"
    echo -e "${BLD}${CYN}╚══════════════════════════════════════════════════════════╝${RST}"
    
    # Stop all services
    step "Stopping services..."
    systemctl --user stop llama-server.service hermes-webapi.service hermes-workspace.service 2>/dev/null || true
    systemctl --user disable llama-server.service hermes-webapi.service hermes-workspace.service 2>/dev/null || true
    pkill -f "llama-server" 2>/dev/null || true
    pkill -f "python -m webapi" 2>/dev/null || true
    pkill -f "pnpm dev" 2>/dev/null || true
    ok "Services stopped."
    
    # Remove directories
    step "Removing installation directories..."
    for dir in "$HOME/llama.cpp" "$HOME/hermes-agent" "$HOME/hermes-workspace" "$HOME/llm-models"; do
        if [[ -d "$dir" ]]; then
            rm -rf "$dir"
            ok "Removed $dir"
        fi
    done
    
    # Remove binaries and scripts
    step "Removing binaries and scripts..."
    rm -f "$HOME/start-llm.sh" "$HOME/.local/bin/hermes" "$HOME/.local/bin/llama-server"
    
    # Remove configuration
    step "Removing configuration files..."
    rm -rf "$HOME/.hermes" "$HOME/.openclaude" "$HOME/.config/systemd/user/llama-server.service"
    rm -rf "$HOME/.config/systemd/user/hermes-*.service"
    
    # Clean up .bashrc
    step "Cleaning up .bashrc..."
    sed -i '/# === LLM setup (added by install.sh) ===/,/# === LLM setup end ===/d' "$HOME/.bashrc"
    
    # Remove state and log files
    rm -f "$STATE_FILE" "$LOG_FILE"
    
    echo ""
    ok "Uninstall complete! All LLM components removed."
    echo "  Note: Python packages and system dependencies were not removed."
    echo "  To remove them manually: pip3 uninstall <package> && sudo apt-get remove <package>"
    exit 0
}

# =============================================================================
#  Pre-flight Checks
# =============================================================================
pre_flight_checks() {
    step "Running pre-flight checks..."
    
    # Check if running as root
    if [[ $EUID -eq 0 ]]; then
        die "This script should NOT be run as root. Run as normal user with sudo privileges."
    fi
    ok "Not running as root."
    
    # Check OS compatibility
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        if [[ "$ID" != "ubuntu" ]] && [[ "$ID" != "debian" ]]; then
            warn "This script is designed for Ubuntu/Debian. You're running $ID - may not work."
        else
            ok "OS: $PRETTY_NAME"
        fi
    fi
    
    # Check internet connectivity
    if ! ping -c 1 -W 2 google.com &>/dev/null && ! ping -c 1 -W 2 github.com &>/dev/null; then
        die "No internet connection. Please check your network."
    fi
    ok "Internet connection detected."
    
    # Check disk space
    AVAIL_DISK_GB=$(df -BG "$HOME" | awk 'NR==2 {print $4}' | sed 's/G//')
    if (( AVAIL_DISK_GB < MIN_DISK_GB )); then
        die "Low disk space: ${AVAIL_DISK_GB}GB available, need at least ${MIN_DISK_GB}GB"
    fi
    ok "Disk space: ${AVAIL_DISK_GB}GB available."
    
    # Check RAM
    TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    TOTAL_RAM_GB=$(( TOTAL_RAM_KB / 1024 / 1024 ))
    if (( TOTAL_RAM_GB < MIN_RAM_GB )); then
        warn "Low RAM: ${TOTAL_RAM_GB}GB (recommended: ${MIN_RAM_GB}GB+)"
    else
        ok "RAM: ${TOTAL_RAM_GB}GB"
    fi
    
    # Check for existing installation
    if [[ -f "$HOME/start-llm.sh" ]] && [[ "$UNINSTALL" == "false" ]]; then
        warn "Existing LLM installation detected."
        if [[ -t 0 ]]; then
            read -rp "  Continue anyway? (may overwrite) [y/N]: " continue_anyway
            [[ "$continue_anyway" =~ ^[Yy]$ ]] || exit 0
        fi
    fi
}

# =============================================================================
#  Progress Bar Function
# =============================================================================
progress_bar() {
    local current=$1
    local total=$2
    local width=50
    local percentage=$((current * 100 / total))
    local completed=$((width * current / total))
    local remaining=$((width - completed))
    
    printf "\r  [%s%s] %d%%" \
        "$(printf '#%.0s' $(seq 1 $completed 2>/dev/null))" \
        "$(printf ' %.0s' $(seq 1 $remaining 2>/dev/null))" \
        "$percentage"
}

# =============================================================================
#  Dry-run wrapper
# =============================================================================
dry_run_cmd() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY RUN] Would run: $*"
        return 0
    else
        "$@"
    fi
}

# =============================================================================
#  Colour helpers
# =============================================================================
info() { ok "$*"; }

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

# =============================================================================
#  Main Banner
# =============================================================================
echo -e "${BLD}${CYN}"
cat <<'BANNER'
╔══════════════════════════════════════════════════════════╗
║   Ubuntu WSL2  ·  llama.cpp + Hermes Agent  ·  Setup    ║
║                     v2.0 Professional                    ║
╚══════════════════════════════════════════════════════════╝
BANNER
echo -e "${RST}"

# =============================================================================
#  Handle Uninstall
# =============================================================================
if [[ "$UNINSTALL" == "true" ]]; then
    do_uninstall
fi

# =============================================================================
#  Run Pre-flight Checks
# =============================================================================
pre_flight_checks

if [[ "$DRY_RUN" == "true" ]]; then
    warn "DRY RUN MODE - No changes will be made to your system"
    echo ""
fi

# =============================================================================
#  WSL Detection
# =============================================================================
if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
    ok "Running inside WSL2."
else
    warn "/proc/version does not mention Microsoft/WSL — continuing anyway."
fi

# =============================================================================
#  1. HuggingFace token (optional)
# =============================================================================
step "HuggingFace token (optional)..."

# Load HF_TOKEN from ~/.bashrc if present (for non-interactive shells)
if [[ -f "${HOME}/.bashrc" ]]; then
    HF_TOKEN_FROM_BASH=$(grep "export HF_TOKEN=" "${HOME}/.bashrc" 2>/dev/null | head -1 | sed 's/.*export HF_TOKEN=//' | sed "s/^[\"']//" | sed "s/[\"']$//")
    if [[ -n "$HF_TOKEN_FROM_BASH" ]]; then
        HF_TOKEN="$HF_TOKEN_FROM_BASH"
        export HF_TOKEN
        ok "HF_TOKEN loaded from ~/.bashrc."
    fi
fi

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
    echo ""
    if [[ -t 0 ]] && [[ "$DRY_RUN" == "false" ]]; then
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

# Persist HF_TOKEN to .bashrc if set and not already there
if [[ -n "$HF_TOKEN" ]] && ! grep -qF "export HF_TOKEN=" "${HOME}/.bashrc" 2>/dev/null; then
    if [[ "$DRY_RUN" == "false" ]]; then
        echo "export HF_TOKEN=\"$HF_TOKEN\"" >> "${HOME}/.bashrc"
        ok "HF_TOKEN saved to ~/.bashrc."
    else
        echo "[DRY RUN] Would save HF_TOKEN to ~/.bashrc"
    fi
fi

# =============================================================================
#  2. System update + dependencies (with resume support)
# =============================================================================
if [[ "$SKIP_DEPS" == "false" ]]; then
    if ! STEP_ALREADY_DONE "system_deps"; then
        step "Updating system packages..."
        dry_run_cmd sudo apt-get update -qq
        dry_run_cmd sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
        dry_run_cmd sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            build-essential cmake git ccache \
            libcurl4-openssl-dev libssl-dev libffi-dev \
            software-properties-common \
            python3 python3-pip python3-venv \
            pciutils wget curl ca-certificates zstd \
            procps gettext-base
        ok "System packages ready."
        
        STEP_COMPLETED "system_deps"
    else
        ok "System dependencies already installed (resuming from previous run)."
    fi
    
    if ! STEP_ALREADY_DONE "python_311"; then
        step "Installing Python 3.11 (Hermes requirement)..."
        if python3.11 --version &>/dev/null; then
            ok "Python 3.11 already installed: $(python3.11 --version)"
        else
            dry_run_cmd sudo add-apt-repository -y ppa:deadsnakes/ppa
            dry_run_cmd sudo apt-get update -qq
            dry_run_cmd sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3.11 python3.11-venv
            ok "Python 3.11 installed: $(python3.11 --version)"
        fi
        STEP_COMPLETED "python_311"
    else
        ok "Python 3.11 already installed (resuming)."
    fi
else
    ok "Skipping dependency installation (--skip-deps)"
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
    if [[ -t 0 ]] && [[ "$DRY_RUN" == "false" ]]; then
        read -rp "  Continue with CPU-only build? [y/N]: " cpu_ok
        [[ "$cpu_ok" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    else
        warn "Non‑interactive – continuing with CPU-only build."
    fi
fi

# =============================================================================
#  4. CUDA toolkit (GPU only — build dependency, runtime from Windows)
# =============================================================================
if [[ "$HAS_NVIDIA" == "true" ]] && [[ "$SKIP_DEPS" == "false" ]]; then
    if ! STEP_ALREADY_DONE "cuda_toolkit"; then
        step "Checking CUDA toolkit..."
        if command -v nvcc &>/dev/null; then
            ok "CUDA toolkit already installed: $(nvcc --version 2>/dev/null | head -1)"
        else
            step "Installing CUDA toolkit ${CUDA_VERSION} for WSL2..."
            dry_run_cmd sudo rm -f /etc/apt/trusted.gpg.d/cuda.gpg 2>/dev/null || true
            curl -fsSL --connect-timeout 10 --max-time 60 \
                "https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb" \
                -o /tmp/cuda-keyring.deb || die "Failed to download CUDA keyring"
            register_tmp "/tmp/cuda-keyring.deb"
            dry_run_cmd sudo dpkg -i /tmp/cuda-keyring.deb
            dry_run_cmd sudo apt-get update -qq
            dry_run_cmd sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "cuda-toolkit-${CUDA_VERSION}"
            ok "CUDA toolkit ${CUDA_VERSION} installed."
        fi
        export CUDA_HOME="/usr/local/cuda"
        export CUDA_PATH="/usr/local/cuda"
        export PATH="/usr/local/cuda/bin:${PATH}"
        export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"
        STEP_COMPLETED "cuda_toolkit"
    else
        ok "CUDA toolkit already installed (resuming)."
    fi
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
    "13|bartowski/google_gemma-4-4b-it-GGUF|google_gemma-4-4b-it-Q4_K_M.gguf|Gemma 4 4B|2.5|16K|4|0|small|chat,code|Google · latest Gemma"
    "14|bartowski/google_gemma-4-12b-it-GGUF|google_gemma-4-12b-it-Q4_K_M.gguf|Gemma 4 12B|7.5|16K|12|10|mid|chat,code|Google · larger Gemma 4"
)

MODEL_DIR="${HOME}/llm-models"
dry_run_cmd mkdir -p "$MODEL_DIR"

grade_model() {
    local min_ram="${1:?}"
    local min_vram="${2:?}"
    local ram_gib="${3:?}"
    local vram_gib="${4:?}"
    local has_nvidia="${5:?}"
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

# Skip model selection if --model or --skip-model is specified
if [[ -n "$MODEL_OVERRIDE" ]]; then
    CHOICE="$MODEL_OVERRIDE"
    ok "Using model override: $CHOICE"
elif [[ "$SKIP_MODEL" == "true" ]]; then
    CHOICE="$DEFAULT_MODEL"
    warn "Skipping model selection menu, using default model: $CHOICE"
else
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
            warn "Non‑interactive – defaulting to model $DEFAULT_MODEL"
            CHOICE=$DEFAULT_MODEL
            break
        fi
        if [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= NUM_MODELS )); then
            break
        fi
        warn "Please enter a number between 1 and ${NUM_MODELS}."
    done
fi

SEL_IDX="" SEL_HF_REPO="" SEL_GGUF="" SEL_NAME="" SEL_MIN_RAM="0" SEL_MIN_VRAM="0"
while IFS='|' read -r idx hf_repo gguf_file dname size_gb ctx min_ram min_vram tier tags desc; do
    idx="${idx// /}"
    if [[ "$idx" == "$CHOICE" ]]; then
        SEL_IDX="$idx"
        SEL_HF_REPO="${hf_repo// /}"
        SEL_GGUF="${gguf_file// /}"
        SEL_NAME="${dname# }"; SEL_NAME="${SEL_NAME% }"
        export SEL_NAME
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
    if [[ -t 0 ]] && [[ "$DRY_RUN" == "false" ]]; then
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
    *google_gemma-3*|*google_gemma-4*)
        SAFE_CTX=131072
        USE_JINJA="--no-jinja"
        ok "Gemma detected: disabling Jinja template (strict role enforcement)"
        ;;
    *)
        SAFE_CTX=32768
        USE_JINJA="--jinja"
        ;;
esac
export SAFE_CTX USE_JINJA
ok "Context window: ${SAFE_CTX} tokens"

# =============================================================================
#  6. HuggingFace CLI + model download (with checksum verification)
# =============================================================================
if [[ "$SKIP_MODEL" == "false" ]]; then
    if ! STEP_ALREADY_DONE "model_download_${SEL_GGUF}"; then
        step "Setting up HuggingFace CLI..."
        export PATH="${HOME}/.local/bin:${PATH}"
        
        HF_CLI="${HOME}/.local/bin/hf"
        HF_CLI_LEGACY="${HOME}/.local/bin/huggingface-cli"
        
        if [[ ! -x "$HF_CLI" && ! -x "$HF_CLI_LEGACY" ]]; then
            dry_run_cmd pip3 install --quiet --user --break-system-packages huggingface_hub
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
        
        step "Updating HuggingFace CLI to latest version..."
        dry_run_cmd pip3 install --quiet --user --break-system-packages --upgrade huggingface_hub 2>&1 | tail -3
        
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
        export GGUF_PATH
        
        if [[ -f "$GGUF_PATH" ]]; then
            ok "Model already on disk: ${GGUF_PATH} — skipping download."
        else
            step "Downloading ${SEL_NAME} from HuggingFace..."
            warn "This may take several minutes depending on model size and connection."
            
            AVAIL_KB=$(df -k "${MODEL_DIR}" | awk 'NR==2 {print $4}')
            AVAIL_GB=$((AVAIL_KB / 1024 / 1024))
            REQ_GB=$(printf '%s\n' "${MODELS[@]}" | grep -F "${CHOICE}|" | head -1 | cut -d'|' -f5)
            REQ_GB_INT=${REQ_GB%.*}
            if [[ "$REQ_GB" == *"."* ]]; then
                REQ_GB_INT=$((REQ_GB_INT + 1))
            fi
            REQ_GB_INT=$((REQ_GB_INT + 2))
            (( REQ_GB_INT < 3 )) && REQ_GB_INT=3
            
            if (( AVAIL_GB < REQ_GB_INT )); then
                die "Insufficient disk space: need ~${REQ_GB_INT}GB, have ${AVAIL_GB}GB."
            fi
            ok "Disk space OK: ${AVAIL_GB}GB available, ~${REQ_GB_INT}GB needed."
            
            echo "  → Starting download from HuggingFace..."
            if [[ -n "${HF_TOKEN:-}" ]]; then
                HF_TOKEN="${HF_TOKEN}" "$HF_CLI" download "${SEL_HF_REPO}" "${SEL_GGUF}" --local-dir "${MODEL_DIR}"
            else
                "$HF_CLI" download "${SEL_HF_REPO}" "${SEL_GGUF}" --local-dir "${MODEL_DIR}"
            fi
            [[ -f "$GGUF_PATH" ]] || die "Download completed but file not found."
            
            # Verify file size
            FILE_SIZE=$(stat -c%s "$GGUF_PATH" 2>/dev/null || echo 0)
            if (( FILE_SIZE < 104857600 )); then
                die "Downloaded file suspiciously small (${FILE_SIZE} bytes)."
            fi
            
            # Verify checksum if available
            EXPECTED_HASH=$(curl -s "https://huggingface.co/${SEL_HF_REPO}/raw/main/${SEL_GGUF}.sha256" 2>/dev/null | cut -d' ' -f1)
            if [[ -n "$EXPECTED_HASH" ]]; then
                ACTUAL_HASH=$(sha256sum "$GGUF_PATH" | cut -d' ' -f1)
                if [[ "$ACTUAL_HASH" != "$EXPECTED_HASH" ]]; then
                    warn "Checksum mismatch! File may be corrupted."
                    if [[ -t 0 ]] && [[ "$DRY_RUN" == "false" ]]; then
                        read -rp "  Continue anyway? [y/N]: " continue_anyway
                        [[ "$continue_anyway" =~ ^[Yy]$ ]] || rm -f "$GGUF_PATH"
                    fi
                else
                    ok "Checksum verified."
                fi
            fi
            
            if command -v numfmt &>/dev/null; then
                ok "Model downloaded: ${GGUF_PATH} ($(numfmt --to=iec-i --suffix=B "${FILE_SIZE}"))"
            else
                ok "Model downloaded: ${GGUF_PATH} (size: ${FILE_SIZE} bytes)"
            fi
        fi
        STEP_COMPLETED "model_download_${SEL_GGUF}"
    else
        ok "Model already downloaded (resuming from previous run)."
        GGUF_PATH="${MODEL_DIR}/${SEL_GGUF}"
        export GGUF_PATH
    fi
else
    ok "Skipping model download (--skip-model)"
    GGUF_PATH="${MODEL_DIR}/${SEL_GGUF}"
    export GGUF_PATH
fi

# =============================================================================
#  7. Build llama.cpp (skip if binary exists or --skip-build)
# =============================================================================
if [[ "$SKIP_BUILD" == "false" ]]; then
    if ! STEP_ALREADY_DONE "llama_cpp_build"; then
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
            else
                warn "ccache not found — building without cache (slower recompilation)"
            fi
            
            LLAMA_DIR="${HOME}/llama.cpp"
            
            if [[ -d "$LLAMA_DIR/.git" ]]; then
                dry_run_cmd git -C "$LLAMA_DIR" fetch --depth 1 origin master
                dry_run_cmd git -C "$LLAMA_DIR" reset --hard origin/master
            else
                dry_run_cmd git clone --depth 1 --branch master "$LLAMA_CPP_REPO" "$LLAMA_DIR"
            fi
            
            cd "$LLAMA_DIR"
            
            # Don't export CC/CXX as ccache wrappers — interferes with nvcc
            unset CC CXX
            
            if [[ -f "build/bin/llama-server" ]] && [[ -f "/usr/local/bin/llama-server" ]]; then
                echo "  → llama.cpp already built and installed — skipping rebuild"
            else
                # Wipe build dir if cmake flags differ from last run
                CMAKE_FINGERPRINT_FILE="build/.cmake_flags"
                if [[ "$HAS_NVIDIA" == "true" ]]; then
                    CMAKE_FLAGS_HASH="CUDA-FA_ALL_QUANTS"
                else
                    CMAKE_FLAGS_HASH="CPU-only"
                fi
                
                if [[ -f "$CMAKE_FINGERPRINT_FILE" ]]; then
                    STORED_HASH=$(cat "$CMAKE_FINGERPRINT_FILE")
                    if [[ "$STORED_HASH" != "$CMAKE_FLAGS_HASH" ]]; then
                        warn "Build flags changed ($STORED_HASH → $CMAKE_FLAGS_HASH) — wiping build dir"
                        dry_run_cmd rm -rf build
                    fi
                fi
                
                if [[ "$HAS_NVIDIA" == "true" ]]; then
                    dry_run_cmd cmake -B build \
                        -DGGML_CUDA=ON \
                        -DGGML_CUDA_FA_ALL_QUANTS=ON \
                        -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc \
                        -DGGML_CCACHE=ON \
                        -DCMAKE_BUILD_TYPE=Release \
                        > /tmp/cmake-config.log 2>&1 \
                        || { cat /tmp/cmake-config.log; die "CMake CUDA config failed"; }
                else
                    dry_run_cmd cmake -B build \
                        -DGGML_CCACHE=ON \
                        -DCMAKE_BUILD_TYPE=Release \
                        > /tmp/cmake-config.log 2>&1 \
                        || { cat /tmp/cmake-config.log; die "CMake CPU config failed"; }
                fi
                
                # Store fingerprint
                echo "$CMAKE_FLAGS_HASH" > "$CMAKE_FINGERPRINT_FILE"
                
                echo -e "  ${CYN}Compiling ($(nproc) cores) — live progress:${RST}"
                
                # Build only llama-server — skips failing examples
                if ! cmake --build build --config Release \
                        --target llama-server \
                        -j"$(nproc)" 2>&1 | \
                    while IFS= read -r line; do
                        [[ "$line" =~ ^\[\ *[0-9]+% ]] && printf "\r  %s" "$line" || true
                        [[ "$line" =~ (error:|Error) ]] && printf "\n  ${RED}%s${RST}\n" "$line" || true
                    done; then
                    
                    if [[ "$HAS_NVIDIA" == "true" ]]; then
                        warn "CUDA build failed — falling back to CPU-only..."
                        dry_run_cmd rm -rf build
                        dry_run_cmd cmake -B build -DGGML_CCACHE=ON -DCMAKE_BUILD_TYPE=Release \
                            > /tmp/cmake-config.log 2>&1 \
                            || { cat /tmp/cmake-config.log; die "CPU fallback cmake failed"; }
                        echo "CPU-only" > "$CMAKE_FINGERPRINT_FILE"
                        dry_run_cmd cmake --build build --config Release \
                            --target llama-server \
                            -j"$(nproc)" || die "CPU build also failed"
                        HAS_NVIDIA=false
                    else
                        die "Build failed."
                    fi
                fi
                printf "\n"
                
                dry_run_cmd sudo cmake --install build --quiet 2>/dev/null \
                    || warn "System-wide install failed — using build directory."
            fi
            cd ~
            
            if command -v ccache &>/dev/null; then
                echo ""
                ok "ccache stats:"
                ccache -s 2>/dev/null | grep -E "cache (hit|miss)|cache size|max size" || true
                echo ""
            fi
            
            LLAMA_SERVER_BIN=$(find_llama_server || true)
            export LLAMA_SERVER_BIN
            [[ -n "$LLAMA_SERVER_BIN" ]] || die "llama-server not found after build."
            ok "llama-server: ${LLAMA_SERVER_BIN}"
        fi
        STEP_COMPLETED "llama_cpp_build"
    else
        ok "llama.cpp already built (resuming from previous run)."
        # Re-find the binary
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
        export LLAMA_SERVER_BIN
    fi
else
    ok "Skipping llama.cpp build (--skip-build)"
    # Try to find existing binary
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
    export LLAMA_SERVER_BIN
    if [[ -z "$LLAMA_SERVER_BIN" ]]; then
        warn "No llama-server binary found. Run without --skip-build to build it."
    fi
fi

# =============================================================================
#  8. Hermes Agent (outsourc-e fork with WebAPI support)
# =============================================================================
if ! STEP_ALREADY_DONE "hermes_agent"; then
    step "Setting up Hermes Agent..."
    HERMES_AGENT_DIR="${HOME}/hermes-agent"
    HERMES_VENV="${HERMES_AGENT_DIR}/.venv"
    export HERMES_AGENT_DIR HERMES_VENV
    HERMES_BIN="${HOME}/.local/bin/hermes"
    HERMES_WEBAPI_INSTALLED=false
    HERMES_WORKSPACE_INSTALLED=false
    export PATH="${HOME}/.local/bin:${PATH}"
    
    # ── Clone or update the fork ──────────────────────────────────────────────────
    if [[ -d "${HERMES_AGENT_DIR}/.git" ]]; then
        ok "Hermes Agent (outsourc-e fork) already cloned — updating to latest..."
        cd "${HERMES_AGENT_DIR}"
        dry_run_cmd git fetch origin 2>/dev/null && dry_run_cmd git reset --hard origin/main 2>/dev/null || warn "Hermes git update failed (continuing with existing code)"
        cd - >/dev/null
    else
        step "Cloning outsourc-e/hermes-agent (WebAPI fork)..."
        dry_run_cmd git clone "$HERMES_AGENT_REPO" "${HERMES_AGENT_DIR}" 2>&1 | tail -3
        ok "Hermes Agent cloned."
    fi
    
    # ── Create / verify venv ──────────────────────────────────────────────────────
    if [[ ! -d "${HERMES_VENV}" ]]; then
        step "Creating Python virtual environment for Hermes Agent..."
        dry_run_cmd python3.11 -m venv "${HERMES_VENV}"
        ok "Venv created at ${HERMES_VENV}"
    else
        ok "Venv already exists at ${HERMES_VENV}"
    fi
    
    # ── Install/update dependencies ───────────────────────────────────────────────
    if ! "${HERMES_VENV}/bin/python" -c "import fastapi" &>/dev/null; then
        step "Installing Hermes Agent dependencies (first time ~2-5 min)..."
        dry_run_cmd "${HERMES_VENV}/bin/pip" install -e "${HERMES_AGENT_DIR}[all]"
        ok "Hermes Agent dependencies installed."
        touch "${HERMES_VENV}/installed_marker"
    else
        ok "Hermes Agent dependencies already installed."
    fi
    
    # Validate fastapi installation
    if ! "${HERMES_VENV}/bin/python" -c "import fastapi" &>/dev/null; then
        warn "fastapi not found in venv — re-installing dependencies"
        dry_run_cmd "${HERMES_VENV}/bin/pip" install fastapi uvicorn
    fi
    
    # ── Symlink hermes binary to ~/.local/bin ─────────────────────────────────────
    HERMES_VENV_BIN="${HERMES_VENV}/bin/hermes"
    if [[ -x "$HERMES_VENV_BIN" ]]; then
        dry_run_cmd mkdir -p "${HOME}/.local/bin"
        dry_run_cmd ln -sf "$HERMES_VENV_BIN" "$HERMES_BIN"
        ok "Symlinked hermes → ${HERMES_BIN}"
    else
        warn "hermes binary not found in venv at ${HERMES_VENV_BIN}"
    fi
    
    # ── Update check ──────────────────────────────────────────────────────────────
    if [[ -x "$HERMES_BIN" ]] && "${HERMES_BIN}" --help &>/dev/null; then
        HERMES_VER=$("${HERMES_BIN}" --version 2>/dev/null || echo "installed")
        ok "Hermes Agent ready: ${HERMES_VER}"
        HERMES_WEBAPI_INSTALLED=true
        
        step "Checking for Hermes updates..."
        UPDATE_OUTPUT=$("${HERMES_BIN}" update --check 2>&1 || true)
        if echo "$UPDATE_OUTPUT" | grep -qi "update available"; then
            if [[ -t 0 ]] && [[ "$DRY_RUN" == "false" ]]; then
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
    
    # ── Apply Hermes WebAPI patches ───────────────────────────────────────────────
    step "Applying Hermes WebAPI patches..."
    
    # Patch chat.py to handle dict content
    CHAT_PY="${HERMES_AGENT_DIR}/hermes/webapi/chat.py"
    if [[ -f "$CHAT_PY" ]]; then
        if grep -q "content.lower()" "$CHAT_PY" && ! grep -q "isinstance(content, str)" "$CHAT_PY"; then
            dry_run_cmd sed -i 's/content\.lower()/content = content if isinstance(content, str) else str(content)\n    content.lower()/g' "$CHAT_PY"
            ok "Patched chat.py for dict content handling."
        else
            ok "chat.py already patched or not applicable."
        fi
    else
        warn "chat.py not found at $CHAT_PY"
    fi
    
    # Patch deps.py to handle model config dict
    DEPS_PY="${HERMES_AGENT_DIR}/hermes/webapi/deps.py"
    if [[ -f "$DEPS_PY" ]]; then
        if grep -q "config.get(\"model\")" "$DEPS_PY" && ! grep -q "model.get(\"default\")" "$DEPS_PY"; then
            dry_run_cmd sed -i 's/model = config\.get("model")/model = config.get("model")\n    if isinstance(model, dict):\n        model = model.get("default", model)/g' "$DEPS_PY"
            ok "Patched deps.py for model config dict handling."
        else
            ok "deps.py already patched or not applicable."
        fi
    else
        warn "deps.py not found at $DEPS_PY"
    fi
    
    STEP_COMPLETED "hermes_agent"
else
    ok "Hermes Agent already installed (resuming)."
    HERMES_AGENT_DIR="${HOME}/hermes-agent"
    HERMES_VENV="${HERMES_AGENT_DIR}/.venv"
    export HERMES_AGENT_DIR HERMES_VENV
    HERMES_WEBAPI_INSTALLED=true
fi

# =============================================================================
#  8c. Configure Hermes → llama-server (http://localhost:8080/v1)
# =============================================================================
step "Configuring Hermes for local llama-server..."

HERMES_DIR="${HOME}/.hermes"
dry_run_cmd mkdir -p "${HERMES_DIR}"/{cron,sessions,logs,memories,skills}

CONFIG_FILE_HERMES="${HERMES_DIR}/config.yaml"
ENV_FILE_HERMES="${HERMES_DIR}/.env"

if [[ "$DRY_RUN" == "false" ]]; then
    cat > "$ENV_FILE_HERMES" <<'ENV_EOF' | sed "s|@@SEL_NAME@@|$SEL_NAME|g"
OPENAI_API_KEY=llama
LLM_MODEL=@@SEL_NAME@@
ENV_EOF
fi

if [[ -f "$CONFIG_FILE_HERMES" ]]; then
    if grep -q "^model:" "$CONFIG_FILE_HERMES" 2>/dev/null; then
        dry_run_cmd sed -i 's/provider: ".*"/provider: custom/g' "$CONFIG_FILE_HERMES" 2>/dev/null || true
        dry_run_cmd sed -i 's/provider: .*/provider: custom/g' "$CONFIG_FILE_HERMES" 2>/dev/null || true
        dry_run_cmd sed -i "s/default: \".*\"/default: \"${SEL_NAME}\"/g" "$CONFIG_FILE_HERMES" 2>/dev/null || true
        dry_run_cmd sed -i "s/default: .*/default: \"${SEL_NAME}\"/g" "$CONFIG_FILE_HERMES" 2>/dev/null || true
        if ! grep -q "^  base_url:" "$CONFIG_FILE_HERMES" 2>/dev/null; then
            dry_run_cmd sed -i '/^model:/a\  base_url: http://localhost:8080/v1' "$CONFIG_FILE_HERMES" 2>/dev/null || true
        else
            dry_run_cmd sed -i 's|^  base_url:.*|  base_url: http://localhost:8080/v1|' "$CONFIG_FILE_HERMES" 2>/dev/null || true
        fi
    else
        if [[ "$DRY_RUN" == "false" ]]; then
            cat >> "$CONFIG_FILE_HERMES" <<'MODEL_EOF' | sed "s|@@SEL_NAME@@|$SEL_NAME|g"

model:
  default: "@@SEL_NAME@@"
  provider: custom
  base_url: http://localhost:8080/v1
MODEL_EOF
        fi
    fi
    if grep -q "^custom:" "$CONFIG_FILE_HERMES" 2>/dev/null; then
        dry_run_cmd sed -i '/^custom:/,/^[a-z]/{/^custom:/d; /^[a-z]/!d}' "$CONFIG_FILE_HERMES" 2>/dev/null || true
    fi
    ok "config.yaml configured for local server."
else
    if [[ "$DRY_RUN" == "false" ]]; then
        cat > "$CONFIG_FILE_HERMES" <<'CONFIG_EOF' | sed "s|@@SEL_NAME@@|$SEL_NAME|g"
# Hermes Agent Configuration
# Generated by install.sh for @@SEL_NAME@@

model:
  default: "@@SEL_NAME@@"
  provider: custom
  base_url: http://localhost:8080/v1

# API key is stored in .env file (OPENAI_API_KEY=llama)
CONFIG_EOF
    fi
    ok "config.yaml created."
fi

ok "Hermes configured → llama-server (${SEL_NAME} at http://localhost:8080/v1)"

# =============================================================================
#  8d. Hermes Workspace Integration (Web UI)
# =============================================================================
step "Setting up Hermes Workspace..."
WORKSPACE_DIR="${HOME}/hermes-workspace"
export WORKSPACE_DIR

if [[ ! -f "${HOME}/.hermes/.env" ]]; then
    step "Creating Hermes Agent .env..."
    dry_run_cmd mkdir -p "${HOME}/.hermes"
    if [[ "$DRY_RUN" == "false" ]]; then
        cat > "${HOME}/.hermes/.env" <<'HERMES_ENV_EOF' | sed "s|@@SEL_NAME@@|$SEL_NAME|g"
# Hermes Agent Environment
# Generated by install.sh
OPENAI_API_KEY=llama
LLM_MODEL=@@SEL_NAME@@
HERMES_WEBAPI_HOST=0.0.0.0
HERMES_WEBAPI_PORT=${HERMES_WEBAPI_PORT}
HERMES_ENV_EOF
    fi
    ok "Hermes Agent .env created."
else
    if ! grep -q "^HERMES_WEBAPI_HOST=" "${HOME}/.hermes/.env" 2>/dev/null; then
        if [[ "$DRY_RUN" == "false" ]]; then
            cat >> "${HOME}/.hermes/.env" <<HERMES_ENV_ADD
# WebAPI settings (added by install.sh)
HERMES_WEBAPI_HOST=0.0.0.0
HERMES_WEBAPI_PORT=${HERMES_WEBAPI_PORT}
HERMES_ENV_ADD
        fi
        ok "Added WebAPI settings to ~/.hermes/.env."
    fi
fi

# ── Hermes WebAPI systemd service ─────────────────────────────────────────────
step "Configuring Hermes WebAPI service..."
dry_run_cmd mkdir -p "${HOME}/.config/systemd/user"
if [[ "$DRY_RUN" == "false" ]]; then
    cat > "${HOME}/.config/systemd/user/hermes-webapi.service" <<'WEBAPI_SERVICE_EOF' | sed -e "s|@@HERMES_AGENT_DIR@@|$HERMES_AGENT_DIR|g" -e "s|@@HERMES_VENV@@|$HERMES_VENV|g" -e "s|@@HOME@@|$HOME|g" -e "s|@@HERMES_WEBAPI_PORT@@|$HERMES_WEBAPI_PORT|g"
[Unit]
Description=Hermes Agent WebAPI
After=llama-server.service network.target
Requires=llama-server.service

[Service]
Type=simple
WorkingDirectory=@@HERMES_AGENT_DIR@@
ExecStart=@@HERMES_VENV@@/bin/python -m webapi --port @@HERMES_WEBAPI_PORT@@
Restart=on-failure
RestartSec=5
Environment=HOME=@@HOME@@
Environment=PATH=@@HERMES_VENV@@/bin:@@HOME@@/.local/bin:/usr/local/cuda/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
WEBAPI_SERVICE_EOF
fi

if systemctl --user daemon-reload 2>/dev/null && [[ "$DRY_RUN" == "false" ]]; then
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
    dry_run_cmd git fetch origin 2>/dev/null && dry_run_cmd git reset --hard origin/main 2>/dev/null || true
    cd - >/dev/null
else
    step "Cloning outsourc-e/hermes-workspace..."
    dry_run_cmd git clone "$HERMES_WORKSPACE_REPO" "${WORKSPACE_DIR}" 2>&1 | tail -3
fi

# ── Node.js LTS ────────────────────────────────────────────────────────────────
if ! command -v node &>/dev/null || [[ "$(which node 2>/dev/null)" == /mnt/* ]] || [[ "$(node --version 2>/dev/null | sed 's/v//')" != "${NODEJS_VERSION}."* ]]; then
    step "Installing Node.js ${NODEJS_VERSION} LTS..."
    curl -fsSL "https://deb.nodesource.com/setup_${NODEJS_VERSION}.x" | dry_run_cmd sudo -E bash - 2>/dev/null
    dry_run_cmd sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs
    export PATH="/usr/bin:/bin:/usr/local/bin:${PATH}"
else
    ok "Node.js $(node --version) already installed"
fi

# ── pnpm installation ─────────────────────────────────────────────────────────
step "Installing pnpm..."
if ! command -v pnpm &>/dev/null; then
    dry_run_cmd npm install -g pnpm
    export PATH="$HOME/.local/bin:$PATH"
fi
if ! command -v pnpm &>/dev/null; then
    die "pnpm installation failed – please install manually."
fi
ok "pnpm $(pnpm --version) ready."

# ── Install workspace dependencies ────────────────────────────────────────────
cd "${WORKSPACE_DIR}"
if [[ ! -d "node_modules" ]]; then
    step "Installing Hermes Workspace dependencies (first time ~2-5 min)..."
    dry_run_cmd pnpm install
elif [[ ! -f "node_modules/.pnpm_install_complete" ]]; then
    step "Updating Hermes Workspace dependencies..."
    dry_run_cmd pnpm update
    dry_run_cmd touch "node_modules/.pnpm_install_complete"
else
    ok "Hermes Workspace dependencies already up to date."
fi

# ── Workspace .env ────────────────────────────────────────────────────────────
WORKSPACE_ENV="${WORKSPACE_DIR}/.env"
if [[ ! -f "${WORKSPACE_ENV}" ]]; then
    if [[ "$DRY_RUN" == "false" ]]; then
        cat > "${WORKSPACE_ENV}" <<WORKSPACE_ENV
# Hermes Workspace Configuration
HERMES_API_URL=http://127.0.0.1:${HERMES_WEBAPI_PORT}
WORKSPACE_ENV
    fi
    ok "Workspace .env created."
else
    if ! grep -q "^HERMES_API_URL=" "${WORKSPACE_ENV}" 2>/dev/null; then
        if [[ "$DRY_RUN" == "false" ]]; then
            echo "HERMES_API_URL=http://127.0.0.1:${HERMES_WEBAPI_PORT}" >> "${WORKSPACE_ENV}"
        fi
        ok "Added HERMES_API_URL to workspace .env."
    fi
fi
cd - >/dev/null

# ── Hermes Workspace systemd service ──────────────────────────────────────────
step "Configuring Hermes Workspace service..."
PNPM_BIN="$(command -v pnpm)"
export PNPM_BIN
if [[ -z "$PNPM_BIN" ]]; then
    die "pnpm not found in PATH. Installation may have failed."
fi

if [[ "$DRY_RUN" == "false" ]]; then
    cat > "${HOME}/.config/systemd/user/hermes-workspace.service" <<'WORKSPACE_SERVICE_EOF' | sed -e "s|@@WORKSPACE_DIR@@|$WORKSPACE_DIR|g" -e "s|@@PNPM_BIN@@|$PNPM_BIN|g" -e "s|@@HOME@@|$HOME|g" -e "s|@@HERMES_WORKSPACE_PORT@@|$HERMES_WORKSPACE_PORT|g"
[Unit]
Description=Hermes Workspace Web UI
After=hermes-webapi.service network.target
Requires=hermes-webapi.service

[Service]
Type=simple
WorkingDirectory=@@WORKSPACE_DIR@@
ExecStart=@@PNPM_BIN@@ dev --port @@HERMES_WORKSPACE_PORT@@
Restart=on-failure
RestartSec=5
Environment=HOME=@@HOME@@
Environment=NODE_ENV=production
Environment=PATH=@@HOME@@/.local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
WORKSPACE_SERVICE_EOF
fi

if systemctl --user daemon-reload 2>/dev/null && [[ "$DRY_RUN" == "false" ]]; then
    systemctl --user enable hermes-workspace.service 2>/dev/null || true
    ok "Hermes Workspace systemd service enabled."
else
    warn "systemd --user unavailable — Workspace must be started manually."
fi

HERMES_WEBAPI_INSTALLED=true
HERMES_WORKSPACE_INSTALLED=true
ok "Hermes Workspace integration complete."

# =============================================================================
#  9. Update system & Python packages
# =============================================================================
if [[ "$SKIP_DEPS" == "false" ]]; then
    step "Updating system packages and Python dependencies..."
    if [[ ! -f /var/cache/apt/pkgcache.bin ]] || find /var/cache/apt/pkgcache.bin -mmin +60 2>/dev/null | grep -q pkgcache; then
        echo "  → Updating system package lists..."
        dry_run_cmd sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
        echo "  → Upgrading system packages..."
        dry_run_cmd sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
    else
        echo "  → System packages recently updated — skipping"
    fi
    
    if ! pip3 list --user 2>/dev/null | grep -q "^pip "; then
        echo "  → Updating Python package managers..."
        dry_run_cmd pip3 install --user --break-system-packages --upgrade pip setuptools wheel
    else
        echo "  → pip already up to date"
    fi
    ok "System and Python package managers updated."
fi

# =============================================================================
#  10. Create ~/start-llm.sh (using sed for safety)
# =============================================================================
step "Creating launch script..."
LAUNCH_SCRIPT="${HOME}/start-llm.sh"

# Template for the launch script – using sed for safety
# Ensure variables are available for sed substitution
export HERMES_AGENT_DIR HERMES_VENV WORKSPACE_DIR
if [[ "$DRY_RUN" == "false" ]]; then
    cat > "$LAUNCH_SCRIPT" << 'LAUNCH_EOF' | sed -e "s|@@GGUF_PATH@@|$GGUF_PATH|g" -e "s|@@SEL_NAME@@|$SEL_NAME|g" -e "s|@@LLAMA_SERVER_BIN@@|$LLAMA_SERVER_BIN|g" -e "s|@@SAFE_CTX@@|$SAFE_CTX|g" -e "s|@@USE_JINJA@@|$USE_JINJA|g" -e "s|@@HERMES_AGENT_DIR@@|$HERMES_AGENT_DIR|g" -e "s|@@HERMES_VENV@@|$HERMES_VENV|g" -e "s|@@WORKSPACE_DIR@@|$WORKSPACE_DIR|g" -e "s|@@HERMES_WEBAPI_PORT@@|$HERMES_WEBAPI_PORT|g" -e "s|@@HERMES_WORKSPACE_PORT@@|$HERMES_WORKSPACE_PORT|g" -e "s|@@LLAMA_SERVER_PORT@@|$LLAMA_SERVER_PORT|g"
#!/usr/bin/env bash
# start-llm.sh – generated by install.sh v${SCRIPT_VERSION}
GGUF="@@GGUF_PATH@@"
MODEL_NAME="@@SEL_NAME@@"
LLAMA_BIN="@@LLAMA_SERVER_BIN@@"
SAFE_CTX="@@SAFE_CTX@@"
USE_JINJA="@@USE_JINJA@@"
HERMES_AGENT_DIR="@@HERMES_AGENT_DIR@@"
HERMES_VENV="@@HERMES_VENV@@"
WORKSPACE_DIR="@@WORKSPACE_DIR@@"
HERMES_WEBAPI_PORT="@@HERMES_WEBAPI_PORT@@"
HERMES_WORKSPACE_PORT="@@HERMES_WORKSPACE_PORT@@"
LLAMA_SERVER_PORT="@@LLAMA_SERVER_PORT@@"
export PNPM_HOME="${HOME}/.local/share/pnpm"
export PATH="${PATH}"

# Check for running services
LLAMA_PID=$(pgrep -f "llama-server" 2>/dev/null || true)
WEBAPI_PID=$(pgrep -f "python -m webapi" 2>/dev/null || true)
WORKSPACE_PID=$(pgrep -f "pnpm dev" 2>/dev/null | grep -i workspace || true)

if [[ -n "$LLAMA_PID" || -n "$WEBAPI_PID" || -n "$WORKSPACE_PID" ]]; then
    echo -e "\n⚠️  Services already running:"
    [[ -n "$LLAMA_PID" ]] && echo "   llama-server:  $LLAMA_PID"
    [[ -n "$WEBAPI_PID" ]] && echo "   Hermes WebAPI: $WEBAPI_PID"
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
echo "  Model     : $MODEL_NAME"
echo "  Context   : ${SAFE_CTX} tokens"
echo "  Jinja     : ${USE_JINJA}"
echo ""
echo "  Endpoints:"
echo "  ────────────────────────────────────────────────────────────────"
echo "  llama-server   → http://localhost:${LLAMA_SERVER_PORT}  (LLM inference)"
echo "  Hermes WebAPI  → http://localhost:${HERMES_WEBAPI_PORT}  (Agent API)"
echo "  Hermes Workspace → http://localhost:${HERMES_WORKSPACE_PORT}  (Web UI ⭐)"
echo "  ────────────────────────────────────────────────────────────────"
echo ""
echo "  Press Ctrl+C to stop all services."
echo ""

# Start llama-server
echo "[1/3] Starting llama-server..."
"${LLAMA_BIN}" -m "${GGUF}" -ngl 99 -fa on -c "${SAFE_CTX}" -np 1 \
    --cache-type-k q4_0 --cache-type-v q4_0 --host 0.0.0.0 --port ${LLAMA_SERVER_PORT} ${USE_JINJA} &
LLAMA_PID=$!
sleep 2

for i in {1..15}; do
    if curl -sf http://localhost:${LLAMA_SERVER_PORT}/v1/models &>/dev/null; then
        echo "✓ llama-server ready (PID: $LLAMA_PID)"
        break
    fi
    sleep 1
done

# Start Hermes WebAPI (using absolute venv python)
echo "[2/3] Starting Hermes WebAPI..."
cd "${HERMES_AGENT_DIR}"
"${HERMES_VENV}/bin/python" -m webapi --port ${HERMES_WEBAPI_PORT} &
WEBAPI_PID=$!
sleep 2

for i in {1..20}; do
    if curl -sf http://localhost:${HERMES_WEBAPI_PORT}/health &>/dev/null 2>&1; then
        echo "✓ Hermes WebAPI ready at http://localhost:${HERMES_WEBAPI_PORT}"
        break
    elif curl -sf http://localhost:${HERMES_WEBAPI_PORT}/docs &>/dev/null 2>&1; then
        echo "✓ Hermes WebAPI ready at http://localhost:${HERMES_WEBAPI_PORT} (using /docs endpoint)"
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
pnpm dev --port ${HERMES_WORKSPACE_PORT} &
WORKSPACE_PID=$!
sleep 2

echo "✓ Hermes Workspace starting (PID: $WORKSPACE_PID)"
echo ""
echo "╭──────────────────────────────────────────────────────────────────╮"
echo "│  All services started! Open http://localhost:${HERMES_WORKSPACE_PORT} in your browser│
echo "╰──────────────────────────────────────────────────────────────────╯"
echo ""

wait
LAUNCH_EOF
    chmod +x "$LAUNCH_SCRIPT"
    
    # Validate the generated script
    if bash -n "$LAUNCH_SCRIPT" 2>/dev/null; then
        ok "Launch script syntax validated."
    else
        warn "Launch script has syntax errors. Please check manually."
    fi
fi

ok "Launch script: ~/start-llm.sh"

# =============================================================================
#  11. systemd user service (llama-server only)
# =============================================================================
step "Creating systemd user service for llama-server..."
dry_run_cmd mkdir -p "${HOME}/.config/systemd/user"
if [[ "$DRY_RUN" == "false" ]]; then
    cat > "${HOME}/.config/systemd/user/llama-server.service" <<'SERVICE_EOF' | sed -e "s|@@LLAMA_SERVER_BIN@@|$LLAMA_SERVER_BIN|g" -e "s|@@GGUF_PATH@@|$GGUF_PATH|g" -e "s|@@SAFE_CTX@@|$SAFE_CTX|g" -e "s|@@USE_JINJA@@|$USE_JINJA|g" -e "s|@@HOME@@|$HOME|g" -e "s|@@LLAMA_SERVER_PORT@@|$LLAMA_SERVER_PORT|g"
[Unit]
Description=llama-server LLM inference
After=network.target

[Service]
Type=simple
ExecStart=@@LLAMA_SERVER_BIN@@ -m @@GGUF_PATH@@ -ngl 99 -fa on -c @@SAFE_CTX@@ -np 1 --cache-type-k q4_0 --cache-type-v q4_0 --host 0.0.0.0 --port @@LLAMA_SERVER_PORT@@ @@USE_JINJA@@
Restart=on-failure
RestartSec=5
Environment=HOME=@@HOME@@
Environment=PATH=/usr/local/cuda/bin:@@HOME@@/.local/bin:/usr/bin:/bin
StandardOutput=file:/tmp/llama-server.log
StandardError=file:/tmp/llama-server.log

[Install]
WantedBy=default.target
SERVICE_EOF
fi

if systemctl --user daemon-reload 2>/dev/null && [[ "$DRY_RUN" == "false" ]]; then
    systemctl --user enable llama-server.service 2>/dev/null || true
    ok "llama-server systemd service enabled."
    echo "  To start automatically on login, run: loginctl enable-linger $USER"
else
    warn "systemd --user unavailable — services must be started manually with 'start-llm'"
fi

# =============================================================================
#  12. ~/.bashrc helpers
# =============================================================================
step "Adding helpers to ~/.bashrc..."

MARKER="# === LLM setup (added by install.sh) ==="
if grep -qF "$MARKER" "${HOME}/.bashrc" 2>/dev/null; then
    ok "Helpers already in ~/.bashrc — skipping."
else
    if [[ "$DRY_RUN" == "false" ]]; then
        cat >> "${HOME}/.bashrc" <<'BASHRC_START'

# === LLM setup (added by install.sh) ===
[[ -n "${__LLM_BASHRC_LOADED:-}" ]] && return 0
export __LLM_BASHRC_LOADED=1

export RED='\033[0;31m' GRN='\033[0;32m' YLW='\033[1;33m'
export CYN='\033[0;36m' BLD='\033[1m' RST='\033[0m'

show_progress() {
    local msg="$1"
    echo -ne "  → ${msg}...\r"
}
export PATH="/usr/local/cuda/bin:${PATH}"
export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"
export PNPM_HOME="${HOME}/.local/share/pnpm"
export PATH="/usr/bin:/bin:/usr/local/bin:${HOME}/.local/bin:${HOME}/.hermes/node/bin:${PATH}"
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
alias switch-model='~/.local/bin/install.sh 2>/dev/null || echo "install.sh not found in PATH"'
alias hermes-update='hermes update'
alias hermes-doctor='hermes doctor'
alias hermes-sessions='hermes sessions list'
alias hermes-summarise='echo "Summarise: decisions, code, bugs, current task. Drop rest."'

# Model management aliases
llm-download() {
    if [[ -z "$1" ]]; then
        echo "Usage: llm-download <model_number>"
        echo "Run 'llm-models' to see available models"
        return 1
    fi
    ~/.local/bin/install.sh --model "$1" --skip-build --skip-deps
}

llm-remove() {
    local model_path="$HOME/llm-models/$1"
    if [[ -f "$model_path" ]]; then
        rm -i "$model_path"
        echo "Removed $1"
    else
        echo "Model not found: $1"
    fi
}

llm-switch() {
    if [[ -z "$1" ]]; then
        echo "Usage: llm-switch <model_number>"
        return 1
    fi
    stop-llm
    ~/.local/bin/install.sh --model "$1" --skip-deps --skip-build
    start-llm
}

# Hermes Workspace aliases
alias start-workspace='cd ~/hermes-workspace && pnpm dev'
alias stop-workspace='pkill -f "pnpm dev" && echo "Hermes Workspace stopped."'
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
    WORKSPACE_PID=$(pgrep -f "pnpm dev" 2>/dev/null | grep -i workspace || true)
    
    if [[ -n "$LLAMA_PID" ]]; then
        echo -e "${GRN}  ✓ llama-server   → http://localhost:${LLAMA_SERVER_PORT}  (PID: $LLAMA_PID)${RST}"
    else
        echo -e "${RED}  ✗ llama-server   → not running${RST}"
    fi
    
    if [[ -n "$WEBAPI_PID" ]]; then
        echo -e "${GRN}  ✓ Hermes WebAPI  → http://localhost:${HERMES_WEBAPI_PORT}  (PID: $WEBAPI_PID)${RST}"
    else
        echo -e "${YLW}  ⚠ Hermes WebAPI  → not running${RST}"
    fi
    
    if [[ -n "$WORKSPACE_PID" ]]; then
        echo -e "${GRN}  ✓ Workspace      → http://localhost:${HERMES_WORKSPACE_PORT}  (PID: $WORKSPACE_PID)${RST}"
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
Constraints
<!-- What NOT to do -->
Known Issues
<!-- Document bugs -->
AGENTS
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
echo -e "${BLD}${CYN}│${RST} ${CYN}llm-download${RST} → Download a new model"
echo -e "${BLD}${CYN}│${RST} ${CYN}llm-switch${RST} → Switch to a different model"
echo -e "${BLD}${CYN}│${RST} ${CYN}vram${RST} → GPU/VRAM usage"
echo -e "${BLD}${CYN}│${RST} ${CYN}hermes${RST} → Hermes AI agent"
echo -e "${BLD}${CYN}╰────────────────────────────────────────────────────────────────╯${RST}"
echo ""
}

[[ $- == *i* ]] && show_llm_summary
BASHRC_END
ok "Helpers written to ~/.bashrc."
else
echo "[DRY RUN] Would add helpers to ~/.bashrc"
fi
fi

=============================================================================
13. .wslconfig RAM hint
=============================================================================
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
WSL_RAM=$(( RAM_GiB * 4 / 5 ))
(( WSL_RAM < 16 )) && WSL_RAM=16
(( WSL_RAM > 96 )) && WSL_RAM=96
WSL_SWAP=$(( WSL_RAM / 2 ))
(( WSL_SWAP < 8 )) && WSL_SWAP=8

if [[ "$DRY_RUN" == "false" ]]; then
cat > "$WSLCONFIG" <<WSLCFG
; Generated by install.sh v${SCRIPT_VERSION}
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
else
echo "[DRY RUN] Would write .wslconfig with ${WSL_RAM}GB RAM"
fi
elif [[ -n "$WSLCONFIG" && -f "$WSLCONFIG" ]]; then
ok ".wslconfig already exists — skipping."
else
warn "Could not locate Windows user profile — skipping .wslconfig."
fi

=============================================================================
Quick Benchmark (optional)
=============================================================================
if [[ -t 0 ]] && [[ "$DRY_RUN" == "false" ]] && [[ "$SKIP_MODEL" == "false" ]]; then
echo ""
read -rp "Run quick benchmark to verify performance? [y/N]: " run_bench
if [[ "$run_bench" =~ ^[Yy]$ ]]; then
step "Running quick benchmark..."
if [[ -x "$LLAMA_SERVER_BIN" ]]; then
"$LLAMA_SERVER_BIN" -m "$GGUF_PATH" -ngl 99 -c 512 -n 100 --temp 0 --prompt "Hello, how are you?" 2>&1 |
grep -E "eval time|prompt eval time|llama_print_timings" || echo "Benchmark complete"
else
warn "llama-server not found, skipping benchmark"
fi
fi
fi

=============================================================================
Final summary & AGENTS.md
=============================================================================
create-agents-md "${HOME}" 2>/dev/null || true

echo ""
echo -e "${GRN}${BLD}"
cat <<'EOF'
╔══════════════════════════════════════════════════════════╗
║ Setup Complete! ║
╚══════════════════════════════════════════════════════════╝
EOF
echo -e "${RST}"
echo -e " ${BLD}Versions Installed:${RST}"
echo -e " Node.js → $(node --version 2>/dev/null || echo 'Not installed')"
echo -e " npm → $(npm --version 2>/dev/null || echo 'Not installed')"
echo -e " pnpm → $(pnpm --version 2>/dev/null || echo 'Not installed')"
echo -e " Python → $(python3 --version 2>/dev/null || echo 'Not installed')"
echo -e " llama.cpp → $(llama-server --version 2>&1 | head -1 || echo 'Latest')"
echo -e " ${BLD}Services:${RST}"
echo -e " llama-server → http://localhost:${LLAMA_SERVER_PORT}/v1"
echo -e " llama.cpp Web UI → http://localhost:${LLAMA_SERVER_PORT}"
echo -e " Hermes WebAPI → http://localhost:${HERMES_WEBAPI_PORT}"
echo -e " Hermes Workspace → http://localhost:${HERMES_WORKSPACE_PORT} ⭐"
echo -e " Model → ${SEL_NAME} (context: ${SAFE_CTX})"
[[ "$HERMES_WEBAPI_INSTALLED" == "true" ]] && echo -e " Hermes Agent → outsourc-e fork with WebAPI"
[[ "$HERMES_WORKSPACE_INSTALLED" == "true" ]] && echo -e " Hermes Workspace → Full web UI installed"

echo ""
echo -e " ${BLD}Usage:${RST}"
echo -e " ${CYN}start-llm-services${RST} → Auto-start all services (systemd)"
echo -e " ${CYN}start-llm${RST} → Start full stack manually"
echo -e " ${CYN}stop-llm${RST} → Stop all services"
echo -e " ${CYN}restart-llm${RST} → Restart all services"
echo -e " ${CYN}llm-status${RST} → Check running processes"
echo -e " ${CYN}llm-services${RST} → Check systemd services"
echo -e " ${CYN}llm-log${RST} → Tail llama-server logs"
echo -e " ${CYN}llm-models${RST} → List downloaded models"
echo -e " ${CYN}llm-download${RST} → Download a new model"
echo -e " ${CYN}llm-switch${RST} → Switch to a different model"
echo -e " ${CYN}switch-model${RST} → Change model (re-run installer)"
echo -e " ${CYN}hermes${RST} → Hermes AI agent (CLI)"
echo -e " ${CYN}vram${RST} → GPU/VRAM usage"

echo ""
echo -e " ${BLD}Open in Browser:${RST}"
echo -e " ${GRN}http://localhost:${HERMES_WORKSPACE_PORT}${RST} → Hermes Workspace (main UI ⭐)"
echo -e " ${CYN}http://localhost:${LLAMA_SERVER_PORT}${RST} → llama.cpp Web UI (basic)"
echo ""
echo -e " ${YLW}Note:${RST} Run 'source ~/.bashrc' or open a new terminal."
echo -e " ${GRN}Auto-start:${RST} Services start automatically after enabling linger:"
echo -e " ${CYN}sudo loginctl enable-linger $USER${RST}"
echo ""
echo -e " ${BLD}Log file:${RST} $LOG_FILE"
echo -e " ${BLD}State file:${RST} $STATE_FILE"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
echo -e "${YLW}${BLD}Dry run complete. No changes were made to your system.${RST}"
echo -e "Remove --dry-run and run again to actually install."
fi
