# uiui S1 and uiui P1: on-device dictation models for Indian professionals

Technical report, 31 October 2026. Model revision `full-1029-s16000-f16`.

## Summary

uiui is a macOS dictation app. We set out to build the best on-device speech model for English-first Indian professionals: Indian English, Hinglish written in Roman script, and workplace vocabulary.

Starting from NVIDIA Parakeet TDT 0.6B v3, by way of Fermion Research's Phonon-2, we retrained the model on about 2,400 hours of Indian and Hindi speech. It stays small enough for the Apple Neural Engine, with 4-bit encoder weights.

**What we achieved**

| Word error rate %, lower is better | Parakeet v3 | uiui S1 | Change |
|---|---|---|---|
| Indian English (our dev-select set) | 25.98 | 9.93 | -16.05 |
| Hinglish (dev-select) | 82.24 | 21.88 | -60.36 |
| Workplace dictation (dev-select) | 28.07 | 19.91 | -8.16 |
| Hindi spoken, Roman output (dev-select) | 95.68 | 26.59 | -69.09 |
| Native English (dev-select) | **2.53** | 3.79 | +1.26 |

- It has the lowest error of the models we tested on the MUCS Hinglish test subset (41.31%).
- It beats Parakeet and both Qwen3 models on the Svarah Indian English subset. Whisper is still better there.
- It runs at roughly 170 to 200 times real time on an M5 Pro, about four times faster than the fastest Qwen3 run. The throughput conditions differ, as noted in section 6.

**What we did not achieve**

- Qwen3-ASR-1.7B remains more accurate on pure Hindi and clearly read English. It is a much larger model that does not run on the Neural Engine in our setup.
- Native English is slightly worse than the base model.
- Post-processing does not yet improve on the speech model's own output. It only stopped doing harm (section 7).
- **Licensing of some inherited and training data is unresolved. Read section 9 before any commercial use.**

## Models and origins

| uiui name | What it is | Built from | Licence |
|---|---|---|---|
| **uiui S1** | Speech recognition | [NVIDIA Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) (CC-BY-4.0), through Fermion Research's [Phonon-2](https://huggingface.co/FermionResearch/Phonon-2) and [Phonon-2 Core ML](https://huggingface.co/FermionResearch/Phonon-2-CoreML) (CC-BY-4.0) | CC-BY-SA-4.0 |
| **uiui P1** | Punctuation and casing | [punctuator-multilingual-minilm-v2](https://huggingface.co/ldenoue/punctuator-multilingual-minilm-v2) by ldenoue (MIT) | MIT |

uiui S1 is retrained and re-quantised, but keeps the base model's architecture, tokenizer and feature extraction. It runs on Fermion Research's [phonon-coreml](https://github.com/FermionResearch/phonon-coreml) runtime (Apache-2.0), vendored here with our changes. Code identifiers and folders still use the names `Phonon` and `MiniLM`. uiui S1 is unrelated to Superwhisper's S1-mini.

## 1. Goal and constraints

- **Users:** English-first Indian professionals who mix in Hindi and technical or business terms.
- **Output:** Latin script only, with punctuation and casing.
- **Device:** runs locally on a Mac, with the encoder on the Neural Engine. No audio leaves the machine.
- **One shared model:** no separate per-language models and no language switch.
- **Evaluation discipline:** a locked scoring formula, a held-out set, and a small listening check (the "vibe" set) to catch overfitting to the metric.

## 2. Model

| Part | Detail |
|---|---|
| Lineage | Parakeet TDT 0.6B v3 (NVIDIA), then Phonon-2 (Fermion Research), then our fine-tune |
| Encoder | FastConformer; all 264 linear layers 4-bit: a 16-entry float16 lookup table per 16 output rows, trained with quantisation-aware training |
| Decoder | TDT, stored as float16, about 35 MB. Greedy decoding, no language model |
| Vocabulary | Parakeet's 8,192-token SentencePiece vocabulary, unchanged |
| Windows | Compiled for 5, 10, 15 and 35 s. The app loads one 15 s function, with 2 s overlap on long audio |
| Size | About 345 MB encoder, 256 MB as a compressed pack |

The 6-bit decoder used upstream cost too much accuracy once the model handled Hinglish. On the same encoder it scored 1.07 points worse on dev-select and 0.92 worse on the held-out set than a full-precision decoder, so we ship float16.

**Number spacing.** The tokenizer cannot encode a space before a digit, so "at 10" and "at10" are identical to the model. No training change can fix that, and our attempts confirmed it (experiments 016, 019). A deterministic rule in the runtime splits glued words and numbers while keeping identifiers such as `HbA1c` and `md5` intact.

## 3. Training data

The final mix samples 12 sources by weight rather than by duration. In total it holds about 2,406 hours, and 55% of sampling is Indian English.

| Source | Hours | Weight | Content | Labels |
|---|---|---|---|---|
| NPTEL en2indic | 282.0 | 0.200 | Indian English lectures | Dataset text, filtered for agreement and alignment |
| Common Voice India | 81.0 | 0.179 | Read Indian-accent English | Sentence text, 532 disagreeing clips dropped |
| NPTEL2020 | 131.5 | 0.171 | Indian English lectures | YouTube subtitles, kept only when they agree with the model (WER at most 0.2) |
| LibriSpeech clean-100 | 59.8 | 0.123 | Native English | Gold text |
| MUCS 2021 | 82.9 | 0.098 | Hindi-English code-switching | Devanagari romanised, then formatted |
| Workplace TTS (two sets) | 37.1 | 0.082 | Synthetic workplace dictation, 16 voices | The script itself |
| IndicVoices (two sets) | 268.4 | 0.082 | Spontaneous Hindi | Romanised and formatted |
| Shrutilipi | 1,296.6 | 0.025 | Hindi radio news | Romanised and formatted, no alignment filter |
| Vaani | 146.9 | 0.025 | Hindi speech | Cleaned, romanised and formatted |
| Kathbath | 19.6 | 0.016 | Hindi speech | Romanised and formatted |

**Romanisation.** Hindi references were converted with a 49,484-word lexicon. A language model proposed English spellings for loanwords, and the most frequent 1,000 or so were reviewed by hand. We estimate 10 to 15% of the unreviewed tail is wrong. The cleanup model then added punctuation and casing without changing any words.

**Workplace speech.** About 19,000 clips were synthesised with Indic Parler-TTS, in English and Hinglish, from text written for this project. Because it is synthetic, the workplace test category measures vocabulary more than real workplace acoustics.

**Augmentation.** Noise, reverb, speed and gain changes, plus SpecAugment. Sources with restrictive licences were excluded.

## 4. Training recipe

| | First full run (full-1028) | Second full run (full-1029) |
|---|---|---|
| Start | Best short experiment (008) | full-1028 step 18,000 |
| Steps | 20,000 | 16,000 |
| Learning rate | 3e-5 cosine | 2e-5 cosine |
| Knowledge distillation | None | None |
| Workplace TTS | Set 1 at 0.082 | Sets 1 and 2 at 0.041 each |
| Wall time | About 9 hours | About 5 hours 40 minutes |

Both runs used a batch of 6 with 3 accumulation steps, EMA 0.998, bf16, clips up to 15 s, and one RTX 5090.

The full lineage was: a dense teacher, then 4-bit with distillation, then an automated experiment loop, then the two full runs. The largest single gains in that loop were rebalancing the data mix towards Indian English (S -2.06, then -0.44) and removing distillation (-0.72).

## 5. Evaluation

**Score.** S = 0.40 Indian English + 0.25 Hinglish + 0.15 workplace + 0.10 Hindi + 0.10 native English. Lower is better.

| Set | Clips | Hours | Use |
|---|---|---|---|
| dev-select | 2,294 | 4.8 | Choosing between experiments |
| dev-hold | 2,294 | 4.4 | Reported only; speakers and audio disjoint from dev-select |
| vibe | 60 | 0.1 | Goodhart check on real voices |

Hinglish and Hindi use a transliteration-tolerant error rate: spelling variants that are attested count as correct, while real differences such as hai/hain or ke/ka remain errors. English categories use raw word error. No number normalisation is applied, so "10" and "ten" count as different.

**Keep rule.** An experiment is kept only if the upper end of a paired bootstrap 95% interval on the S change is below zero, and no category guard is broken. Unchanged control runs drifted by about 0.1 S, so we treat smaller changes as noise.

**Progress**

| Model | Dev-select S | Held-out S | Indian English | Hinglish | Workplace | Hindi | Native |
|---|---|---|---|---|---|---|---|
| Starting 4-bit model | 19.98 | 18.42 | 16.28 | 22.12 | 22.30 | 26.35 | 4.00 |
| 002, Indian English 55% | 17.48 | 16.29 | 11.74 | 22.28 | 19.80 | 26.52 | 3.98 |
| 008, no distillation | 16.77 | 15.67 | 10.71 | 22.26 | 18.73 | 26.06 | 4.00 |
| full-1028 step 18,000 | 15.68 | 14.54 | 10.39 | 20.47 | 15.62 | 25.28 | 3.94 |
| **full-1029 step 16,000** | **15.47** | **14.35** | 10.43 | 20.02 | 15.12 | 25.19 | 3.87 |

Category columns are held-out word error rates.

**Honest notes on process**

- The two full runs were promoted by hand after scoring on both sets, outside the automatic keep rule.
- Steps 14,000 and 16,000 tied on dev-select. Step 16,000 was slightly lower on the held-out set (by 0.003), so that set may have influenced the choice. The effect is negligible, but the held-out set is not perfectly clean for this final step.
- The second workplace TTS set was used in the full run even though its short experiment did not clear the keep rule on its own. Workplace error did improve at both seeds.
- The Parakeet comparison in the summary uses dev-select, because we have no Parakeet score on the held-out set. Dev-select was used for choosing our models, so this slightly flatters ours.

## 6. Comparison with other models

Public test subsets of 150 clips each, on an Apple M5 Pro. Word error rate %. Differences of a point or two are noise at this size. English sets use raw word error; the three Hindi and Hinglish sets use the transliteration-tolerant score, and Devanagari output from other models was romanised first.

| Model | Svarah | Monsoon | LibriSpeech | FLEURS en | MUCS | Hindi accents | FLEURS hi | Disk |
|---|---|---|---|---|---|---|---|---|
| **uiui S1 (ours)** | 12.94 | 7.01 | 2.24 | 6.40 | **41.31** | 28.93 | 30.31 | 0.38 GB |
| Phonon-2 original | 18.86 | 8.01 | 2.43 | 7.27 | 87.54 | 77.94 | 88.76 | 0.33 GB |
| Parakeet v3 (fp32) | 16.59 | 6.98 | 2.27 | 4.56 | 87.17 | 77.70 | 90.27 | 2.5 GB |
| Whisper large-v3 auto | 12.5 | 5.8 | 3.0 | 4.2 | 70.4 | 39.7 | 37.5 | 3.1 GB |
| Whisper large-v3 English | **7.2** | 5.9 | 3.0 | 4.2 | 92.9 | 84.7 | 98.5 | 3.1 GB |
| Whisper turbo auto | 12.0 | 6.8 | 2.3 | 4.6 | 72.2 | 57.1 | 38.0 | 1.6 GB |
| Qwen3-ASR-0.6B auto | 15.7 | 6.7 | 2.1 | 4.8 | 49.7 | 24.5 | 21.2 | 1.9 GB |
| Qwen3-ASR-1.7B auto | 14.7 | **5.6** | **1.6** | **3.7** | 47.6 | **23.0** | **16.8** | 4.7 GB |
| Oriserve Swift English | 17.1 | 17.0 | 10.5 | 18.3 | 53.5 | 28.4 | 31.2 | 0.29 GB |
| Oriserve Prime English | 15.7 | 15.4 | 3.0 | 9.3 | 52.9 | 35.1 | 26.2 | 3.1 GB |

Forcing English helps Qwen 1.7B on MUCS (45.6), which is still above ours. Forcing English on Whisper makes its Hindi and Hinglish results far worse.

**On our own larger test (dev-select, 2,294 clips, S):** uiui S1 15.47, Qwen 1.7B 16.01, Qwen 0.6B 17.98, Whisper large-v3 auto 23.99, Whisper turbo auto 25.65, Parakeet v3 44.98. This test was designed around our target users and was used to select our model, so it favours us. Qwen 1.7B stays well ahead on Hindi (19.41 against 26.59) and native English (2.03 against 3.79).

**Speed.** Across six of the seven public sets the model ran at about 173 times real time on the Neural Engine, and 201 times on our 600-clip A/B set. The first set ran at 34 times, most likely because it includes model loading, so we exclude it. The earlier 132 times figure for full-1028 came from a different run. Other models ran in batches of 8 on the GPU, so speed is not strictly like for like; in a batch-of-1 probe, Qwen 0.6B reached 29.5 times and Qwen 1.7B 16.3 times.

**Not measured:** Apple SpeechAnalyzer, WhisperKit, and FluidAudio's Parakeet, on these sets. Memory use and latency of this exact build have also not been measured. The original Phonon-2 used about 0.15 GB of RSS plus Neural Engine memory that this figure doesn't fully count, and its latency was 7 to 26 ms for clips of 3 to 15 s.

## 7. Post-processing

**The finding.** Our cleanup model was built for speech models that output plain lowercase words. It stripped punctuation and predicted it again. Once the speech model learned to format its own text, cleanup made things worse.

Measured on 600 real app transcripts, on correctly recognised words (higher is better except the last row):

| % | Speech model alone | Old cleanup | ft3 cleanup | Editor (experimental) |
|---|---|---|---|---|
| Punctuation F1 | **88.6** | 66.2 | 70.1 | 88.3 |
| Commas | 79.9 | 32.3 | 55.9 | **81.9** |
| Question marks | **95.5** | 57.1 | 59.3 | 93.6 |
| Capitals mid-sentence | 87.3 | 55.6 | 79.8 | **88.1** |
| Wrongly capitalised | **1.0** | 2.0 | 3.7 | 1.4 |

**How the app works now**

1. If the raw transcript contains any capital letter or any of `.,?!`, it is treated as formatted. The cleanup model is skipped, and only a light final punctuation pass runs (88.3 punctuation F1 on the test above). The check runs before dictionary replacements, so a capitalised dictionary word cannot change the decision.
2. Only all-lowercase text with no punctuation goes through uiui P1 (revision `ft3`), which adds punctuation and casing without changing words, and then the final pass.

The tagger is a 34 MB per-channel INT8 classifier. Retraining it took Hinglish punctuation F1 on clean text from 52 to 89, but normal Phonon output now bypasses it. It remains for unformatted text.

**Planned stages**

| Stage | Idea | Outcome |
|---|---|---|
| 0 | Don't override formatted output | Shipped |
| 1 | Editor model that sees the speech model's formatting and edits it | Built, not shipped. Workplace commas rose from 74.2 to 80.9 on the held-out set, but overall it was neutral and it added wrong capitals in Hindi (1.5 to 2.8) |
| 2 | Learned word-swap corrections | Dropped. The top 500 swaps cover only 9.3% of Hinglish errors and 5.9% of English errors |
| 3 | Small on-device language model for self-corrections, lists and written formats | Not started. Needs a test set of real dictations first |

The editor could not win because it was trained towards the same targets the speech model already learned. Further gains need something the speech model lacks: the user's vocabulary and context, or a goal beyond a verbatim transcript.

## 8. What we tried that did not work

| Experiment | Change | Result |
|---|---|---|
| 002zb | 282 h more NPTEL alone in the short run | +0.01 S |
| 003 | Indian English 65% | No change |
| 004, 005 | No TTS / 20% TTS | No gain |
| 002za | Augmentation in a short run | -0.11, interval crossed zero |
| 009 | Learning rate 1e-4 | -0.16, interval crossed zero |
| 012 | Filtering Hindi labels using Qwen | +0.15, worse |
| 013 | 90 h of pseudo-labels from Whisper and Qwen agreement | +0.06 |
| 015, 007 | More LibriSpeech or native data | No gain, native gap remained |
| 016, 017, 019 | Digit-spacing labels and number-reading TTS | Not reliable; tokenizer limit |
| 020 | Distillation from the original Parakeet on native English | +0.07 to +0.09 |
| 021 | 15 to 25 s clips | +0.01 to +0.11 |
| N-gram language model | Shallow fusion in decoding | Helped Hindi sets (dev mix 18.50 to 17.61), hurt English (Svarah 18.65 to 19.98); not used |
| Acoustic adapter, token bias | Earlier lightweight pilots | Rejected, no held-out gain |

Short experiments often could not show gains that the full runs later delivered. The 010b mix was not kept in its short run, but was the mix behind full-1028. So short runs are a noisy guide to long-run value.

## 9. Licences and open questions

**Runtime and base.** Source code is Apache-2.0. uiui S1 weights are CC-BY-SA-4.0, uiui P1 is MIT. Parakeet and Phonon-2 weights are CC-BY-4.0. The Phonon runtime and FluidAudio are Apache-2.0. Silero VAD and ONNX Runtime are MIT. SentencePiece and Indic Parler-TTS are Apache-2.0. Attribution is in `resources/Phonon/NOTICE` and `Vendor/MiniLM/licenses`.

We chose CC-BY-SA-4.0 for uiui S1 because share-alike data went into training, and CC-BY material can be included under it. **A licence we choose can only grant rights we hold, so it cannot settle the questions below.** They need a human or legal decision, especially before commercial use:

1. **SPGISpeech, inherited from upstream.** Phonon-2's notice lists SPGISpeech as training audio. Its Hugging Face page describes the content as for academic research and internal use only, and it doesn't directly address trained models. This is the most serious open question, and it comes from the base rather than from our own training.
2. **NPTEL, 37% of our sampling.** Dataset publishers state CC-BY-4.0, but NPTEL's own licence is unclear. Secondary sources conflict between CC-BY-SA and CC-BY-NC-SA, so a non-commercial restriction hasn't been ruled out.
3. **Share-alike data.** MUCS 2021 is CC-BY-SA-4.0, and upstream's CHiME-6 is too. Whether trained weights count as adaptations is unsettled; our CC-BY-SA choice is meant to satisfy either answer.
4. **Common Voice through a mirror.** Common Voice is generally CC0, but the mirror we used carries no licence field, and we could not confirm the release version.
5. **Gated dataset terms.** We have not reviewed the access-form terms of the AI4Bharat and Vaani datasets beyond their CC tags.

An unlicensed NPTEL mirror was downloaded during early work. It is not in the final mix, nor in the four main earlier training configurations we checked. Early smoke runs were not checked.

## 10. Limits

- Public comparison subsets are small, at 150 clips per set.
- The workplace test category is synthetic. There is no large real-world workplace test.
- The vibe set is only 60 clips.
- Some training labels are weak: subtitles, unaligned radio news and the romanisation tail.
- Hindi output is Roman script only.
- Native English is below the base model, and two targeted attempts did not close the gap.
- Real-user testing of this exact build is still pending at the time of writing.

## 11. Reproducibility

The training, data, evaluation, export and cleanup code is in [`ml/`](../ml/README.md), under Apache-2.0. It is a cleaned copy: machine paths were replaced with one workspace root, and debugging scripts were left out.

- **Not included:** audio, manifests, checkpoints, evaluation sets, per-clip results and the transliteration variant tables. The variant tables can be rebuilt with `ml/speech/eval/evalx/build_variants.py`, but the hand-curated part cannot be recreated exactly, so rebuilt scores may differ slightly.
- **Verified after cleaning:** all code compiles and imports, and tests that need no data pass. One scorer test needs the variant tables, and it passed when they were supplied.
- **Not verified after cleaning:** no training, data, export or benchmark run was repeated end to end.
- **Small known change:** one name in the sentence generators was replaced, so regenerated synthetic text will differ slightly from what we trained on.
- **Possible evaluation influence:** the romanisation lexicon was built from training text and from evaluation-set reference text. It maps vocabulary only, but evaluation words may be better covered than unseen words.

The app verifies the shipped model against pinned hashes in `resources/Phonon/assets.json`.
