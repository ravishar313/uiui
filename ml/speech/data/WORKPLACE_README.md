# Workplace dictation text corpus (English-first Indian professionals)

License: CC0 1.0 (public domain dedication). Everything here was written originally for this project: no scraped
text, no third-party corpora, no real people's data. Names, companies and brands are used only as vocabulary.

Purpose: text for training and evaluating an on-device speech recognizer, and the scripts a TTS engine should read to
synthesise matching audio. Text only; no audio is included.

## Files

Only this README is included in this repository; the corpus files and generator scripts listed below are not.

| File | Contents |
|---|---|
| `terms.tsv` | 2046 terms: `term, written_form, spoken_forms (|-separated), category, field`. |
| `sentences_train.jsonl` | 12000 sentences: `id, text, field, register, mix, terms`. |
| `sentences_eval.jsonl` | 1200 sentences, same schema; disjoint from train (see below). |
| `eval_only_terms.txt` | 294 terms that never appear in any train sentence. |
| `spoken.jsonl` | `id, split, text, speak` for every train and eval sentence. `text` is the target transcript; `speak` is the TTS script. |
| `stats.json` | All numbers quoted here, produced by `build.py`. |
| `raw/` | Hand-written batches (`hand_*.txt`) and generated candidate pools (`gen_*.tsv`). |
| `terms_src.txt`, `make_terms.py` | Source of `terms.tsv`. |
| `frames_*.txt`, `clauses_*.txt`, `gen.py` | Hand-written sentence frames and short clauses, and the generator that fills them. |
| `build.py`, `common.py`, `indic_speak.py` | Validation, dedup, split, term detection, number/acronym verbalisation. |

Rebuild: `python3 make_terms.py && python3 gen.py && python3 build.py` (deterministic, seeds fixed; about 30 s).

## Counts

- Terms: 2046. By category: company 136, surname 135, fname_m 128, fname_f 115, fin_term 96, tech 85, city 84, tool_cloud 81, med 78, date 73, jargon 65, money 65, role 63, edu 62, doc 60, hr 59, legal 46, meeting 44, time 41, idiom 40, tool_fin 36, app_brand 36, institution 36, metric 36, acr_noun 35, tool_crm 33, consult 33, sales 32, tool_doc 27, mkt 26, tool_track 19, filing 19, regulator 17, tool_chat 15, period 14, vp_person 13, vp_work 13, month 12, vp_intr 10, tag_lead 9, time_ref 7, tag_state 5, status 3, tag_attach 2, urgency 1, numword 1.
- Terms by field: general 1197, finance 168, tech 166, business 136, education 98, medical 78, sales 65, hr 59, legal 46, consulting 33.
- Train: 12000 sentences, 30.0% Hinglish. Eval: 1200 sentences, 30.0% Hinglish.
- Mean length: 12.0 words (train), 12.53 (eval); 89.9% of train sentences have 8-20 words; all have 4-30.
- Sentences containing digits (times, dates, money, percentages): 45% of train, 47% of eval.
- Distinct terms occurring: 1752 in train, 1296 in eval (294 of 294 eval-only terms occur in eval).

### Field (train / eval)

| field | train | share | eval |
|---|---|---|---|
| general | 4205 | 35.0% | 426 |
| business | 1352 | 11.3% | 121 |
| tech | 1316 | 11.0% | 126 |
| finance | 1261 | 10.5% | 148 |
| education | 930 | 7.8% | 63 |
| hr | 810 | 6.8% | 80 |
| medical | 775 | 6.5% | 78 |
| legal | 714 | 6.0% | 91 |
| consulting | 637 | 5.3% | 67 |

`field` is the domain of the first specialised term in the sentence ("general" when the sentence only has
office vocabulary, names, tools or numbers).

### Register (train)

| register | n | share |
|---|---|---|
| message | 7176 | 59.8% |
| note | 1542 | 12.8% |
| meeting | 1214 | 10.1% |
| email | 1082 | 9.0% |
| task | 986 | 8.2% |

Eval register counts: {'message': 656, 'email': 123, 'meeting': 115, 'task': 113, 'note': 193}.

## How eval is held out

1. About 15% of terms in every slot-filled category (names, cities, companies, tools, acronyms, finance, medical,
   and so on) were sampled with a fixed seed and written to `eval_only_terms.txt`. Terms that are fixed phrases
   inside hand-written frames (Indian-English idioms such as "prepone", "do the needful") and the tiny closed
   categories (`tag_*`, `status`, `time_ref`, `month`) are not held out, so the share is 14.4% of all terms.
   Terms that are a word-subsequence of a longer term (for example "reimbursement" inside "reimbursement claim") are never held out, so
   a held-out term cannot leak through a longer one.
2. Train sentences are generated and then filtered with a detector: any sentence containing an eval-only term is
   dropped. Leaks found after the build: 0.
3. Eval uses frames and clauses that train never sees: 20% of frames and 15% of clauses (per register) are reserved for eval,
   so eval sentences have different sentence skeletons, not only different words. Eval draws held-out terms about
   half the time in each slot, so most eval sentences contain at least one unseen term; the rest use train vocabulary in new
   frames.
4. Train and eval share no exact sentence and no 6-word span (train/eval shared 6-grams: 0).
   Hand-written sentences containing an eval-only term go to eval; about 10% of the other hand-written sentences go to eval too.

## Dedup and diversity checks (all from `stats.json`)

- Exact duplicates (case-insensitive): none within a split; 0 between splits.
- Repeated 6-word spans: the builder rejects any sentence that shares a 6-word span (lower-cased, punctuation
  ignored) with an already accepted sentence. Result: sentences sharing a 6-gram with another sentence in the same
  split: 0 (train), 0 (eval). This is stricter than requested, so
  no "common phrase" exemption was needed.
- Skeleton diversity (terms replaced by `T`, numbers by `N`): 6493 distinct skeletons across 12000 train
  sentences; the most common single skeleton occurs 78 times. Eval: 775 skeletons over 1200;
  max 17.
  A 6-gram filter does not catch reuse of a skeleton with different slot fillers, so this is the honest measure of template reuse.

## Spoken forms

`speak` expands text the way people say it: letter-spelled acronyms ("EOD" -> "E O D", "KPI" -> "K P I"), word
acronyms stay words ("SEBI", "NEET"), `1:1` -> "one on one", `Q3` -> "Q three", `FY25` -> "F Y twenty five",
`P&L` -> "P and L", times ("4:30 pm" -> "four thirty p m"), dates ("15th Nov" -> "fifteenth November"), percentages,
years ("2026" -> "twenty twenty six") and Indian number words ("₹25 lakh" -> "twenty five lakh rupees", "1,50,000" ->
"one lakh fifty thousand"). Hinglish words are left in Roman script. `terms.tsv` lists alternative spoken forms
(for example "end of day" for EOD) so a TTS front-end can sample them; `speak` always uses the first. After conversion,
0 sentences still contain a digit, % or ₹.

## Known weaknesses

- **Most sentences are generated from hand-written frames and clauses, not written one by one.** I wrote about
  369 sentences directly and 776 frames and 190 short clauses with typed slots; the rest is
  slot filling. Frames are grammatical, but random slot combinations are sometimes semantically odd ("the PAN is 7 lakh
  short", "shipped the RAM to feature flag"). Fine for acoustic and vocabulary coverage, weak as a language model of what
  people actually mean.
- Skeleton reuse is real (see above); the 6-gram check only guarantees no long copied spans.
- Hinglish is simple Roman-Hindi code-mixing built from a small set of verbs and particles (hai, kar do, tak, ko, par,
  mein, nahi...). It under-represents longer Hindi clauses, spelling variation (`nhi`, `kr do`, `krna`), and
  Hindi-heavy sentences with English only for nouns.
- Hindi-side grammar uses fixed-gender forms ("rahunga", "karunga"); speakers of the other gender would say
  "rahungi", "karungi". Not modelled.
- No Tamil, Telugu, Bengali or other mixes; no speech disfluencies (um, uh, restarts, corrections), which real dictation has.
- Numbers come from fixed pools (65 money, 41 time, 73 date forms) plus random small integers; digits-as-words dictation
  ("two five lakh") and read-out phone numbers, emails and URLs are not covered.
- Names and brands are a small sample (243 first names,
  135 surnames, 136 companies); rare names are absent.
- The `terms` field is found by exact string detection, so inflections ("SLAs", "prepones") are not tagged.
- `field` is a heuristic from the terms used, and `register` is a label of intended style, not a measured property.
- Term lists are my own judgement of workplace vocabulary and may contain errors (spoken forms of some brands, for
  example). Check `terms.tsv` before using it as ground truth.

## Provenance

Written by Claude (Anthropic) on 2026-10-27 for the uiui ASR project. Original work, dedicated to the public domain under CC0 1.0.
