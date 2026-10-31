# uiui cleanup model: eval + fine-tune harness (PyTorch, MPS on a Mac)

Model: 33.8M multilingual MiniLM token classifier. 8 logits on the final subword of each word: 0-4 NONE/COMMA/PERIOD/QUESTION/EXCLAMATION, 5-7 LOWER/CAP/UPPER. It never changes words.
Everything under the app repository root (set `UIUI_APP_ROOT`; default is the root of this repository) is read-only and is only referenced (FP32 checkpoint `model-sources/MiniLM`, shipped int8 ONNX + SentencePiece in `resources/MiniLM`).

## Files
| file | purpose |
|---|---|
| `uiui_cleanup.py` | Python port of the app pipeline (details below) with ONNX and Torch backends |
| `tagging.py` | gold text -> ASR-style input (lowercase, no punctuation) and per-word punct/case labels |
| `parity.py` | ONNX int8 vs Torch FP32 agreement |
| `eval_cleanup.py` | the evaluation script (`--gold jsonl`) |
| `finetune.py` | fine-tuning (original recipe by default) |
| `build_general.py` | builds the general-English regression set and replay pool |
| `tests/test_port.py` | Swift test fixtures ported to pin the port (`python tests/test_port.py`) |
| `run_all.sh` | parity + baselines + the one fine-tune + its evals (about 6 min) |
| `sample/` | 91 hand-written sentences (60 train / 31 eval) for smoke tests |
| `data/workplace/` | frozen copy of the workplace corpus used here (md5 in `MD5.txt`; the data directories are not included in this repository) |
| `data/general/` | FLEURS/OASST2 downloads, `regression_eval.jsonl` (534), `replay_train.jsonl` (7,289) |
| `runs/` | metrics, worst examples, predictions, checkpoints (not included) |

Setup: create a Python 3.12 virtualenv, then install `torch transformers onnxruntime sentencepiece safetensors numpy regex`.

## What the app does (and the port mirrors)
`DictationCleanup.finish` -> `DictationCleanupText.segments` (split at whitespace into <=450 UTF-8 byte segments) -> `MiniLMFormattingRuntime.generate` per segment:
1. `accepted(source, source)` guard. Sources containing any of `/ \ @ \` < > [ ] { } | = _ + * $ #`, `a.b`, `1:1`/`10:30`, `x(`, `--flag`, bullets, code-ish first words are **returned unchanged, with no model run**. In the workplace eval 159 of 1,200 sentences (13%) hit this (decimals like 3.5 lakh and 7.2, times like 10:30, CI/CD, `St.`).
2. Words = regex `\p{L}[\p{L}\p{M}\p{N}'’-]*|\p{N}+(?:[.,]\p{N}+)*`, URLs skipped. All other punctuation in the input is ignored by the model and, except inside URLs, **deleted** from gaps by `reconstruct` (`. , ! ? ; :`), so the model sees the same input whether the ASR emitted punctuation or not. Model input is NFKC + lowercase of each word, so ASR casing is also irrelevant to the model.
3. Per-word SentencePiece encode (`pieces` ids: piece 0 -> 3, else piece+1), window = `[0] + pieces + [2]`, windows of <=126 pieces with 25 pieces / 24 words of context each side (`chunks`), logits read at the **last piece of each word**, argmax punct (0-4) and case (5-7) independently.
4. `reconstruct`: append `, . ? !` after the word, `applyCase` (CAP first letter, UPPER all; a word that already has an internal capital is left alone, which with lowercase ASR input means mixed forms like iPhone/GitHub can never be produced: the app leaves these to a personal-dictionary step).
5. `accepted(candidate, source)` re-check, then `DictationPunctuation.finalize` adds a terminal `.`/`?` if the text ends in a letter/digit (port includes the question heuristic).
What Phonon emits: lowercase, no punctuation (the evalsets are built that way and Parakeet is the fallback that does emit punctuation); either way step 2 makes it irrelevant.

Port approximations: Swift Character (grapheme) vs Python code point, Swift `lowercased()/folding` vs Python `lower()/casefold()`, ICU vs `regex`. No Swift run was possible without writing into the app repo, so the tokenizer/windowing/reconstruct/finalize port is pinned by the app's own Swift test fixtures (7 groups, all pass) rather than by a bit-exact cross-run.

## Parity (shipped int8 ONNX vs FP32 PyTorch, same Python pipeline)
`parity.py`: 210 inputs (100 workplace eval, 100 general, 10 long multi-window dictations, all lowercase/no-punct), 4,716 words. ONNX runs with the app's session options (1 thread, sequential, CPU).
- punctuation tag agreement 99.70% (14 words), case 99.43% (27 words)
- 188/210 sentences have identical tags, 200/210 identical final output strings
- logit abs diff: mean 0.040, p99 0.19, max 0.58
Disagreements are borderline quantization flips (e.g. `april` CAP vs lower, `.` vs `?`), consistent with the pilot report where FP32 vs int8 differ by about 0.1 point. Remaining difference between this harness and the app: the Swift-vs-Python approximations above and onnxruntime 1.31 (Python) vs 1.23 (app).

## Metrics (eval_cleanup.py)
Gold -> `strip_input` (lowercase; drop `. , ; : ! ?` unless between two alphanumerics such as `5.5`, `1:1`, `3,00,000`; drop quotes/brackets/dashes) -> full pipeline above (gate + finalize; `--no-gate`/`--no-finalize` for diagnostics) -> word-by-word comparison with the same word regex, so alignment is exact (0 alignment failures). Gold `;` counts as COMMA, `:` as NONE. Reported: per-class punctuation P/R/F1 (+ micro F1 excl. NONE), case accuracy on non-mixed words, **acronym-exact** (gold all-caps words >=2 chars incl. Q3, KPI; exact string), **proper-noun cap rate** (gold Capitalised, not sentence-initial, not "I"), sentence-start cap, over-capitalisation of lowercase words, mixed-case forms (iPhone, GitHub: exact rate always 0 by design), special forms (`1:1`/`10:30`, `P&L`, `₹N lakh`) as exact substring survival, sentence exact match (string and tags), top failing acronyms/proper nouns, `worst.jsonl`. Splits via `--split-by mix,field,register,source`.
Caveat for `--no-gate`: gated sentences then lose their `:`/`.` (words merge) and drop out as alignment failures, so those numbers are on an easier subset.

## Baselines (workplace eval, 1,200 sentences = 840 en + 360 hinglish; percentages)
| | punct F1 (excl NONE) | PERIOD | COMMA | QUESTION | case acc | acronym-exact (n=731) | proper-noun cap (n=1319) | sentence exact (string / tags) |
|---|---|---|---|---|---|---|---|---|
| shipped int8, ALL | 61.7 | 81.7 | 18.6 | 49.8 | 87.8 | 67.8 | 36.1 | 8.7 / 9.4 |
| en | 63.9 | 82.0 | 25.4 | 57.8 | 89.0 | 71.3 (568) | 40.9 (1050) | 9.9 / 10.8 |
| hinglish | 55.9 | 80.8 | 0.6 | 11.4 | 84.7 | 55.8 (163) | 17.1 (269) | 5.8 / 6.1 |
| FP32 (original checkpoint), ALL | 61.8 | 81.6 | 18.9 | 50.0 | 87.8 | 68.5 | 36.5 | 8.8 / 9.8 |

Other baseline facts (shipped int8, ALL): sentence-start cap 70.7%, lowercase words wrongly capitalised 2.9%, `₹N lakh` survives 93%, `10:30`/`1:1` survive 100% (they are gated, untouched), mixed-case forms exact 0% (first letter right 43%). Top acronym misses: CGPA, ASAP, GAAP, AS, SOW, EOD, BBA, IIM, EOM, ROAS (all left lowercase). Top proper-noun misses: month abbreviations (Aug, Jun, Feb, Mar, Nov; sometimes wrongly all-caps AUG/NOV/JAN), weekday Monday, product names (Opsgenie), common-word names (Form, Life).
General English regression (534 held-out sentences: 134 FLEURS dev, 400 OASST2): punct F1 77.9, PERIOD 92.5, COMMA 57.2, QUESTION 92.5 (OASST2), case acc 96.8, proper-noun 56.8, sentence exact 36.3 (`runs/baseline_onnx_general`).

## Fine-tune ft1 (one run)
Recipe: `finetune.py --train data/workplace/sentences_train.jsonl --replay data/general/replay_train.jsonl --replay-share 0.3 --out runs/ft1`, init = FP32 checkpoint, mode last2 (layers 10-11 + classifier, 3,552,008 trainable params, identical to training-config.json), AdamW lr 2e-5 wd 0.01, constant LR, clip 1.0, 2 epochs, batch 16, seed 20261024, final-piece supervision, mixed-case words masked from the case loss. Mix: 11,640 workplace (3% held out as dev) + 4,989 replay (30%; FLEURS train + OASST2 sentences) = 16,629 windows, 1,040 steps per epoch.
**Runtime on MPS: 53 s (epoch 1) and 49 s (epoch 2)**, plus about 15 s start-up; peak well under the 1.7 GB the original run reported. Best epoch by dev = 2.

| eval (FP32 Torch, vs FP32 baseline) | punct F1 | COMMA | QUESTION | case acc | acronym-exact | proper-noun | sentence exact (string) |
|---|---|---|---|---|---|---|---|
| workplace ALL: base -> ft1 | 61.8 -> 71.2 | 18.9 -> 53.6 | 50.0 -> 53.8 | 87.8 -> 92.0 | 68.5 -> 75.8 | 36.5 -> 61.2 | 8.8 -> 17.2 |
| workplace en | 64.1 -> 73.3 | 25.5 -> 57.6 | 58.7 -> 64.8 | 89.0 -> 92.0 | 71.8 -> 77.1 | 41.6 -> 65.3 | 10.2 -> 18.3 |
| workplace hinglish | 55.6 -> 65.9 | 1.2 -> 43.5 | 10.8 -> **0.0** | 84.6 -> 91.9 | 57.1 -> 71.2 | 16.4 -> 45.0 | 5.6 -> 14.4 |
| general regression (534) | 78.0 -> 83.4 | 57.5 -> 71.5 | 92.5 -> 93.5 | 96.8 -> 97.3 | 64.4 -> 66.1 | 57.0 -> 69.2 | 36.1 -> 42.5 |

No regression on general English, but note the replay pool is the same distribution (FLEURS/OASST2) as the regression set, so it is a no-damage check, not proof of broader generalisation; the gains there mostly show these sources were under-fit by the original last2 run. Not yet done: ONNX int8 export of ft1 (the app ships per-channel int8 MatMul+Gather, opset 17, legacy exporter, see the pilot REPORT); int8 flips about 0.3% of tags.

## Open issues
- Hinglish QUESTION F1 went to 0 (from a weak 10.8): "theek hai?" / "okay?" tag questions end as `.`; training has 224 Hinglish `?` sentences but the model learned period; finalize also forces `.`.
- Acronym-exact only 75.8%: CGPA, GAAP, AS, BBA, IIM, ROAS, Q3 still lowercase. 13% of eval sentences (decimals, times, `/`) are skipped entirely by the app's structured-text guard, which dominates sentence-exact scores; that is an app-policy decision, not a model issue.
- Exclamation never predicted (no gold exclamations in the corpus). Mixed-case brand forms (GitHub, iPhone, LinkedIn) need dictionary restoration downstream.
- The workplace corpus is slot-filled templates (its README says so): eval sentences share skeletons within eval and some pairings are semantically odd; gold punctuation in it follows one style (e.g. comma after discourse words), so comma F1 partly measures matching that style. Results are for this corpus, not real dictation; a hand-checked set of real dictated text would be needed before shipping.
- Dev selection uses a 3% slice of the same train corpus (in-distribution); the held-out eval file was never used for selection.
- Training windows are single sentences; the app feeds up to 450 bytes. `--pack-words` exists but is untested beyond smoke.

## Suggested experiments
1. `--unfreeze-layers 4 --mode lastN` and `--mode all` with lr 1e-5; compare acronym/proper-noun gains vs general regression.
2. Replay share 10/30/50% and replay from OASST2 only vs FLEURS only; also an LR sweep (1e-5, 2e-5, 5e-5).
3. `--case-class-weights 1,1,3` and `--case-weight 2` aimed at acronyms (UPPER) and names.
4. `--pack-words 40` to train on dictation-length windows (sentence-start caps after previous period).
5. More epochs (3-4) with `--schedule linear --warmup-frac 0.05`; early stop on dev.
6. Add Hinglish tag-question/"kya ...?" oversampling, and a few hundred hand-written real-world dictated Hinglish lines.
7. `--mixed-case cap` (teach GitHub -> Github rather than github) vs mask; or add the dictionary restoration step to the eval.
8. Export ft checkpoint with the shipped recipe (per-channel int8) and run `eval_cleanup.py --backend onnx --ckpt <onnx>` to measure quantization loss on the new tasks.
9. Disfluency/ASR-error robustness: noise the input (um, repeated words) once the corpus has it.
10. Evaluate with the guard relaxed for decimals/times in the app (policy experiment, `--no-gate` needs reconstruct to keep `:`/`.` first).

## ft3 (Hinglish casing/punctuation, label formatting) - 2026-10-27
- Data: `data/hinglish/` (`train_hand_0*.txt` 1,527 hand-written lines, `eval_hand.txt` 332 separately written held-out lines, packed variant `eval_hinglish_packed.jsonl` = 2-4 held-out lines joined, `hindi_lexicon.txt`, built by `build_hinglish.py`). Eval lines are never in train (exact-match check).
- ft3 = `runs/ft3/best` (copy of `runs/ft3c/best`): `--mode all --lr 3e-5 --epochs 5 --schedule linear --warmup-frac 0.05 --pack-words 40 --pack-frac 0.9 --punct-class-weights 1,1,1,1.5,1` on train_nat_plus_slot + hinglish x2 + 30% replay. Key finding: last2/2 epochs/single-sentence windows (ft3a) left QUESTION at ~0 even on training sentences (underfit); unfreezing more layers + more epochs fixed it; packing is needed for multi-sentence utterances.
- `uiui_cleanup.py --label-mode [--hinglish-questions]` (CLI + `Cleaner.clean(label_mode=...)`): app finalize never rewrites a model '?' into '.'; it only appends '.' when the model left no mark, and only fixes English questions. Label mode keeps the model's mark and adds '.' only if none. `--hinglish-questions` optionally promotes a final '.'/none to '?' on Hinglish patterns (kya/kab/... start, "hai na", "haina", "ya nahi", final "kya"). With ft3 it is not needed.
- `eval_hinglish.py` compares models (`--spec NAME=onnx|torch:path`), results in `runs/compare_final/compare.json`; `--track` logs to the lab dashboard (`cleanup-*`, tags cleanup,mac).
