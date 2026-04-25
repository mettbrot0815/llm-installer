# LLM Installer for Ubuntu WSL2 (2026 Edition)

A hybrid installer that combines modern CMake builds with model selection and agent integration, optimized for RTX 3060 12GB.

## Features

- **llama.cpp** - High-performance LLM inference with CUDA GPU acceleration
- **Modern build system** - CMake-based with Ampere optimizations
- **Optimized server flags** - Flash attention, q8_0 KV cache, balanced threading
- **Simple model management** - Download and switch between GGUF models
- **Ready-to-use wrappers** - start-llm, stop-llm, status commands

## Quick Start

```bash
# Clone the repository
git clone https://github.com/mettbrot0815/llm-installer.git
cd llm-installer

# Run the installer
chmod +x install.sh
./install.sh
```

## Requirements

- **OS**: Ubuntu 24.04+ (WSL2 recommended)
- **RAM**: Minimum 8GB, recommended 16GB+
- **GPU**: NVIDIA RTX 30-series with CUDA support
- **Disk**: Minimum 50GB free space

## Installation

The installer performs the following steps:

1. **System Setup**
    - Updates system packages
    - Installs build tools, CUDA toolkit, and dependencies
    - Detects hardware (RAM, CPU, GPU)

2. **Model Selection**
    - Interactive menu to choose from optimized models
    - Hardware-aware recommendations

3. **llama.cpp Build**
    - Clones and builds llama.cpp with CMake
    - Optimizes for RTX 3060 (Ampere architecture)
    - Enables CUDA acceleration and ccache for fast rebuilds

4. **Model Download**
    - Downloads selected model via HuggingFace
    - Supports token authentication for faster downloads

5. **Agent Setup** (optional)
    - Installs and configures Hermes Agent
    - Points to local llama-server endpoint

6. **Wrapper Scripts**
    - Creates start-llm, stop-llm, llm-status commands
    - Optimized server flags for performance and stability

## Usage

### Start llama-server

```bash
start-llm
```

Starts the server at `http://localhost:8080/v1` with optimized settings for RTX 3060.

### Stop llama-server

```bash
stop-llm
```

### Check Status

```bash
llm-status
```

### Use Hermes Agent

```bash
hermes
```

Starts the Hermes Agent configured to use your local llama-server.

### List Commands

| Command | Description |
|---------|-------------|
| `start-llm` | Start llama-server |
| `stop-llm` | Stop llama-server |
| `llm-status` | Show server status |
| `hermes` | Run Hermes Agent (if installed) |

## Default Model

The installer downloads Qwopus-GLM-18B-Healed-Q4_K_M.gguf (10.5GB), optimized for RTX 3060 12GB VRAM.

## Building llama.cpp

The installer uses CMake with CUDA optimizations:

```bash
rm -rf build
cmake -B build \
  -DGGML_CUDA=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CUDA_ARCHITECTURES="86" \
  -DLLAMA_CURL=ON \
  -DGGML_CCACHE=ON
cmake --build build --config Release -j8
```

## Updating llama.cpp

To update to the latest version:

```bash
cd ~/llama.cpp
git pull
rm -rf build
cmake -B build -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES="86" -DLLAMA_CURL=ON -DGGML_CCACHE=ON
cmake --build build --config Release -j8
```

## Configuration

Add to your `~/.bashrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

### HuggingFace Token (recommended)

For faster downloads and higher rate limits:

```bash
export HF_TOKEN="hf_your_token_here"
```

### Available Models

The installer includes models optimized for 12GB VRAM:

| Model | Size | Context | Best For |
|-------|------|---------|----------|
| Qwen 3.5 9B | 5.3 GB | 256K | Fast general purpose |
| Qwen2.5 Coder 14B | 9 GB | 131K | Coding performance |
| Qwopus-GLM 18B | 10.5 GB | 64K | Balanced performance |
| Gemma 4 12B | 7.3 GB | 128K | Long context |
| Qwen 3.5 35B MoE | 22 GB | 128K | High performance |

## Help & Support

- **llama.cpp Documentation**: https://github.com/ggml-org/llama.cpp
- **Issues**: [GitHub Issues](https://github.com/mettbrot0815/llm-installer/issues)

## License

MIT License - see LICENSE file for details.

## Contributing

Contributions are welcome! Please submit issues and pull requests.
