# Pseudo-label pipeline (Whisper-large-v3 + agreement filter)

Written 2026-10-27 on a Mac, smoke-tested on MPS, meant to run on a CUDA machine. Nothing here has run on CUDA yet.

Files: `pl_whisper.py` (label), `pl_filter.py` (filter + report), `mk_smoke_manifest.py` (smoke only). The `smoke/` outputs (EVAL-ONLY) are not included.

## Run on one GPU
Env: `torch`, `transformers>=5`, `soundfile`, `librosa`. Model `openai/whisper-large-v3` (Apache-2.0, ungated).

```bash
# manifest rows: {"id","audio","seconds"}  (audio 16 kHz wav, <= 30 s; our clips are 0.5-15 s)
python pl_whisper.py --manifest unlab.jsonl --out wh/shard0.jsonl --shard 0/1 --batch 32 --ckpt 500
#   --mode fallback (default): greedy num_beams=1 / no sampling; clips that look degenerate (compression_ratio > 2.0 or a
#   repeated n-gram) are re-decoded once with no_repeat_ngram_size=5 + repetition_penalty 1.1; `decode` column says which.
#   --mode greedy | guard force one path.  Language is forced to English, task=transcribe, no timestamps.
# agreement mode (needs our model's transcript for the same ids: jsonl id,hypothesis -- e.g. phonon-eval output):
python pl_filter.py --whisper wh/shard0.jsonl --ours ours.jsonl --wer 0.15 --out train_pl.jsonl --report report.json
# no second hypothesis available:
python pl_filter.py --whisper wh/shard0.jsonl --whisper-only --out train_pl.jsonl --report report.json
```
Resume: re-run the same command; ids already in `--out` are skipped (a torn last line is redone). Output is appended and fsync'd every `--ckpt` rows.
Shards: `--shard k/n` takes rows `i % n == k` of the id-sorted manifest. One GPU: run n=1. Several processes on one GPU is not faster for large-v3; use `--shard` for several GPUs, then `cat` the outputs.
Output of `pl_whisper.py`: `id, audio, seconds, whisper_text, avg_logprob, no_speech_prob, compression_ratio, duration, decode`.
`avg_logprob` is the teacher-forced mean token log-prob over text tokens + EOT (the openai-whisper definition); `no_speech_prob` is P(`<|nospeech|>`) at the first decoder step; `compression_ratio` is len(utf8)/len(zlib) of the text.
(`generate(output_scores=True)` is broken for Whisper in transformers 5.21, hence the extra teacher-forced pass; it costs about 15% on top of decoding.)

Filter output (`train_pl.jsonl`): `id, audio, reference (= Whisper text, cased and punctuated as emitted), seconds, source ("pseudo-whisper-large-v3"), pl_agreement (1 - WER vs ours, null in whisper-only mode)`. `report.json`: keep-rate, kept hours, reject reasons (first reason, and every reason).

### Filter rules
Agreement mode keeps a clip iff normalized WER(whisper, ours) <= 0.15 and avg_logprob >= -0.5 and compression_ratio <= 2.4 and no_speech_prob <= 0.5 and words/sec in [0.8, 5.0] and no hallucination marker.
Whisper-only mode (stricter): avg_logprob >= -0.25, compression_ratio <= 2.0, no_speech_prob <= 0.2, words/sec in [1.0, 4.5], >= 3 words, same markers. All thresholds have flags.
Normalization for the agreement WER only: NFKC, lowercase, punctuation stripped, digit-group commas removed, spelled-out 0-20 -> digits. (Whisper writes "2021", Phonon often writes words or vice versa; the normalizer is deliberately small, so some good clips are lost to number/spelling style: this makes the filter conservative.)
Hallucination markers: 1-gram x6 / 2-gram x4 / 3,4-gram x3 repeated in a row; subtitle/outro phrases ("thank you for watching", "subtitles by", "amara.org", "please subscribe", urls, [music], ...); any letter outside Latin script.
Note the substring list is aggressive ("subtitle", ".com", "mbc", "www."): a lecture that really says "dot com" is dropped; accepted for training data.

### Expected throughput (estimate, not measured on CUDA)
Measured here: M5 Pro MPS fp16, batch 8, whole pipeline including the scoring pass: 15-21x realtime (Svarah/Monsoon smoke, 150 clips each in ~60 s). A single modern datacenter GPU (A100/L40S class) with fp16 and batch 32 should reach roughly 100-250x realtime on short clips, i.e. 100 h of audio in about 0.5-1 h. Treat as a guess until the first CUDA run; `pl_whisper.py` prints realtime factor at every checkpoint. Use `--batch 48` if VRAM allows (large-v3 fp16 needs ~3.5 GB for weights).

## Source candidates (unlabelled or weakly labelled English with Indian accent)
Never use: Svarah, Monsoon, Lahaja and anything under `evalsets/` (eval only). The `eval_only_do_not_train` list in `data/manifests/pilot.yaml` is authoritative. `pl_filter.py` does not know the eval sets; dedupe against eval speakers/text with the existing exclusion step (data/README.md step 2) before training.

| source | what | license (how verified) | status |
|---|---|---|---|
| NPTEL clips that failed our subtitle filter | `$UIUI_ML_ROOT/data-nptel/cand.jsonl` minus the passing ids (`data/manifests/nptel/train.jsonl` has the 19,017 passing rows; summary.json says 33,697 were dropped for `phonon_disagrees`). Lecture audio, Indian English, ideal for this pipeline. `cand.jsonl` was not available where this was written, so it was not counted. | skbose/indian-english-nptel-v0 has **no license field** on the HF card and `data/README.md` already flags it "needs decision, weight 0". NPTEL course content is generally CC-BY-SA 4.0 per NPTEL's site, but I did not verify that for this mirror. | **UNVERIFIED, a licensing decision is needed** before any training use. |
| ai4bharat/NPTEL | AI4Bharat's own NPTEL release (HF API: `license: cc-by-4.0`, gated auto). Not opened; terms not accepted. | cc-by-4.0 per HF card API | Verified on the card only; gated, terms not accepted. Check its language scope and whether it overlaps skbose's data. |
| Common Voice English, Indian-accent tag, beyond what we have | We use CC0 `cvindia` (68 h train). More: other CV releases / splits (`other`, `invalidated`, unvalidated) filtered to `accents` containing India (`India and South Asia (India, Pakistan, Sri Lanka)`). Those clips already have text; use Whisper as a second opinion rather than the label, or use the unvalidated ones as pure pseudo-label audio. | CC0 (Common Voice project; our `data/README.md` records CC0 for cvindia). The HF card for mozilla-foundation/common_voice_17_0 shows no license field via API; trust the project terms but re-check the exact release. | Mostly verified; check exact release terms. |
| IndicVoices English / code-mixed portions | ai4bharat/IndicVoices (HF API: cc-by-4.0, gated auto; terms accepted). It is Indian-language speech; English segments appear as code-mixed Hinglish etc., not a clean English split. Whisper forced to English will hallucinate on Hindi audio, so run a language-ID gate first or use the Hinglish pipeline instead. | cc-by-4.0 (card) | Verified; usable only after LID gating. Probably low yield for English. |
| Vaani (ARTPARK-IISc/Vaani) | Large untranscribed (~98% of clips) district-wise speech, CC-BY-4.0 on the card (gated auto). Mostly regional languages; English share unknown. `data/README.md` records that ~2% have transcripts and the transcription repo is gated and not accepted. | cc-by-4.0 (card) | Verified on the card; low English yield; needs LID. Terms not accepted. |
| Spring-INX | SPRING Lab IITM: HF org `SPRINGLab`, repos `SPRING_INX_<language>_R1/R2` (and `speechlab/SPRING_INX_R1`). I found no English subset and **no license field** on any of the listed cards. | not stated | **UNVERIFIED**; do not use until a licence and an English part are confirmed. |
| LibriSpeech etc. | not Indian accent; rehearsal only (already in the mix). | CC-BY-4.0 | not a pseudo-label source |

Recommendation: start with the NPTEL failed-filter set (largest known pool of in-domain Indian-English speech), once the license question is settled, then Common Voice India unvalidated.
Warning for NPTEL: those clips already failed because Phonon disagreed with the subtitle text. With agreement mode, `ours` = current Phonon, so the filter keeps clips Phonon already gets right (low information gain; also circular). Prefer `--whisper-only` or a different `ours` model (e.g. Qwen3-ASR-1.7B hypotheses) for hard-clip mining, and expect lower pseudo-label quality there (see below).

## Smoke test result (EVAL SETS, NEVER TRAINING DATA)
Files under `smoke/` are prefixed `EVAL_ONLY.` and exist only to estimate pseudo-label quality. Source: the fixed 150-clip subsets of svarah-partial and monsoon-en-in (`$UIUI_ML_ROOT/bench/subsets`), "ours" = `$UIUI_ML_ROOT/bench/hyp/phonon2-shipped.<set>.jsonl`. WER is computed with the filter's own normalizer against the true references (references lowercase/unpunctuated, so punctuation and case are ignored).

| set | mode | kept / 150 | keep-rate | WER of kept PL vs true ref | WER of all Whisper vs true ref | top reject reasons |
|---|---|---|---|---|---|---|
| svarah-partial | agreement WER<=0.10 | 74 | 49% | 4.42% | 7.18% | disagrees_with_ours:67, low_avg_logprob:5, words_per_sec_out_of_range:4 |
| svarah-partial | agreement WER<=0.15 | 87 | 58% | 4.2% | 7.18% | disagrees_with_ours:54, low_avg_logprob:5, words_per_sec_out_of_range:4 |
| svarah-partial | agreement WER<=0.25 | 113 | 75% | 5.81% | 7.18% | disagrees_with_ours:28, low_avg_logprob:5, words_per_sec_out_of_range:4 |
| svarah-partial | whisper-only (strict) | 122 | 81% | 6.39% | 7.18% | low_avg_logprob:24, too_few_words:1, words_per_sec_out_of_range:2, high_no_speech_prob:1 |
| monsoon-en-in | agreement WER<=0.10 | 93 | 62% | 4.03% | 5.86% | disagrees_with_ours:56, low_avg_logprob:1 |
| monsoon-en-in | agreement WER<=0.15 | 118 | 79% | 4.52% | 5.86% | disagrees_with_ours:31, low_avg_logprob:1 |
| monsoon-en-in | agreement WER<=0.25 | 136 | 91% | 5.14% | 5.86% | disagrees_with_ours:13, low_avg_logprob:1 |
| monsoon-en-in | whisper-only (strict) | 140 | 93% | 5.72% | 5.86% | low_avg_logprob:9, high_no_speech_prob:1 |

Reading: Whisper-large-v3 (English forced) alone is 7.2% / 5.9% WER on these sets (Phonon-2: 18.9% / 8.0%). Agreement filtering at 0.10-0.15 lowers the label WER to roughly 4% but keeps only 49-79% of clips; looser thresholds trade quality for yield. Some of the residual error is likely reference-style mismatch (digits vs words, spelling) rather than Whisper mistakes (not audited clip by clip). Caveats: 150 clips per set (about 1-2k words), clips are short read/prompted speech, not lectures; Phonon is weak on Svarah, which is why agreement keep-rate is lower there. Numbers come from `smoke/EVAL_ONLY.*.report-*.json` (not included).
