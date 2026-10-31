---
license: mit
task_categories:
- text-generation
language:
- en
size_categories:
- 100K<n<1M
tags:
- speech-to-text
- transcript-cleanup
- disfluency-correction
- synthetic-data
- sotto-asr
pretty_name: SottoASR Transcript Cleanup Dataset
configs:
- config_name: default
  data_files:
  - split: train
    path: data/train-*
  - split: validation
    path: data/validation-*
dataset_info:
  features:
  - name: input
    dtype: string
  - name: output
    dtype: string
  splits:
  - name: train
    num_bytes: 33192538
    num_examples: 135503
  - name: validation
    num_bytes: 1296731
    num_examples: 6921
  download_size: 18979669
  dataset_size: 34489269
---

# SottoASR Transcript Cleanup Dataset

<p align="center">
  <a href="https://sotto.app">sotto.app</a> · 
  <a href="https://huggingface.co/juanquivilla/sotto-cleanup-lfm25-350m">Trained Model (bf16)</a> · 
  <a href="https://huggingface.co/juanquivilla/sotto-cleanup-lfm25-350m-mlx-5bit">MLX 5-bit Model</a>
</p>

## Overview

124K+ synthetic training pairs for fine-tuning small language models on speech-to-text transcript cleanup. This dataset was used to train the [SottoASR transcript cleanup model](https://huggingface.co/juanquivilla/sotto-cleanup-lfm25-350m) — a 350M parameter model that **exceeds a prompted 2B model** on this task while being 8x faster.

Part of [**SottoASR**](https://sotto.app) — a local, privacy-first speech-to-text application for macOS.

## Task

**Input:** Raw, lowercase, unpunctuated ASR transcript with speech disfluencies
**Output:** Clean, properly formatted text with disfluencies removed

```jsonl
{"input": "uh the server is uh running low on memory", "output": "The server is running low on memory."}
{"input": "use redis wait no memcached is better", "output": "Use Memcached."}
{"input": "ship it", "output": "Ship it."}
{"input": "send the email to john period", "output": "Send the email to John."}
```

## Categories

| Category | % | Description |
|----------|---|-------------|
| self_correction | 14% | Speaker corrects themselves mid-sentence |
| preserve_wording | 13% | Clean input — model must NOT over-edit |
| filler_removal | 11% | Remove uh, um, uhm, er, ah |
| mixed | 10% | Multiple disfluency types combined |
| crutch_words | 8% | Remove basically, you know, I mean, etc. |
| false_start | 8% | Remove abandoned sentence beginnings |
| dictation_commands | 8% | Convert "period" → ".", "comma" → "," |
| misheard_words | 7% | Fix ASR errors (post gress → Postgres) |
| grammar | 7% | Fix spoken grammar (gonna → going to) |
| list_formatting | 6% | Convert spoken lists to numbered format |
| adversarial | 5% | Words that look like fillers but are meaningful |

## Domains

Software engineering (24%), general business (19%), casual conversation (15%), medical (10%), legal (8%), finance (7%), technical (5%), creative (5%), academic (5%)

## Generation Method

Three-layer approach:
1. **Programmatic corruption** (Layer 1) — deterministic disfluency injection into clean public text
2. **LLM-generated** (Layer 2) — context-dependent patterns via Qwen3.5-35B and Grok 4.20
3. **Hand-crafted** (Layer 3) — expert-written samples for edge cases

94.6% validation pass rate. Details in the [training research document](https://huggingface.co/juanquivilla/sotto-cleanup-lfm25-350m).

## Splits

| Split | Samples |
|-------|---------|
| train | 118,069 |
| val | 6,215 |

## License

MIT
