# Ubuntu WSL2 LLM Setup Script

This script automates the installation of a complete local LLM stack on Ubuntu WSL2, including llama.cpp with CUDA support, Hermes Agent, and the web UI.

## Features

- **llama.cpp Build**: CUDA-accelerated with Flash Attention and KV cache quantization.
- **Model Download**: Supports various GGUF models from HuggingFace (Qwen3.5 9B recommended).
- **Hermes Agent**: Self-improving AI agent with web API and workspace UI.
- **Web UI**: Hermes Workspace at http://localhost:3000 for chatting and management.
- **Systemd Services**: Auto-start services for reliability.
- **Validation**: Built-in checks to prevent common errors (empty variables, missing dependencies).

## Requirements

- Ubuntu WSL2 on Windows
- NVIDIA GPU (optional, but recommended for performance)
- Internet connection for downloads

## Quick Start

```bash
git clone https://github.com/your-repo/llm-setup.git  # Replace with your repo
cd llm-setup
./install.sh
```

The script will:
1. Update system packages
2. Install CUDA toolkit (if GPU detected)
3. Build llama.cpp from source
4. Download and select a model
5. Set up Hermes Agent and Workspace
6. Generate ~/start-llm.sh for launching the stack
7. Configure systemd services and bash helpers

## Usage

After installation:

- **Start manually**: `./start-llm.sh`
- **Start via systemd**: `start-llm-services`
- **Stop**: `stop-llm`
- **Status**: `llm-status`
- **Web UI**: http://localhost:3000

## Model Selection

The script prompts for model selection with hardware grading (S/A/B/C/F based on RAM/VRAM fit).

Recommended: Qwen 3.5 9B for RTX 3060 12GB.

## Troubleshooting

- If start-llm.sh has errors, re-run install.sh to regenerate.
- For port conflicts, kill processes: `pkill -f "llama-server"; pkill -f "webapi"; pkill -f "pnpm dev"`
- Check logs: `llm-log` or `/tmp/llama-server.log`

## Files

- `install.sh`: Main setup script
- `start-llm.sh`: Generated launch script (created by install.sh)
- `TESTING_CHECKLIST.md`: Testing guide
- `summary.md`: Summary of setup

## License

MIT