# 🚀 LLM Stack Installation - Comprehensive Test Plan

## Overview
This test plan validates the complete LLM installation script functionality, covering all components, optimizations, and edge cases.

## 🔍 Pre-Installation Checks

### System Requirements
- [ ] **Ubuntu/Debian detection**: Script identifies compatible OS
- [ ] **WSL2 detection**: Properly detects Windows Subsystem for Linux
- [ ] **Hardware detection**: CPU cores, RAM, GPU detection
- [ ] **Disk space check**: Validates sufficient space for selected model

### Dependencies Check
- [ ] **Git availability**: `git --version` works
- [ ] **curl availability**: Network connectivity test
- [ ] **sudo access**: Administrative privileges confirmed
- [ ] **Internet connectivity**: Can download from GitHub/npm

## 🛠️ Core Installation Tests

### 1. System Updates (Smart Caching)
- [ ] **Apt cache check**: Only updates if >60 minutes old
- [ ] **Package upgrades**: System packages updated without breaking existing installs
- [ ] **Python pip update**: setuptools, wheel, pip updated
- [ ] **No redundant downloads**: Subsequent runs skip already-updated packages

### 2. Node.js & npm Setup
- [ ] **Version detection**: Installs Node.js 24.x if not present
- [ ] **Windows Node.js bypass**: Detects and ignores Windows installations
- [ ] **npm update handling**: Gracefully handles permission errors
- [ ] **PATH prioritization**: System Node.js takes precedence

### 3. pnpm Installation
- [ ] **Local installation**: Installs to `~/.local/share/pnpm`
- [ ] **Windows conflict resolution**: Removes Windows npm from PATH
- [ ] **Version verification**: `pnpm --version` works after install
- [ ] **PATH integration**: pnpm available in new shells

### 4. CUDA Toolkit (GPU Systems)
- [ ] **NVIDIA detection**: Only installs if GPU present
- [ ] **Existing install check**: Skips if `nvcc` already available
- [ ] **PATH setup**: CUDA binaries added to PATH
- [ ] **Library path**: LD_LIBRARY_PATH updated

## 🧠 LLM Core Components

### 5. llama.cpp Build
- [ ] **Git repository**: Updates from ggml-org/llama.cpp
- [ ] **Build optimization**: Skips rebuild if binaries exist
- [ ] **CUDA compilation**: Uses GPU acceleration when available
- [ ] **System installation**: Binaries installed to `/usr/local/bin`
- [ ] **ccache integration**: Build caching for faster recompilation

### 6. Model Download
- [ ] **HuggingFace CLI**: Installs and configures hf client
- [ ] **Model selection**: Interactive menu with hardware compatibility
- [ ] **Download verification**: Checks file size and integrity
- [ ] **Resume capability**: Handles interrupted downloads
- [ ] **Disk space validation**: Prevents insufficient space errors

### 7. Hermes Agent Setup
- [ ] **Fork cloning**: Updates outsourc-e/hermes-agent
- [ ] **Virtual environment**: Creates isolated Python environment
- [ ] **Dependency installation**: Installs with [all] extras
- [ ] **WebAPI command**: `python -m webapi` works
- [ ] **Configuration**: `.env` and `config.yaml` properly set

### 8. Hermes Workspace
- [ ] **Repository update**: Latest commits from main branch
- [ ] **Dependency installation**: pnpm install completes
- [ ] **Build process**: No compilation errors
- [ ] **PATH integration**: Workspace binaries accessible

## 🎨 Optional Components

### 9. Video Generation (CUDA)
- [ ] **GPU requirement**: Only offered if NVIDIA GPU detected
- [ ] **User approval**: Interactive prompt for installation
- [ ] **CUDA dependencies**: PyTorch with CUDA wheels
- [ ] **Script generation**: `generate_video.py` created and executable
- [ ] **PATH integration**: `llm-video` added to PATH

### 10. Qwen Code Assistant
- [ ] **Node.js compatibility**: Works with installed Node.js version
- [ ] **npm installation**: @qwen-code/cli package installs
- [ ] **PATH setup**: qwen command available globally
- [ ] **qwen instant compatibility**: Works with external install scripts

## 🔧 Service Management

### 11. Systemd Services
- [ ] **Service creation**: All services properly defined
- [ ] **Dependency chain**: llama-server → webapi → workspace
- [ ] **Auto-start**: Services enabled for boot
- [ ] **Manual control**: start/stop/restart commands work
- [ ] **Status monitoring**: `llm-services` shows correct status

### 12. Launch Script
- [ ] **Process management**: Correctly starts/stops all services
- [ ] **Health checks**: Waits for services to be ready
- [ ] **Timeout handling**: Graceful handling of slow startups
- [ ] **PID tracking**: Properly tracks running processes
- [ ] **Log management**: Creates and manages log files

## 🖥️ User Interface & Experience

### 13. Interactive Prompts
- [ ] **Model selection**: Hardware-aware recommendations
- [ ] **Video generation**: Optional with clear disk space warning
- [ ] **User confirmation**: Clear yes/no prompts
- [ ] **Error handling**: Graceful handling of user cancellations

### 14. Progress Indicators
- [ ] **Long operations**: Shows progress for >30 second tasks
- [ ] **Package downloads**: Visual feedback during pip installs
- [ ] **Build processes**: CMake and compilation progress
- [ ] **Service startup**: Health check status updates

### 15. Shell Integration
- [ ] **bashrc updates**: All aliases and PATH changes applied
- [ ] **Profile updates**: Video PATH added when applicable
- [ ] **Environment variables**: HF_TOKEN, PNPM_HOME, etc. set
- [ ] **New shell compatibility**: Changes work in new terminals

## 🐛 Error Handling & Edge Cases

### 16. Network Issues
- [ ] **Download failures**: Graceful retry mechanisms
- [ ] **Partial downloads**: Resume capability
- [ ] **Mirror fallbacks**: Alternative download sources
- [ ] **Offline detection**: Clear error messages

### 17. Permission Issues
- [ ] **sudo access**: Proper privilege escalation
- [ ] **File permissions**: Correct ownership of installed files
- [ ] **Directory creation**: Handles permission-restricted directories
- [ ] **System service**: Proper systemd service permissions

### 18. Hardware Variations
- [ ] **CPU-only systems**: Graceful degradation without GPU
- [ ] **Limited RAM**: Appropriate model size recommendations
- [ ] **Storage constraints**: Smaller model alternatives
- [ ] **WSL limitations**: Windows-specific workarounds

### 19. Software Conflicts
- [ ] **Existing installations**: Detects and preserves user setups
- [ ] **PATH conflicts**: Resolves Windows/WSL binary conflicts
- [ ] **Library conflicts**: Handles CUDA/driver version mismatches
- [ ] **Python environment**: Isolated virtual environments

## 🎯 Functional Testing

### 20. Service Startup
- [ ] **Sequential startup**: llama-server first, then dependencies
- [ ] **Health verification**: All endpoints respond correctly
- [ ] **Port availability**: No conflicts on 8080, 8642, 3000
- [ ] **Process isolation**: Services run in correct user contexts

### 21. API Functionality
- [ ] **llama-server API**: OpenAI-compatible chat completions
- [ ] **Hermes WebAPI**: Agent communication endpoints
- [ ] **Workspace UI**: Full web interface loads
- [ ] **Tool calling**: Function execution capabilities

### 22. CLI Tools
- [ ] **hermes command**: Agent interaction works
- [ ] **qwen command**: Code assistant functionality
- [ ] **vram monitoring**: GPU usage display
- [ ] **Service management**: All control commands work

### 23. Model Operations
- [ ] **Model loading**: Selected model loads without errors
- [ ] **Inference speed**: Reasonable token generation rates
- [ ] **Context handling**: Proper context window management
- [ ] **Memory usage**: Appropriate VRAM/CPU utilization

## 📊 Performance Validation

### 24. Installation Speed
- [ ] **First run**: Completes in reasonable time
- [ ] **Subsequent runs**: Much faster due to optimizations
- [ ] **Network efficiency**: Minimal redundant downloads
- [ ] **Build caching**: ccache effectiveness

### 25. Runtime Performance
- [ ] **Startup time**: Services start within expected timeframe
- [ ] **Memory usage**: Appropriate resource utilization
- [ ] **Response latency**: Acceptable API response times
- [ ] **Concurrent users**: Handles multiple connections

## 🔄 Update & Maintenance

### 26. Update Mechanisms
- [ ] **Component updates**: All tools update to latest versions
- [ ] **Dependency updates**: Python packages refreshed
- [ ] **Security patches**: Latest security updates applied
- [ ] **Configuration preservation**: User settings maintained

### 27. Backup & Recovery
- [ ] **Configuration backup**: Important files preserved
- [ ] **Rollback capability**: Can revert problematic updates
- [ ] **Data preservation**: Models and configurations safe
- [ ] **Clean uninstall**: Complete removal possible

## 🎉 Success Criteria

### **Installation Success**
- [ ] All components install without errors
- [ ] Services start automatically on boot
- [ ] Web interfaces accessible on correct ports
- [ ] CLI tools functional and responsive
- [ ] No system stability issues

### **User Experience**
- [ ] Clear progress indicators throughout
- [ ] Helpful error messages with solutions
- [ ] Intuitive command structure
- [ ] Comprehensive documentation available
- [ ] Reasonable resource requirements

### **Maintainability**
- [ ] Clean, readable code structure
- [ ] Proper error handling and logging
- [ ] Modular component design
- [ ] Easy update mechanisms
- [ ] Comprehensive testing coverage

---

## 🧪 Test Execution Checklist

### **Environment Setup**
- [ ] Fresh Ubuntu/WSL2 system
- [ ] Sufficient disk space (50GB+)
- [ ] Internet connectivity
- [ ] NVIDIA GPU (optional, for CUDA testing)

### **Test Execution Order**
1. [ ] Run installation script with different options
2. [ ] Test all CLI commands
3. [ ] Verify web interfaces
4. [ ] Test service management
5. [ ] Validate API functionality
6. [ ] Performance benchmarking
7. [ ] Update mechanism testing
8. [ ] Error scenario testing

### **Documentation Updates**
- [ ] Update README with any new features
- [ ] Document known limitations
- [ ] Create troubleshooting guide
- [ ] Update version compatibility matrix

**Test Status**: ⏳ Ready for execution
**Estimated Duration**: 2-4 hours for full test suite
**Success Rate Target**: 100% core functionality, 95%+ optional features</content>
<parameter name="filePath">/workspace/8a2131b2-e10d-4ca4-b0be-3cc27d8e159c/sessions/agent_99581cb9-23f5-47a7-928a-e683046d082e/TESTING_CHECKLIST.md