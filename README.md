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

The installer provides a curated list of models:

| # | Model | Size | Best For |
|---|-------|------|----------|
| 1 | Qwen3.5-0.8B | 0.5 GB | Quick tests, edge devices |
| 2 | Qwen3.5-2B | 1 GB | Fast CPU inference |
| 3 | Qwen3.5-4B | 2 GB | Capable CPU performance |
| 4 | Phi-4 Mini | 2 GB | Strong reasoning |
| 5 | Qwen3.5-9B | 5.3 GB | General purpose |
| 6 | Carnice-9b (Hermes) | 6.9 GB | Hermes-tuned agent |
| 7 | Llama 3.1 8B | 4.1 GB | Excellent instruction following |
| 8 | Qwen2.5 Coder 14B | 9 GB | #1 coding performance |

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
