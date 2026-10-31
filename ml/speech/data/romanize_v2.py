#!/usr/bin/env python3
"""romanize_v2: Devanagari (or mixed) text -> casual Roman Hinglish. Same pipeline as romlib.roman (lexicon.tsv with the LLM loanword
pass + en_overrides.tsv + deterministic fallback) plus these fixes found in the label audit:

  1. Unicode cleanup before lookup (clean_deva): doubled nasals/visarga/matras (हैंं, यहाँँ, नहींं), the artefacts ाे->ो ाै->ौ ेा->ो ाॅ->ॉ,
     visarga after a vowel sign (कहाः, हैः), "|" after Devanagari -> danda.
  2. Collision rows: ठा/ठी/ठे no longer collapse onto tha/thi/the; मैन -> "man" (was "main"); the bare letters क/थ/य/ठ become their
     consonant only (k/th/y/thh) instead of ka/tha/ya. (मेन stays "main": it is usually "main road".)
  3. OVERRIDES: garbled deterministic spellings of frequent words (udahran, teekakran, vidhanasbha, ...). No schwa-rule change.

Usage:
  from romanize_v2 import romanize_v2          # this directory (speech/data) must be on sys.path
  romanize_v2("उदाहरण के लिए यहाँँ है|")                 # style="train": sentence case, keeps . , ? !
  romanize_v2(text, style="eval")                     # lowercase, no punctuation (eval sets)
  romanize_v2(text, legacy=True)                      # identical to romlib.roman (v1), for diffing
CLI:
  python3 romanize_v2.py "देवनागरी पाठ" [--style eval] [--legacy]
  python3 romanize_v2.py --jsonl in.jsonl --field reference_raw --out out.jsonl [--out-field reference] [--style train]
"""
import json
import os
import re
import sys
import unicodedata
from functools import lru_cache

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import romlib  # noqa: E402
from lexlib import norm_deva  # noqa: E402

VERSION = "romanize_v2.1"

_ZW = "‍‌"


def clean_deva(t):
    t = unicodedata.normalize("NFC", t).replace("‍", "").replace("‌", "")
    t = re.sub(r"([ऀ-ःा-ौ])\1+", r"\1", t)        # doubled nasal / visarga / vowel sign
    t = re.sub(r"[ँं]{2,}", lambda m: m.group(0)[0], t)     # mixed doubled nasals
    t = t.replace("ाे", "ो").replace("ाै", "ौ").replace("ेा", "ो").replace("ाॅ", "ॉ")
    t = re.sub(r"([ा-ौ])ः", r"\1", t)                  # visarga after a vowel sign (typo)
    t = re.sub(r"(?<=[ऀ-ॿ])\s*\|", "। ", t)           # "है|" -> "है।"
    return t


# deva -> roman, applied before lexicon.tsv. Keys are NFC, no ZWJ.
OVERRIDES = {
    # --- collision rows ---
    "ठा": "thha", "ठी": "thhi", "ठे": "thhe", "मैन": "man",
    "क": "k", "थ": "th", "य": "y", "ठ": "thh",
    # --- garbled deterministic spellings (spelling = majority Aksharantar form where attested, else confident) ---
    "उदाहरण": "udaharan", "टीकाकरण": "teekakaran", "वातावरण": "vaatavaran", "दीपावली": "deepavali", "विधानसभा": "vidhansabha",
    "संक्रमण": "sankraman", "अक्षरों": "aksharon", "जानवरों": "jaanvaron", "फरवरी": "pharvari", "पर्यावरण": "paryavaran",
    "सरस्वती": "saraswati", "लोकसभा": "loksabha", "प्रचलित": "prachalit", "बेहतरीन": "behtareen", "पारंपरिक": "paaramparik",
    "संवाददाता": "samvaddata", "उपकरण": "upkaran", "वाराणसी": "varanasi", "ड्रॉपडाउन": "dropdown", "ड्रापडाउन": "dropdown",
    "राइटक्लिक": "rightclick", "एक्जीक्यूट": "execute", "उदाहरणस्वरूप": "udaharanswaroop", "उदाहरणस्वरुप": "udaharanswaroop",
    "अलगअलग": "alagalag",
}
OVERRIDES = {norm_deva(k): v for k, v in OVERRIDES.items()}


@lru_cache(maxsize=2_000_000)
def word_v2(w):
    w = norm_deva(w)
    r = OVERRIDES.get(w)
    if r is not None:
        return r
    return romlib.word(w)


def romanize_v2(text, style="train", legacy=False):
    if legacy:
        return romlib.roman(text, style)
    t = romlib.clean_src(clean_deva(text))
    out = []
    for is_deva, piece in romlib.tokens(t):
        out.append(word_v2(piece) if is_deva else piece)
    r = re.sub(r"\s+", " ", "".join(out)).strip()
    if style == "eval":
        r = re.sub(r"[.,?!;:]", " ", r).replace("-", " ")
        r = re.sub(r"(?<![A-Za-z0-9])'|'(?![A-Za-z0-9])", " ", r)
        return " ".join(r.split())
    return romlib.sentence_case(r)


roman_v2 = romanize_v2


def main(argv):
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("text", nargs="?")
    ap.add_argument("--style", default="train")
    ap.add_argument("--legacy", action="store_true")
    ap.add_argument("--jsonl"); ap.add_argument("--field", default="reference_raw")
    ap.add_argument("--out"); ap.add_argument("--out-field", default="reference")
    a = ap.parse_args(argv)
    if a.jsonl:
        with open(a.jsonl) as f, open(a.out, "w") as o:
            for l in f:
                r = json.loads(l)
                r[a.out_field] = romanize_v2(r[a.field], a.style, a.legacy)
                o.write(json.dumps(r, ensure_ascii=False) + "\n")
    else:
        print(romanize_v2(a.text if a.text is not None else sys.stdin.read(), a.style, a.legacy))


if __name__ == "__main__":
    main(sys.argv[1:])
