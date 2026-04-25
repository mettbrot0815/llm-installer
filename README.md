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
    - Detects hardware (RAM, CPU, GPU VRAM)

2. **Model Selection**
    - Interactive menu with hardware grading
    - 5 optimized models for 12GB VRAM RTX 3060
    - Shows performance grades (S/A/B/C/F)

3. **llama.cpp Build**
    - Clones and builds llama.cpp with CMake
    - RTX 3060 optimized (Ampere architecture, CUDA 86)
    - Enables CUDA acceleration, ccache, and performance flags

4. **Model Download**
    - Downloads selected model via HuggingFace CLI
    - Supports token authentication for faster downloads
    - Automatic fallback for manual download

5. **Wrapper Scripts**
    - `start-llm`: Optimized server launcher with readiness checks
    - `stop-llm`: Clean shutdown
    - `llm-status`: Server status monitoring
    - `switch-model`: Interactive model switcher
    - `vram`: GPU memory and system monitoring

6. **Agent Setup** (optional)
    - Installs and configures Hermes Agent
    - Automatic configuration for local server endpoint

7. **Systemd Service** (optional)
    - User service for auto-start on login
    - Persistent background operation

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

Shows if server is running and endpoint info.

### Switch Models

```bash
switch-model
```

Interactive menu to select and download different models.

### Monitor GPU Usage

```bash
vram
```

Shows GPU memory usage, temperature, and server status.

### Use Hermes Agent

```bash
hermes
```

Starts the Hermes Agent configured to use your local llama-server.

### Systemd Service (optional)

```bash
systemctl --user start llama-server
systemctl --user stop llama-server
systemctl --user enable llama-server  # Auto-start on login
```

### List Commands

| Command | Description |
|---------|-------------|
| `start-llm` | Start llama-server |
| `stop-llm` | Stop llama-server |
| `llm-status` | Show server status |
| `switch-model` | Interactive model selection |
| `vram` | GPU memory & status monitor |
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

The installer includes models optimized for 12GB VRAM RTX 3060:

| Model | Size | Context | Grade | Best For |
|-------|------|---------|-------|----------|
| Qwen 3.5 9B | 5.3 GB | 256K | **S** | Fast general purpose, excellent performance |
| Qwen2.5 Coder 14B | 9 GB | 131K | **A** | Coding performance, #1 on benchmarks |
| Qwopus-GLM 18B | 10.5 GB | 64K | **A** | Balanced performance, community optimized |
| Gemma 4 12B | 7.3 GB | 128K | **A** | Long context, Google quality |
| Qwen 3.5 35B MoE | 22 GB | 128K | **B** | High performance, MoE efficiency |

**Grade Legend:**
- **S** = Runs great (excellent performance)
- **A** = Runs well (good performance)
- **B** = Decent (acceptable performance)
- **C** = Tight fit (may be slow)
- **F** = Too heavy (not recommended)

## Help & Support

- **llama.cpp Documentation**: https://github.com/ggml-org/llama.cpp
- **Issues**: [GitHub Issues](https://github.com/mettbrot0815/llm-installer/issues)

## License

MIT License - see LICENSE file for details.

## Contributing

Contributions are welcome! Please submit issues and pull requests.
