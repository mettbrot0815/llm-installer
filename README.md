# LLM Installer for Ubuntu WSL2

A production-hardened installer script that sets up a complete local LLM development environment on Ubuntu WSL2.

## Features

- **llama.cpp** - High-performance LLM inference with GPU acceleration
- **Hermes Agent** - AI agent framework with persistent memory and tool use
- **Goose** - AI coding agent (optional)
- **OpenCode** - Terminal TUI coding agent (optional)
- **AutoAgent** - Deep research agent (optional)
- **OpenClaude** - Claude-compatible CLI (optional)

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

- **OS**: Ubuntu 22.04+ (WSL2 recommended)
- **RAM**: Minimum 8GB, recommended 16GB+
- **GPU**: NVIDIA with CUDA support (optional, for faster inference)
- **Disk**: Minimum 50GB free space

## Installation

The installer performs the following steps:

1. **System Setup**
   - Updates system packages
   - Installs Python 3.11, build tools, and dependencies
   - Detects hardware (CPU, RAM, GPU)

2. **HuggingFace Integration**
   - Prompts for HuggingFace token (optional)
   - Sets up HuggingFace CLI
   - Configures authentication

3. **Model Selection**
   - Provides a catalog of pre-configured models
   - Automatically downloads selected model
   - Supports custom GGUF model downloads

4. **llama.cpp Installation**
   - Clones and builds llama.cpp from source
   - Optimizes for CUDA if GPU detected
   - Creates launch scripts and systemd service

5. **Agent Installation**
   - Hermes Agent (core)
   - Goose, OpenCode, AutoAgent, OpenClaude (optional)

## Usage

### Start llama-server

```bash
start-llm
```

This starts the local LLM server at `http://localhost:8080/v1`

### Use Hermes Agent

```bash
hermes
```

### Switch Models

```bash
switch-model
```

Quickly switch between different GGUF models (lightweight, ~5 seconds)

### List Commands

| Command | Description |
|---------|-------------|
| `start-llm` | Start llama-server |
| `stop-llm` | Stop llama-server |
| `restart-llm` | Restart llama-server |
| `switch-model` | Pick different model |
| `llm-status` | Show status and active model |
| `llm-log` | Tail llama-server log |
| `llm-models` | List all GGUF files |
| `vram` | Show GPU/VRAM usage |

## Default Models

The installer provides a curated list of models optimized for 12GB VRAM RTX 3060:

| # | Model | Size | Context | Best For |
|---|---|------|--------|----------|
| 1 | Qwen 3.5 9B | 5.3 GB | 256K | General purpose, fast |
| 2 | Carnice-9b (Hermes) | 6.9 GB | 256K | Agent-tuned, tool-use |
| 3 | Llama 3.1 8B | 4.1 GB | 128K | Instruction following |
| 4 | Qwen2.5 Coder 14B | 9 GB | 131K | Coding, #1 performance |
| 5 | Qwen 3 14B | 9 GB | 131K | Chat, code, reasoning |
| 6 | Gemma 3 12B | 7.3 GB | 128K | Strict roles, tools |
| 7 | Gemma 4 12B | 7.3 GB | 128K | 128K context |
| 8 | Qwen 3.5 35B MoE | 22 GB | 128K | MoE, 3B active |
| 9 | DeepSeek R1 32B | 17 GB | 64K | Reasoning |
| 10 | Harmonic Hermes 9B | 6.5 GB | 256K | Hermes-tuned |
| 11 | Qwopus-GLM 18B | 10.5 GB | 64K | Merged GLM |
| 12 | Gemma 4 26B MoE | 9.4 GB | 128K | MoE, 4B active |

## Building llama.cpp

The installer uses CMake for building:

```bash
rm -rf build
cmake -B build \
  -DGGML_CUDA=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CUDA_ARCHITECTURES="86" \
  -DLLAMA_CURL=ON
cmake --build build --config Release -j8
```

For RTX 3060 12GB, use CUDA architectures "86" (Ampere). Adjust -j for your CPU cores.

## Updating llama.cpp

To update llama.cpp to the latest version:

```bash
cd ~/llama.cpp
git pull origin master
rm -rf build
cmake -B build -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES="86" -DLLAMA_CURL=ON
cmake --build build --config Release -j8
```

## Configuration

### HuggingFace Token

For faster downloads and higher rate limits, add your HuggingFace token:

```bash
export HF_TOKEN="hf_your_token_here"
```

### GitHub Token

For higher API rate limits and private repository access:

```bash
export GITHUB_TOKEN="ghp_your_token_here"
```

### Environment Files

- `~/.hermes/config.yaml` - Hermes configuration
- `~/.hermes/.env` - Environment variables
- `~/.config/goose/config.yaml` - Goose configuration
- `~/.config/opencode/opencode.json` - OpenCode configuration
- `~/.autoagent/.env` - AutoAgent configuration

## Help & Support

- **Documentation**: [agentskills.io](https://agentskills.io)
- **Hermes Skills**: `hermes skills browse` or `hermes skills search <query>`
- **Issues**: [GitHub Issues](https://github.com/mettbrot0815/llm-installer/issues)

## License

MIT License - see LICENSE file for details.

## Contributing

Contributions are welcome! Please submit issues and pull requests.
