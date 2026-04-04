#!/usr/bin/env bash
# =============================================================================
#  install-beta.sh  –  Ubuntu WSL2  ·  llama.cpp + Hermes + Goose + AutoAgent
#
#  This is the beta installer. It runs install.sh first (all stable features),
#  then offers two optional additional agents:
#
#  ┌─ Goose (block/goose) ────────────────────────────────────────────────────┐
#  │  Rust-based CLI agent · 30k+ stars · Linux Foundation project             │
#  │  Works directly with llama-server via OpenAI-compatible API              │
#  │  MCP support · developer extensions · extensible recipes                 │
#  │  Config: GOOSE_PROVIDER=openai, OPENAI_HOST=http://localhost:8080        │
#  │  GOOSE_MODEL must be the exact GGUF filename (what /v1/models returns)   │
#  └──────────────────────────────────────────────────────────────────────────┘
#
#  ┌─ AutoAgent (HKUDS) ──────────────────────────────────────────────────────┐
#  │  Python-based · Zero-code multi-agent framework · Deep Research mode     │
#  │  #1 open-source on GAIA benchmark · compatible with llama-server via     │
#  │  OPENAI_BASE_URL + OPENAI_API_KEY + COMPLETION_MODEL env vars            │
#  │  Requires Docker for sandbox mode; CPU mode works without Docker         │
#  │  Best with models that have strong tool-calling: Qwen3 series            │
#  └──────────────────────────────────────────────────────────────────────────┘
#
#  Usage:
#    chmod +x install-beta.sh && bash install-beta.sh
#
#  This script calls install.sh first. Make sure install.sh is in the same
#  directory, or set INSTALL_SH env var to the path.
# =============================================================================
set -euo pipefail

# ── Strip Windows /mnt/* from PATH ────────────────────────────────────────────
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

TMPFILES=()
cleanup() { local f; for f in "${TMPFILES[@]+"${TMPFILES[@]}"}"; do [[ -n "$f" && -f "$f" ]] && rm -f "$f"; done; }
trap cleanup EXIT INT TERM
register_tmp() { TMPFILES+=("$1"); }

echo -e "${BLD}${YLW}"
cat <<'BANNER'
╔══════════════════════════════════════════════════════════╗
║   Ubuntu WSL2  ·  llama.cpp + Agents  ·  BETA Setup     ║
║   Hermes Agent + Goose + AutoAgent                        ║
╚══════════════════════════════════════════════════════════╝
BANNER
echo -e "${RST}"

# =============================================================================
#  Step 1: Run the main installer first
# =============================================================================
INSTALL_SH="${INSTALL_SH:-$(dirname "$(realpath "$0")" 2>/dev/null || dirname "$0")/install.sh}"

if [[ ! -f "$INSTALL_SH" ]]; then
    # Try to download it from the same repo
    warn "install.sh not found at ${INSTALL_SH}."
    echo ""
    if [[ -t 0 ]]; then
        read -rp "  Download install.sh automatically? [Y/n]: " dl_yn
    else
        dl_yn="y"
    fi
    if [[ ! "$dl_yn" =~ ^[Nn]$ ]]; then
        INSTALL_SH="/tmp/install-llm-main.sh"
        curl -fsSL --connect-timeout 15 --max-time 60 \
            "https://raw.githubusercontent.com/mettbrot0815/llm-installer/refs/heads/main/install.sh" \
            -o "$INSTALL_SH" || die "Failed to download install.sh"
        register_tmp "$INSTALL_SH"
        ok "Downloaded install.sh."
    else
        die "Cannot proceed without install.sh."
    fi
fi

echo ""
echo -e "  ${BLD}Step 1/3: Running main installer (llama.cpp + Hermes Agent)${RST}"
echo -e "  ──────────────────────────────────────────────────────────────"
echo ""
bash "$INSTALL_SH"

# Pick up variables from the main install — read them back from start-llm.sh
LAUNCH_SCRIPT="${HOME}/start-llm.sh"
if [[ -f "$LAUNCH_SCRIPT" ]]; then
    SEL_GGUF=$(grep '^GGUF=' "$LAUNCH_SCRIPT" 2>/dev/null | head -1 | sed 's/GGUF="//;s/".*//' | xargs basename 2>/dev/null || echo "model.gguf")
    SEL_NAME=$(grep '^MODEL_NAME=' "$LAUNCH_SCRIPT" 2>/dev/null | head -1 | sed 's/MODEL_NAME="//;s/".*//' || echo "local-model")
    SAFE_CTX=$(grep '^SAFE_CTX=' "$LAUNCH_SCRIPT" 2>/dev/null | head -1 | sed 's/SAFE_CTX="//;s/".*//' || echo "32768")
else
    SEL_GGUF="model.gguf"; SEL_NAME="local-model"; SAFE_CTX="32768"
fi

export PATH="${HOME}/.local/bin:${PATH}"

echo ""
echo -e "${BLD}${YLW}"
cat <<'HDR'
╔══════════════════════════════════════════════════════════╗
║   Beta Add-ons: Goose + AutoAgent                        ║
╚══════════════════════════════════════════════════════════╝
HDR
echo -e "${RST}"

# =============================================================================
#  Step 2: Goose (block/goose)
# =============================================================================
echo -e "  ${BLD}Step 2/3: Goose AI Agent${RST}"
echo ""
echo -e "  ${BLD}What it is:${RST}"
echo -e "  • Rust-based CLI agent from Block (Square/Cash App engineers)"
echo -e "  • 30,000+ GitHub stars · donated to Linux Foundation"
echo -e "  • 25+ LLM providers · MCP protocol · extensible recipes"
echo -e "  • Works with llama-server OpenAI-compatible API"
echo -e "  • Dev tools built-in: file system, terminal, code execution"
echo ""
echo -e "  ${BLD}Requirements:${RST} Internet for install only. Runs 100% local after."
echo ""

GOOSE_INSTALLED=false

if [[ -t 0 ]]; then
    read -rp "  Install Goose? [y/N]: " install_goose
else
    install_goose="n"
fi

if [[ "$install_goose" =~ ^[Yy]$ ]]; then
    step "Installing Goose CLI (block/goose)..."

    if command -v goose &>/dev/null; then
        ok "Goose already installed: $(goose --version 2>/dev/null || echo 'installed')"
        GOOSE_INSTALLED=true
    else
        if curl -fsSL --connect-timeout 15 --max-time 120 \
            https://github.com/block/goose/releases/download/stable/download_cli.sh \
            -o /tmp/goose-install.sh 2>/dev/null; then
            register_tmp "/tmp/goose-install.sh"
            bash /tmp/goose-install.sh || warn "Goose install script failed — check output above."
            export PATH="${HOME}/.local/bin:${PATH}"
        else
            warn "Failed to download Goose install script — skipping."
        fi

        if command -v goose &>/dev/null; then
            ok "Goose installed: $(goose --version 2>/dev/null || echo 'ok')"
            GOOSE_INSTALLED=true
        else
            warn "Goose binary not found in PATH. May need: export PATH=\"\${HOME}/.local/bin:\${PATH}\""
        fi
    fi

    if [[ "$GOOSE_INSTALLED" == "true" ]]; then
        step "Configuring Goose for local llama-server..."
        mkdir -p "${HOME}/.config/goose"

        # CRITICAL Goose config notes (from docs + user experience):
        # - OPENAI_HOST: base URL WITHOUT /v1 (just http://localhost:8080)
        # - OPENAI_BASE_PATH: v1/chat/completions (the path component)
        # - GOOSE_MODEL: MUST be the exact GGUF filename that llama-server
        #   reports as model ID in /v1/models (i.e. just the filename)
        # - OPENAI_API_KEY: any non-empty string (local server ignores auth)
        cat > "${HOME}/.config/goose/config.yaml" <<GOOSE_CFG
# Goose configuration — local llama-server (llama.cpp)
# Generated by install-beta.sh
#
# CRITICAL: OPENAI_HOST must NOT have /v1 — that goes in OPENAI_BASE_PATH
# GOOSE_MODEL must be the exact filename llama-server reports (see /v1/models)

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
        ok "Goose configured → http://localhost:8080 (model: ${SEL_GGUF})"

        # Add goose aliases to bashrc
        MARKER_GOOSE="# === Goose aliases ==="
        if ! grep -qF "$MARKER_GOOSE" "${HOME}/.bashrc" 2>/dev/null; then
            cat >> "${HOME}/.bashrc" <<GOOSE_ALIASES

${MARKER_GOOSE}
alias goose-config='goose configure'
goose-model() {
    # Update goose config with a new model filename
    local new_model="\${1:?Usage: goose-model <filename.gguf>}"
    sed -i "s|^GOOSE_MODEL:.*|GOOSE_MODEL: \${new_model}|" ~/.config/goose/config.yaml 2>/dev/null || \
        echo "GOOSE_MODEL: \${new_model}" >> ~/.config/goose/config.yaml
    echo "Goose model updated to: \${new_model}"
    echo "Restart goose to apply."
}
GOOSE_ALIASES
            ok "Goose aliases added to ~/.bashrc."
        fi

        echo ""
        echo -e "  ${BLD}Goose quick-start:${RST}"
        echo -e "  ${CYN}goose${RST}           Start chatting (uses local llama-server)"
        echo -e "  ${CYN}goose configure${RST} Reconfigure provider/model interactively"
        echo -e "  ${CYN}goose-model <file.gguf>${RST}  Switch model after switch-model"
        echo ""
        warn "If Goose shows wrong model or connects to cloud: run 'goose configure'"
        warn "Select: OpenAI → OPENAI_HOST=http://localhost:8080 → model=${SEL_GGUF}"
    fi
else
    ok "Skipping Goose."
fi

# =============================================================================
#  Step 3: AutoAgent (HKUDS/AutoAgent)
#
#  AutoAgent (HKUDS) is a zero-code, natural-language-driven multi-agent
#  framework with Deep Research mode (#1 open-source on GAIA benchmark).
#  It connects to llama-server via OPENAI_BASE_URL + API key env vars.
#
#  Caveat: AutoAgent works BEST with strong tool-calling models (Qwen3 series).
#  It requires Docker for full sandbox mode, but can run in CLI mode without it.
# =============================================================================
echo ""
echo -e "  ${BLD}Step 3/3: AutoAgent (HKUDS)${RST}"
echo ""
echo -e "  ${BLD}What it is:${RST}"
echo -e "  • Zero-code multi-agent framework from Hong Kong University"
echo -e "  • Deep Research mode: competes with OpenAI's Deep Research (free)"
echo -e "  • #1 open-source on GAIA benchmark · natural language agent building"
echo -e "  • Works with local llama-server as the LLM backend"
echo -e "  • Supports: agent editor, workflow editor, user mode (deep research)"
echo ""
echo -e "  ${BLD}Requirements:${RST}"
echo -e "  • Python 3.11 (already installed)"
echo -e "  • Docker optional (enables isolated sandbox; CLI mode works without)"
echo -e "  • Best models: Qwen3.5-9B+ or any model with strong tool-calling"
echo ""
echo -e "  ${YLW}Note:${RST} 'deep research' CLI mode works without Docker."
echo -e "       Full agent/workflow editor requires Docker."
echo ""

AUTOAGENT_INSTALLED=false
AUTOAGENT_DIR="${HOME}/autoagent"

if [[ -t 0 ]]; then
    read -rp "  Install AutoAgent? [y/N]: " install_autoagent
else
    install_autoagent="n"
fi

if [[ "$install_autoagent" =~ ^[Yy]$ ]]; then
    step "Installing AutoAgent (HKUDS)..."

    # ── uv (required by AutoAgent) ────────────────────────────────────────────
    if ! command -v uv &>/dev/null; then
        step "Installing uv (fast Python package manager)..."
        curl -LsSf https://astral.sh/uv/install.sh | sh
        export PATH="${HOME}/.cargo/bin:${HOME}/.local/bin:${PATH}"
        ok "uv installed."
    else
        ok "uv already installed: $(uv --version)"
    fi

    # ── Clone / update AutoAgent ──────────────────────────────────────────────
    if [[ -d "${AUTOAGENT_DIR}/.git" ]]; then
        ok "AutoAgent already cloned — updating..."
        cd "${AUTOAGENT_DIR}"
        git fetch origin 2>/dev/null && git reset --hard origin/main 2>/dev/null || \
            warn "AutoAgent git update failed — continuing with existing code."
        cd ->/dev/null
    else
        step "Cloning HKUDS/AutoAgent..."
        git clone https://github.com/HKUDS/AutoAgent.git "${AUTOAGENT_DIR}" 2>&1 | tail -3
        ok "AutoAgent cloned."
    fi

    # ── Create Python 3.11 venv with uv ──────────────────────────────────────
    AUTOAGENT_VENV="${AUTOAGENT_DIR}/.venv"
    if [[ ! -d "$AUTOAGENT_VENV" ]]; then
        step "Creating Python 3.11 venv for AutoAgent..."
        uv venv "${AUTOAGENT_VENV}" --python 3.11
        ok "Venv created."
    else
        ok "AutoAgent venv already exists."
    fi

    # ── Install AutoAgent ─────────────────────────────────────────────────────
    step "Installing AutoAgent dependencies..."
    (
        export VIRTUAL_ENV="${AUTOAGENT_VENV}"
        export PATH="${AUTOAGENT_VENV}/bin:${PATH}"
        cd "${AUTOAGENT_DIR}"
        # Install with uv (much faster than pip)
        uv pip install -e "." 2>&1 | tail -5
    ) || warn "AutoAgent install completed with warnings — check above."
    ok "AutoAgent installed."

    # ── Create ~/.autoagent config dir ───────────────────────────────────────
    mkdir -p "${HOME}/.autoagent"

    # ── Create AutoAgent .env ─────────────────────────────────────────────────
    # AutoAgent uses litellm under the hood, so we set the openai-compatible vars.
    # COMPLETION_MODEL uses litellm model format: "openai/<model-name>"
    # API_BASE_URL: the full base URL with /v1
    cat > "${HOME}/.autoagent/.env" <<AUTOAGENT_ENV
# AutoAgent — local llama-server configuration
# Generated by install-beta.sh

# LLM backend (llama-server via OpenAI-compatible API)
COMPLETION_MODEL=openai/${SEL_GGUF}
API_BASE_URL=http://localhost:8080/v1
OPENAI_API_KEY=sk-no-key-needed

# Debug mode (set to True for verbose output)
DEBUG=False
AUTOAGENT_ENV
    ok "~/.autoagent/.env written."

    # ── Create start-autoagent.sh wrapper ─────────────────────────────────────
    cat > "${HOME}/start-autoagent.sh" <<AUTOAGENT_LAUNCHER
#!/usr/bin/env bash
# start-autoagent.sh — generated by install-beta.sh
# Starts AutoAgent in deep research (user) mode with local llama-server

AUTOAGENT_VENV="${AUTOAGENT_VENV}"
AUTOAGENT_DIR="${AUTOAGENT_DIR}"

# Check llama-server is running
if ! curl -sf http://localhost:8080/v1/models &>/dev/null; then
    echo -e "\n  ⚠️  llama-server is not running."
    echo -e "  Start it first: start-llm"
    echo ""
    read -rp "  Start llama-server now? [Y/n]: " yn
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

echo ""
echo "  Starting AutoAgent (deep research mode)..."
echo "  Model: ${SEL_GGUF}"
echo "  API  : http://localhost:8080/v1"
echo ""

source "${AUTOAGENT_VENV}/bin/activate"
cd "${AUTOAGENT_DIR}"

# Load .env
set -a
source "${HOME}/.autoagent/.env" 2>/dev/null || true
set +a

# Run AutoAgent in user mode (deep research — no Docker needed)
auto deep-research
AUTOAGENT_LAUNCHER
    chmod +x "${HOME}/start-autoagent.sh"
    ok "Created ~/start-autoagent.sh"

    # ── Add AutoAgent aliases to bashrc ───────────────────────────────────────
    MARKER_AA="# === AutoAgent aliases ==="
    if ! grep -qF "$MARKER_AA" "${HOME}/.bashrc" 2>/dev/null; then
        cat >> "${HOME}/.bashrc" <<AUTOAGENT_ALIASES

${MARKER_AA}
export PATH="${AUTOAGENT_VENV}/bin:\${PATH}"

alias autoagent='bash ~/start-autoagent.sh'
alias autoagent-research='bash ~/start-autoagent.sh'

autoagent-full() {
    # Full AutoAgent (requires Docker) — agent editor + workflow editor
    source "${AUTOAGENT_VENV}/bin/activate"
    cd "${AUTOAGENT_DIR}"
    set -a; source "${HOME}/.autoagent/.env" 2>/dev/null || true; set +a
    auto main
}

autoagent-model() {
    # Update AutoAgent model after switch-model
    local new_model="\${1:?Usage: autoagent-model <filename.gguf>}"
    sed -i "s|^COMPLETION_MODEL=.*|COMPLETION_MODEL=openai/\${new_model}|" \
        ~/.autoagent/.env 2>/dev/null || \
        echo "COMPLETION_MODEL=openai/\${new_model}" >> ~/.autoagent/.env
    echo "AutoAgent model updated to: openai/\${new_model}"
}
AUTOAGENT_ALIASES
        ok "AutoAgent aliases added to ~/.bashrc."
    fi

    AUTOAGENT_INSTALLED=true

    echo ""
    echo -e "  ${BLD}AutoAgent quick-start:${RST}"
    echo -e "  ${CYN}autoagent${RST}               Deep research mode (no Docker needed)"
    echo -e "  ${CYN}autoagent-full${RST}           Full mode with agent/workflow editor (needs Docker)"
    echo -e "  ${CYN}autoagent-model <file>${RST}  Update model after switch-model"
    echo ""
    warn "AutoAgent works best with Qwen3.5-9B+ or models with strong tool-calling."
    warn "On small models (< 7B), complex research tasks may produce poor results."
else
    ok "Skipping AutoAgent."
fi

# =============================================================================
#  Done
# =============================================================================
echo ""
echo -e "${YLW}${BLD}"
cat <<'EOF'
╔══════════════════════════════════════════════════════════╗
║           Beta Setup Complete!                           ║
╚══════════════════════════════════════════════════════════╝
EOF
echo -e "${RST}"
echo -e " ${BLD}Installed:${RST}"
echo -e "  llama-server   → http://localhost:8080"
echo -e "  Hermes Agent   → hermes (CLI)"
[[ "$GOOSE_INSTALLED"     == "true" ]] && echo -e "  Goose          → goose (CLI)"
[[ "$AUTOAGENT_INSTALLED" == "true" ]] && echo -e "  AutoAgent      → autoagent (CLI)"
echo -e "  Model          → ${SEL_NAME}"
echo ""
echo -e " ${BLD}All commands:${RST}"
echo -e "  ${CYN}hermes${RST}            Hermes Agent CLI"
[[ "$GOOSE_INSTALLED"     == "true" ]] && echo -e "  ${CYN}goose${RST}             Goose CLI"
[[ "$AUTOAGENT_INSTALLED" == "true" ]] && echo -e "  ${CYN}autoagent${RST}         AutoAgent deep research"
[[ "$AUTOAGENT_INSTALLED" == "true" ]] && echo -e "  ${CYN}autoagent-full${RST}    AutoAgent full mode (Docker)"
echo -e "  ${CYN}start-llm${RST}         Start llama-server"
echo -e "  ${CYN}switch-model${RST}      Change model (all agents updated)"
echo -e "  ${CYN}llm-status${RST}        Check running services"
echo ""
if [[ "$AUTOAGENT_INSTALLED" == "true" ]]; then
echo -e " ${YLW}After switch-model, update agent configs:${RST}"
echo -e "  ${CYN}autoagent-model <new-file.gguf>${RST}"
[[ "$GOOSE_INSTALLED" == "true" ]] && echo -e "  ${CYN}goose-model <new-file.gguf>${RST}"
echo ""
fi
echo -e " ${YLW}Note:${RST} Run 'source ~/.bashrc' or open a new terminal."
echo ""
