# v2 / vb manifests (created 2026-10-27)

Nothing existing was modified. All new dirs keep the same ids, audio paths, speakers and train/dev split as their source manifest.
Extra fields: `reference_v1` (old reference, only when it changed); vb dirs also `reference_raw_std` (old standardized Devanagari) and
`has_unintelligible`. Per-dir stats are in `<dir>/summary_v2.json`.

## romanize_v2
`romanize_v2.py` = romlib.roman (lexicon.tsv incl. the LLM loanword pass, en_overrides.tsv, deterministic fallback; with `legacy=True` it is
bit-identical to romlib.roman: 100% of existing rows reproduced) plus: (1) Unicode cleanup before lookup (doubled nasals/visarga/matras,
ाे->ो, ेा->ो, visarga after a vowel sign, "|" -> danda); (2) collision fixes: ठा/ठी/ठे -> thha/thhi/thhe, मैन -> man, bare क/थ/य/ठ -> k/th/y/thh;
(3) about 25 word overrides for garbled deterministic spellings (udaharan, teekakaran, vidhansabha, ...; list in the file). No schwa-rule change.
Override spellings come from Aksharantar's non-Dakshina rows where attested, else are our own choice; no Dakshina (BY-SA) data is used for targets.

Call (this directory, `speech/data`, must be on sys.path):

    import sys; sys.path.insert(0, "speech/data")
    from romanize_v2 import romanize_v2
    romanize_v2(deva_text)                 # train style: sentence case, keeps . , ? !
    romanize_v2(deva_text, style="eval")   # lowercase, no punctuation (eval sets)
    # CLI: python3 romanize_v2.py "देवनागरी" | python3 romanize_v2.py --jsonl in --field reference_raw --out out
It memoizes per word (lru_cache), so it is safe on tens of millions of tokens. It does not use r2lib.nk().
Vaani: run `vaani_clean.clean(raw)` first, then romanize_v2 on the cleaned text (as vaani_v2 does).

## Directories
- `indicvoices_vb/`, `indicvoices2_vb/`: reference from the IndicVoices **verbatim** field (old manifests used `text` = `normalized`, the standardized field),
  tags stripped (`<...>`, `[...]`, `{...}`, `###`; only `<unintelligible>` occurs in verbatim, kept as `has_unintelligible`), romanized with v2.
  Caveat: verbatim also carries annotator spelling noise (हे/ए for है, नइ/नई for नहीं, औ for और, त for तो, बी/वी for भी); consider filtering or a hybrid.
- `mucs_v2/`, `kathbath_v2/`, `shrutilipi_v2/` (10 h), `vaani_v2/` (train, dev, test_eval), `shrutilipi_full_v2/`: same clips, references re-romanized with v2 only.
- `dev-mix_v2.jsonl` (v2 romanizer on the same standardized text), `dev-mix_vb.jsonl` (indicvoices rows use verbatim). English rows untouched.
- `../evalsets-lexicon-v2/{hiacc,mucs-hien-test,fleurs-hi}/manifest.jsonl`.
- cvindia_full and librispeech: unchanged (English).

Rebuild: `python build_v2.py vb|v2|full|devmix|evalsets` in `speech/data` (needs `$UIUI_ML_ROOT/eval-dev/vb_<src>.jsonl`, produced by an extraction script that re-reads only the text columns of the HF parquet; that script is not included).

## indicvoices_hy / indicvoices2_hy / dev-mix_hy.jsonl (hybrid)
Same clips and splits. Base text is the STANDARDIZED Devanagari; a standardized token is replaced by the verbatim token only for these exact
(standardized -> verbatim) pairs: पर->पे, कर->के (never as the first token, i.e. only as a conjunctive participle after a verb stem), लेकर->लेके,
हैं->है, है->हैं, कि->की, की->कि, नहीं->ना. DP token alignment; rows with more than 30% unmatched tokens keep the standardized text (about 4.5% of rows).
Not taken (annotator spelling noise): हे/ए for है, नई/नइ/नही for नहीं, औ/ओर for और, त for तो, बी/वी for भी, बहोत/बोहोत, रा/रए, पहेले, and Sh/S spelling swaps.
Not taken but possible later: की->का / का->की / के->का (about 350 each way; may be annotator hearing errors rather than speech), वह->वो and यह->ये (romanize identically).
Romanized with romanize_v2 (train style). Fields: `reference_raw` = hybrid Devanagari, `reference_raw_std`, `reference_raw_vb` (cleaned verbatim), `hy_replacements`, `reference_v1`, `has_unintelligible`.
`dev-mix_hy.jsonl`: IndicVoices rows hybrid, kathbath/mucs via romanize_v2, English untouched. Rebuild: `python build_hy.py --procs 5` (`speech/data`). Stats: `indicvoices_hy/summary_hy.json`.
