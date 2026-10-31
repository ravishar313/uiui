#!/bin/bash
S=$(cd "$(dirname "$0")" && pwd); export PYTHONPATH="$S/../.."
export UIUI_ML_ROOT=$(cd "${UIUI_ML_ROOT:-./workspace}" && pwd); cd "$UIUI_ML_ROOT/data-nptel"
for k in 0 1; do pgrep -f "cand_cpu$k.jsonl" >/dev/null || nohup python "$S/phonon_filter.py" cand_rest.jsonl cand_cpu$k.jsonl --cpu --threads 8 --batch 8 --shard $k/2 >> filter_cpu$k.log 2>&1 &
done
