#!/usr/bin/env bash
set -euo pipefail

echo "========================================"
echo "🚀 Fresh Ubuntu 24.04 WSL2 + RTX 3060 12GB Installer"
echo "   CUDA 12.6 (patched) + Carnice-9B Agent (128k Context)"
echo "   + Windows binaries & environment blocked"
echo "   + llama.cpp rebuilds only on updates"
echo "========================================"

MODELS_DIR="/home/$USER/llm-models"
LLAMA_DIR="/home/$USER/llama.cpp"
START_SCRIPT="/home/$USER/start-carnice.sh"
PORT="8080"

# ---------------------------------------------
# 0. Sanitize PATH and Windows env vars
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
  # Clean PATH
  NEW_PATH=""
  IFS=':' read -ra PATHS <<< "$PATH"
  for p in "${PATHS[@]}"; do
    if [[ "$p" != /mnt/* ]]; then
      NEW_PATH="${NEW_PATH:+$NEW_PATH:}$p"
    fi
  done
  export PATH="$NEW_PATH"

  # Remove Windows-specific environment variables
  unset WSLENV USERPROFILE APPDATA LOCALAPPDATA HOMEDRIVE HOMEPATH
fi
EOF
      echo "→ Sanitizer added to $rc"
    fi
  done
}

# ---------------------------------------------
# 1. System & CUDA 12.6 (stable)
# ---------------------------------------------
setup_fresh_system() {
  echo "→ Updating system..."
  sudo apt-get update

  echo "→ Installing dependencies..."
  sudo apt-get install -y build-essential cmake git curl wget python3 python3-pip \
                          python3-venv linux-headers-generic ninja-build

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
# 2. Install GCC 13 (compatible with CUDA)
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
# 3. Patch CUDA math_functions.h (fix noexcept conflict)
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
# 4. Build llama.cpp (only on updates)
# ---------------------------------------------
build_llama() {
  cd "/home/$USER" || exit

  if [[ ! -d "$LLAMA_DIR" ]]; then
    echo "→ Cloning llama.cpp..."
    git clone https://github.com/ggerganov/llama.cpp.git "$LLAMA_DIR"
    cd "$LLAMA_DIR"
    NEED_BUILD=1
  else
    cd "$LLAMA_DIR"
    echo "→ Checking for updates..."
    # Fetch latest without merging (to compare)
    git fetch --prune
    LOCAL=$(git rev-parse @)
    REMOTE=$(git rev-parse @{u} 2>/dev/null || echo "")
    if [[ -z "$REMOTE" ]]; then
      echo "⚠️  No upstream branch set – assuming no updates."
      REMOTE="$LOCAL"
    fi

    if [[ "$LOCAL" != "$REMOTE" ]]; then
      echo "→ Update available (${LOCAL:0:7} → ${REMOTE:0:7}). Pulling..."
      git pull --ff-only
      NEED_BUILD=1
    elif [[ ! -f "build/bin/llama-server" ]]; then
      echo "→ Build directory exists but binary missing – rebuilding..."
      NEED_BUILD=1
    else
      echo "✅ Already up‑to‑date (${LOCAL:0:7}). Skipping rebuild."
      return 0
    fi
  fi

  if [[ -n "${NEED_BUILD:-}" ]]; then
    rm -rf build

    # Isolate from Windows paths during build
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

    echo "→ Building llama.cpp (8‑12 minutes)..."
    cmake --build build --config Release -j "$(nproc)"

    export PATH="$SAVED_PATH"
    echo "✅ Build completed!"
  fi
}

# ---------------------------------------------
# 5. Create start script for Carnice-9B
# ---------------------------------------------
create_start_script() {
  cat > "$START_SCRIPT" << 'EOF'
#!/usr/bin/env bash
cd ~/llama.cpp

echo "🚀 Starting Carnice-9B Agent (128k context | optimised for RTX 3060)"

pkill -f "llama-server.*--port 8080" || true
sleep 1

./build/bin/llama-server \
  -m ~/llm-models/Carnice-9b-Q6_K.gguf \
  -ngl 94 \
  -c 131072 \
  -b 1024 \
  -ub 512 \
  --cache-type-k q8_0 \
  --cache-type-v q4_0 \
  --temp 0.7 \
  --top-p 0.95 \
  --repeat-penalty 1.05 \
  --host 0.0.0.0 \
  --port 8080 \
  --jinja \
  --flash-attn \
  --no-mmap \
  --defrag-thold 0.1
EOF

  chmod +x "$START_SCRIPT"
  echo "✅ Start script created: ~/start-carnice.sh"
}

# ---------------------------------------------
# 6. Model download instruction
# ---------------------------------------------
download_model() {
  if [[ -f "$MODELS_DIR/Carnice-9b-Q6_K.gguf" ]]; then
    echo "✅ Model already exists."
  else
    echo ""
    echo "📥 Download the Carnice-9b-Q6_K model with:"
    echo ""
    echo "mkdir -p $MODELS_DIR && wget -c 'https://huggingface.co/kai-os/Carnice-9b-GGUF/resolve/main/Carnice-9b-Q6_K.gguf?download=true' -O $MODELS_DIR/Carnice-9b-Q6_K.gguf"
    echo ""
    read -rp "Press Enter after downloading (or Ctrl+C to exit)..."
  fi
}

# ---------------------------------------------
# 7. Main execution
# ---------------------------------------------
sanitize_path_now
setup_fresh_system
install_gcc13
patch_cuda_math
mkdir -p "$MODELS_DIR"
build_llama
create_start_script
download_model
make_sanitizer_permanent

echo ""
echo "========================================"
echo "✅ Installation complete – no CUDA/glibc conflicts!"
echo "✅ Windows binaries (node, npm, python, git, ...) blocked."
echo "✅ Windows environment variables (WSLENV, APPDATA, ...) removed."
echo "✅ llama.cpp rebuilds ONLY when 'git pull' fetches new commits."
echo ""
echo "Next steps:"
echo "  1. Download the model if not yet done (see above)"
echo "  2. Close and reopen your WSL terminal"
echo "  3. Start the server:   ~/start-carnice.sh"
echo "  4. API endpoint:       http://localhost:${PORT}/v1"
echo ""
echo "To stop: Press Ctrl+C"
echo "========================================"
