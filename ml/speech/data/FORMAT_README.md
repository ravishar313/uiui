# FORMAT_README: formatted (`*_fmt`) Hinglish training manifests

New dirs next to the originals, read-only: `$UIUI_ML_ROOT/data/manifests/<name>_fmt/{train.jsonl,summary.json}`. Rows are identical to the source rows except `reference` (formatted) and a new `reference_unformatted` (the source reference). Originals untouched.
Rows/hours below come from each `summary.json`. Word-identity check: per row, the formatted text with `. , ! ? ; :` removed and lowercased equals the same normalisation of the source reference, else the original is kept; **mismatches: 0 in all six**. Rows the app's structured-text guard rejects (code characters etc.) are left unformatted.

## Pipeline
Text-only: `id`+`reference` were extracted from the manifests, formatted on a separate machine, and only `id`+`reference_fmt` were joined back by a single process. The formatting scripts and policy file (stage1_pool*.py, stage2_local.py, stage2_final.py, policy.json) are not included in this repository.
1. ft3 (`cleanup/runs/ft3/best`, label mode: model terminal punctuation kept, Hinglish-question heuristic off), 450-byte segments, `accepted` guard.
2. Precision-first casing policy: sentence starts capitalised; mid-sentence capital only for curated `cap_ok` names/places/brands/festivals/Hindi months and weekdays, or term/weekday/month/city overrides; all-caps only for curated `acro_ok` or term overrides; every other model capital lowercased; model punctuation kept. Unix commands stay lowercase.
3. Term overrides from `data/workplace/terms.tsv` (written forms with an uppercase letter only, exact casing, case-insensitive whole-word/phrase match), single tokens in the stoplist skipped.
`cap_ok` (337 entries) and `acro_ok` (64) were curated from mucs/kathbath first and extended after reviewing the most frequent consistently-capitalised tokens of indicvoices*, vaani and the first half of shrutilipi. Names not in these lists or in terms.tsv stay lowercase (recall loss, mainly rarer news names in shrutilipi); no spelling is changed.

## Per-manifest results
| manifest | rows | hours | rows changed | word-identity mismatches | mid-sentence words capitalised after policy | raw ft3 non-lowercase mid-sentence share |
|---|---|---|---|---|---|---|

| indicvoices_hy_fmt | 73519 | 118.12 | 73497 | 0 | 0.78% | 6.79% |
| indicvoices2_hy_fmt | 90485 | 150.26 | 90465 | 0 | 0.84% | 6.91% |
| mucs_v2_fmt | 46989 | 82.9 | 45250 | 0 | 1.18% | 8.04% |
| vaani_v2_fmt | 101839 | 146.93 | 68562 | 0 | 0.33% | 5.64% |
| kathbath_v2_fmt | 13737 | 19.56 | 13737 | 0 | 1.92% | 13.71% |
| shrutilipi_full_v2_fmt | 714190 | 1296.56 | 714091 | 0 | 3.25% | 22.24% |

Unformatted by the structured-text guard: indicvoices_hy 23, indicvoices2_hy 21, mucs_v2 1804, vaani_v2 670, kathbath_v2 1, shrutilipi_full_v2 109.

## False-capital estimate
- Raw ft3 on 500 long unpunctuated labels (250 mucs + 250 indicvoices, seed 5): 6.38% (mucs) and 6.19% (indicvoices) of mid-sentence words capitalised (ft2: 4.09% / 1.89%); the extra capitals are mostly ordinary Hindi words. The last column above is the same measure over whole sets (raw ft3 caps or all-caps on mid-sentence words), 5.6% to 22% depending on source.
- After the policy a capital can only appear for a curated name/brand/acronym, so the false rate is bounded by errors in those lists. Random samples of capitalised mid-sentence tokens (about 90 from shrutilipi, a handful from the smaller sets) contained no clear Hindi common-word false capitals; borderline: titles such as Mukhymantri/Pradhanmantri (capitalised as titles), Finance, SEM, Dec. Estimate: well under 1% of capitalised mid-sentence tokens, not formally hand-labelled.
- Local v2 rebuild (mucs/kathbath) differed from the training machine's references on 154 and 37 rows (lexicon differences), so formatting was done on the training machine's text, not the local rebuild.

## Known issues
- ft3 punctuation is sometimes odd (stray mid-sentence "?", frequent commas before toh/aur); kept as-is.
- Hindi common words that happen to be names (sarkar, diya, khushi, pooja, ...) stay lowercase by design (stoplist: aarti, amplitude, android, angular, apple, as, ba, bindu, buffer, busy, ca, cat, chitra, chrome, cob, coda, coo, crud, cs, cursor, cypress, da, darshan, das, dev, discord, disha, diya, do, ed, ekta, em, er, eta, excel, flask, garima, gate, gill, gm, gong, harsh, indeed, intercom, it, jan, jest, jyoti, kam, kavita, keynote, khushi, kiran, kra, lakshmi, lambda, lc, linear, loom, lop, main, mar, mau, meta, mom, na, naukri, nav, nidhi, notion, om, oracle, outlook, outreach, pan, par, pat, pip, pooja, posh, ps, ram, react, rekha, rm, roshni, rust, safari, sam, sap, sarkar, sat, seema, sentry, signal, sip, slack, snowflake, sop, sow, stripe, suman, swagger, swift, ta, tally, tam, tan, tat, telegram, the, titan, us, varsha, vidya, visa, windows, word, wow, zephyr, zoom).
- Throughput on a Mac (8 CPU processes, ft3): about 130 to 210 rows/s per job; MPS was slower than CPU for these short sequences. Whole run about 3.5 hours wall for 1.07M rows; the training machine's CPU was not used for formatting.



The per-manifest before/after example lists that used to follow here were sampled from the corpora and are not included.
