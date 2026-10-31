# Phonon-2 fine-tuning data (pilot)

Built 2026-10-26/27 on a Mac. Pipeline code: `speech/data/`. Lab dashboard runs: `ingest-*`, `lexicon-llm`, `relabel-*`, `phonon-dev-difficulty` (kind=data).

## Layout
- `manifests/<source>/{train,dev}.jsonl` rows: `id, audio, reference, reference_raw, speaker, source, lang(hinglish|en), seconds` (nptel/cvindia also `phonon_wer`). `manifests/<source>/summary.json` per-source counts and drop reasons.
- `manifests/pilot.yaml` sources, hours, suggested sampling weights, licenses. `manifests/stats.json`, `manifests/samples_50.txt` (50 random train rows per source), `manifests/phonon_dev_difficulty.json`.
- `audio/<source>/*.wav` 16 kHz mono PCM16, 0.5 s <= clip <= 15 s (about 52 GB).
- `lexicon/lexicon.tsv` (deva, count, deterministic, llm_proposal, final, source, note), `lexicon/denylist.txt`, `lexicon/llm_cache.jsonl`.
- `evalsets-lexicon/<set>/manifest.jsonl` for mucs-hien-test, hiacc, fleurs-hi: same rows/audio, `reference` re-romanized with the same lexicon (lowercase, no punctuation, same format as evalsets), old value kept as `reference_hybrid`.
- `stage/<source>/` ingest rows, per-source stats (clip drop counts), Phonon outputs. `raw/` is empty (shards deleted after conversion).

## Hours (train / dev), speakers
| source | lang | train h | dev h | train spk | license |
|---|---|---|---|---|---|
| indicvoices (Hindi, 21 spread shards) | hinglish | 118.1 | 2.2 | 1880 | CC-BY-4.0 |
| mucs (OpenSLR 104 train via HF mirror) | hinglish | 82.9 | 1.9 | 507 | OpenSLR: CC-BY-SA-4.0 (HF mirror says cc-by-4.0). Tagged source=mucs |
| kathbath (Hindi) | hinglish | 19.6 | 0.5 | 68 | CC-BY-4.0 |
| shrutilipi (Hindi, AIR news) | hinglish | 9.8 | 0.2 | 166 pseudo | CC-BY-4.0 |
| cvindia (Common Voice en, Indian accent) | en | 68.1 | 2.1 | 1009 | CC0 |
| nptel (skbose/indian-english-nptel-v0) | en | 38.9 | 0.8 | 447 | NO STATED LICENSE: needs decision. weight 0 / default_enabled false in pilot.yaml |
| librispeech (train-clean-100) | en | 59.8 | 1.4 | 236 | CC-BY-4.0 |

Default pilot mix (nptel excluded): 397.2 h incl. nptel 38.9 h, so 358 h default: hinglish 230.4, Indian English 68.1, rehearsal 59.8.
Not obtained: Vaani (see below). Lahaja, Svarah, MonsoonASR untouched (eval only).

## Steps
1. Download parquet shards (HF, non-xet; xet stalled), decode (soundfile / ffmpeg for m4a, mp3), resample to 16 kHz mono, write PCM16 wav, drop <0.5 s and >15 s (counts in `stage/*/stats.json`), delete shard.
2. Exclusion: any speaker id appearing in `evalsets/*/manifest.jsonl`, any utterance id, and any text equal (normalized) to an eval reference or eval `source_references` source text or a MUCS-test transcript is dropped. MUCS: 30 test speakers / 30 test recordings from the dianavdavidson mirror test split were checked; none occur in train (ids are disjoint; the mirror has no cross-id narrator info, so same-person-different-id overlap cannot be ruled out). 3467 MUCS train rows dropped for identical text with eval/test (templated tutorial sentences).
3. Dev: 2% speaker-disjoint per source (speakers taken in hash order until >=2% of rows; Shrutilipi has no speaker ids, so pseudo-speakers = runs of 40 consecutive rows in a shard, only approximately disjoint).
4. Lexicon (`scripts/build_lexicon.py`): 49,484 unique Devanagari words (1.88 M tokens, incl. eval source texts). Deterministic converter from data-research (`romanize_hybrid.roman_word`, with fixes: no global jn->gy, ज्ञ->gy, y/tr endings, -iye endings) plus ~200 canonical function-word spellings (hai hain nahi kya main mein hoon raha/rahi/rahe kyunki yeh woh toh aur kuch bahut abhi theek accha). Qwen2.5-7B MLX (few-shot, prefix-cached) proposes English spellings for every non-protected word with count>=2 (or containing ऑ/ॉ); a proposal is kept only if it passes the wordfreq (zipf>=3) + phonetic similarity filter, stricter for count<=2, and the word is not in the denylist (148 reviewed common Hindi words: साझा, चीन, ...). 4,383 words (4.7% of tokens) get English spellings. Top ~1000 by frequency were manually reviewed; the long tail (rare words) has an estimated 10-15% wrong English substitutions (e.g. पीटना->pet, फॉदर->folder).
5. Romanization = lexicon lookup; Devanagari digits -> digits, । -> ".", tags/braces removed, sentence case, standalone "i" -> "I". Source punctuation is kept but none is invented: IndicVoices, Kathbath, Shrutilipi, MUCS text has no punctuation, so those references are capitalized, unpunctuated. `reference_raw` keeps the original.
6. English: shipped Phonon was run on every clip. Libri (WER<15%) and NPTEL (WER<15%) references are the GOLD words in Phonon's cased/punctuated surface style (word-level merge: Phonon surface where words agree, gold word otherwise). Common Voice keeps its own cased, punctuated sentence (kept if Phonon WER<50%, to drop mismatched audio only).

## Known problems / limitations
- Vaani: not built. The main ARTPARK-IISc/Vaani repo has ~2% of clips transcribed (2/100 in a sampled Delhi row group), so streaming 50 h would mean reading roughly 2,000+ h of audio. The official transcribed subset ARTPARK-IISc/Vaani-transcription-part is a separate gated repo whose terms were not accepted. Also its transcripts carry {english-gloss}, <noise> tags (cleaner already in `romlib.clean_src`).
- NPTEL: only 37% of clips pass WER<15%; license undecided (above).
- IndicVoices: clips >15 s dropped (7.6%), kept 120.4 h of 21 shards of 82 (more shards available). Number words stay as words (e.g. "paanch nau aath"), not digits.
- Hindi/English loan recall is partial (e.g. गैस stays "gais" when unseen by LLM); tail precision noted above.
- Disk: 52 GB audio. Duplicate Common Voice ids (5,968) removed in finalize.
- Phonon difficulty (fair WER, 100 dev rows each): see `manifests/phonon_dev_difficulty.json`; Hindi sets 79-95% are expected for an English-only model (checked: hyp vs ref pairs look like correct labels, not label noise).
