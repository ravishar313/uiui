#!/bin/bash
# batch-1 real-time factor probe: BS=1 on the first 20 clips of monsoon-en-in (rerun of run_hf.py into a scratch dir)
S=$(cd "$(dirname "$0")" && pwd)
export UIUI_ML_ROOT=$(cd "${UIUI_ML_ROOT:-./workspace}" && pwd); cd "$UIUI_ML_ROOT/bench"
PYTHONPATH="$S/../.." python "$S/rtf_probe.py"
