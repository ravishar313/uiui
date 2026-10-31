#!/bin/bash
# Autoresearch runner: loops over ar/queue/*.yaml in name order, one experiment at a time on GPU $AR_GPU (default 0); start one runner per GPU (see program.md, runner_lib.py, ops/gpu_guard.py).
# Start (idempotent, tmux + flock):  $AR_HOME/ops/start_ar.sh   Stop all after their current experiment: touch $AR_HOME/STOP;  one GPU: touch STOP-gpuN
# Survives reboots through cron (@reboot + */10 -> start_ar.sh); a run interrupted by a reboot restarts from scratch (its out dir is per experiment).
set -u
AR=${AR_HOME:-$(cd "$(dirname "$(readlink -f "$0")")" && pwd)}; export AR_HOME=$AR
export AR_PY=${AR_PY:-python3}; PY=$AR_PY
ML=${UIUI_ML_ROOT:-$PWD/workspace}
POLL=${AR_POLL_SECS:-60}; ERR_RETRY=${AR_ERR_RETRY:-300}
export AR_GPU=${AR_GPU:-0}; G=$AR_GPU
case $G in ''|*[!0-9]*) echo "AR_GPU must be a GPU index (got '$G')"; exit 2;; esac
export AR_DUTY_SLEEP=${AR_DUTY_SLEEP:-0.12}      # train.py idles this fraction of each step: our own util stays ~77-80 % (< 90 %); 0 = off
mkdir -p "$AR"/{queue,done,out,state,logs} "$AR/state/running/gpu$G"
exec 9>"$AR/state/runner-gpu$G.lock"; flock -n 9 || { echo "runner for GPU $G already running"; exit 0; }
say() { echo "[$(date '+%F %T')] runner.sh gpu$G: $*"; }
stopped() { [ -f "$AR/STOP" ] || [ -f "$AR/STOP-gpu$G" ]; }

gpu_busy() {   # looks at GPU $G only (the other GPU has its own runner).  Reason is printed by gpu_guard.py busy.
  [ "${AR_SKIP_GPU_CHECK:-0}" = 1 ] && return 1
  compgen -G "$ML/jobs/active/*.job" >/dev/null && { BUSY_WHY="production job file"; return 0; }
  # busy: a process of ours on GPU $G, a foreign process > 6 GB, or util > 20 % (10 s mean) with none of ours there.  Small idle resident services of other users don't count.
  BUSY_WHY=$("$PY" "$AR/ops/gpu_guard.py" busy --gpu "$G" 2>&1); return $?
}
has_work() { compgen -G "$AR/queue/*.yaml" >/dev/null && return 0; compgen -G "$AR/state/running/gpu$G/*.yaml" >/dev/null && return 0; grep -q '"rows": null' "$AR/best.json" 2>/dev/null && return 0; return 1; }

say "up (AR_HOME=$AR, duty sleep $AR_DUTY_SLEEP)"
[ "$G" -gt 0 ] && sleep $(( G * ${AR_STAGGER_SECS:-90} ))   # don't load two models at the same instant
while true; do
  stopped && { say "STOP file present: exiting"; exit 0; }
  if ! has_work; then sleep "$POLL"; continue; fi
  if ! "$PY" -I "$AR/locked/verify.py" --ar-home "$AR"; then say "locked sets / evaluator / test manifests differ from hashes.json: REFUSING to run; retry in ${ERR_RETRY}s"; sleep "$ERR_RETRY"; continue; fi
  if gpu_busy; then say "GPU $G in use ($BUSY_WHY): waiting"; sleep 120; continue; fi
  "$PY" "$AR/runner_lib.py" run-one 9>&-; rc=$?
  case $rc in
    0) ;;                                  # handled one; look for the next immediately
    10|11) sleep "$POLL" ;;                # queue empty / best.json not initialised
    12) sleep 120 ;;                       # pre-empted by the GPU guard (experiment is back in the queue); gpu_busy decides when to go on
    *) say "runner_lib exit $rc; retry in ${ERR_RETRY}s"; sleep "$ERR_RETRY" ;;
  esac
done
