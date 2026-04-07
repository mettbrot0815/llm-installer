# LLM Installer — Ubuntu WSL2

> A production-grade, single-script installer for a complete local AI inference and agent stack on Ubuntu WSL2.

## Overview

This project provides a fully automated Bash installer that sets up **llama.cpp** as a local inference server alongside a suite of AI agent frameworks — all configured to work together out of the box.

### Stack Components

| Component | Purpose | URL |
|-----------|---------|-----|
| **llama.cpp** | Local LLM inference server (GGML backend) | `http://localhost:8080` |
| **Hermes Agent** | NousResearch's AI agent with self-learning memory (Honcho) | `hermes` CLI |
| **Goose** | Block's Rust-based AI agent (optional) | `goose` CLI |
| **OpenCode** | Anomalyco's Go-based coding agent TUI (optional) | `opencode` CLI |
| **AutoAgent** | HKUDS's multi-agent deep research tool (optional) | `autoagent` CLI |

## Features

- **14 pre-curated GGUF models** with hardware compatibility grading (S/A/B/C/F)
- **Two installation modes**: full install or lightweight model switching
- **Automatic hardware detection** — RAM, GPU, VRAM, CUDA
- **HuggingFace integration** — token management, CLI setup, authenticated downloads
- **Hermes Agent** configured with persistent memory and self-learning (Honcho)
- **agentskills.io** compatible — portable skill files loaded on demand
- **systemd user service** for persistent auto-start across reboots
- **Bash helper aliases and functions** — `start-llm`, `stop-llm`, `switch-model`, `llm-status`, `vram`, and more
- **Idempotent** — safe to re-run; skips already-completed steps
- **Non-interactive safe** — sensible defaults when stdin is not a TTY

## Quick Start

### Prerequisites

- Ubuntu on WSL2 (Windows 11 recommended)
- NVIDIA GPU with CUDA support (optional, but recommended for performance)
- At least 8 GB RAM (16 GB+ recommended for mid-tier models)

### Installation

```bash
# Download and run the installer
curl -fsSL https://raw.githubusercontent.com/mettbrot0815/llm-installer/refs/heads/main/install.sh -o install.sh
chmod +x install.sh
bash install.sh
```

The installer will guide you through:

1. HuggingFace token setup (optional but recommended)
2. System package installation
3. Hardware detection
4. Model selection from a graded catalogue
5. llama.cpp build from source
6. Hermes Agent installation and configuration
7. Optional agent installs (Goose, OpenCode, AutoAgent)
8. systemd service setup for auto-start
9. Bash helper aliases and functions

### Switching Models

After the initial install, switch to a different model in seconds:

```bash
switch-model
```

This lightweight mode skips all expensive setup and only:
- Shows the model selection table
- Downloads the new model (if needed)
- Regenerates `start-llm.sh`
- Updates all agent configurations
- Restarts the llama-server

## Model Catalogue

The installer includes a curated catalogue of 14 GGUF models, automatically graded against your hardware:

| Tier | Models | Size | Use Case |
|------|--------|------|----------|
| **TINY** | Qwen3.5 0.8B, 2B | <1 GB | Instant response, edge testing |
| **SMALL** | Qwen3.5 4B, Phi-4 Mini | 1–2 GB | Fast CPU inference, everyday use |
| **MID** | Qwen3.5 9B, Carnice-9b, Llama 3.1 8B, Gemma 3/4 12B | 4–9 GB | Best quality/speed balance |
| **LARGE** | Qwen3 30B MoE, DeepSeek R1 32B, Llama 3.3 70B | 17–39 GB | High-end GPU required |

**Recommended starting points:**
- **Model 5** — Qwen3.5 9B: General purpose, ~50 tok/s on RTX 3060
- **Model 6** — Carnice-9b: Fine-tuned specifically for Hermes Agent harness

## Post-Install Usage

### Server Management

```bash
start-llm       # Start llama-server
stop-llm        # Stop llama-server
restart-llm     # Restart llama-server
llm-log         # Tail llama-server log
llm-models      # List all downloaded .gguf files
llm-status      # Show current status and active model
```

### Agent Interaction

```bash
hermes          # Chat with Hermes Agent
hermes model    # Switch Hermes provider/model
hermes doctor   # Diagnose config issues
hermes skills   # Browse/install skills

goose           # Goose agent (if installed)
opencode / oc   # OpenCode coding agent (if installed)
autoagent       # AutoAgent deep research (if installed)
```

### System Monitoring

```bash
vram            # GPU/VRAM usage
```

### Web UI

The llama.cpp server includes a built-in web UI at **http://localhost:8080**.

## Architecture

### Execution Flow

```
1.  HuggingFace token management
2.  System packages (apt, pip, CUDA)          [skipped in switch-model]
3.  Hardware detection (RAM, GPU, VRAM)
4.  CUDA toolkit check/install                [skipped in switch-model]
5.  Model catalogue + interactive selector
6.  HuggingFace CLI setup
7.  Download selected model (if not on disk)
8.  Build llama.cpp from source               [skipped in switch-model]
9.  Install + configure Hermes Agent          [skipped in switch-model]
10. pip update                                [skipped in switch-model]
11. Generate ~/start-llm.sh launcher
12. systemd user service                      [skipped in switch-model]
12b. Install Hermes skills (agentskills.io)   [skipped in switch-model]
13. Optional agents (Goose/OpenCode/AutoAgent)[skipped in switch-model]
13d. Update all agent configs for new model
14. ~/.bashrc helpers + aliases               [skipped in switch-model]
15. .wslconfig RAM hint                       [skipped in switch-model]
```

### Configuration Files

| File | Purpose |
|------|---------|
| `~/.hermes/config.yaml` | Hermes model, memory, agent settings |
| `~/.hermes/.env` | Hermes environment variables |
| `~/.config/goose/config.yaml` | Goose configuration |
| `~/.config/opencode/opencode.json` | OpenCode configuration |
| `~/.autoagent/.env` | AutoAgent environment |
| `~/start-llm.sh` | llama-server launcher script |
| `~/.config/systemd/user/llama-server.service` | systemd auto-start service |
| `%USERPROFILE%\.wslconfig` | WSL2 RAM/VRAM limits (Windows side) |

### Hermes Agent Configuration

Hermes is pre-configured for local inference:

```yaml
setup_complete: true
model:
  provider: custom
  base_url: http://localhost:8080/v1
  default: <model-name>
  context_length: <safe-context>
terminal:
  backend: local
agent:
  max_turns: 90
memory:
  honcho:
    enabled: true
```

## Project Structure

```
├── install.sh                          # Main installer script
├── README.md                           # This file
└── .planning/codebase/
    ├── ARCHITECTURE.md                 # Architecture analysis
    ├── TECHNOLOGY.md                   # Tech stack documentation
    ├── DEPENDENCIES.md                 # External and system dependencies
    ├── ROADMAP.md                      # Completed milestones + next steps
    └── QUALITY.md                      # Quality analysis and bug fixes
```

## Known Issues & Fixes

This version includes fixes for the following issues:

| Severity | Issue | Status |
|----------|-------|--------|
| HIGH | Duplicate HF CLI + model selector block | ✅ Fixed |
| HIGH | switch-model not truly lightweight | ✅ Fixed (`_SMO` sentinel) |
| HIGH | Hermes install URL typo | ✅ Fixed |
| HIGH | llm-status bashrc broken syntax | ✅ Fixed |
| HIGH | Python YAML-unsafe regex | ✅ Fixed |
| MED | Honcho memory disabled | ✅ Fixed |
| MED | Missing curl retry flags | ✅ Fixed |
| MED | No Hermes skills installed | ✅ Fixed |
| LOW | HF token prompt on switch-model | ✅ Fixed |

## Development

### Idempotency

The installer is designed to be safe to re-run:
- Checks for existing installations before installing
- Skips already-completed steps with informative messages
- Preserves user modifications where possible

### Error Handling

- `set -euo pipefail` for strict error handling
- Temp file cleanup via `trap`
- Graceful fallbacks for optional components
- Clear error messages with actionable guidance

### CUDA Notes

- GPU driver lives in Windows — **never install `cuda-drivers` inside WSL2**
- The installer only installs the CUDA toolkit, not the drivers
- Without CUDA, llama.cpp falls back to CPU-only mode (much slower)

## License

This project is provided as-is for personal and educational use. Individual components (llama.cpp, Hermes, Goose, OpenCode, AutoAgent) are subject to their respective licenses.

## Acknowledgments

- [llama.cpp](https://github.com/ggml-org/llama.cpp) — GGML inference engine
- [Hermes Agent](https://github.com/NousResearch/hermes-agent) — NousResearch AI agent
- [Goose](https://github.com/block/goose) — Block's AI agent
- [OpenCode](https://github.com/anomalyco/opencode) — Coding agent TUI
- [AutoAgent](https://github.com/HKUDS/AutoAgent) — Deep research agent
- [agentskills.io](https://agentskills.io) — Open standard for portable agent skills
