#!/bin/bash
S=$(cd "$(dirname "$0")" && pwd); export PYTHONPATH="$S/../.."
export UIUI_ML_ROOT=$(cd "${UIUI_ML_ROOT:-./workspace}" && pwd); cd "$UIUI_ML_ROOT/bench"
for b in mlx-qwen06-bf16 mlx-qwen06-4bit mlx-w3turbo-fp16 mlx-w3turbo-4bit; do python $S/latency_probe.py $b > results/latency.$b.log 2>&1; done
for b in hf-qwen06-fp16 hf-qwen06-bf16 hf-w3turbo-fp16; do python $S/latency_probe.py $b > results/latency.$b.log 2>&1; done
