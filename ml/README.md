# ml: training, evaluation and export code for the uiui speech and cleanup models

This directory holds the Python/shell code that produced the shipped on-device models and the results in
[`docs/technical-report.md`](../docs/technical-report.md). It is a curated copy: debugging probes, one-off scratch
scripts, superseded versions, logs, outputs and virtualenvs were left out. No datasets, audio, manifests,
checkpoints, evaluation sets or result files are included.

## Layout

```
ml/
  uiui_root.py        UIUI_ML_ROOT helper (workspace root) and load_yaml()
  requirements.txt
  speech/
    train/            training loop, model modes (full / qat / lora / decoder), data loader, augmentation,
                      distillation, TDT decoding, evaluation, PTQ checks
    configs/          the training configs (YAML, paths use ${UIUI_ML_ROOT})
    data/             ingest, Devanagari -> Roman conversion, lexicon, manifests, English relabelling (+ READMEs)
    data-nptel/       NPTEL candidate selection, Phonon agreement filter, speaker clustering, manifests
    data-nptel-en2indic/  English-to-Indic NPTEL filter
    tts/              synthetic number-sentence generator and TTS prompt filter
    analysis/         digit-spacing label fix, long LibriSpeech clip builder
    pseudo/           Whisper pseudo-labelling and agreement filter
    eval/evalx/       the scorer (score.py, fair_wer.py, roman_variants.py, build_variants.py)
    eval/score/       checkpoint scoring helpers
    export/           PyTorch checkpoint -> Core ML bundle (encoder graph, five-value/LUT compression, decoder.bin)
    lm/               n-gram LM prepare/build/decode experiments and repetition-guard tools
    bench/            Mac benchmark scripts for third-party ASR models
    autoresearch/     locked-evaluation experiment runner, GPU guard, selection logic and tests
    lab/tracker.py    small file-based run tracker used by training and data scripts
    trainability/scripts/  fast TDT loss, QAT parametrisation, container reader used by train/modes.py
  cleanup/            punctuation/casing model: Python port of the app pipeline, fine-tuning, disfluency editor,
                      evaluation, int8 ONNX export, tests (see cleanup/README.md)
```

## Setup

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install -r ml/requirements.txt          # install the subset your stage needs (see comments in the file)
export PYTHONPATH=$PWD/ml                   # makes `uiui_root` importable; do not use `python -I`
export UIUI_ML_ROOT=$PWD/workspace          # optional; this is the default (relative to the current directory)
```

`UIUI_ML_ROOT` is the workspace that holds everything this code reads and writes: `data/` (manifests, audio, lexicon),
`evalsets/`, `train/out/` (run outputs), `ar/` (autoresearch home), `trainability/hf/parakeet` (the base HF model
directory) and so on. Configs use `${UIUI_ML_ROOT}`; `uiui_root.load_yaml` expands it (and the autoresearch runner does the same).
Scripts that need code from another directory find it relative to their own location.

## What runs each stage

| Stage | Scripts |
|---|---|
| Data ingest | `speech/data/ingest_parquet.py` (HF parquet -> 16 kHz wav + staged rows), `common.py`, `finalize.py` (eval exclusion, speaker-disjoint dev split, manifests), `report.py` |
| NPTEL | `speech/data-nptel/` (`zen_dl.sh` download, `decode.py`, `build_cand.py`, `phonon_filter*.py`, `build_pass.py`/`embed_pass.py`, `spk_embed*.py`, `finalize2.py`), `speech/data-nptel-en2indic/filter_en2indic.py` |
| Romanise | `speech/data/build_lexicon.py` (lexicon), `lexlib.py`, `romlib.py`, `romanize_hybrid.py`, `romanize_v2.py` (Devanagari -> casual Roman), `vaani_clean.py`, `build_v2.py`, `build_hy.py` (v2 / hybrid manifests), `reroman_evalsets.py`; see `speech/data/V2_README.md` |
| English labels | `speech/data/english_relabel.py` (needs the Phonon evaluator binary, see limits) |
| Label fixes / extra sets | `speech/analysis/` (`digsp*.py`, `build_libri_long.py`), `speech/tts/` (`gen_num.py`, `finalize.py`), `speech/pseudo/` |
| Train | `speech/train/train.py` with a config from `speech/configs/`; `modes.py`, `data.py`, `augment.py`, `distill.py`, `int6_dec.py`, `ckpt.py` |
| Checks during/after training | `speech/train/evaluate.py`, `ptq_eval.py`, `sens_scan.py`, `error_audit.py`, `verify_ckpt.py`, `profile_step.py`, `bench_kd.py`, `eval/score/score_ckpts.py`, `make_shim.py` |
| Evaluation / scoring | `speech/eval/evalx/score.py` (WER/CER with Hinglish normaliser), `fair_wer.py`, `roman_variants.py`; `speech/autoresearch/locked/` (set construction, locking, selection) |
| Export | `speech/export/export_bundle.py` (see `speech/export/README.md`), `accept.py` (compare two bundles), `compile_bundle.sh` |
| LM / decoding | `speech/lm/` (`prepare_text.py`, `build_lm.sh`, `run_decode.py`, `leak_check.py`, guard tools) |
| Benchmark | `speech/bench/` (`make_subsets.py`, `run_hf.py`, `run_all.sh`, `score_all.py`, latency/RTF probes) |
| Experiment runner | `speech/autoresearch/` (`runner.sh`, `runner_lib.py`, `program.md`, `ops/gpu_guard.py`, `ops/start_ar.sh`) |
| Text cleanup | `cleanup/` (`uiui_cleanup.py` port, `finetune.py`, `finetune_disfl.py`, `editor/`, `eval_*.py`, `asr_eval/`, `export/export_int8.py`, `run_all.sh`) |
| TTS | `speech/tts/` generates prompts only; the audio synthesis step itself is not part of this directory |

## Running a training config

Training expects the manifests and base model named in the config under `$UIUI_ML_ROOT` (they are not provided).

```bash
export PYTHONPATH=$PWD/ml UIUI_ML_ROOT=/path/to/workspace
# single GPU
python ml/speech/train/train.py --config ml/speech/configs/full-1029-v1.yaml
# two GPUs (DDP)
torchrun --nproc_per_node=2 ml/speech/train/train.py --config ml/speech/configs/full-1029-v1.yaml
# resume / override a value
python ml/speech/train/train.py --config ml/speech/configs/full-1029-v1.yaml --resume auto --set train.total_steps=100
```

Outputs go to `out_dir` from the config (`$UIUI_ML_ROOT/train/out/<run>`). `full-1029-v1.yaml` continues from
`full-1028-v1.yaml` (`model.init_ckpt` points at a step directory of that run, rebuilt with `speech/eval/score/make_shim.py`
if it was saved without `optim.pt`); `round3_lut4_kd_v1.yaml` distils from the checkpoint produced by `teacher_dense_r2.yaml`.
Configs prefixed `smoke_`, `bench_` and `resume_test` are for short CPU/GPU plumbing checks and need small local manifests
(`speech/train/make_smoke_data.py`).

Evaluation sets referenced as `ar/locked/*.jsonl` are produced by `speech/autoresearch/locked/build_sets_v2.py` and
frozen with `lock.py`; they are not included. Copy or link `speech/eval/evalx` to `$AR_HOME/locked/evalx` (already a
symlink inside this tree) before locking.

Export of a trained checkpoint (macOS, coremltools):

```bash
python ml/speech/export/export_bundle.py <checkpoint> <out_dir> [--requantize] [--allow-lossy]
```

## Limits

- No datasets are included, and several are gated or need accepted terms on the Hugging Face hub (for example
  IndicVoices and Vaani). The `.tsv` Roman spelling-variant tables used by `fair_wer.py` are not included either;
  `speech/eval/evalx/variants/README.md` says how to rebuild them. Without them the variant folding is a no-op.
- The locked evaluation sets, their hashes and the allowed-train list are not included. `autoresearch` tests that need
  them (`test_gpu_runners.py`, `dryrun.py`, `wiring_v2.py`, `cpu_train_test.py`) cannot run from this tree alone.
- Some tools referenced by the code are outside this directory: the Swift `phonon-eval` evaluator (set `PHONON_EVAL_BIN`;
  `PHONON_BUNDLE` for the model bundle), the formatting scripts described in `speech/data/FORMAT_README.md`, the
  workplace-text generator described in `speech/data/WORKPLACE_README.md`, the `eval-dev` text extraction used by
  `build_v2.py`, the TTS synthesis step, and the app resources needed by `cleanup/` (`UIUI_APP_ROOT`, default is the
  repository root).
- The code was run on two RTX 5090 GPUs (training, data, LM decoding) and on Apple silicon Macs (export, benchmarks,
  cleanup model). Other hardware is untested.
- Paths were rewritten from the original machine-specific layout to `UIUI_ML_ROOT`. The pure-Python test suites that need
  no data were run after the rewrite (see below); training, data, export, benchmark, LM and autoresearch runs
  were not re-run end to end on the cleaned tree. Treat paths and the shell wrappers as lightly verified.
- Scripts under `speech/bench/` expect separate environments for MLX models (`mlx-whisper`, `mlx-audio`) and for
  Hugging Face models; `run_latency.sh` calls `python` for both, so activate the right one.

## Tests that need no data

```bash
export PYTHONPATH=$PWD/ml
python ml/cleanup/tests/test_port.py
cd ml/speech/autoresearch/tests && python -m unittest test_select_v2 test_augment
cd ml/speech/export && python -m pytest tests
```

`test_select_v2` has one scorer test that needs the Roman variant tables and fails without them.

## Licence

Apache-2.0, as for the repository root. Vendored or third-party code and model/data licences stay with their owners;
see `speech/export/assets/` (Apache-2.0 code licence, CC-BY-4.0 weights licence, NOTICE) and the dataset licences
listed in the READMEs under `speech/data/` and `speech/pseudo/`.
