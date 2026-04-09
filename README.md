# LLM Installer for Ubuntu WSL2

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform: WSL2](https://img.shields.io/badge/Platform-Ubuntu%20WSL2-orange)](https://ubuntu.com/wsl)

**A production-hardened, one-command installer** that sets up a complete local LLM + Agent environment on Ubuntu under WSL2.

---

## ✨ Features

- Full `llama.cpp` server with CUDA support
- Hermes Agent (self-improving agent with memory)
- Optional agents: Goose, OpenCode, AutoAgent, OpenClaude
- 14 curated GGUF models with hardware-aware recommendations
- Automatic hardware detection (RAM, CPU cores, GPU VRAM)
- Secure Hugging Face & GitHub token handling
- Systemd user service for automatic startup
- Lightweight model switcher (`switch-model`)
- Rich Bash helper commands
- Idempotent — safe to run multiple times

---

## 🚀 Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/mettbrot0815/llm-installer/main/install.sh -o install.sh
chmod +x install.sh
./install.sh

PrerequisitesUbuntu 22.04 or 24.04 in WSL2 (Windows 11 recommended)
Minimum 8 GB RAM (16 GB+ strongly recommended)
NVIDIA GPU optional but highly recommended

What's IncludedComponent
Description
Type
llama.cpp
High-performance LLM inference server
Core
Hermes Agent
Main self-improving agent + Honcho memory
Core
Goose
Fast Rust-based agent
Optional
OpenCode
Coding-focused TUI agent
Optional
AutoAgent
Multi-agent research tool
Optional
Systemd Service
Auto-start llama-server
Optional
Bash Helpers
start-llm, switch-model, vram, etc.
Always

Usagebash

start-llm          # Start the LLM server
stop-llm           # Stop the server
restart-llm        # Restart server
llm-status         # Show status and active model
switch-model       # Change model (fast mode)
vram               # Show GPU memory usage
llm-log            # Tail server logs
hermes             # Launch main agent

Web UI: http://localhost:8080Available Install Scriptsinstall.sh — Main recommended version
install2.sh — Most security-hardened version (recommended for production)
install3.sh — Latest revision with additional changes

Security & Best PracticesStrict set -euo pipefail
Safe credential handling (tokens never hardcoded)
Proper WSL2 PATH cleaning
Clean temp file management with traps
Idempotent design

NotesOptimized for NVIDIA GPUs in WSL2
Works in CPU-only mode (slower with larger models)
All agents connect to the local llama.cpp backend

Made for the local AI community — Private, fast, and fully offline.Star  the repo if this helps you!

