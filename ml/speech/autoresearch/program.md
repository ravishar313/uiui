# autoresearch: hill-climbing the on-device ASR model

Adapted from karpathy/autoresearch. You are an autonomous researcher. You propose an experiment, the runner trains it for a fixed wall-clock budget on the training machine,
a locked scorer decides whether it beat the current best, and you keep going. **The model only improves when an experiment measurably beats the current best.**

Goal: lower WER for the real user, an English-first Indian professional who sometimes mixes Hindi (Roman script) and uses a lot of workplace vocabulary, without hurting Indian
or native English, for the shipping model: every encoder linear is a
lut4 4-bit LUT per 16 rows (QAT), distilled from a dense teacher. Same architecture, same on-device size, same decode speed: only the weights, training recipe,
data mix, loss and schedule may change.

## Where things live

- Code: `$AR_HOME/code/` is a copy of `train/` + `export/` (plus `lab/`, `eval/`, `trainability/`); `program.md`, `runner.sh`, `runner_lib.py` and `ops/` sit in `$AR_HOME`.
- `$AR_HOME` (conventionally `$UIUI_ML_ROOT/ar`) holds `code/`, `queue/`, `done/`, `out/ar-<exp>/`, `results.tsv`, `kept.tsv`, `best.json`, `locked/`.
- After every code change: commit in `ar/code` and write the short commit hash to `ar/code/COMMIT`.
- Results: `results.tsv`, `best.json`; per experiment `out/ar-<exp>/{train.log,verdict.json,sanity.json,vibe.md}`; the tracker dashboard (tag `autoresearch`).

## What you may and may not touch

You MAY edit experiment configs (queue files, `ar/code/train/configs/*.yaml`) and the code in the `ar/code` snapshot: recipe, losses, schedules, data sampling and
augmentation, distillation, EMA, optimiser, QAT/LUT details. Keep `train.py`'s default behaviour intact when new keys are absent.

You MUST NOT edit or work around: `ar/locked/` (dev-sel, dev-hold, vibe, `select_v2.py`, `verify.py`, `evalx/` = the scorer copy of `score.py` + `fair_wer.py` + `roman_variants.py` + variant tables, `hashes.json`), `eval/evalx/score.py`, `ar/code/train/evaluate.py` (hash-locked:
the runner refuses to start if it changes), the eval manifests, or `$UIUI_ML_ROOT/train` and `$UIUI_ML_ROOT/export` (production). Do not train on dev, test or vibe clips:
configs may only use the train manifests listed in `locked/allowed_train.json` (the eight `data/manifests/<src>/train.jsonl` sources, plus nptel2020 and the workplace synthetic train set once they exist) (anything else is rejected as a crash). Do not read or tune against
`kept.tsv` (hold-out and test numbers are report-only for the human owner; peeking turns them into a second selection set). Never log or print audio, notes, prompts or credentials.
Do not kill processes you did not start.

## GPU rule (two GPUs, guarded)

The training machine's PSU is weak (it hard-resets under too much CPU+GPU load). Both GPUs may be used, each under 90%, if our jobs pause or stop safely
when load gets too high or someone else starts a GPU job. So: one runner per GPU (`ar-gpu0`, `ar-gpu1`, `AR_GPU=N`), one experiment per GPU, each
throttled by `AR_DUTY_SLEEP` (default 0.12, ~77% util), and `ops/gpu_guard.py` (`ar-guard`) pauses (SIGSTOP), resumes or pre-empts (back to the queue)
our own train.py when a new foreign GPU process appears, a GPU averages > 90% util or power, or total power > 90% of both limits. A runner only starts on
a GPU with no job of ours, no foreign process > 6 GB and no foreign utilisation. Never start another GPU process by hand; keep CPU side jobs moderate
(niced, load < ~16). Debug on CPU or by queuing a short experiment.

## Budget

Default **25 minutes of training per experiment** (`train.max_minutes: 25`; evaluation and model loading do not count). Hard timeout: budget + 25 min.
Set `train.total_steps` so the schedule ends near the budget (check s/step in an earlier `train.log`), or set `train.time_schedule: true` to drive the cosine LR by elapsed
budget instead of steps. EMA decay must fit the steps you will actually get (0.999 needs well over 1000). Use a new `train.seed` per experiment so you do not replay the data order of earlier runs.

## Queue file (`ar/queue/NNN-short-name.yaml`; name order = run order; names unique forever)

```yaml
description: one line, what and why          # required; goes to results.tsv
base: round3_lut4_kd_v1.yaml                 # a config in ar/code/train/configs (or absolute); omit if this file is a full config
overrides:                                   # deep-merged over base
  optim: {lr: 3.0e-5}
  train: {max_minutes: 25, total_steps: 1500, seed: 7}
commit: 1a2b3c4d                             # optional: crash unless ar/code/COMMIT contains this (use when the experiment needs your code change)
init_ckpt: best                              # default; resolved to best.json at run time (do not paste paths)
```

The runner enforces: eval sets (dev-sel + vibe), no eval at start, final eval only, run dir, tags, `model.init_ckpt`, checkpoint settings, allowed train manifests.
Every experiment starts from the current best model (EMA weights; QAT/lut4 structure from the config; fresh optimiser, schedule and EMA). Queue several if you like:
each starts from whatever is best when it begins.

## The decision rule (locked, `ar/locked/select_v2.py`)

`dev-sel` (about 2.4k clips, 5 categories, exact numbers in `locked/leakage_report.json`) is scored per clip for the candidate and the current best. The categories (field `cat`):
`en_in` Indian English (Svarah, Monsoon, Common Voice India, NPTEL lectures), `cm` English-heavy code-mixed (spoken-tutorial MUCS plus IndicVoices clips that are >= 25% English words),
`work` workplace dictation (synthetic TTS with a `terms` list of workplace vocabulary), `hi` Hindi robustness (Kathbath, Vaani, IndicVoices with little English), `native` native English
(LibriSpeech, FLEURS-en). WER per category: **T-WER** (`fair_wer.twer`, eval-only variant map: attested Roman-Hindi spelling variants are folded, but hai/hain, ke/ka, par/pe, kar/ke,
mein/main stay errors; score.py's fair WER is NOT used) for `cm` and `hi`; **raw-token WER** (lowercase, punctuation stripped) for `en_in`, `work` and `native`.

Primary score **S = 0.40 en_in + 0.25 cm + 0.15 work + 0.10 hi + 0.10 native** (lower is better; a category absent from the sets is dropped and the weights renormalised, recorded in
`verdict.json`). Paired bootstrap stratified by category (1000 resamples, clips resampled with replacement within each category, same indices for candidate and best) gives delta S =
S_candidate - S_best with a 95% CI (absolute points).

**KEEP** if delta-S CI upper bound < 0 **and** every guard holds (per-category point delta, absolute WER points): en_in <= +0.2, native <= +0.3, cm <= +0.3, work <= +0.5, hi <= +1.0,
**and** workplace term accuracy (share of the reference `terms` of `work` clips reproduced exactly: case-insensitive, punctuation-stripped, multi-word terms as contiguous sequences) does
not drop by more than 1.0 point. Otherwise **DISCARD**.
Runaway = hyp words / ref words > 3. Sanity rules then force DISCARD whatever the WER says: empty hyps > best + 2; any new runaway clip (dev-sel or vibe);
Devanagari characters in more than 0.5% of hyps (output must stay Roman). A gain inside the CI is a discard: do not argue, run a better experiment.
`verdict.json` holds S, delta S with CI, the per-category table (WER, delta, CI, guard) and the term accuracy. `vibe.md` (about 60 fixed clips across the categories, previous best vs new,
changed lines flagged) and `sanity.json` (length ratio, empties, runaways, Devanagari share, type-token ratio, English-loanword share in cm/hi references) exist for every experiment.
Read them for kept and near-miss runs; a gain bought with collapsed vocabulary or mangled loanwords is not progress, so say so in the next description.

## Logging (`ar/results.tsv`, tab-separated, written by the runner; never edit)

`exp_id  commit  S  en_in_wer  cm_wer  work_wer  hi_wer  native_wer  d_S  ci_S  runaways  peak_gb  minutes  status  description  term_acc  cm_fw_pts`; status is `keep`, `discard` or `crash`
(WERs as defined above; `term_acc` = workplace term accuracy in percent; `cm_fw_pts` = cm T-WER points that come from function words; `ci_S` is `lo,hi`; crashes have blank metrics and the reason in the description). `ar/best.json` names the current best checkpoint and its rows.
Disk: only the best and the last 2 discarded experiments keep checkpoints (about 15 GB each).

## The loop

1. Read `results.tsv`, `best.json`, the latest `vibe.md` / `sanity.json`. Pick the next idea: LR and schedule, LUT/scale learning rates, KD weights and layers, data mix and weights,
   SpecAugment, EMA, weight decay, hard-example mining from the train-side error audit, loss tweaks, decoder/joint fine-tuning, label smoothing, and so on.
2. Edit the config (and `ar/code` if needed: commit; change code only when the runner is idle or the queued experiments do not depend on the old code; the
   `commit:` guard protects you). A code idea that fails: `git reset --hard HEAD~1`.
3. Write the queue file. Wait for its row in `results.tsv` (about 40 to 70 minutes including evaluation).
4. Keep means the new best is automatic. Discard or crash: read `train.log` / `verdict.json`, then try the next idea. Simpler is better: a tiny gain that adds ugly complexity is not
   worth it; deleting something and getting equal-or-better results is a win.
5. **Do not stop to ask whether to continue.** The human owner may be asleep. Keep running experiments until interrupted. When ideas run dry, re-read the code, combine near-misses,
   try bolder changes. A trivial crash (typo, shape): fix it and requeue under a new name; a fundamentally broken idea: move on.

## Safeguards you do not control (so do not game them)

`dev-hold` (same recipe as dev-sel, disjoint clips and speakers; S and per-category WER) is scored on every kept experiment and four report-only test sets (hiacc, mucs-hien-test, fleurs-hi,
librispeech-clean; Svarah and Monsoon are now inside dev-sel / dev-hold) on every 3rd kept one; both go to `kept.tsv` for the human owner. Locked files are sha256-checked before every experiment. A gain that exists only on dev-sel is a selection artefact and shows up there.
