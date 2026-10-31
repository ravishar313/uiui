# Roman-Hinglish spelling-variant data (scorer side only)

The .tsv tables are not included in this repository. Without them `roman_variants.VariantMap` loads an empty map (the scorer still runs, but the Roman-Hinglish variant folding in `fair_wer.py` is then a no-op).

Rebuild: `python build_variants.py --aksh <Aksharantar hin json files> --dak <Dakshina hi.translit.sampled tsv files> [--root $UIUI_ML_ROOT]` (from `eval/evalx`). It reads `<root>/data/lexicon/lexicon.tsv` (built by `speech/data/build_lexicon.py`) and the LibriSpeech train manifest `<root>/data/manifests/librispeech/train.jsonl`, and writes `variants_permissive.tsv` and `variants_evalonly_dakshina.tsv` into `variants/`. `extra_variants.tsv` was a small hand-curated list in the same `variant<TAB>canonical` format (lines starting with `#` are comments); it is not shipped, create your own if wanted. The tables are built from the public Aksharantar and Dakshina data, never from evaluation transcripts.

Used by `roman_variants.py` and `fair_wer.py`.

| file | derived from | license | allowed use |
|---|---|---|---|
| `variants_permissive.tsv` | Aksharantar hin (manual CC-BY, mined CC0), rows whose `source` is NOT `Dakshina`/`Existing`; plus our own lexicon spelling as a vote | CC-BY 4.0 (attribute AI4Bharat) / CC0 | scorer, and may be reused elsewhere with attribution |
| `variants_evalonly_dakshina.tsv` | votes that include Dakshina Hindi lexicon counts (CC BY-SA 4.0) and Aksharantar rows copied from Dakshina/"Existing" sets | **CC BY-SA 4.0** | **EVAL ONLY.** Never use as a training target, never fold it into training text, never ship it inside the app. If this file is redistributed it carries BY-SA terms. |
| `extra_variants.tsv` | hand-curated by us | ours | anything |

Format of the two generated files: `variant<TAB>canonical<TAB>variant_votes<TAB>canonical_votes<TAB>n_deva_words`.
`eval-only` lists only entries not already present (with the same target) in the permissive file.
Raw Aksharantar / Dakshina downloads are not stored in the repo (re-download, see `build_variants.py` header).
`fair_wer.twer(rows, use_eval_only=False)` / `--no-eval-only` scores without the BY-SA data (difference on the teacher dev-mix: 0.08 T-WER points).

## How the map is built
1. Per Devanagari word, collect attested romanizations with votes (Aksharantar: 1 per pair; Dakshina: elicitation count; our lexicon spelling: +4 for words seen >= 50 times in our corpora so canonical forms match our labels).
2. Canonical = most-voted spelling; prefer an English word (LibriSpeech words with n>=3 plus /usr/share/dict) when it is attested at >= 1/3 of the top votes and the word is not a Hindi word in our lexicon (loanword rule).
3. A variant is mapped only if: it is not a canonical of any other word; not in the protected list; length >= 2; it points at one Devanagari word clearly (runner-up < 30% of its votes); it is not an English word (he, me, to, or, so ... stay as they are); and it is close to the canonical (same vowel-collapsed key, or edit distance 1 on keys of length >= 6).
4. Chains are resolved (a>b>c becomes a>c); hand-curated `extra_variants.tsv` wins over data.

## Protected (never merged)
`PROTECTED` in `roman_variants.py`: hai/hain, ke/ka/ki, ko, par/pe, se, mein/main, kar/karke/karte/..., tha/thi/the, raha/rahi/rahe, gaya/gayi/gaye, wala/wali/wale, mera/meri/mere (and apna, hamara, uska, unka, ...), is/us/in/un, kaha/kahan, kab/kaun/kaise, ... Gender/number forms are different Devanagari words, so they are never in one cluster; the protected list is the safety net for noisy mined pairs.
Known deliberate collapses that follow our label convention: yeh = ye, yah; woh = wo, vo (ये/यह and वो/वह are one lexicon entry each in our romanizer, so spelling them differently in a hypothesis is not an error against our references).
