#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

if ((BASH_VERSINFO[0] < 4)); then
  echo "ERROR: Bash 4+ required (found ${BASH_VERSION})." >&2
  exit 1
fi

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'
step(){ echo -e "${CYN}[*] $*${RST}"; }
ok(){ echo -e "${GRN}[+] $*${RST}"; }
warn(){ echo -e "${YLW}[!] $*${RST}"; }
die(){ echo -e "${RED}[ERROR] $*${RST}"; exit 1; }
skip(){ echo -e "${CYN}[~] $*${RST}"; }

readonly INSTALLER_VERSION="2026.04.26"
readonly APP_DIR="${HOME}/llm-installer"
readonly LLAMA_DIR="${APP_DIR}/llama.cpp"
readonly MODELS_DIR="${APP_DIR}/models"
readonly BIN_DIR="${LLAMA_DIR}/build/bin"
readonly CFG_DIR="${HOME}/.llm-installer"
readonly CFG_FILE="${CFG_DIR}/config"
readonly VERSION_FILE="${HOME}/.llm-versions"
readonly START_SCRIPT="${APP_DIR}/start-llm.sh"
readonly DEFAULT_PORT=8080

mkdir -p "${APP_DIR}" "${MODELS_DIR}" "${CFG_DIR}"
touch "${VERSION_FILE}"

PORT="${DEFAULT_PORT}"
MODEL_ID=""
MODEL_FILE=""
MODEL_REPO=""
MODEL_CTX="131072"
SAMPLING_TEMP="0.7"
SAMPLING_TOP_P="0.95"
SAMPLING_MIN_P="0.0"
KV_PREF="auto"
UI_CHOICE="none"
BUILD_BACKEND="cuda"

GPU_VENDOR="cpu"
GPU_NAME="CPU-only"
GPU_VRAM_GB=0
SYS_RAM_GB=0
GPU_GEN="unknown"
NGPU=0

_read_version(){ grep -F "^$1=" "${VERSION_FILE}" 2>/dev/null | head -1 | cut -d'=' -f2- || true; }
_write_version(){
  local k="$1" v="$2" tmp
  tmp=$(mktemp)
  awk -F= -v k="$k" -v v="$v" 'BEGIN{f=0} $1==k{$0=k"="v;f=1} {print} END{if(!f) print k"="v}' "${VERSION_FILE}" >"${tmp}"
  mv -f "${tmp}" "${VERSION_FILE}"
  chmod 600 "${VERSION_FILE}"
}

load_config(){
  [[ -f "${CFG_FILE}" ]] || return 0
  # shellcheck source=/dev/null
  source "${CFG_FILE}"
  PORT="${PORT:-$DEFAULT_PORT}"
  SAMPLING_TEMP="${SAMPLING_TEMP:-0.7}"
  SAMPLING_TOP_P="${SAMPLING_TOP_P:-0.95}"
  SAMPLING_MIN_P="${SAMPLING_MIN_P:-0.0}"
  KV_PREF="${KV_PREF:-auto}"
  UI_CHOICE="${UI_CHOICE:-none}"
  MODEL_ID="${MODEL_ID:-}"
  MODEL_FILE="${MODEL_FILE:-}"
  MODEL_REPO="${MODEL_REPO:-}"
  MODEL_CTX="${MODEL_CTX:-131072}"
}

save_config(){
  cat > "${CFG_FILE}" <<EOF
PORT=${PORT}
MODEL_ID=${MODEL_ID}
MODEL_FILE=${MODEL_FILE}
MODEL_REPO=${MODEL_REPO}
MODEL_CTX=${MODEL_CTX}
SAMPLING_TEMP=${SAMPLING_TEMP}
SAMPLING_TOP_P=${SAMPLING_TOP_P}
SAMPLING_MIN_P=${SAMPLING_MIN_P}
KV_PREF=${KV_PREF}
UI_CHOICE=${UI_CHOICE}
BUILD_BACKEND=${BUILD_BACKEND}
EOF
  chmod 600 "${CFG_FILE}"
}

need_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

install_base_deps(){
  step "Installing base dependencies"
  sudo apt-get update -y
  sudo apt-get install -y git curl ca-certificates build-essential cmake pkg-config jq bc lsof whiptail python3 python3-venv software-properties-common
}

detect_hardware(){
  step "Detecting hardware"
  SYS_RAM_GB=$(free -g | awk '/^Mem:/ {print $2}')
  if command -v nvidia-smi >/dev/null 2>&1; then
    GPU_VENDOR="nvidia"
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1 | sed 's/,.*//')
    GPU_VRAM_GB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | awk 'NR==1{sum=0} {sum+=$1} END{printf "%d", (sum/1024)}')
    NGPU=$(nvidia-smi -L | wc -l)
    if [[ "${GPU_NAME}" =~ 50[0-9]{2} || "${GPU_NAME}" =~ Blackwell ]]; then GPU_GEN="blackwell";
    elif [[ "${GPU_NAME}" =~ 40[0-9]{2} || "${GPU_NAME}" =~ Ada ]]; then GPU_GEN="ada";
    elif [[ "${GPU_NAME}" =~ 30[0-9]{2} || "${GPU_NAME}" =~ Ampere ]]; then GPU_GEN="ampere";
    else GPU_GEN="nvidia"; fi
  elif lspci | grep -qiE 'AMD|Radeon'; then
    GPU_VENDOR="amd"
    GPU_NAME=$(lspci | grep -iE 'VGA|3D' | grep -iE 'AMD|Radeon' | head -1 | sed 's/^.*: //')
    GPU_VRAM_GB=0
    NGPU=$(lspci | grep -ciE 'AMD|Radeon')
    GPU_GEN="rdna"
  else
    GPU_VENDOR="cpu"; GPU_NAME="CPU-only"; GPU_VRAM_GB=0; NGPU=0; GPU_GEN="cpu"
  fi
  ok "GPU: ${GPU_NAME} (${GPU_VENDOR}, gen=${GPU_GEN}, approx VRAM=${GPU_VRAM_GB}GB, gpus=${NGPU})"
  ok "System RAM: ${SYS_RAM_GB}GB"
}

detect_cuda_root(){
  local root=""
  if command -v nvcc >/dev/null 2>&1; then
    root="$(dirname "$(dirname "$(command -v nvcc)")")"
  fi
  if [[ -z "${root}" || ! -d "${root}/include" || ! -d "${root}/lib64" ]]; then
    for cand in /usr/local/cuda /usr/local/cuda-13.1 /usr/local/cuda-13.0 /usr/local/cuda-12.9 /usr/local/cuda-12.8 /opt/cuda; do
      if [[ -d "${cand}/include" && -d "${cand}/lib64" ]]; then
        root="${cand}"
        break
      fi
    done
  fi
  echo "${root}"
}

detect_nvcc_bin(){
  local bin=""
  if command -v nvcc >/dev/null 2>&1; then
    bin="$(command -v nvcc)"
    if "${bin}" --version 2>/dev/null | grep -qi 'Cuda compilation tools'; then
      echo "${bin}"
      return 0
    fi
  fi
  for cand in /usr/local/cuda/bin/nvcc /usr/local/cuda-13.1/bin/nvcc /usr/local/cuda-13.0/bin/nvcc /usr/local/cuda-12.9/bin/nvcc /usr/local/cuda-12.8/bin/nvcc; do
    if [[ -x "${cand}" ]] && "${cand}" --version 2>/dev/null | grep -qi 'Cuda compilation tools'; then
      echo "${cand}"
      return 0
    fi
  done
  echo ""
}

ensure_cuda_toolkit(){
  [[ "${GPU_VENDOR}" == "nvidia" ]] || return 0
  step "Validating CUDA Toolkit for llama.cpp (CUDAToolkit + CUDA_CUDART)"

  local cuda_root
  cuda_root="$(detect_cuda_root)"
  if [[ -n "${cuda_root}" && -f "${cuda_root}/include/cuda_runtime.h" ]] && compgen -G "${cuda_root}/lib64/libcudart.so*" >/dev/null; then
    ok "CUDA toolkit detected at ${cuda_root}"
    return 0
  fi

  warn "CUDA runtime components not fully detected; installing CUDA toolkit packages (12.8+ preferred)"
  sudo apt-get update -y
  sudo apt-get install -y nvidia-cuda-toolkit || true

  cuda_root="$(detect_cuda_root)"
  if [[ -z "${cuda_root}" || ! -f "${cuda_root}/include/cuda_runtime.h" ]] || ! compgen -G "${cuda_root}/lib64/libcudart.so*" >/dev/null; then
    warn "CUDA toolkit still incomplete; CUDA build may fail, CPU fallback is armed"
    GPU_VENDOR="cpu"
    GPU_GEN="cpu"
    return 0
  fi

  if [[ ! -e /usr/local/cuda ]]; then
    sudo ln -s "${cuda_root}" /usr/local/cuda || true
  fi
  ok "CUDA toolkit ready: ${cuda_root}"
}

build_llama_cpp(){
  step "Installing/Updating llama.cpp"
  if [[ ! -d "${LLAMA_DIR}/.git" ]]; then
    git clone https://github.com/ggml-org/llama.cpp.git "${LLAMA_DIR}"
  fi
  (
    cd "${LLAMA_DIR}"
    git fetch --tags origin
    local_remote=$(git rev-parse origin/master)
    local_installed=$(_read_version llama_cpp_commit)
    if [[ "${local_installed}" == "${local_remote}" ]]; then
      skip "llama.cpp already current (${local_remote:0:8})"
      return
    fi
    git checkout master
    git reset --hard origin/master

    local cmake_flags="-DGGML_NATIVE=ON -DGGML_OPENMP=ON -DGGML_CUDA=OFF -DGGML_VULKAN=OFF"
    local cuda_root=""
    local nvcc_bin=""
    case "${GPU_VENDOR}" in
      nvidia)
        ensure_cuda_toolkit
        if [[ "${GPU_VENDOR}" != "nvidia" ]]; then
          BUILD_BACKEND="cpu"
        else
          BUILD_BACKEND="cuda"
          cuda_root="$(detect_cuda_root)"
          nvcc_bin="$(detect_nvcc_bin)"
          if [[ -z "${nvcc_bin}" ]]; then
            warn "No valid nvcc compiler detected; forcing CPU backend to avoid gcc CUDA flag errors"
            BUILD_BACKEND="cpu"
          else
            cmake_flags+=" -DGGML_CUDA=ON"
          fi
          [[ -n "${cuda_root}" ]] && cmake_flags+=" -DCUDAToolkit_ROOT=${cuda_root}"
          [[ -n "${nvcc_bin}" ]] && cmake_flags+=" -DCMAKE_CUDA_COMPILER=${nvcc_bin}"
          cmake_flags+=" -DCMAKE_CUDA_ARCHITECTURES=native"
        fi
        ;;
      amd)
        BUILD_BACKEND="vulkan"
        cmake_flags+=" -DGGML_VULKAN=ON"
        ;;
      *)
        BUILD_BACKEND="cpu"
        ;;
    esac

    rm -rf build
    if ! cmake -S . -B build ${cmake_flags}; then
      if [[ "${BUILD_BACKEND}" == "cuda" ]]; then
        warn "CUDA CMake configure failed (likely missing CUDA_CUDART). Retrying with CPU fallback."
        BUILD_BACKEND="cpu"
        cmake -S . -B build -DGGML_NATIVE=ON -DGGML_OPENMP=ON
      else
        die "CMake configure failed"
      fi
    fi
    if ! cmake --build build -j"$(nproc)"; then
      if [[ "${BUILD_BACKEND}" == "cuda" ]]; then
        warn "CUDA build failed (e.g. nvcc/gcc flag mismatch such as -compress-mode=size). Retrying with CPU fallback."
        rm -rf build
        BUILD_BACKEND="cpu"
        cmake -S . -B build -DGGML_NATIVE=ON -DGGML_OPENMP=ON
        cmake --build build -j"$(nproc)"
      else
        die "Build failed"
      fi
    fi
    _write_version llama_cpp_commit "${local_remote}"
  )
  [[ -x "${BIN_DIR}/llama-server" ]] || die "llama-server build failed"
  ok "llama.cpp ready"
}

# id|full_name|repo|gguf|ctx|vram_q4|vram_q5|tags
MODELS=(
"qwen35_7b|Qwen 3.5 7B Instruct – Fast Daily Chat|bartowski/Qwen3.5-7B-Instruct-GGUF|Qwen3.5-7B-Instruct-Q5_K_M.gguf|131072|6|7|chat,reasoning"
"qwen35_9b|Qwen 3.5 9B Instruct – Better Small Generalist|bartowski/Qwen3.5-9B-Instruct-GGUF|Qwen3.5-9B-Instruct-Q5_K_M.gguf|131072|7|8|chat,reasoning"
"gemma4_9b|Gemma 4 9B It – Compact High Quality|unsloth/gemma-4-9b-it-GGUF|gemma-4-9b-it-Q5_K_M.gguf|131072|7|8|chat,multimodal"
"gemma4_12b|Gemma 4 12B It – Balanced Quality|bartowski/gemma-4-12b-it-GGUF|gemma-4-12b-it-Q5_K_M.gguf|131072|9|11|chat,multimodal"
"phi4_14b|Phi-4 14B Instruct – Efficient Reasoning|bartowski/Phi-4-14B-GGUF|Phi-4-14B-Q5_K_M.gguf|65536|10|12|chat,reasoning,code"
"ministral8b|Ministral 8B Instruct – Fast Mistral Family|bartowski/Ministral-8B-Instruct-GGUF|Ministral-8B-Instruct-Q5_K_M.gguf|131072|6|7|chat,agent"
"ministral14b|Ministral 14B Instruct – Strong Midrange|bartowski/Ministral-14B-Instruct-GGUF|Ministral-14B-Instruct-Q5_K_M.gguf|131072|10|12|chat,reasoning"
"qwen35_27b|Qwen 3.5 27B Instruct – 24GB Sweet Spot|bartowski/Qwen3.5-27B-Instruct-GGUF|Qwen3.5-27B-Instruct-Q4_K_M.gguf|131072|17|21|chat,reasoning,agent"
"qwen35_32b|Qwen 3.5 32B Instruct – Premium Midrange|bartowski/Qwen3.5-32B-Instruct-GGUF|Qwen3.5-32B-Instruct-Q4_K_M.gguf|131072|19|23|chat,reasoning"
"gemma4_26b_moe|Gemma 4 26B-A3B It (MoE) – Creative + Efficient|mradermacher/gemma-4-26b-a3b-it-GGUF|gemma-4-26b-a3b-it.Q4_K_M.gguf|131072|18|22|chat,MoE,multimodal"
"gemma4_27b_moe|Gemma 4 27B-A4B It (MoE) – Strong Creative & Multimodal|bartowski/Gemma-4-27B-A4B-It-GGUF|Gemma-4-27B-A4B-It-Q4_K_M.gguf|131072|19|23|chat,MoE,multimodal"
"qwen3_30b_a3b|Qwen 3 30B-A3B Instruct (MoE) – Efficient Agentic|bartowski/Qwen3-30B-A3B-Instruct-GGUF|Qwen3-30B-A3B-Instruct-Q4_K_M.gguf|131072|20|24|chat,agent,MoE"
"r1_distill_32b|DeepSeek R1 Distill Qwen 32B – Compact Reasoner|bartowski/DeepSeek-R1-Distill-Qwen-32B-GGUF|DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf|65536|19|23|reasoning,code"
"glm47_32b|GLM-4.7 32B Instruct – Multilingual Workhorse|bartowski/GLM-4.7-32B-Instruct-GGUF|GLM-4.7-32B-Instruct-Q4_K_M.gguf|131072|19|23|chat,agent"
"glm5_34b|GLM-5 34B Instruct – Advanced Tool Use|bartowski/GLM-5-34B-Instruct-GGUF|GLM-5-34B-Instruct-Q4_K_M.gguf|131072|21|25|chat,agent,reasoning"
"qwen36_35b_a3b|Qwen 3.6 35B-A3B Instruct (MoE) – Best Reasoning & Efficiency|bartowski/Qwen3.6-35B-A3B-Instruct-GGUF|Qwen3.6-35B-A3B-Instruct-Q4_K_M.gguf|131072|22|26|reasoning,agent,MoE"
"qwen3_coder_32b|Qwen3-Coder 32B – Top Coding Agent|bartowski/Qwen3-Coder-32B-Instruct-GGUF|Qwen3-Coder-32B-Instruct-Q4_K_M.gguf|131072|19|23|code,agent,reasoning"
"mistral_large3|Mistral Large 3 123B MoE – Frontier Generalist|bartowski/Mistral-Large-3-Instruct-GGUF|Mistral-Large-3-Instruct-Q4_K_M.gguf|131072|48|58|chat,MoE,reasoning"
"mistral_large3_1|Mistral Large 3.1 123B MoE – Improved Reasoning|bartowski/Mistral-Large-3.1-Instruct-GGUF|Mistral-Large-3.1-Instruct-Q4_K_M.gguf|131072|50|60|chat,MoE,reasoning"
"deepseek_v32|DeepSeek V3.2 671B MoE – Frontier Reasoning|bartowski/DeepSeek-V3.2-GGUF|DeepSeek-V3.2-Q4_K_M.gguf|131072|180|220|reasoning,agent,MoE"
"llama4_maverick|Llama 4 Maverick 400B MoE – Heavy Frontier Agent|bartowski/Llama-4-Maverick-GGUF|Llama-4-Maverick-Q4_K_M.gguf|262144|120|155|agent,MoE,long-context"
"llama4_scout|Llama 4 Scout 109B MoE – Extreme Long Context (1M+)|bartowski/Llama-4-Scout-GGUF|Llama-4-Scout-Q4_K_M.gguf|262144|56|70|long-context,MoE,reasoning"
"minimax_m27|MiniMax M2.7 120B MoE – Long-Context Utility|bartowski/MiniMax-M2.7-Instruct-GGUF|MiniMax-M2.7-Instruct-Q4_K_M.gguf|262144|60|74|long-context,MoE,chat"
"qwen35_35b_a3b|Qwen 3.5 35B-A3B Instruct (MoE) – Premium Local Default|bartowski/Qwen3.5-35B-A3B-Instruct-GGUF|Qwen3.5-35B-A3B-Instruct-Q4_K_M.gguf|131072|22|27|reasoning,agent,MoE"
)

grade_model(){
  local q4="$1" q5="$2" req
  req=$q5
  (( GPU_VRAM_GB < q5 )) && req=$q4
  if (( GPU_VRAM_GB >= req + 4 )); then echo "S";
  elif (( GPU_VRAM_GB >= req )); then echo "A";
  elif (( GPU_VRAM_GB + 4 >= req )); then echo "B";
  elif (( GPU_VRAM_GB + 8 >= req )); then echo "C";
  else echo "F"; fi
}

auto_recommend_quant(){
  local q4="$1" q5="$2"
  if (( GPU_VRAM_GB >= q5 + 2 )); then echo "Q5_K_M"; else echo "Q4_K_M"; fi
}

show_model_table(){
  printf "\n${BLD}%-3s %-62s %-5s %-10s %-26s %s${RST}\n" "#" "Full Name" "Grade" "Context" "Tags" "VRAM Q4/Q5"
  printf '%*s\n' 130 '' | tr ' ' '-'
  local i=1
  for row in "${MODELS[@]}"; do
    IFS='|' read -r id name repo gguf ctx q4 q5 tags <<<"$row"
    local g
    g=$(grade_model "$q4" "$q5")
    printf "%-3s %-62.62s %-5s %-10s %-26.26s %s/%s GB\n" "$i" "$name" "$g" "${ctx}" "$tags" "$q4" "$q5"
    ((i++))
  done
  printf "u   %-62s\n" "Custom Hugging Face GGUF"
}

suggest_model_tier(){
  if ((GPU_VRAM_GB >= 48)); then echo "Large frontier MoE tier recommended (35B+ MoE / 100B+ partial split).";
  elif ((GPU_VRAM_GB >= 24)); then echo "Mid-high tier recommended (27B–35B, mostly Q5/Q4).";
  elif ((GPU_VRAM_GB >= 16)); then echo "Sweet spot tier recommended (14B–32B Q4).";
  elif ((GPU_VRAM_GB >= 10)); then echo "Compact tier recommended (9B–14B).";
  else echo "Small tier recommended (7B–9B or CPU offload)."; fi
}

select_model(){
  step "Model selection"
  echo "Hardware recommendation: $(suggest_model_tier)"
  show_model_table
  read -r -p "Choose model number or 'u' for custom [default: last saved or 1]: " choice
  if [[ -z "${choice}" ]]; then
    if [[ -n "${MODEL_ID}" ]]; then
      ok "Keeping saved model: ${MODEL_ID}"
      return
    fi
    choice=1
  fi

  if [[ "${choice}" == "u" ]]; then
    read -r -p "HF repo (user/repo): " MODEL_REPO
    read -r -p "GGUF filename: " MODEL_FILE
    read -r -p "Context size (e.g. 131072): " MODEL_CTX
    MODEL_ID="custom"
    return
  fi

  [[ "${choice}" =~ ^[0-9]+$ ]] || die "Invalid selection"
  ((choice>=1 && choice<=${#MODELS[@]})) || die "Selection out of range"
  IFS='|' read -r MODEL_ID model_name MODEL_REPO MODEL_FILE MODEL_CTX q4 q5 tags <<<"${MODELS[$((choice-1))]}"
  local rq
  rq=$(auto_recommend_quant "$q4" "$q5")
  MODEL_FILE="${MODEL_FILE/Q4_K_M/${rq}}"
  MODEL_FILE="${MODEL_FILE/Q5_K_M/${rq}}"
  ok "Selected: ${model_name} (${rq}, ctx=${MODEL_CTX})"
}

ensure_hf_cli(){
  if ! command -v huggingface-cli >/dev/null 2>&1; then
    step "Installing huggingface_hub cli"
    python3 -m pip install --user --upgrade huggingface_hub[cli]
    export PATH="${HOME}/.local/bin:${PATH}"
  fi
}

download_model(){
  step "Ensuring model file exists"
  local model_path="${MODELS_DIR}/${MODEL_FILE}"
  if [[ -f "${model_path}" ]]; then
    ok "Model already present: ${model_path}"
    return
  fi
  ensure_hf_cli
  step "Downloading ${MODEL_REPO}/${MODEL_FILE}"
  huggingface-cli download "${MODEL_REPO}" "${MODEL_FILE}" --local-dir "${MODELS_DIR}" --local-dir-use-symlinks False
  [[ -f "${model_path}" ]] || die "Model download failed"
  ok "Model downloaded"
}

list_models(){
  step "Installed models"
  find "${MODELS_DIR}" -maxdepth 1 -type f -name '*.gguf' -printf '%f\n' | nl -w2 -s'. '
}

delete_model(){
  list_models || true
  read -r -p "Enter exact GGUF filename to delete (or empty to skip): " file
  [[ -z "${file}" ]] && return
  rm -f "${MODELS_DIR}/${file}"
  ok "Deleted ${file}"
}

update_checks(){
  step "Checking for installer and llama.cpp updates"
  local remote_installer
  remote_installer=$(curl -fsSL https://raw.githubusercontent.com/mettbrot0815/llm-installer/refs/heads/main/install.sh | sha256sum | awk '{print $1}')
  local local_installer
  local_installer=$(sha256sum "$0" | awk '{print $1}')
  if [[ "${remote_installer}" != "${local_installer}" ]]; then warn "Installer update available"; else ok "Installer appears current"; fi
  if [[ -d "${LLAMA_DIR}/.git" ]]; then
    (
      cd "${LLAMA_DIR}"
      git fetch -q origin
      local h l
      l=$(git rev-parse HEAD)
      h=$(git rev-parse origin/master)
      [[ "$l" == "$h" ]] && ok "llama.cpp up to date" || warn "llama.cpp update available"
    )
  fi
}

supports_cache_type(){
  local cache="$1"
  "${BIN_DIR}/llama-server" --help 2>&1 | grep -q -- "${cache}"
}

apply_model_settings(){
  local n_ctx="$MODEL_CTX" batch ubatch ngl kvk kvv extra=""
  local q_backend="${GPU_VENDOR}"

  ngl=999
  batch=512
  ubatch=256

  if [[ "${q_backend}" == "nvidia" ]]; then
    case "${GPU_GEN}" in
      blackwell) batch=2048; ubatch=1024;;
      ada)       batch=1536; ubatch=768;;
      ampere)    batch=1024; ubatch=512;;
      *)         batch=1024; ubatch=512;;
    esac
  elif [[ "${q_backend}" == "amd" ]]; then
    batch=1024; ubatch=512
  else
    ngl=0; batch=256; ubatch=128
  fi

  kvk="q8_0"; kvv="q8_0"
  if [[ "${KV_PREF}" == "aggressive" ]] || ((GPU_VRAM_GB>0 && GPU_VRAM_GB < 16)); then
    kvk="q8_0"; kvv="turbo4"
  fi
  if [[ "${KV_PREF}" == "memory" ]]; then
    kvk="turbo4"; kvv="turbo4"
  fi

  if ! supports_cache_type "${kvk}" || ! supports_cache_type "${kvv}"; then
    warn "Requested KV cache type unsupported by build; falling back to q8_0"
    kvk="q8_0"; kvv="q8_0"
  fi

  if [[ "${MODEL_ID}" == *"moe"* || "${MODEL_ID}" == deepseek_v32 || "${MODEL_ID}" == llama4_* || "${MODEL_ID}" == minimax_m27 || "${MODEL_ID}" == mistral_large3* ]]; then
    extra+=" -n-cpu-moe 1"
  fi

  if (( n_ctx > 262144 )); then
    warn "Very high context (${n_ctx}) needs substantial RAM/VRAM and may be slower"
  fi

  LLAMA_FLAGS="--jinja --no-mmap --flash-attn -ngl ${ngl} --ctx-size ${n_ctx} --batch-size ${batch} --ubatch-size ${ubatch} --cache-type-k ${kvk} --cache-type-v ${kvv} --temp ${SAMPLING_TEMP} --top-p ${SAMPLING_TOP_P} --min-p ${SAMPLING_MIN_P} --parallel 1 ${extra}"
}

setup_start_script(){
  apply_model_settings
  local model_path="${MODELS_DIR}/${MODEL_FILE}"
  cat > "${START_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
APP_DIR="${APP_DIR}"
BIN="${BIN_DIR}/llama-server"
MODEL="${model_path}"
PORT="${PORT}"
PID_FILE="${APP_DIR}/llama-server.pid"
LOG_FILE="${APP_DIR}/llama-server.log"
FLAGS='${LLAMA_FLAGS}'

if [[ ! -x "\${BIN}" ]]; then
  echo "llama-server not found: \${BIN}" >&2
  exit 1
fi
if [[ ! -f "\${MODEL}" ]]; then
  echo "Model missing: \${MODEL}" >&2
  exit 1
fi

if [[ -f "\${PID_FILE}" ]] && kill -0 "$(cat "\${PID_FILE}")" 2>/dev/null; then
  echo "Stopping existing llama-server PID $(cat "\${PID_FILE}")"
  kill "$(cat "\${PID_FILE}")" || true
  sleep 1
fi

if lsof -iTCP:"\${PORT}" -sTCP:LISTEN -t >/dev/null 2>&1; then
  old_pid="$(lsof -iTCP:"\${PORT}" -sTCP:LISTEN -t | head -1)"
  echo "Port \${PORT} busy by PID \${old_pid}; terminating"
  kill "\${old_pid}" || true
  sleep 1
fi

nohup "\${BIN}" -m "\${MODEL}" --port "\${PORT}" \${FLAGS} >"\${LOG_FILE}" 2>&1 &
echo $! > "\${PID_FILE}"
echo "llama-server started on port \${PORT} (PID $(cat "\${PID_FILE}"))"
echo "Log: \${LOG_FILE}"
EOF
  chmod +x "${START_SCRIPT}"
}

setup_bash_helpers(){
  local rc="${HOME}/.bashrc"
  touch "$rc"
  grep -q 'alias start-llm=' "$rc" || echo "alias start-llm='${START_SCRIPT}'" >> "$rc"
  grep -q 'alias stop-llm=' "$rc" || cat >> "$rc" <<'EOF'
alias stop-llm='if [[ -f ~/llm-installer/llama-server.pid ]]; then kill $(cat ~/llm-installer/llama-server.pid) 2>/dev/null || true; rm -f ~/llm-installer/llama-server.pid; fi'
EOF
}

setup_systemd(){
  if [[ "$(ps -p 1 -o comm=)" != "systemd" ]]; then
    warn "Systemd not active; skipping service setup"
    return
  fi
  mkdir -p "${HOME}/.config/systemd/user"
  cat > "${HOME}/.config/systemd/user/llm-installer.service" <<EOF
[Unit]
Description=llama.cpp local inference server
After=network.target

[Service]
Type=simple
ExecStart=${START_SCRIPT}
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  ok "Systemd user service ready: llm-installer.service"
}

install_optional_ui(){
  echo "Optional UI: [1] none [2] Open WebUI [3] SillyTavern"
  read -r -p "Choose UI [${UI_CHOICE}]: " ui
  case "${ui:-$UI_CHOICE}" in
    2|open-webui)
      UI_CHOICE="open-webui"
      python3 -m venv "${APP_DIR}/webui-venv"
      "${APP_DIR}/webui-venv/bin/pip" install -U open-webui
      ok "Open WebUI installed (run: ${APP_DIR}/webui-venv/bin/open-webui serve)"
      ;;
    3|sillytavern)
      UI_CHOICE="sillytavern"
      if ! command -v node >/dev/null 2>&1; then
        warn "Node.js missing; installing LTS"
        curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
        sudo apt-get install -y nodejs
      fi
      if [[ ! -d "${APP_DIR}/SillyTavern/.git" ]]; then
        git clone https://github.com/SillyTavern/SillyTavern.git "${APP_DIR}/SillyTavern"
      fi
      (cd "${APP_DIR}/SillyTavern" && npm install)
      ok "SillyTavern installed"
      ;;
    *) UI_CHOICE="none";;
  esac
}

benchmark_after_launch(){
  read -r -p "Run quick benchmark after launch? [y/N]: " yn
  [[ "${yn}" =~ ^[Yy]$ ]] || return
  if [[ -x "${BIN_DIR}/llama-bench" ]]; then
    "${BIN_DIR}/llama-bench" -m "${MODELS_DIR}/${MODEL_FILE}" -ngl 999 -npp 128 -ntg 128 || warn "Benchmark finished with warning"
  else
    warn "llama-bench binary not found in this build"
  fi
}

show_api_helpers(){
  cat <<EOF

OpenAI-compatible endpoint:
  http://127.0.0.1:${PORT}/v1/chat/completions

Example:
  curl -s http://127.0.0.1:${PORT}/v1/chat/completions \\
    -H 'Content-Type: application/json' \\
    -d '{"model":"local","messages":[{"role":"user","content":"Hello"}],"temperature":${SAMPLING_TEMP}}'

Health:
  curl -s http://127.0.0.1:${PORT}/health
EOF
}

integrity_note(){
  step "Integrity checks"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$0" > "${CFG_DIR}/install.sh.sha256"
    ok "Stored installer hash at ${CFG_DIR}/install.sh.sha256"
  fi
}

menu_main(){
  echo
  echo "1) Full install/update"
  echo "2) Start server"
  echo "3) Model list"
  echo "4) Model delete"
  echo "5) Update checks"
  echo "6) Exit"
  read -r -p "Select action [1]: " action
  case "${action:-1}" in
    1) workflow_full ;;
    2) "${START_SCRIPT}" ;;
    3) list_models ;;
    4) delete_model ;;
    5) update_checks ;;
    6) exit 0 ;;
    *) die "Invalid action" ;;
  esac
}

workflow_full(){
  install_base_deps
  detect_hardware
  build_llama_cpp
  select_model
  read -r -p "Server port [${PORT}]: " p; PORT="${p:-$PORT}"
  read -r -p "Temperature [${SAMPLING_TEMP}]: " t; SAMPLING_TEMP="${t:-$SAMPLING_TEMP}"
  read -r -p "Top-p [${SAMPLING_TOP_P}]: " tp; SAMPLING_TOP_P="${tp:-$SAMPLING_TOP_P}"
  read -r -p "Min-p [${SAMPLING_MIN_P}]: " mp; SAMPLING_MIN_P="${mp:-$SAMPLING_MIN_P}"
  read -r -p "KV cache preference [auto/aggressive/memory] (${KV_PREF}): " kv; KV_PREF="${kv:-$KV_PREF}"
  download_model
  setup_start_script
  setup_bash_helpers
  setup_systemd
  install_optional_ui
  integrity_note
  save_config
  "${START_SCRIPT}"
  benchmark_after_launch
  show_api_helpers
  ok "Done"
}

main(){
  load_config
  need_cmd awk; need_cmd sed; need_cmd curl
  menu_main
}

main "$@"
exit 0
