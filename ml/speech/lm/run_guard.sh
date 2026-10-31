#!/bin/bash
# Guard evaluation under the two symbol-cap semantics.  Runs from $UIUI_ML_ROOT/dec-dev/ (cache/ already encoded).
S0=$(cd "$(dirname "$0")" && pwd); export PYTHONPATH="$S0/../.."; mkdir -p "${UIUI_ML_ROOT:-./workspace}/dec-dev"; export UIUI_ML_ROOT=$(cd "${UIUI_ML_ROOT:-./workspace}" && pwd); cd "$UIUI_ML_ROOT/dec-dev"; export PYTHONDONTWRITEBYTECODE=1 CUDA_VISIBLE_DEVICES= OMP_NUM_THREADS=12
S=dev-mix,hiacc,mucs,fleurs-hi,svarah-partial,monsoon-en-in,librispeech-clean
R="python $S0/run_decode.py eval --cache cache --sets $S"
f() { grep -v -i warn | cut -c1-135; }
echo "## HF semantics (no per-frame cap), no guard";                 $R --max-symbols -1 --dump runs/h-base   2>&1 | f
echo "## HF semantics, guard all (K=3, n 3-6, p99.9 rate, zero-dur)"; $R --max-symbols -1 --guard --g-tps 11.65 --dump runs/h-guard 2>&1 | f
echo "## HF semantics, guard zero-dur only";                          $R --max-symbols -1 --guard --g-nmax 0 --g-zero 0 --dump runs/h-gzero 2>&1 | f
echo "## HF semantics, guard ngram only";                             $R --max-symbols -1 --guard --g-zero -1 --dump runs/h-gng 2>&1 | f
echo "## HF semantics, guard rate only";                              $R --max-symbols -1 --guard --g-nmax 0 --g-zero -1 --g-tps 11.65 --dump runs/h-grate 2>&1 | f
