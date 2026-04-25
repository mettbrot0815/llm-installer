#!/usr/bin/env bash

echo "Testing Model Selector from install.sh..."

# Extract the model selection part from install.sh
MODELS=(
  "1|unsloth/Qwen3.5-9B-GGUF|Qwen3.5-9B-Q4_K_M.gguf|Qwen3.5-9B|5.3|256K|8|6|mid|chat,code,reasoning|@sudoingX pick · 50 tok/s on RTX 3060"
  "2|kai-os/Carnice-9b-GGUF|Carnice-9b-Q6_K.gguf|Carnice-9b (Hermes)|6.9|256K|8|6|mid|hermes,agent,tool-use|Qwen3.5-9B tuned for Hermes Agent harness"
  "3|bartowski/Meta-Llama-3.1-8B-Instruct-GGUF|Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf|Llama 3.1 8B|4.1|128K|8|6|mid|chat,code,reasoning|Meta · excellent instruction"
  "4|bartowski/Qwen2.5-Coder-14B-Instruct-GGUF|Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf|Qwen2.5 Coder 14B|8.99|131K|12|10|mid|code|#1 coding on 3060"
  "5|Qwen/Qwen3-14B-GGUF|Qwen3-14B-Q4_K_M.gguf|Qwen 3 14B|9.0|131K|14|10|mid|chat,code,reasoning|Strong planning"
  "6|bartowski/google_gemma-3-12b-it-GGUF|google_gemma-3-12b-it-Q4_K_M.gguf|Gemma 3 12B|7.3|128K|12|10|mid|chat,code|Google Gemma 3 · strict roles"
  "7|bartowski/google_gemma-4-12b-it-GGUF|google_gemma-4-12b-it-Q4_K_M.gguf|Gemma 4 12B|7.3|128K|12|10|mid|chat,code|Google Gemma 4 · 128K ctx"
  "8|unsloth/Qwen3-30B-A3B-GGUF|Qwen3-30B-A3B-Q4_K_M.gguf|Qwen 3 30B MoE|17.0|128K|20|16|large|chat,code,reasoning|MoE · 3B active params"
  "9|bartowski/DeepSeek-R1-Distill-Qwen-32B-GGUF|DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf|DeepSeek R1 32B|17.0|64K|32|20|large|reasoning|R1 distill"
  "10|DJLougen/Harmonic-Hermes-9B-GGUF|Harmonic-Hermes-9B-Q5_K_M.gguf|Harmonic Hermes 9B|6.5|256K|8|6|mid|hermes,agent,tool-use|Harmonic AI · Hermes-tuned 9B · Q5_K_M"
  "11|KyleHessling1/Qwopus-GLM-18B-Merged-GGUF|Qwopus-GLM-18B-Healed-Q4_K_M.gguf|Qwopus-GLM 18B|10.5|64K|12|10|mid|chat,code,reasoning|Merged GLM · Q4_K_M · community"
  "12|unsloth/gemma-4-26B-A4B-it-GGUF|gemma-4-26B-A4B-it-UD-IQ3_XXS.gguf|Gemma 4 26B MoE|9.4|128K|12|10|mid|chat,code,reasoning|Google MoE · 4B active · IQ3_XXS"
)

echo ""
echo "Available Models:"
echo "─────────────────────────────────────"
local idx hf_repo gguf_file dname size_gb ctx min_ram min_vram tier tags desc
while IFS='|' read -r idx hf_repo gguf_file dname size_gb ctx min_ram min_vram tier tags desc; do
    echo "$idx) $dname ($size_gb GB, $ctx ctx)"
    echo "   $desc"
    echo ""
done < <(printf '%s\n' "${MODELS[@]}")

echo "This is how the model selector appears in the install.sh script!"
echo ""
echo "Users can select by number (1-12) or 'u' for custom URL."
