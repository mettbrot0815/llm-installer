LLM Stack Installer for Ubuntu WSL2
A production‑hardened, one‑command installer that sets up a complete local LLM environment on Ubuntu under WSL2.
llama.cpp · Hermes Agent · Goose · OpenCode · AutoAgent · OpenClaude

https://img.shields.io/badge/License-MIT-yellow.svg
https://img.shields.io/badge/ShellCheck-passing-brightgreen
https://img.shields.io/badge/platform-Ubuntu%2520WSL2-orange

✨ Features
Fully automated – Installs system dependencies, CUDA toolkit (if GPU present), builds llama.cpp, and configures all agents.

Hardware‑aware – Detects RAM, CPU cores, NVIDIA GPU/VRAM and recommends the best model for your system.

Model catalogue – 14 curated GGUF models from tiny to 70B with context‑size and Jinja presets.

Secure token handling – Extracts HuggingFace / GitHub tokens safely (no sed injection).

Idempotent & update‑aware – Safe to run repeatedly; updates only changed components.

Lightweight model switching – Change models in seconds without rebuilding anything (switch-model).

Systemd user service – Optional auto‑start of llama-server on login.

Comprehensive shell helpers – start-llm, stop-llm, llm-status, vram, and more added to ~/.bashrc.

🚀 Quick Install
bash
curl -fsSL https://raw.githubusercontent.com/mettbrot0815/llm-installer/refs/heads/main/install.sh | bash
Note: Review the script before piping to bash. A local copy can be obtained with:

bash
curl -fsSL https://raw.githubusercontent.com/.../install.sh -o install.sh
chmod +x install.sh
./install.sh
📋 Prerequisites
Ubuntu 22.04 or 24.04 running under WSL2 (Windows 10/11).

At least 8 GB RAM (16 GB recommended for models ≥ 9B).

NVIDIA GPU (optional but strongly recommended) with drivers ≥ 545 and CUDA 12.6 support.

Internet connection (downloads several GB of models and packages).

User with sudo privileges (passwordless sudo recommended for fully unattended install).

🧠 What Gets Installed
Component	Description
llama.cpp	Latest master built with CUDA (if GPU) or CPU‑only.
Hermes Agent	Official NousResearch agent with persistent memory and tool use.
Goose (optional)	Block’s Rust‑based AI agent (coding / dev tasks).
OpenCode (optional)	Terminal TUI coding agent supporting 75+ providers.
AutoAgent (optional)	HKUDS deep‑research multi‑agent (CLI mode, no Docker).
OpenClaude (optional)	Claude‑compatible CLI with local model support.
Model catalogue	14 pre‑configured GGUF models from 0.8B to 70B.
🖥️ Usage
Full Installation
Run the script interactively:

bash
./install.sh
You will be prompted for:

HuggingFace and GitHub tokens (optional but recommended for higher rate limits).

Model selection (interactive table with hardware‑based grades).

Optional agents (Goose, OpenCode, AutoAgent, OpenClaude).

After completion, open a new terminal or source ~/.bashrc to load the new aliases.

Model Switching (Lightweight)
To change the active model without rebuilding anything:

bash
switch-model
This re‑runs only the model selection, download, and configuration steps – typically completes in < 30 seconds (excluding download time).

⌨️ Post‑Install Commands
Command	Description
start-llm	Start llama-server (API on http://localhost:8080).
stop-llm	Stop llama-server.
restart-llm	Restart the server.
switch-model	Change the active model (lightweight).
llm-status	Show server status and active model.
llm-log	Tail the server log (/tmp/llama-server.log).
llm-models	List all downloaded .gguf files.
vram	Display GPU/VRAM usage (requires nvidia-smi).
hermes	Start Hermes Agent chat.
goose	Start Goose (if installed).
opencode / oc	Start OpenCode (if installed).
autoagent	Launch AutoAgent deep‑research (if installed).
openclaude	Launch OpenClaude (if installed).
⚙️ Configuration Files
Path	Purpose
~/.hermes/config.yaml	Hermes model, memory, and wizard settings.
~/.hermes/.env	Hermes environment (OPENAI_BASE_URL, etc.).
~/.config/goose/config.yaml	Goose local provider configuration.
~/.config/opencode/opencode.json	OpenCode model and provider settings.
~/.autoagent/.env	AutoAgent environment (model selection).
~/.openclaude/config.json	OpenClaude provider configuration.
~/.claude/config.json	Claude Desktop / Code local provider (if Claude detected).
~/.config/systemd/user/llama-server.service	User systemd service for auto‑start.
~/.wslconfig (Windows side)	WSL2 memory/processor limits (generated if missing).
🔧 Troubleshooting
llama-server fails to start
Check the log: tail -f /tmp/llama-server.log

Ensure the model file exists: ls -lh ~/llm-models/

If port 8080 is already in use: sudo lsof -i :8080

CUDA / GPU not detected
Verify NVIDIA driver installation: nvidia-smi

For WSL2, ensure you are using the latest kernel: wsl --update

Reinstall CUDA toolkit manually if needed.

switch-model not found
The alias is added to ~/.bashrc. Run source ~/.bashrc or open a new terminal.

Disk space insufficient
The script checks free space before downloading. Free up space or choose a smaller model.

sudo password prompt hangs
Some steps (e.g., system‑wide cmake install) require sudo. If you don’t have passwordless sudo, the script will skip those steps with a warning. You can safely ignore.

🔒 Security Notes
Token extraction is performed by sourcing ~/.bashrc in a subshell – no sed/grep parsing that could be exploited.

GitHub token is configured via a git credential helper, not embedded in URLs.

Temporary files are created with mktemp and cleaned up automatically (even on Ctrl+C).

All external downloads use HTTPS with certificate validation.

The script does not run with elevated privileges except for specific sudo commands (package installation, CUDA setup).

⚠️ Supply‑chain risk: The script installs software from GitHub and PyPI. While official sources are used, always review the script and consider running it in an isolated environment first.

📦 Requirements (installed automatically)
build-essential, cmake, git, ccache

python3.11, pip, uv

curl, wget, zstd

CUDA Toolkit 12.6 (if NVIDIA GPU detected)

Node.js 22.x (if OpenClaude selected)

🤝 Contributing
Contributions are welcome! Please open an issue or pull request on GitHub.
Before submitting, ensure your changes pass shellcheck and follow the existing style (shfmt -i 4 -s).

📄 License
This project is licensed under the MIT License – see the LICENSE file for details.

🙏 Acknowledgements
llama.cpp by Georgi Gerganov

Hermes Agent by NousResearch

Goose by Block

OpenCode by Anomaly

AutoAgent by HKUDS

OpenClaude by gitlawb
