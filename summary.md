# LLM Stack Installation Script - Fix Summary

## Overview
This document summarizes all the fixes and improvements made to the `install.sh` script for setting up a complete LLM stack with llama.cpp, Hermes Agent, and Workspace integration.

## Major Issues Fixed

### 1. Windows npm/Node.js Conflicts
**Problem**: Windows npm installations were interfering with WSL Node.js installations, causing pnpm and other tools to fail with "node: not found" errors.

**Fixes Applied**:
- Added Windows npm path detection and removal from PATH
- Ensured system Node.js takes precedence over Windows installations
- Forced local pnpm installation to avoid Windows npm conflicts
- Updated Node.js to latest LTS version (24.x)

### 2. Hermes WebAPI Startup Issues
**Problem**: The script tried to use `hermes webapi` command which doesn't exist in the outsourc-e fork, causing "invalid choice" errors and missing uvicorn dependencies.

**Fixes Applied**:
- Changed WebAPI startup to use `python -m webapi` (correct command for outsourc-e fork)
- Added `[all]` extras to hermes-agent installation to include uvicorn and other WebAPI dependencies
- Updated all process monitoring, killing, and systemd service configurations
- Fixed environment variables and port configurations

### 3. Service Auto-Start and Dependencies
**Problem**: Services weren't properly configured for auto-start with correct dependencies, causing startup failures and circular dependencies.

**Fixes Applied**:
- Fixed systemd service dependencies (llama-server → hermes-webapi → hermes-workspace)
- Updated systemd service commands to use correct executable paths
- Added proper environment variables to systemd services
- Improved service status monitoring and management

### 4. Software Version Updates
**Problem**: Script was using outdated software versions and not updating dependencies.

**Fixes Applied**:
- Node.js: Updated from v22 to v24 LTS
- npm: Added latest version updates
- pnpm: Ensured latest version installation
- Python packages: Added update commands for all major packages
- Git repositories: Updated to latest commits on main branches

## Detailed Changes

### System Updates
```bash
# Added system package updates
sudo apt-get update && sudo apt-get upgrade

# Updated Python package manager
pip install --upgrade pip setuptools wheel
```

### Node.js and pnpm Improvements
```bash
# Updated Node.js to v24 LTS
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -

# Improved pnpm installation with conflict avoidance
curl -fsSL https://get.pnpm.io/install.sh | sh -
export PNPM_HOME="${HOME}/.local/share/pnpm"
export PATH="$PNPM_HOME:$PATH"
```

### Windows Compatibility
```bash
# Windows npm path cleanup
if [[ -d "/mnt/c/Users/${USER}/.npm-global" ]]; then
    export PATH=$(echo "$PATH" | sed 's|/mnt/c/Users/'${USER}'/.npm-global[^:]*:||g')
fi

# System Node.js prioritization
export PATH="/usr/bin:/bin:/usr/local/bin:${PATH}"
```

### Hermes Agent Fixes
```bash
# Correct dependency installation
pip install -e "${HERMES_AGENT_DIR}[all]"

# Correct WebAPI startup
python -m webapi  # instead of 'hermes webapi'
```

### Systemd Service Improvements
```ini
# llama-server.service
[Unit]
After=network.target

[Service]
ExecStart=/path/to/llama-server [args]

# hermes-webapi.service
[Unit]
After=llama-server.service
Requires=llama-server.service

[Service]
ExecStart=/path/to/python -m webapi

# hermes-workspace.service
[Unit]
After=hermes-webapi.service
Requires=hermes-webapi.service

[Service]
ExecStart=/path/to/pnpm dev
```

### Process Management Updates
```bash
# Updated all process detection
WEBAPI_PID=$(pgrep -f "python -m webapi")

# Updated killing commands
pkill -f "python -m webapi"

# Updated aliases
alias start-hermes-api='python -m webapi'
alias stop-hermes-api='pkill -f "python -m webapi"'
```

### PATH and Environment Configuration
```bash
# Updated .bashrc PATH order
export PATH="/usr/bin:/bin:/usr/local/bin:${PNPM_HOME}:${HOME}/.local/bin:${HOME}/.hermes/node/bin:${HOME}/llm-video:${PATH}"
export PNPM_HOME="${HOME}/.local/share/pnpm"
```

## Software Versions (Updated)

| Component | Version | Notes |
|-----------|---------|-------|
| Node.js | v24.14.1 LTS | Latest stable LTS |
| npm | Latest | Updated alongside Node.js |
| pnpm | v10.33.x | Latest from standalone installer |
| Python | 3.11+ | System default |
| llama.cpp | Latest | Built from source |
| Hermes Agent | Latest | outsourc-e fork, main branch |
| Workspace | Latest | outsourc-e fork, main branch |

## New Commands Added

```bash
# Service management
start-llm-services    # Auto-start via systemd
start-llm           # Manual start
stop-llm            # Stop all services
restart-llm         # Restart all services

# Monitoring
llm-status          # Show running services
llm-services        # Show systemd service status
llm-log             # Tail llama-server logs
llm-models          # List downloaded models

# Individual services
start-hermes-api    # Start WebAPI manually
stop-hermes-api     # Stop WebAPI manually
start-workspace     # Start Workspace manually
stop-workspace      # Stop Workspace manually
```

## Configuration Files

### ~/.hermes/.env
```bash
OPENAI_API_KEY=llama
LLM_MODEL=selected_model
HERMES_WEBAPI_HOST=0.0.0.0
HERMES_WEBAPI_PORT=8642
```

### ~/.hermes/config.yaml
```yaml
model:
  default: "selected_model"
  provider: custom
  base_url: http://localhost:8080/v1
```

## Auto-Start Behavior

1. **llama-server** starts first (port 8080)
2. **hermes-webapi** starts after llama-server (port 8642)
3. **hermes-workspace** starts after WebAPI (port 3000/3001)

Services automatically restart on failure and start on system boot.

## Testing Results

- ✅ Windows npm conflicts resolved
- ✅ WebAPI starts without uvicorn errors
- ✅ All services have proper dependencies
- ✅ Auto-start works correctly
- ✅ Process monitoring works
- ✅ Manual control commands work

## Files Modified

- `install.sh`: Main installation script with all fixes
- Systemd services: Proper service configurations
- Shell aliases: Updated for correct commands
- Environment variables: Proper PATH and dependency management

## Compatibility

- ✅ **Linux**: Full support
- ✅ **WSL2**: Windows npm conflicts resolved
- ✅ **systemd**: Proper service management
- ✅ **non-systemd**: Fallback to manual commands

This comprehensive fix ensures the LLM stack installs and runs reliably across different environments.</content>
<parameter name="filePath">/workspace/8a2131b2-e10d-4ca4-b0be-3cc27d8e159c/sessions/agent_99581cb9-23f5-47a7-928a-e683046d082e/summary.md