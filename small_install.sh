#!/usr/bin/env bash
set -euo pipefail

echo "========================================"
echo "🚀 Gemma 4 26B-A4B UD-IQ3_XXS Installer"
echo "   RTX 3060 12GB + 64K Context + Open WebUI (No Docker)"
echo "========================================"

# ====================== CONFIG ======================
MODELS_DIR="/home/$USER/llm-models"
LLAMA_DIR="/home/$USER/llama.cpp"
START_SCRIPT="/home/$USER/start-llm.sh"
WEBUI_DIR="/home/$USER/open-webui"
PORT="8080"
WEBUI_PORT="3000"

# Tuned for your hardware
CONTEXT=65536
NGL=72
BATCH=512
UBATCH=256

echo "→ Using 64K Context | -ngl ${NGL}"

# ====================== BUILD LLAMA.CPP ======================
build_llama() {
  echo "→ Building llama.cpp..."
  cd /home/"$USER" || exit

  if [[ -d "$LLAMA_DIR" ]]; then
    cd "$LLAMA_DIR"
    git pull --ff-only || true
  else
    git clone https://github.com/ggerganov/llama.cpp.git "$LLAMA_DIR"
    cd "$LLAMA_DIR"
  fi

  rm -rf build

  cmake -B build \
    -DGGML_CUDA=ON \
    -DGGML_CUDA_FA=ON \
    -DCMAKE_CUDA_ARCHITECTURES="86" \
    -DCMAKE_BUILD_TYPE=Release

  cmake --build build --config Release -j "$(nproc)"
  echo "✅ llama.cpp built successfully!"
}

# ====================== CREATE START SCRIPT ======================
create_start_script() {
  cat > "$START_SCRIPT" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

GGUF="/home/user/llm-models/gemma-4-26B-A4B-it-UD-IQ3_XXS.gguf"
LLAMA_BIN="/home/user/llama.cpp/build/bin/llama-server"
PORT="8080"
CONTEXT=65536

echo "🚀 Starting Gemma 4 26B-A4B UD-IQ3_XXS | 64K Context"

pkill -9 llama-server 2>/dev/null || true
sleep 2

"${LLAMA_BIN}" \
  -m "${GGUF}" \
  -ngl 72 \
  -fa on \
  -c ${CONTEXT} \
  --cache-type-k q4_0 \
  --cache-type-v q4_0 \
  -b 512 \
  -ub 256 \
  -np 1 \
  --no-mmap \
  --host 0.0.0.0 \
  --port ${PORT} \
  --jinja
EOF

  chmod +x "$START_SCRIPT"
  echo "✅ Start script created"
}

# ====================== INSTALL OPEN WEBUI (No Docker) ======================
install_webui() {
  echo "→ Installing Open WebUI (pip method)..."

  cd /home/"$USER"

  if [[ ! -d "$WEBUI_DIR" ]]; then
    git clone https://github.com/open-webui/open-webui.git "$WEBUI_DIR"
  fi

  cd "$WEBUI_DIR"
  git pull

  python3 -m venv venv
  source venv/bin/activate

  pip install --upgrade pip
  pip install -r requirements.txt

  echo "✅ Open WebUI installed successfully!"
}

# ====================== CREATE SYSTEMD SERVICE ======================
create_systemd_service() {
  echo "→ Creating systemd service..."

  sudo tee /etc/systemd/system/llama-server.service > /dev/null << EOF
[Unit]
Description=Gemma 4 26B llama-server
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=/home/$USER
ExecStart=/home/$USER/start-llm.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable llama-server
  sudo systemctl start llama-server
  echo "✅ Systemd service created"
}

# ====================== MAIN ======================
echo "→ Starting installation..."

sudo apt-get update -qq
sudo apt-get install -y build-essential cmake git curl wget python3 python3-pip python3-venv

mkdir -p "$MODELS_DIR"

build_llama
create_start_script
install_webui
create_systemd_service

echo ""
echo "========================================"
echo "✅ Installation Completed Successfully!"
echo ""
echo "Useful Commands:"
echo "   ./start-llm.sh                    → Start manually"
echo "   sudo systemctl status llama-server"
echo "   sudo systemctl restart llama-server"
echo ""
echo "Access:"
echo "   llama-server → http://localhost:8080"
echo "   Open WebUI   → http://localhost:3000"
echo "========================================"
