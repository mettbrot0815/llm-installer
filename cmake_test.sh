#!/usr/bin/env bash
set -euo pipefail

echo "Building llama.cpp with CUDA support (RTX 3060 optimized)..."
rm -rf build

cmake -B build \
    -DGGML_CUDA=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CUDA_ARCHITECTURES="86" \   # Ampere = RTX 30-series
    -DLLAMA_CURL=ON \
    -DGGML_CCACHE=ON

cmake --build build --config Release -j8

echo "✅ llama.cpp built successfully"
