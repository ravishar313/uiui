#!/bin/bash
# download first NBLK x 250MB of nptel-train.tar.gz.partaa (Zenodo 4590121) in parallel ranges, resumable per block
mkdir -p "${UIUI_ML_ROOT:-./workspace}/data-nptel/zen"; export UIUI_ML_ROOT=$(cd "${UIUI_ML_ROOT:-./workspace}" && pwd); cd "$UIUI_ML_ROOT/data-nptel/zen"
NBLK=${1:-100}
one() { i=$1; f=$(printf blk_%04d $i); s=$((i*250000000)); e=$((s+249999999)); 
  while [ "$(stat -c %s $f 2>/dev/null || echo 0)" != 250000000 ]; do
    curl -sL -r $s-$e -o $f.part --max-time 1800 https://zenodo.org/records/4590121/files/nptel-train.tar.gz.partaa && [ "$(stat -c %s $f.part)" = 250000000 ] && mv $f.part $f || sleep 5
  done; }
export -f one
seq 0 $((NBLK-1)) | xargs -P 14 -I{} bash -c "one {}"
echo ALLDONE
