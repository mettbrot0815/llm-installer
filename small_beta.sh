#!/usr/bin/env bash
set -euo pipefail

echo "========================================"
echo "🚀 Qwopus-GLM-18B (Healed Q4_K_M) Installer"
echo "   Ubuntu 24.04 WSL2 | RTX 3060 12GB"
echo "   Context: 64K | TurboQuant + Flash Attention"
echo "========================================"

MODELS_DIR="/home/$USER/llm-models"
LLAMA_DIR="/home/$USER/turboquant-llama"
START_SCRIPT="/home/$USER/start-qwopus.sh"
PORT="8080"

# Healed model from KyleHessling1
MODEL_REPO="KyleHessling1/Qwopus-GLM-18B-Merged-GGUF"
MODEL_FILE="Qwopus-GLM-18B-Healed-Q4_K_M.gguf"
EXPECTED_SIZE_GB=9.2

# ---------------------------------------------
# 0. Sanitize PATH & Windows env vars (current session + permanent)
# ---------------------------------------------
sanitize_path_now() {
  local new_path=""
  local IFS=':'
  for dir in $PATH; do
    if [[ "$dir" != /mnt/* ]]; then
      new_path="${new_path:+$new_path:}$dir"
    fi
  done
  export PATH="$new_path"
  unset WSLENV USERPROFILE APPDATA LOCALAPPDATA HOMEDRIVE HOMEPATH
  echo "→ Windows paths & env vars removed for this session."
}

make_sanitizer_permanent() {
  local bashrc="$HOME/.bashrc"
  local profile="$HOME/.profile"
  local marker="# --- WSL SANITIZER (Windows binaries & env) ---"
  for rc in "$bashrc" "$profile"; do
    if [[ -f "$rc" ]] && ! grep -qF "$marker" "$rc"; then
      cat >> "$rc" << 'EOF'

# --- WSL SANITIZER (Windows binaries & env) ---
if [[ -n "$WSL_DISTRO_NAME" ]]; then
  NEW_PATH=""
  IFS=':' read -ra PATHS <<< "$PATH"
  for p in "${PATHS[@]}"; do
    if [[ "$p" != /mnt/* ]]; then
      NEW_PATH="${NEW_PATH:+$NEW_PATH:}$p"
    fi
  done
  export PATH="$NEW_PATH"
  unset WSLENV USERPROFILE APPDATA LOCALAPPDATA HOMEDRIVE HOMEPATH
fi
EOF
      echo "→ Sanitizer added to $rc"
    fi
  done
}

# ---------------------------------------------
# 1. System & CUDA 12.6
# ---------------------------------------------
setup_fresh_system() {
  echo "→ Updating system..."
  sudo apt-get update

  echo "→ Installing dependencies..."
  sudo apt-get install -y build-essential cmake git curl wget python3 python3-pip \
                          python3-venv linux-headers-generic ninja-build aria2

  echo "→ Installing CUDA 12.6 (WSL-optimised)..."
  local keyring_deb="/tmp/cuda-keyring_1.1-1_all.deb"
  wget -q -O "$keyring_deb" https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb
  sudo dpkg -i "$keyring_deb"
  rm -f "$keyring_deb"

  sudo apt-get update -qq
  sudo apt-get install -y cuda-toolkit-12-6

  cat << EOF | sudo tee /etc/profile.d/cuda.sh > /dev/null
export PATH=/usr/local/cuda-12.6/bin\${PATH:+:\${PATH}}
export LD_LIBRARY_PATH=/usr/local/cuda-12.6/lib64\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}
EOF

  export PATH="/usr/local/cuda-12.6/bin:${PATH:-}"
  export LD_LIBRARY_PATH="/usr/local/cuda-12.6/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  echo "✅ CUDA 12.6 ready."
}

# ---------------------------------------------
# 2. GCC 13
# ---------------------------------------------
install_gcc13() {
  echo "→ Checking GCC version..."
  if gcc --version | head -1 | grep -qE "13\."; then
    echo "✅ GCC 13 already default."
    return 0
  fi
  echo "→ Installing GCC 13..."
  sudo apt-get install -y gcc-13 g++-13
  sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-13 100
  sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-13 100
  echo "✅ GCC 13 set as default."
  gcc --version
}

# ---------------------------------------------
# 3. Patch CUDA math_functions.h (noexcept fix)
# ---------------------------------------------
patch_cuda_math() {
  local math_h
  math_h=$(find /usr/local/cuda-* -name "math_functions.h" -path "*/crt/math_functions.h" 2>/dev/null | head -1)
  if [[ -z "$math_h" ]]; then
    echo "⚠️  Could not find math_functions.h – skipping patch."
    return 0
  fi
  echo "📁 Found CUDA math header: $math_h"
  if grep -q "cospi(double x) noexcept(true)" "$math_h"; then
    echo "✅ CUDA header already patched."
    return 0
  fi
  echo "🔧 Creating backup and patching..."
  sudo cp "$math_h" "${math_h}.backup"
  sudo sed -i 's/\(cospi(double x)\);/\1 noexcept(true);/g' "$math_h"
  sudo sed -i 's/\(sinpi(double x)\);/\1 noexcept(true);/g' "$math_h"
  sudo sed -i 's/\(cospif(float x)\);/\1 noexcept(true);/g' "$math_h"
  sudo sed -i 's/\(sinpif(float x)\);/\1 noexcept(true);/g' "$math_h"
  sudo sed -i 's/\(rsqrt(double x)\);/\1 noexcept(true);/g' "$math_h"
  sudo sed -i 's/\(rsqrtf(float x)\);/\1 noexcept(true);/g' "$math_h"
  echo "✅ Patch applied successfully."
}

# ---------------------------------------------
# 4. Build TurboQuant llama.cpp (CarapaceUDE fork)
#    Only rebuilds on updates or missing binary
# ---------------------------------------------
build_turboquant() {
  cd "/home/$USER" || exit
  if [[ ! -d "$LLAMA_DIR" ]]; then
    echo "→ Cloning TurboQuant fork (CarapaceUDE/turboquant-llama)..."
    git clone https://github.com/CarapaceUDE/turboquant-llama.git "$LLAMA_DIR"
    cd "$LLAMA_DIR"
    NEED_BUILD=1
  else
    cd "$LLAMA_DIR"
    echo "→ Checking for updates..."
    git fetch --prune
    LOCAL=$(git rev-parse @)
    REMOTE=$(git rev-parse @{u} 2>/dev/null || echo "")
    if [[ -z "$REMOTE" ]]; then
      REMOTE="$LOCAL"
    fi
    if [[ "$LOCAL" != "$REMOTE" ]]; then
      echo "→ Update available (${LOCAL:0:7} → ${REMOTE:0:7}). Pulling..."
      git pull --ff-only
      NEED_BUILD=1
    elif [[ ! -f "build/bin/llama-server" ]]; then
      echo "→ Binary missing – rebuilding..."
      NEED_BUILD=1
    else
      echo "✅ Already up‑to‑date (${LOCAL:0:7}). Skipping rebuild."
      return 0
    fi
  fi
  if [[ -n "${NEED_BUILD:-}" ]]; then
    rm -rf build
    SAVED_PATH="$PATH"
    export PATH="/usr/local/cuda-12.6/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    cmake -B build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DGGML_CUDA=ON \
      -DGGML_CUDA_FA=ON \
      -DGGML_CUDA_FA_ALL_QUANTS=ON \
      -DGGML_CUDA_MMQ=ON \
      -DGGML_CUDA_GRAPHS=ON \
      -DGGML_NATIVE=ON \
      -DCMAKE_CUDA_ARCHITECTURES="86"
    echo "→ Building TurboQuant with CUDA (8‑12 minutes)..."
    cmake --build build --config Release -j "$(nproc)"
    export PATH="$SAVED_PATH"
    echo "✅ TurboQuant build completed!"
  fi
}

# ---------------------------------------------
# 5. Setup hfd for fast model downloads
# ---------------------------------------------
setup_hfd() {
  local hfd_script="/home/$USER/hfd.sh"
  if [[ ! -f "$hfd_script" ]]; then
    echo "→ Downloading hfd download tool..."
    wget -q https://hf-mirror.com/hfd/hfd.sh -O "$hfd_script"
    chmod a+x "$hfd_script"
    echo "✅ hfd installed."
  else
    echo "✅ hfd already installed."
  fi
}

# ---------------------------------------------
# 6. Download Healed model (fallback to wget if hfd fails)
# ---------------------------------------------
download_model() {
  local model_path="${MODELS_DIR}/${MODEL_FILE}"
  if [[ -f "$model_path" ]]; then
    local actual_size=$(du -b "$model_path" | cut -f1)
    local expected_bytes=$(echo "$EXPECTED_SIZE_GB * 1024 * 1024 * 1024" | bc | cut -d. -f1)
    if [[ $actual_size -gt $((expected_bytes - 500*1024*1024)) ]]; then
      echo "✅ Model already exists and appears complete: $model_path"
      return 0
    else
      echo "⚠️  Existing model file seems incomplete. Removing and re-downloading."
      rm -f "$model_path"
    fi
  fi
  echo ""
  echo "🚀 Downloading ${MODEL_FILE} using hfd (multi-threaded)..."
  echo "   Repository: ${MODEL_REPO}"
  echo "   File size: ~${EXPECTED_SIZE_GB} GB"
  mkdir -p "$MODELS_DIR"
  export HF_ENDPOINT=https://hf-mirror.com
  if ~/hfd.sh "$MODEL_REPO" --include "$MODEL_FILE" --local-dir "$MODELS_DIR" -x 10 --tool aria2c; then
    echo "✅ Model downloaded successfully via hfd!"
  else
    echo "❌ hfd download failed. Trying fallback with wget..."
    wget -c "https://huggingface.co/${MODEL_REPO}/resolve/main/${MODEL_FILE}" -O "$model_path"
    if [[ -f "$model_path" ]]; then
      echo "✅ Model downloaded via wget fallback."
    else
      echo "❌ Download failed. Please check your network and try again."
      exit 1
    fi
  fi
}

# ---------------------------------------------
# 7. Create start script with robust port killing
#    Uses ss (standard) to kill any process on PORT
# ---------------------------------------------
create_start_script() {
  cat > "$START_SCRIPT" << EOF
#!/usr/bin/env bash
cd ~/turboquant-llama

echo "🚀 Starting Qwopus-GLM-18B Healed (64K context | TurboQuant | RTX 3060 12GB)"
echo "   Model: ${MODEL_FILE}"
echo "   Context: 65536 tokens | KV Cache: turbo4 | Flash Attention: ON"

PORT=${PORT}
# Kill any process listening on TCP port \$PORT
if command -v ss &> /dev/null; then
    PIDS=\$(ss -tlnp | grep ":\$PORT" | grep -oP 'pid=\K[0-9]+' 2>/dev/null)
    if [ -n "\$PIDS" ]; then
        echo "Killing process(es) using port \$PORT: \$PIDS"
        echo "\$PIDS" | xargs -r sudo kill -9
    fi
elif command -v lsof &> /dev/null; then
    PIDS=\$(lsof -ti:\$PORT 2>/dev/null)
    if [ -n "\$PIDS" ]; then
        echo "Killing process(es) using port \$PORT: \$PIDS"
        echo "\$PIDS" | xargs -r sudo kill -9
    fi
else
    echo "⚠️  Neither ss nor lsof found. Cannot verify port \$PORT."
fi
sleep 1

./build/bin/llama-server \\
  -m ~/llm-models/${MODEL_FILE} \\
  -ngl 99 \\
  -c 65536 \\
  -b 1024 \\
  -ub 512 \\
  -ctk turbo4 \\
  -ctv turbo4 \\
  -fa on \\
  --temp 0.7 \\
  --top-p 0.95 \\
  --repeat-penalty 1.05 \\
  --host 0.0.0.0 \\
  --port ${PORT} \\
  --jinja \\
  --no-mmap \\
  --defrag-thold 0.1
EOF

  chmod +x "$START_SCRIPT"
  echo "✅ Start script created: ~/start-qwopus.sh"
}

# ---------------------------------------------
# 8. Print final instructions
# ---------------------------------------------
print_finish() {
  echo ""
  echo "========================================"
  echo "✅ Qwopus-GLM-18B Healed (Q4_K_M) installation complete!"
  echo "✅ TurboQuant + Flash Attention + 64K context configured."
  echo "✅ Windows binaries & environment blocked."
  echo ""
  echo "📦 Model location: ${MODELS_DIR}/${MODEL_FILE}"
  echo "🚀 Start server:    ~/start-qwopus.sh"
  echo "🌐 API endpoint:    http://localhost:${PORT}/v1"
  echo ""
  echo "💡 Tips:"
  echo "   - If you hit out-of-memory, reduce -c to 32768 or lower -ngl (e.g., -ngl 90)."
  echo "   - Monitor VRAM with: nvidia-smi"
  echo "   - The start script automatically kills any process on port ${PORT}."
  echo ""
  echo "To stop server: Press Ctrl+C"
  echo "========================================"
}

# ---------------------------------------------
# Main execution
# ---------------------------------------------
sanitize_path_now
setup_fresh_system
install_gcc13
patch_cuda_math
mkdir -p "$MODELS_DIR"
build_turboquant
setup_hfd
download_model
create_start_script
make_sanitizer_permanent
print_finish
