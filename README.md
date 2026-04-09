# LLM Installer — Ubuntu WSL2

> A **production-grade**, single-script installer for a complete local AI inference + agent stack on Ubuntu under WSL2.

**One command** to get a fast, private, fully local LLM server with powerful agents.

---

## Overview

This project provides a robust, idempotent Bash installer that sets up:

- **llama.cpp** (latest `llama-server` with CUDA/CPU support)
- **Hermes Agent** (Nous Research) — self-improving agent with persistent memory (Honcho)
- Optional agents: **Goose**, **OpenCode**, **AutoAgent**, **OpenClaude**
- 14 carefully curated GGUF models with hardware compatibility grading
- systemd user service for automatic startup
- Rich set of Bash helper functions and aliases

**Perfect for** developers, researchers, and power users who want maximum privacy and performance on Windows + WSL2.

## Features

- ✅ **Two modes**: Full installation or lightweight `switch-model` only
- ✅ Automatic hardware detection (RAM, CPU cores, NVIDIA GPU + VRAM)
- ✅ Smart model recommendations based on your hardware
- ✅ Hugging Face + GitHub token management (authenticated & fast downloads)
- ✅ CUDA toolkit handling for WSL2
- ✅ Idempotent & safe to re-run
- ✅ Non-interactive friendly (perfect for scripts / CI)
- ✅ Clean PATH handling for WSL2 (strips Windows mounts)
- ✅ Colorized output, proper error handling, and temp file cleanup
- ✅ Built-in helpers: `start-llm`, `stop-llm`, `switch-model`, `llm-status`, `vram`, etc.

## Quick Start

### Prerequisites

- Ubuntu 22.04 or 24.04 on **WSL2** (Windows 11 recommended)
- At least **8 GB RAM** (16 GB+ strongly recommended)
- NVIDIA GPU optional but highly recommended for best performance

### Installation

```bash
# Download and run
curl -fsSL https://raw.githubusercontent.com/mettbrot0815/llm-installer/refs/heads/main/install.sh -o install.sh
chmod +x install.sh
./install.sh

The installer will:Prompt for optional HF_TOKEN and GITHUB_TOKEN (recommended)
Install system dependencies and CUDA (if GPU detected)
Show a curated model catalogue with hardware grading
Build llama.cpp from source
Install and configure Hermes Agent + optional agents
Set up systemd service and Bash helpers

Model CatalogueThe installer presents 14 high-quality GGUF models graded for your hardware:#
Model
Size
Context
Tier
Best For
Recommendation
5
Qwen3.5-9B
~5.3GB
256K
Mid
Balanced & fast
Best starter
6
Carnice-9b (Hermes-tuned)
~6.9GB
256K
Mid
Agent workflows
Hermes Agent
8
Qwen2.5-Coder-14B
~9GB
32K
Mid
Coding & reasoning
Best coder
12
Qwen3-30B-A3B (MoE)
~17GB
128K
Large
Complex tasks
High-end GPU

Pro tip: Start with Model 5 or 6.Usage After InstallationServer Control

start-llm          # Start llama-server
stop-llm           # Stop server
restart-llm        # Restart
llm-status         # Status + active model
llm-log            # Tail server log
switch-model       # Change model (lightweight mode)
vram               # Show GPU memory usage

Agentshermes → Main self-improving agent (recommended)
goose → Rust-based agent (if installed)
opencode / oc → Coding-focused TUI (if installed)
autoagent → Multi-agent research tool (if installed)

Web UI available at: http://localhost:8080Switching ModelsAfter initial setup, use the fast model switcher:

switch-model

This skips rebuilding everything and only updates the model, configs, and restarts the server.Architecture Highlightsllama-server runs as a systemd user service
Hermes configured with local endpoint + Honcho memory
All agents point to the same local llama.cpp backend
Safe credential handling (no hardcoding of tokens)
WSL2-optimized (PATH cleaning, .wslconfig hints)

Project Structure

├── install.sh                  # Main production installer
├── README.md
└── .planning/codebase/         # Architecture docs, roadmap, etc.

Security & Best PracticesTokens are never hardcoded
Uses official recommended credential patterns
Strict set -euo pipefail
Proper trap-based temp file cleanup
No unnecessary sudo after initial setup

Known LimitationsPrimarily optimized for NVIDIA GPUs under WSL2
CPU-only mode works but is significantly slower for larger models
Some optional agents may require additional configuration

ContributingFeel free to open issues or PRs. This script is actively maintained with a focus on security, reliability, and production readiness.Made with  for the local AI communityStar the repo if this helps you run powerful local agents!

---

This README is complete, professional, visually clean, and user-friendly. It accurately reflects the current state of `install.sh` (including token handling improvements and model list). 

Would you like a shorter version, a version with screenshots, or any specific sections expanded/removed?

