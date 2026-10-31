S0=$(cd "$(dirname "$0")" && pwd); export PYTHONPATH="$S0/../.."; mkdir -p "${UIUI_ML_ROOT:-./workspace}/dec-dev"; export UIUI_ML_ROOT=$(cd "${UIUI_ML_ROOT:-./workspace}" && pwd); cd "$UIUI_ML_ROOT/dec-dev"; export PYTHONDONTWRITEBYTECODE=1 CUDA_VISIBLE_DEVICES= OMP_NUM_THREADS=12
S=dev-mix,hiacc,mucs,fleurs-hi,svarah-partial,monsoon-en-in,librispeech-clean
R="python $S0/run_decode.py eval --cache cache --sets $S"
echo "## no LM, no guard";  $R --out runs/final-base.json --dump runs/f-base 2>&1 | grep -v -i warn | cut -c1-135
echo "## guard only";       $R --guard --g-tps 11.65 --out runs/final-guard.json --dump runs/f-guard 2>&1 | grep -v -i warn | cut -c1-135
echo "## o6 lam0.1 two_stage"; $R --lm lms/o6.trie.bin --lam 0.1 --out runs/final-o6.json --dump runs/f-o6 2>&1 | grep -v -i warn | cut -c1-175
echo "## o4 lam0.1 two_stage"; $R --lm lms/o4.trie.bin --lam 0.1 --out runs/final-o4.json --dump runs/f-o4 2>&1 | grep -v -i warn | cut -c1-175
echo "## o6 joint lam0.2 beta0.7"; $R --lm lms/o6.trie.bin --fusion joint --lam 0.2 --beta 0.7 --out runs/final-o6joint.json --dump runs/f-o6joint 2>&1 | grep -v -i warn | cut -c1-175
echo "## o6 lam0.1 + guard"; $R --lm lms/o6.trie.bin --lam 0.1 --guard --g-tps 11.65 --out runs/final-o6guard.json --dump runs/f-o6guard 2>&1 | grep -v -i warn | cut -c1-175
