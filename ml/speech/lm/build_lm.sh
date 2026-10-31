#!/bin/bash
# Build KenLM n-gram LMs over BPE token ids.  usage: build_lm.sh <order> <name> <prune...> ; env: TEXT (default lmdata/train_ids.txt)
# Modified Kneser-Ney, interpolated (KenLM default).  CPU limited to 12 cores via taskset.
set -e
D=$(cd "${UIUI_ML_ROOT:-./workspace}" && pwd)/dec-dev
K=$D/kenlm-src/build/bin
ORDER=$1; NAME=$2; shift 2
TEXT=${TEXT:-$D/lmdata/train_ids.txt}
mkdir -p $D/lmdata/tmp $D/lms
CORES=${CORES:-36-47}
taskset -c $CORES $K/lmplz -o $ORDER -S 16G -T $D/lmdata/tmp --discount_fallback ${@:+--prune "$@"} --text $TEXT --arpa $D/lms/$NAME.arpa 2>&1 | tail -n 30
taskset -c $CORES $K/build_binary -q 8 -b 8 trie $D/lms/$NAME.arpa $D/lms/$NAME.trie.bin 2>&1 | tail -n 3
ls -la $D/lms/$NAME.*
