#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# =============================================================================
# small_install.sh — focused WSL2 RTX 3060 local LLM installer
# Installs CUDA toolkit, builds llama.cpp, downloads Harmonic Hermes, installs
# Open WebUI, creates a manual launcher, and configures systemd services.
# =============================================================================

if ((BASH_VERSINFO[0] < 4)); then
  echo "ERROR: Bash 4.0 or later is required (found ${BASH_VERSION})." >&2
  exit 1
fi

readonly APP_NAME="small_install.sh"
readonly MODELS_DIR="${HOME}/llm-models"
readonly MODEL_REPO="mradermacher/Harmonic-Hermes-9B-GGUF"
readonly MODEL_FILE="Harmonic-Hermes-9B-Q5_K_M.gguf"
readonly MODEL_URL="https://huggingface.co/${MODEL_REPO}/resolve/main/${MODEL_FILE}"
readonly LLAMA_DIR="${HOME}/llama.cpp"
readonly LLAMA_REPO="https://github.com/ggml-org/llama.cpp.git"
readonly HERMES_SCRIPT="${HOME}/start-hermes.sh"
readonly WEBUI_DIR="${HOME}/open-webui"
readonly WEBUI_DATA_DIR="${HOME}/.open-webui"
readonly PORT="8082"        # llama-server API port
readonly WEBUI_PORT="3000"  # Open WebUI port
readonly CUDA_VERSION="12.6"
readonly CUDA_KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb"

TMPFILES=()
cleanup() {
  local f
  for f in "${TMPFILES[@]}"; do
    [[ -n "$f" && -f "$f" ]] && rm -f -- "$f"
  done
}
register_tmp() { TMPFILES+=("$1"); }
trap cleanup EXIT

step() { printf '→ %s\n' "$*"; }
ok() { printf '✅ %s\n' "$*"; }
warn() { printf '⚠️  %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_command() {
  command -v "$1" &>/dev/null || die "Required command not found: $1"
}

is_wsl() {
  grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null
}

download_file() {
  local url="$1" dest="$2" label="$3"
  local tmp
  tmp=$(mktemp "/tmp/${APP_NAME}.${label}.XXXXXX") || die "Failed to create temp file for ${label}"
  register_tmp "$tmp"

  if command -v curl &>/dev/null; then
    curl -fL --proto '=https' --max-redirs 5 \
      --connect-timeout 15 --max-time 0 --retry 3 --retry-delay 2 \
      --progress-bar -o "$tmp" "$url" || die "Failed to download ${label}"
  elif command -v wget &>/dev/null; then
    wget --https-only --tries=3 --timeout=30 --show-progress -O "$tmp" "$url" || \
      die "Failed to download ${label}"
  else
    die "curl or wget is required to download ${label}"
  fi

  [[ -s "$tmp" ]] || die "Downloaded ${label} is empty"
  mkdir -p -- "$(dirname -- "$dest")"
  mv -f -- "$tmp" "$dest"
}

verify_shell_installer() {
  local script_path="$1" label="$2"
  [[ -s "$script_path" ]] || die "${label} installer is empty"
  if ! head -n 10 "$script_path" | grep -qE '(^#!|/bin/(env )?(ba)?sh|install|uv)'; then
    die "${label} installer does not look like a shell installer: ${script_path}"
  fi
}

check_disk_space() {
  local dir="$1" required_gib="$2"
  mkdir -p -- "$dir"
  local avail_kb avail_gib_int
  avail_kb=$(df -k "$dir" 2>/dev/null | awk 'NR==2 {print $4}')
  if [[ -z "$avail_kb" || ! "$avail_kb" =~ ^[0-9]+$ ]]; then
    warn "Could not determine free disk space for ${dir}; continuing."
    return 0
  fi
  avail_gib_int=$((avail_kb / 1024 / 1024))
  ((avail_gib_int >= required_gib)) || \
    die "Insufficient disk space in ${dir}: need ~${required_gib} GiB, have ~${avail_gib_int} GiB"
}

echo "========================================"
echo "🚀 Fresh Ubuntu 24.04 WSL2 + RTX 3060 12GB Installer"
echo "   CUDA ${CUDA_VERSION} + optimized llama.cpp + Hermes launcher + Open WebUI"
echo "========================================"

# ====================== 1. FULL SYSTEM & CUDA SETUP ======================
setup_fresh_system() {
  step "Updating system and installing dependencies..."

  if ! is_wsl; then
    warn "This script is optimized for WSL2, but /proc/version does not mention WSL. Continuing."
  fi

  sudo apt-get update -qq

  local -a packages=(
    build-essential
    ca-certificates
    cmake
    curl
    git
    linux-headers-generic
    pciutils
    python3
    python3-pip
    python3-venv
    wget
  )
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages[@]}"

  # Install CUDA toolkit for WSL. NVIDIA documents that WSL should use the
  # wsl-ubuntu CUDA repository and must not install Linux display drivers inside
  # WSL; cuda-toolkit-12-6 installs the SDK/toolkit without the driver package.
  if dpkg -s cuda-keyring &>/dev/null && dpkg -s cuda-toolkit-12-6 &>/dev/null; then
    ok "CUDA toolkit ${CUDA_VERSION} already installed; skipping."
  else
    step "Installing CUDA Toolkit ${CUDA_VERSION} for WSL..."
    local keyring_deb
    keyring_deb=$(mktemp /tmp/cuda-keyring.XXXXXX.deb) || die "Failed to create CUDA keyring temp file"
    register_tmp "$keyring_deb"
    download_file "$CUDA_KEYRING_URL" "$keyring_deb" "cuda-keyring"
    sudo dpkg -i "$keyring_deb"
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cuda-toolkit-12-6
  fi

  local cuda_home="/usr/local/cuda-${CUDA_VERSION}"
  [[ -d "$cuda_home" ]] || cuda_home="/usr/local/cuda"
  cat <<CUDA_PROFILE | sudo tee /etc/profile.d/cuda.sh >/dev/null
export PATH=${cuda_home}/bin\${PATH:+:\${PATH}}
export LD_LIBRARY_PATH=${cuda_home}/lib64\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}
CUDA_PROFILE

  export PATH="${cuda_home}/bin:${PATH}"
  export LD_LIBRARY_PATH="${cuda_home}/lib64:${LD_LIBRARY_PATH:-}"

  if command -v nvidia-smi &>/dev/null; then
    ok "NVIDIA GPU visible to WSL: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo detected)"
  else
    warn "nvidia-smi not found. CUDA toolkit can build llama.cpp, but runtime GPU access may fail until the Windows NVIDIA WSL driver is installed."
  fi

  ok "System dependencies and CUDA environment are ready."
}

# ====================== 2. AUTO TUNING FOR YOUR HARDWARE ======================
auto_tune_settings() {
  CTX="65536"
  NGL="94"
  BATCH="1024"
  UBATCH="512"

  if command -v nvidia-smi &>/dev/null; then
    local vram_mib
    vram_mib=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -dc '0-9' || true)
    if [[ -n "$vram_mib" && "$vram_mib" =~ ^[0-9]+$ && "$vram_mib" -lt 10000 ]]; then
      NGL="60"
      CTX="32768"
      warn "Detected <10 GiB VRAM; reducing context to ${CTX} and GPU layers to ${NGL}."
    fi
  fi

  ok "Auto-tuned settings: ctx=${CTX}, ngl=${NGL}, batch=${BATCH}, ubatch=${UBATCH}"
}

# ====================== 3. BUILD LLAMA.CPP ======================
build_llama() {
  step "Cloning/updating llama.cpp with CUDA support..."

  mkdir -p -- "$HOME"
  if [[ -d "$LLAMA_DIR" && ! -d "${LLAMA_DIR}/.git" ]]; then
    die "${LLAMA_DIR} exists but is not a Git repository. Move it aside or clone llama.cpp there."
  fi

  if [[ -d "${LLAMA_DIR}/.git" ]]; then
    local old_commit new_commit
    old_commit=$(git -C "$LLAMA_DIR" rev-parse HEAD)
    git -C "$LLAMA_DIR" fetch origin master
    git -C "$LLAMA_DIR" merge --ff-only origin/master
    new_commit=$(git -C "$LLAMA_DIR" rev-parse HEAD)

    if [[ "$old_commit" == "$new_commit" && -x "${LLAMA_DIR}/build/bin/llama-server" ]]; then
      ok "llama.cpp is already up to date (${new_commit:0:7}); skipping rebuild."
      return 0
    fi

    step "Building llama.cpp (${old_commit:0:7} → ${new_commit:0:7})..."
  else
    git clone "$LLAMA_REPO" "$LLAMA_DIR"
    step "Fresh llama.cpp clone created. Building..."
  fi

  cmake -S "$LLAMA_DIR" -B "${LLAMA_DIR}/build" \
    -DGGML_CUDA=ON \
    -DGGML_CUDA_FA_ALL_QUANTS=ON \
    -DGGML_NATIVE=ON \
    -DCMAKE_CUDA_ARCHITECTURES="86" \
    -DCMAKE_BUILD_TYPE=Release

  step "Compiling llama.cpp (this may take several minutes)..."
  cmake --build "${LLAMA_DIR}/build" --config Release -j "$(nproc)"
  [[ -x "${LLAMA_DIR}/build/bin/llama-server" ]] || die "llama-server was not produced by the build"

  ok "llama.cpp built successfully for RTX 3060-class CUDA hardware."
}

# ====================== 4. MODEL DOWNLOAD ======================
download_model() {
  mkdir -p -- "$MODELS_DIR"
  local model_path="${MODELS_DIR}/${MODEL_FILE}"

  if [[ -f "$model_path" ]]; then
    local size
    size=$(wc -c <"$model_path" 2>/dev/null || echo 0)
    if ((size >= 104857600)); then
      ok "Model already exists: ${model_path}"
      return 0
    fi
    warn "Existing model file is suspiciously small; re-downloading: ${model_path}"
    rm -f -- "$model_path"
  fi

  check_disk_space "$MODELS_DIR" 10
  step "Downloading ${MODEL_FILE} from Hugging Face..."

  local -a curl_args=(-fL --proto '=https' --max-redirs 5 --connect-timeout 15 --retry 3 --retry-delay 2 --progress-bar -C - -o "$model_path")
  [[ -n "${HF_TOKEN:-}" ]] && curl_args+=(-H "Authorization: Bearer ${HF_TOKEN}")
  curl "${curl_args[@]}" "$MODEL_URL" || die "Model download failed"

  local final_size
  final_size=$(wc -c <"$model_path" 2>/dev/null || echo 0)
  ((final_size >= 104857600)) || die "Downloaded model is suspiciously small (${final_size} bytes)"
  ok "Model downloaded to ${model_path}"
}

# ====================== 5. INSTALL UV + OPEN WEBUI ======================
install_uv() {
  export PATH="${HOME}/.local/bin:${PATH}"
  if command -v uv &>/dev/null; then
    ok "uv already installed: $(uv --version)"
    return 0
  fi

  step "Installing uv (Python package manager)..."
  local uv_installer
  uv_installer=$(mktemp /tmp/uv-installer.XXXXXX.sh) || die "Failed to create uv installer temp file"
  register_tmp "$uv_installer"
  download_file "https://astral.sh/uv/install.sh" "$uv_installer" "uv-installer"
  verify_shell_installer "$uv_installer" "uv"
  UV_NO_MODIFY_PATH=1 sh "$uv_installer"
  export PATH="${HOME}/.local/bin:${PATH}"
  require_command uv
  ok "uv installed: $(uv --version)"
}

install_openwebui() {
  install_uv
  mkdir -p -- "$WEBUI_DIR" "$WEBUI_DATA_DIR"
  cd -- "$WEBUI_DIR"

  if [[ ! -x ".venv/bin/python" ]]; then
    step "Creating Open WebUI virtual environment..."
    uv venv .venv --python 3.11
  fi

  step "Installing/updating Open WebUI via uv..."
  uv pip install --python .venv/bin/python --upgrade open-webui

  local installed
  installed=$(.venv/bin/python -m pip show open-webui 2>/dev/null | awk '/^Version:/ {print $2; exit}' || true)
  ok "Open WebUI ready in ${WEBUI_DIR}/.venv${installed:+ (version ${installed})}"
}

# ====================== 6. CREATE OPTIMIZED HERMES AGENT ======================
create_hermes_script() {
  auto_tune_settings

  if [[ -f "$HERMES_SCRIPT" ]]; then
    cp -f -- "$HERMES_SCRIPT" "${HERMES_SCRIPT}.backup.$(date +%Y%m%d%H%M%S)"
    warn "Existing Hermes launcher backed up before rewrite."
  fi

  cat >"$HERMES_SCRIPT" <<EOF_LAUNCHER
#!/usr/bin/env bash
set -euo pipefail

GGUF="${MODELS_DIR}/${MODEL_FILE}"
LLAMA_BIN="${LLAMA_DIR}/build/bin/llama-server"
PORT="${PORT}"

CTX="${CTX}"
NGL="${NGL}"
BATCH="${BATCH}"
UBATCH="${UBATCH}"

CACHE_K="q8_0"
CACHE_V="q4_0"
EXTRA_FLAGS="--no-mmap --defrag-thold 0.1"

[[ -f "\$GGUF" ]] || { echo "ERROR: model not found: \$GGUF" >&2; exit 1; }
[[ -x "\$LLAMA_BIN" ]] || { echo "ERROR: llama-server not found: \$LLAMA_BIN" >&2; exit 1; }

if command -v ss &>/dev/null && ss -tln 2>/dev/null | awk -v port=":\$PORT" '\$4 ~ port { found=1 } END { exit !found }'; then
  echo "ERROR: port \$PORT is already in use" >&2
  exit 1
fi

echo "🚀 Starting Hermes Agent (ctx=\${CTX} | ngl=\${NGL} | port=\${PORT})"

# shellcheck disable=SC2086
exec "\$LLAMA_BIN" \\
  -m "\$GGUF" \\
  -ngl "\$NGL" \\
  -fa on \\
  -b "\$BATCH" \\
  -ub "\$UBATCH" \\
  -c "\$CTX" \\
  --cache-type-k "\$CACHE_K" \\
  --cache-type-v "\$CACHE_V" \\
  --host 0.0.0.0 \\
  --port "\$PORT" \\
  --jinja \\
  \${EXTRA_FLAGS}
EOF_LAUNCHER

  chmod +x "$HERMES_SCRIPT"
  ok "Hermes launcher written: ${HERMES_SCRIPT}"
}

# ====================== 7. SETUP WSL2 AUTOSTART ======================
setup_autostart() {
  step "Setting up systemd services for llama-server and Open WebUI..."
  require_command systemctl
  auto_tune_settings

  sudo tee /etc/systemd/system/llama-server.service >/dev/null <<EOF_SERVICE
[Unit]
Description=llama.cpp server (Hermes Agent)
After=network.target

[Service]
Type=simple
User=${USER}
WorkingDirectory=${HOME}
Environment=PATH=/usr/local/cuda-${CUDA_VERSION}/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=LD_LIBRARY_PATH=/usr/local/cuda-${CUDA_VERSION}/lib64:/usr/local/cuda/lib64
ExecStart=${LLAMA_DIR}/build/bin/llama-server -m ${MODELS_DIR}/${MODEL_FILE} -ngl ${NGL} -fa on -b ${BATCH} -ub ${UBATCH} -c ${CTX} --cache-type-k q8_0 --cache-type-v q4_0 --host 0.0.0.0 --port ${PORT} --jinja --no-mmap --defrag-thold 0.1
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  sudo tee /etc/systemd/system/open-webui.service >/dev/null <<EOF_SERVICE
[Unit]
Description=Open WebUI
After=network.target llama-server.service
Requires=llama-server.service

[Service]
Type=simple
User=${USER}
WorkingDirectory=${WEBUI_DIR}
Environment=PATH=${HOME}/.local/bin:${WEBUI_DIR}/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=PORT=${WEBUI_PORT}
Environment=DATA_DIR=${WEBUI_DATA_DIR}
Environment=OPENAI_API_BASE_URL=http://localhost:${PORT}/v1
Environment=OPENAI_API_KEY=sk-placeholder
ExecStart=${WEBUI_DIR}/.venv/bin/open-webui serve --port ${WEBUI_PORT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  sudo systemctl daemon-reload
  sudo systemctl enable llama-server.service open-webui.service

  if ! grep -qE '^systemd=true$' /etc/wsl.conf 2>/dev/null; then
    step "Enabling systemd in /etc/wsl.conf..."
    local wsl_tmp
    wsl_tmp=$(mktemp /tmp/wsl-conf.XXXXXX) || die "Failed to create temporary wsl.conf"
    register_tmp "$wsl_tmp"
    python3 - <<'PY_WSL' >"$wsl_tmp"
from pathlib import Path
path = Path("/etc/wsl.conf")
text = path.read_text() if path.exists() else ""
lines = text.splitlines()
out = []
in_boot = False
boot_seen = False
systemd_set = False
for line in lines:
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        if in_boot and not systemd_set:
            out.append("systemd=true")
            systemd_set = True
        in_boot = stripped.lower() == "[boot]"
        boot_seen = boot_seen or in_boot
        out.append(line)
        continue
    if in_boot and stripped.startswith("systemd="):
        if not systemd_set:
            out.append("systemd=true")
            systemd_set = True
        continue
    out.append(line)
if in_boot and not systemd_set:
    out.append("systemd=true")
    systemd_set = True
if not boot_seen:
    if out and out[-1].strip():
        out.append("")
    out.extend(["[boot]", "systemd=true"])
print("\n".join(out) + "\n", end="")
PY_WSL
    sudo install -m 644 "$wsl_tmp" /etc/wsl.conf
    warn "systemd was just enabled. Run in PowerShell: wsl --shutdown, then reopen WSL."
  else
    ok "systemd already enabled in /etc/wsl.conf."
  fi

  sudo tee /etc/profile.d/llm-hint.sh >/dev/null <<EOF_HINT
case \$- in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac
cat <<'HINT_TEXT'

┌─────────────────────────────────────────────┐
│           LLM Stack Quick Reference         │
├─────────────────────────────────────────────┤
│  llama-server: sudo systemctl start llama-server │
│  llama logs  : journalctl -u llama-server -f     │
│  API         : http://localhost:${PORT}/v1        │
│  Open WebUI  : http://localhost:${WEBUI_PORT}     │
└─────────────────────────────────────────────┘

HINT_TEXT
EOF_HINT
  sudo chmod +x /etc/profile.d/llm-hint.sh

  ok "Autostart configured: llama-server=http://localhost:${PORT}/v1, Open WebUI=http://localhost:${WEBUI_PORT}"
}

# ====================== 8. MAIN MENU ======================
main_menu() {
  while true; do
    echo ""
    echo "========================================"
    echo "          RTX 3060 WSL2 Menu"
    echo "========================================"
    echo "1) Rebuild llama.cpp"
    echo "2) Download ${MODEL_FILE}"
    echo "3) Create/Update Hermes Agent script"
    echo "4) Start Hermes Agent (manual)"
    echo "5) Install / Update Open WebUI"
    echo "6) Setup autostart (llama-server + Open WebUI)"
    echo "7) Show service status"
    echo "8) Exit"
    read -rp "Choose [1-8]: " option

    case $option in
      1) build_llama ;;
      2) download_model ;;
      3) create_hermes_script ;;
      4)
        if [[ -x "$HERMES_SCRIPT" ]]; then
          "$HERMES_SCRIPT"
        else
          warn "Please run option 3 first."
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
      *) warn "Invalid option." ;;
    esac
  done
}

# ====================== EXECUTION STARTS HERE ======================
step "Starting focused installation on Ubuntu/WSL2..."
setup_fresh_system
mkdir -p -- "$MODELS_DIR"

build_llama
download_model
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
echo "   1. Open WebUI       → http://localhost:${WEBUI_PORT}"
echo "   2. llama-server API → http://localhost:${PORT}/v1"
echo "   3. Manual launcher  → ${HERMES_SCRIPT}"
echo ""
echo "Your RTX 3060 12GB is now optimized (65k context recommended)."

if [[ -t 0 ]]; then
  main_menu
else
  ok "Non-interactive shell detected; skipping menu."
fi
