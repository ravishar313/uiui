#!/bin/bash
# Start the autoresearch runners (one tmux session ar-gpuN per GPU in $AR_GPUS, default "0 1") and the GPU guard (ar-guard) unless already up (safe to run repeatedly).  From cron:
#   @reboot sleep 60 && $AR_HOME/ops/start_ar.sh >> $AR_HOME/logs/cron.log 2>&1
#   */10 * * * * $AR_HOME/ops/start_ar.sh >> $AR_HOME/logs/cron.log 2>&1
# Each runner waits while a production job file is in $UIUI_ML_ROOT/jobs/active or its own GPU is in use by someone else.  `touch ar/STOP` stops everything (and this script then stays idle);
# `touch ar/STOP-gpuN` stops only GPU N's runner.  The guard (ops/gpu_guard.py) pauses / pre-empts our trainings when the GPUs get too loaded or somebody else starts a job.
ML=${UIUI_ML_ROOT:-$PWD/workspace}
AR=${AR_HOME:-$ML/ar}
PY=${AR_PY:-python3}
[ -f "$AR/STOP" ] && exit 0
mkdir -p "$AR/logs" "$AR/state"
# legacy single runner (tmux ar-runner, state/runner.lock) still alive? then do not start a second runner on GPU 0 next to it
legacy_up() { tmux has-session -t ar-runner 2>/dev/null && return 0; ( exec 8>"$AR/state/runner.lock"; ! flock -n 8 ); }
for g in ${AR_GPUS:-0 1}; do
  [ -f "$AR/STOP-gpu$g" ] && continue
  if [ "$g" = 0 ] && legacy_up; then echo "$(date '+%F %T') legacy runner (ar-runner) still up: not starting ar-gpu0"; continue; fi
  tmux has-session -t "ar-gpu$g" 2>/dev/null || tmux new-session -d -s "ar-gpu$g" "AR_GPU=$g $AR/runner.sh >> $AR/logs/runner-gpu$g.log 2>&1; sleep 5"
done
tmux has-session -t ar-guard 2>/dev/null || tmux new-session -d -s ar-guard "$PY $AR/ops/gpu_guard.py run >> $AR/logs/guard.log 2>&1; sleep 5"
