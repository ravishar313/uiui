#!/usr/bin/env python3
"""Build the Roman-Hinglish spelling-variant map (offline; run once).

Inputs (downloaded separately, never committed):
  --aksh  hin_train.json (+valid/test) from ai4bharat/Aksharantar   (CC-BY manual / CC0 mined)
  --dak   hi.translit.sampled.{train,dev,test}.tsv from Dakshina   (CC BY-SA 4.0)
  our lexicon (data/lexicon/lexicon.tsv) is used only as a tie-break vote.

Outputs, split by license (see variants/README.md):
  variants/variants_permissive.tsv  built only from Aksharantar rows whose source is not Dakshina-derived
  variants/variants_evalonly_dakshina.tsv  built from votes that include Dakshina-derived data (BY-SA, EVAL ONLY)
Each line: variant <TAB> canonical <TAB> variant_votes <TAB> canonical_votes <TAB> n_deva
The eval-only file contains only variants NOT already in the permissive file (or that disagree with it).
"""
import argparse, collections, glob, json, os, re, sys, unicodedata
from uiui_root import ROOT

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from roman_variants import PROTECTED, is_protected_form  # noqa: E402

LEX_VOTES = 4  # our own label spelling counts as this many votes for words seen >= 50 times in our corpora
DAK_DERIVED_AK = {"Dakshina", "Existing"}  # Aksharantar rows copied from Dakshina / other existing (incl. Dakshina) sets


def clean_roman(s):
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower().strip()
    return s if re.fullmatch(r"[a-z]{2,}", s) else None


def clean_deva(s):
    return unicodedata.normalize("NFC", s).replace("‍", "").replace("‌", "").strip()


def edit(a, b):
    d = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        p, d[0] = d[0], i
        for j, y in enumerate(b, 1):
            p, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, p + (x != y))
    return d[-1]


def vkey(w):
    """Spelling-insensitive key: collapse vowel runs, w/v, z/j, ph/f, doubled letters, post-consonant h."""
    for x, y in (("ph", "f"), ("w", "v"), ("z", "j"), ("q", "k"), ("y", "i"), ("sh", "s"), ("ch", "c")):
        w = w.replace(x, y)
    w = re.sub(r"(?<=[^aeiou])h", "", w)
    w = re.sub(r"[aeiou]+", "a", w)
    w = re.sub(r"n(?=[kgtdpb])|m(?=[kgtdpb])", "n", w)   # nasal before a stop: n/m/anusvara are interchangeable
    return re.sub(r"(.)\1+", r"\1", w)


def close_enough(v, c):
    kv, kc = vkey(v), vkey(c)
    if kv == kc:
        return True
    return len(kv) >= 6 and edit(kv, kc) <= 1 and kv[0] == kc[0]


def build(votes, english, lex_final, sources_label):
    """votes: {deva: Counter(roman)}.  Returns {variant: (canon, vvotes, cvotes, n_deva)}."""
    canon = {}
    for d, c in votes.items():
        items = c.most_common()
        top_v = items[0][1]
        best = max(items, key=lambda kv: (kv[1] + (LEX_VOTES if lex_final.get(d) == kv[0] else 0), kv[0] in english,
                                           not re.search(r"[qxz]", kv[0]), -len(kv[0])))[0]
        eng = [kv for kv in items if kv[0] in english and len(kv[0]) >= 3]
        if eng and best not in english and d not in lex_final_hindi and eng[0][1] * 3 >= top_v:
            best = eng[0][0]  # loanword: prefer the English spelling when it is attested often enough
        canon[d] = best
    canon_set = set(canon.values())
    per_variant = collections.defaultdict(dict)  # variant -> {deva: votes}
    for d, c in votes.items():
        for r, n in c.items():
            per_variant[r][d] = n
    out = {}
    for v, dv in per_variant.items():
        if v in canon_set or is_protected_form(v) or len(v) < 2:
            continue
        ranked = sorted(dv.items(), key=lambda kv: -kv[1])
        d, n = ranked[0]
        if len(ranked) > 1 and ranked[1][1] * 10 >= n * 3:   # ambiguous across Devanagari words
            continue
        if v in english and v not in HINDI_OVER_ENGLISH:   # real English word: leave alone
            continue
        c = canon[d]
        if c == v or not close_enough(v, c):
            continue
        out[v] = (c, n, votes[d][c], len(dv))
    return out


def load_english(root):
    eng = collections.Counter()
    p = os.path.join(root, "data/manifests/librispeech/train.jsonl")
    if os.path.exists(p):
        for l in open(p):
            for w in re.findall(r"[a-z']+", json.loads(l)["reference"].lower()):
                eng[w] += 1
    words = {w for w, n in eng.items() if n >= 3 and w.isalpha()}
    try:
        words |= {w.strip().lower() for w in open("/usr/share/dict/words") if w.strip().isalpha()}
    except OSError:
        pass
    return words


# Hindi function words that are also English words: still allow them as VARIANT SOURCES? No: keep empty (left alone).
HINDI_OVER_ENGLISH = {"toh", "tho"}
lex_final_hindi = {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--aksh", nargs="+", required=True)
    ap.add_argument("--dak", nargs="+", required=True)
    ap.add_argument("--root", default=ROOT)
    a = ap.parse_args()
    global lex_final_hindi
    english = load_english(a.root)
    lex_final = {}
    for i, l in enumerate(open(os.path.join(a.root, "data/lexicon/lexicon.tsv"), encoding="utf-8")):
        if i:
            p = l.rstrip("\n").split("\t")
            if len(p) > 4 and re.fullmatch(r"[a-z]+", p[4] or "") and int(p[1]) >= 50:
                lex_final[clean_deva(p[0])] = p[4]
                if p[5] in ("lex", "det") and p[4] not in english:
                    lex_final_hindi[clean_deva(p[0])] = p[4]
    perm = collections.defaultdict(collections.Counter)
    both = collections.defaultdict(collections.Counter)
    for d, r in lex_final.items():
        perm[d][r] += LEX_VOTES
        both[d][r] += LEX_VOTES
    for path in a.aksh:
        for l in open(path, encoding="utf-8"):
            r = json.loads(l)
            d, v = clean_deva(r["native word"]), clean_roman(r["english word"])
            if not v or not d:
                continue
            both[d][v] += 1
            if r["source"] not in DAK_DERIVED_AK:
                perm[d][v] += 1
    for path in a.dak:
        for l in open(path, encoding="utf-8"):
            p = l.rstrip("\n").split("\t")
            if len(p) < 3:
                continue
            d, v = clean_deva(p[0]), clean_roman(p[1])
            if v and d:
                both[d][v] += int(p[2])
    m_perm = build(perm, english, lex_final, "perm")
    m_both = build(both, english, lex_final, "both")
    only = {v: x for v, x in m_both.items() if m_perm.get(v, (None,))[0] != x[0]}
    for name, m in (("variants_permissive.tsv", m_perm), ("variants_evalonly_dakshina.tsv", only)):
        with open(os.path.join(HERE, "variants", name), "w") as f:
            for v, (c, nv, nc, nd) in sorted(m.items()):
                f.write(f"{v}\t{c}\t{nv}\t{nc}\t{nd}\n")
        print(name, len(m))


if __name__ == "__main__":
    main()
