S0=$(cd "$(dirname "$0")" && pwd); export PYTHONPATH="$S0/../.."; mkdir -p "${UIUI_ML_ROOT:-./workspace}/dec-dev"; export UIUI_ML_ROOT=$(cd "${UIUI_ML_ROOT:-./workspace}" && pwd); cd "$UIUI_ML_ROOT/dec-dev"; export PYTHONDONTWRITEBYTECODE=1 CUDA_VISIBLE_DEVICES= OMP_NUM_THREADS=12
for lm in o3 o4 o5 o6 o6p o6phinc; do
 echo "## $lm"
 python $S0/run_decode.py eval --cache cache --sets dev-mix --lm lms/$lm.trie.bin --lam 0.1,0.2,0.3,0.4,0.5,0.7 --out runs/sweep1-$lm.json 2>&1 | grep -v -i warn
done
echo "## two_stage fine, o6 / o4 / o6phinc"
for lm in o6 o4 o6phinc; do echo "# $lm"; $R --lm lms/$lm.trie.bin --lam 0.03,0.05,0.075,0.1,0.15 --out runs/sweep2-$lm.json 2>&1 | grep -v -i warn | cut -c1-120; done
echo "## joint o6"
$R --lm lms/o6.trie.bin --fusion joint --lam 0.05,0.1,0.2,0.3 --beta 0,0.2,0.4,0.7,1.0 --out runs/sweep2-joint.json 2>&1 | grep -v -i warn | cut -c1-120
