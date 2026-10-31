#!/bin/bash
# Reproduce parity + baselines + the single fine-tune + its evals. ~6 min on an M5 Pro.
set -e; cd "$(dirname "$0")"
PY=python; WP=data/workplace; GEN=data/general
$PY build_general.py                                   # needs data/general/{fleurs_en_*.tsv,oasst2_ready.trees.jsonl.gz}, see README
$PY parity.py --workplace $WP/sentences_eval.jsonl --general $GEN/regression_eval.jsonl
$PY eval_cleanup.py --gold $WP/sentences_eval.jsonl --out runs/baseline_onnx_workplace
$PY eval_cleanup.py --gold $GEN/regression_eval.jsonl --split-by source --out runs/baseline_onnx_general
$PY eval_cleanup.py --gold $WP/sentences_eval.jsonl --backend torch --out runs/baseline_fp32_workplace
$PY eval_cleanup.py --gold $GEN/regression_eval.jsonl --backend torch --split-by source --out runs/baseline_fp32_general
$PY finetune.py --train $WP/sentences_train.jsonl --replay $GEN/replay_train.jsonl --replay-share 0.3 --out runs/ft1 | tee runs/ft1.log
$PY eval_cleanup.py --gold $WP/sentences_eval.jsonl --backend torch --ckpt runs/ft1/best --out runs/ft1/eval_workplace
$PY eval_cleanup.py --gold $GEN/regression_eval.jsonl --backend torch --ckpt runs/ft1/best --split-by source --out runs/ft1/eval_general
