#!/usr/bin/env bash
set -euo pipefail

echo "========================================"
echo "🚀 Fresh Ubuntu 24.04 WSL2 + RTX 3060 12GB Installer"
echo "   CUDA 12.6 + Optimized llama.cpp + Hermes Agent + Open WebUI"
echo "========================================"

MODELS_DIR="/home/$USER/llm-models"
LLAMA_DIR="/home/$USER/llama.cpp"
HERMES_SCRIPT="/home/$USER/start-hermes.sh"
WEBUI_DIR="/home/$USER/open-webui"
PORT="8081"       # llama-server API port
WEBUI_PORT="3000"  # Open WebUI port

# ====================== 1. FULL SYSTEM & CUDA SETUP ======================
setup_fresh_system() {
  echo "→ Updating system and installing all dependencies..."

  sudo apt-get update

  echo "→ Installing build tools and dependencies..."
  sudo apt-get install -y \
    build-essential \
    cmake \
    git \
    curl \
    wget \
    python3 \
    python3-pip \
    linux-headers-generic

  # Install CUDA 12.6 for WSL2 (recommended for RTX 3060)
  if dpkg -s cuda-keyring &>/dev/null && dpkg -s cuda-toolkit-12-6 &>/dev/null; then
    echo "✅ CUDA 12.6 already installed, skipping."
  else
    echo "→ Installing CUDA Toolkit 12.6..."
    local keyring_deb="/tmp/cuda-keyring_1.1-1_all.deb"
    wget -q -O "$keyring_deb" https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
    sudo dpkg -i "$keyring_deb"
    rm -f "$keyring_deb"
    sudo apt-get update -qq
    sudo apt-get install -y cuda-toolkit-12-6
  fi

  # Set CUDA environment permanently
  cat << EOF | sudo tee /etc/profile.d/cuda.sh > /dev/null
export PATH=/usr/local/cuda-12.6/bin\${PATH:+:\${PATH}}
export LD_LIBRARY_PATH=/usr/local/cuda-12.6/lib64\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}
EOF

  source /etc/profile.d/cuda.sh

  echo "✅ CUDA 12.6 and all dependencies installed successfully."
}

# ====================== 2. AUTO TUNING FOR YOUR HARDWARE ======================
auto_tune_settings() {
  CTX="65536"      # Safe & good performance on 12GB VRAM
  NGL="94"         # 94 layers = excellent speed with headroom
  BATCH="1024"
  UBATCH="512"
  echo "→ Auto-tuned for RTX 3060 12GB + 16GB RAM: 65k context, 94 layers"
}

# ====================== 3. BUILD LLAMA.CPP ======================
build_llama() {
  echo "→ Cloning/updating llama.cpp with CUDA 12.6..."

  cd /home/"$USER" || exit

  if [[ -d "$LLAMA_DIR" ]]; then
    cd "$LLAMA_DIR"
    OLD_COMMIT=$(git rev-parse HEAD)
    git pull --ff-only
    NEW_COMMIT=$(git rev-parse HEAD)

    if [[ "$OLD_COMMIT" == "$NEW_COMMIT" ]] && [[ -f "build/bin/llama-server" ]]; then
      echo "✅ llama.cpp is already up to date (commit: ${NEW_COMMIT:0:7}). Skipping rebuild."
      return 0
    fi

    echo "→ Update detected (${OLD_COMMIT:0:7} → ${NEW_COMMIT:0:7}). Rebuilding..."
  else
    git clone https://github.com/ggerganov/llama.cpp.git "$LLAMA_DIR"
    cd "$LLAMA_DIR"
    echo "→ Fresh clone. Building..."
  fi

  rm -rf build

  cmake -B build \
    -DGGML_CUDA=ON \
    -DGGML_CUDA_FA=ON \
    -DGGML_CUDA_FA_ALL_QUANTS=ON \
    -DGGML_CUDA_MMQ=ON \
    -DGGML_CUDA_GRAPHS=ON \
    -DGGML_NATIVE=ON \
    -DCMAKE_CUDA_ARCHITECTURES="86" \
    -DCMAKE_BUILD_TYPE=Release

  echo "→ Building llama.cpp (this may take 8-15 minutes)..."
  cmake --build build --config Release -j "$(nproc)"

  echo "✅ llama.cpp built successfully for your RTX 3060!"
}

# ====================== 4. INSTALL UV + OPEN WEBUI ======================
install_openwebui() {
  # Install uv if not already present
  export PATH="$HOME/.local/bin:$PATH"
  if ! command -v uv &>/dev/null; then
    echo "→ Installing uv (Python package manager)..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    echo "✅ uv installed: $(uv --version)"
  else
    echo "✅ uv already installed: $(uv --version)"
  fi

  mkdir -p "$WEBUI_DIR"
  cd "$WEBUI_DIR"

  # Check installed version safely — never let version detection abort the script
  INSTALLED=""
  if [[ -f ".venv/bin/python" ]]; then
    INSTALLED=$(.venv/bin/python -m pip show open-webui 2>/dev/null | awk '/^Version:/ {print $2}' || true)
  fi

  # Get latest version from PyPI safely
  LATEST=$(curl -fsSL https://pypi.org/pypi/open-webui/json 2>/dev/null | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4 || true)

  if [[ -n "$INSTALLED" && -n "$LATEST" && "$INSTALLED" == "$LATEST" ]]; then
    echo "✅ Open WebUI already up to date (${INSTALLED}). Skipping install."
    return 0
  fi

  if [[ -n "$INSTALLED" ]]; then
    echo "→ Updating Open WebUI ${INSTALLED} → ${LATEST:-unknown}..."
  else
    echo "→ Installing Open WebUI via uv..."
    # Only create venv if it does not already exist
    if [[ ! -f ".venv/bin/python" ]]; then
      uv venv .venv --python 3.11
    fi
  fi

  source .venv/bin/activate
  uv pip install --upgrade open-webui
  deactivate

  echo "✅ Open WebUI installed in ${WEBUI_DIR}/.venv"
}

# ====================== 5. CREATE OPTIMIZED HERMES AGENT ======================
create_hermes_script() {
  auto_tune_settings

  if [[ -f "$HERMES_SCRIPT" ]]; then
    echo "✅ Hermes Agent script already exists. Skipping."
    return 0
  fi

  cat > "$HERMES_SCRIPT" << EOF
#!/usr/bin/env bash
set -euo pipefail

GGUF="${MODELS_DIR}/Harmonic-Hermes-9B-Q5_K_M.gguf"
LLAMA_BIN="${LLAMA_DIR}/build/bin/llama-server"
PORT="${PORT}"

CTX="${CTX}"
NGL="${NGL}"
BATCH="${BATCH}"
UBATCH="${UBATCH}"

CACHE_K="q8_0"
CACHE_V="q4_0"
FLASH_ATTN="1"

EXTRA_FLAGS="--no-mmap --defrag-thold 0.1"

echo "🚀 Starting Hermes Agent (65k ctx | 94 layers | Optimized for RTX 3060 12GB)"

"\$LLAMA_BIN" \
  -m "\$GGUF" \
  -ngl "\$NGL" \
  -fa "\$FLASH_ATTN" \
  -b "\$BATCH" \
  -ub "\$UBATCH" \
  -c "\$CTX" \
  --cache-type-k "\$CACHE_K" \
  --cache-type-v "\$CACHE_V" \
  --host 0.0.0.0 \
  --port "\$PORT" \
  --jinja \
  \${EXTRA_FLAGS} &

echo "✅ Hermes Agent running!"
echo "   Endpoint: http://localhost:\${PORT}/v1"
echo "   Monitor VRAM: watch -n 0.5 nvidia-smi"
EOF

  chmod +x "$HERMES_SCRIPT"
  echo "✅ Hermes Agent start script created."
}

# ====================== 6. SETUP WSL2 AUTOSTART ======================
setup_autostart() {
  echo "→ Setting up WSL2 autostart for llama-server and Open WebUI..."

  # --- systemd service: llama-server ---
  sudo tee /etc/systemd/system/llama-server.service > /dev/null << EOF
[Unit]
Description=llama.cpp server (Hermes Agent)
After=network.target

[Service]
Type=simple
User=${USER}
WorkingDirectory=/home/${USER}
Environment="PATH=/usr/local/cuda-12.6/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="LD_LIBRARY_PATH=/usr/local/cuda-12.6/lib64"
ExecStart=${LLAMA_DIR}/build/bin/llama-server \
  -m ${MODELS_DIR}/Harmonic-Hermes-9B-Q5_K_M.gguf \
  -ngl 94 \
  -fa 1 \
  -b 1024 \
  -ub 512 \
  -c 65536 \
  --cache-type-k q8_0 \
  --cache-type-v q4_0 \
  --host 0.0.0.0 \
  --port ${PORT} \
  --jinja \
  --no-mmap \
  --defrag-thold 0.1
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  # --- systemd service: open-webui ---
  sudo tee /etc/systemd/system/open-webui.service > /dev/null << EOF
[Unit]
Description=Open WebUI
After=network.target llama-server.service

[Service]
Type=simple
User=${USER}
WorkingDirectory=${WEBUI_DIR}
Environment="PATH=/home/${USER}/.local/bin:${WEBUI_DIR}/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# PORT must be set as env var — open-webui reads this before uvicorn binds.
# Relying solely on --port is unreliable on bare-metal pip installs and would
# conflict with llama-server already holding port 8080.
Environment="PORT=${WEBUI_PORT}"
# DATA_DIR keeps webui.db outside the venv so it survives uv reinstalls/upgrades.
Environment="DATA_DIR=/home/${USER}/.open-webui"
Environment="OPENAI_API_BASE_URL=http://localhost:${PORT}/v1"
Environment="OPENAI_API_KEY=sk-placeholder"
ExecStart=${WEBUI_DIR}/.venv/bin/open-webui serve --port ${WEBUI_PORT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  # Enable both services
  sudo systemctl daemon-reload
  sudo systemctl enable llama-server.service
  sudo systemctl enable open-webui.service

  # WSL2 does not run systemd by default — ensure it is enabled in wsl.conf
  if ! grep -q "systemd=true" /etc/wsl.conf 2>/dev/null; then
    echo "→ Enabling systemd in /etc/wsl.conf..."
    sudo tee -a /etc/wsl.conf > /dev/null << EOF

[boot]
systemd=true
EOF
    echo "⚠️  systemd was just enabled. You must restart WSL2 once for autostart to take effect:"
    echo "    Run in PowerShell: wsl --shutdown"
    echo "    Then reopen WSL2."
  else
    echo "✅ systemd already enabled in /etc/wsl.conf."
  fi

  # --- /etc/profile.d/ hint shown on every new terminal ---
  sudo tee /etc/profile.d/llm-hint.sh > /dev/null << 'HINT'
echo ""
echo "┌─────────────────────────────────────────────┐"
echo "│           LLM Stack Quick Reference         │"
echo "├─────────────────────────────────────────────┤"
echo "│  Hermes Agent (llama-server)                │"
echo "│    start:   sudo systemctl start llama-server  │"
echo "│    stop:    sudo systemctl stop llama-server   │"
echo "│    status:  sudo systemctl status llama-server │"
echo "│    logs:    journalctl -u llama-server -f      │"
echo "│    API:     http://localhost:8080/v1           │"
echo "├─────────────────────────────────────────────┤"
echo "│  Open WebUI                                 │"
echo "│    start:   sudo systemctl start open-webui    │"
echo "│    stop:    sudo systemctl stop open-webui     │"
echo "│    status:  sudo systemctl status open-webui   │"
echo "│    logs:    journalctl -u open-webui -f        │"
echo "│    UI:      http://localhost:3000              │"
echo "└─────────────────────────────────────────────┘"
echo ""
HINT
  sudo chmod +x /etc/profile.d/llm-hint.sh

  echo "✅ Autostart configured:"
  echo "   llama-server → http://localhost:${PORT}/v1"
  echo "   open-webui   → http://localhost:${WEBUI_PORT}"
}

# ====================== 7. MAIN MENU ======================
main_menu() {
  while true; do
    echo ""
    echo "========================================"
    echo "          RTX 3060 WSL2 Menu"
    echo "========================================"
    echo "1) Rebuild llama.cpp"
    echo "2) Download Harmonic-Hermes-9B-Q5_K_M.gguf"
    echo "3) Create/Update Hermes Agent script"
    echo "4) Start Hermes Agent (manual)"
    echo "5) Install / Update Open WebUI"
    echo "6) Setup autostart (llama-server + Open WebUI)"
    echo "7) Show service status"
    echo "8) Exit"
    read -rp "Choose [1-8]: " option

    case $option in
      1) build_llama ;;
      2)
        mkdir -p "$MODELS_DIR"
        echo "→ Downloading Harmonic-Hermes-9B-Q5_K_M.gguf..."
        wget --show-progress -O "${MODELS_DIR}/Harmonic-Hermes-9B-Q5_K_M.gguf" \
          https://huggingface.co/mradermacher/Harmonic-Hermes-9B-GGUF/resolve/main/Harmonic-Hermes-9B-Q5_K_M.gguf
        echo "✅ Model downloaded to ${MODELS_DIR}"
        ;;
      3) create_hermes_script ;;
      4)
        if [[ -x "$HERMES_SCRIPT" ]]; then
          "$HERMES_SCRIPT"
        else
          echo "Please run option 3 first."
        fi
        ;;
      5) install_openwebui ;;
      6) setup_autostart ;;
      7)
        echo "--- llama-server ---"
        sudo systemctl status llama-server.service --no-pager || true
        echo ""
        echo "--- open-webui ---"
        sudo systemctl status open-webui.service --no-pager || true
        ;;
      8) echo "Goodbye!"; exit 0 ;;
      *) echo "Invalid option." ;;
    esac
  done
}

# ====================== EXECUTION STARTS HERE ======================
echo "→ Starting fresh installation on Ubuntu 24.04 WSL2..."
setup_fresh_system
mkdir -p "$MODELS_DIR"

build_llama
create_hermes_script
install_openwebui
setup_autostart

echo ""
echo "========================================"
echo "✅ Installation Completed Successfully!"
echo ""
echo "Services will autostart on next WSL2 boot."
echo "If systemd was just enabled, run in PowerShell: wsl --shutdown"
echo ""
echo "Next steps:"
echo "   1. Download model     → Press 2"
echo "   2. Open WebUI         → http://localhost:${WEBUI_PORT}"
echo "   3. llama-server API   → http://localhost:${PORT}/v1"
echo ""
echo "Your RTX 3060 12GB is now optimized (65k context recommended)."
main_menu
