#!/usr/bin/env bash

echo "🎯 Complete LLM Workflow Demo"
echo "=============================="
echo ""

echo "1. Install the system:"
echo "   ./install.sh"
echo "   → Builds llama.cpp with CMake + CUDA"
echo "   → Downloads selected model"
echo "   → Creates wrapper scripts"
echo ""

echo "2. Switch models:"
echo "   switch-model"
echo "   → Shows 12 optimized models for RTX 3060"
echo "   → Downloads and configures selected model"
echo ""

echo "3. Start the server:"
echo "   start-llm"
echo "   → Launches with RTX 3060 optimized flags"
echo "   → Flash attention, q8_0/q4_0 KV cache, 6 threads"
echo "   → Readiness check with progress feedback"
echo ""

echo "4. Monitor system:"
echo "   vram"
echo "   → GPU memory, temperature, utilization"
echo "   → Server status and active model"
echo ""

echo "5. Use the LLM:"
echo "   llm-status    → Check if server is running"
echo "   stop-llm      → Stop the server cleanly"
echo "   hermes        → Chat with Hermes Agent"
echo ""

echo "6. Auto-start (optional):"
echo "   systemctl --user start llama-server"
echo "   → Background service with auto-restart"
echo ""

echo "✅ All commands are installed to ~/.local/bin/"
echo "✅ Add to ~/.bashrc: export PATH=\"\$HOME/.local/bin:\$PATH\""
echo ""
echo "🚀 Ready for production LLM inference on RTX 3060!"
