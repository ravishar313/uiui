#!/bin/bash
S=$(cd "$(dirname "$0")" && pwd); export PYTHONPATH="$S/../.."
export UIUI_ML_ROOT=$(cd "${UIUI_ML_ROOT:-./workspace}" && pwd); cd "$UIUI_ML_ROOT/bench"; export HF_HOME=$PWD/hf BS=8 PYTHONWARNINGS=ignore
H="mucs-hien-test hiacc fleurs-hi"
R="python $S/run_hf.py"
$R parakeet auto
$R swift en; $R swift auto $H
$R qwen06 auto; $R qwen06 en $H
$R w3turbo auto; $R w3turbo en
$R qwen17 auto; $R qwen17 en $H
$R prime en; $R prime auto $H
$R w3 auto; $R w3 en
echo ALLDONE
