#!/usr/bin/env python3
"""Score ASR hypotheses: WER/CER per category, with a Hinglish spelling normalizer.

Usage: python3 score.py hyp.jsonl [hyp2.jsonl ...] [--show N]
Rows need: id, cat, reference, hypothesis.

Two WERs are reported:
  strict  lowercase, punctuation removed, digits/number words untouched
  fair    also folds Roman-Hindi spelling variants (kyaa→kya, nahin→nahi, …),
          number words→digits and "p.m."→"pm", so a model isn't penalised for
          an equally valid spelling. Hill-climb on "fair"; watch "strict".
"""
import json
import re
import sys
import unicodedata
from collections import defaultdict

# Canonical Roman-Hindi spellings. Keys are variants, values the canonical form.
HINGLISH_VARIANTS = {
    "kyaa": "kya", "kia": "kya", "nahin": "nahi", "nai": "nahi", "nahee": "nahi", "nhi": "nahi",
    "hain": "hai", "he": "hai", "hay": "hai", "hoon": "hun", "hu": "hun", "hoo": "hun",
    "mai": "main", "mein": "me", "mei": "me", "mien": "me", "toh": "to", "tho": "to",
    "accha": "acha", "achha": "acha", "acchha": "acha", "theek": "thik", "tik": "thik", "thick": "thik",
    "bahut": "bohot", "bohat": "bohot", "bahot": "bohot", "kyun": "kyu", "kyon": "kyu",
    "kyunki": "kyuki", "kyonki": "kyuki", "yeh": "ye", "yah": "ye", "woh": "wo", "voh": "wo", "vo": "wo",
    "aaj": "aj", "aap": "ap", "abhi": "abhi", "phir": "fir", "pehle": "pehle", "pahle": "pehle",
    "karo": "karo", "kro": "karo", "krna": "karna", "raha": "raha", "rha": "raha", "rahi": "rahi", "rhi": "rahi",
    "rahe": "rahe", "rhe": "rahe", "kar": "kar", "kr": "kar", "ki": "ki", "ke": "ke", "ko": "ko",
    "yaar": "yar", "bhai": "bhai", "bhaiya": "bhaiya", "ek": "ek", "tum": "tum", "tu": "tu",
    "kaafi": "kafi", "kahan": "kaha", "kahaan": "kaha", "yahan": "yaha", "wahan": "waha",
    "jaunga": "jaunga", "jaoonga": "jaunga", "aaunga": "aunga", "aaonga": "aunga", "paunga": "paunga",
    "baje": "baje", "bajey": "baje", "garmi": "garmi", "chahiye": "chahiye", "chaahiye": "chahiye",
    "samajh": "samajh", "samaj": "samajh", "shayad": "shayad", "khayal": "khayal", "khyal": "khayal",
    "ismein": "isme", "isme": "isme", "usme": "usme", "usmein": "usme", "humein": "hume", "hamein": "hume",
    "chhota": "chota", "chota": "chota", "ghar": "ghar", "das": "das", "dus": "das",
    "subah": "subah", "subha": "subah", "tabiyat": "tabiyat", "tabiyet": "tabiyat", "thoda": "thoda", "thodi": "thodi",
    "chalo": "chalo", "chalega": "chalega", "milte": "milte", "dena": "dena", "lena": "lena",
}

NUMBER_WORDS = {
    "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
    "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12",
    "fifteen": "15", "twenty": "20", "thirty": "30", "fourteenth": "14th",
}


def base_tokens(text):
    text = unicodedata.normalize("NFKC", text).lower().replace("’", "'")
    text = re.sub(r"(?<=\d),(?=\d{2})", "", text)          # 48,500 → 48500
    text = re.sub(r"\b([ap])\.\s?m\.?", r"\1m", text)        # p.m. → pm
    text = re.sub(r"(?<=\d):(?=\d)", " ", text)              # 3:30 → 3 30
    text = re.sub(r"[^\w' ]+", " ", text)
    return [t.strip("'") for t in text.split() if t.strip("'")]


# --- extra Hinglish folding, adapted from data-research/scripts/hinglish_normalizer.py -------------
# Applied only to Hinglish-style categories, AFTER the table above, to both reference and hypothesis.
CANON = {
    "hai": ["he", "hey", "h", "haai", "hae"], "hain": ["hein", "hen", "hayn"],
    "nahi": ["nahin", "nahee", "nahii", "nhi", "nai", "nahiin", "nahein"], "kya": ["kyaa", "kia"],
    "main": ["mai", "mae"], "mein": ["me", "men", "mei", "mien"], "hoon": ["hun", "hu", "hoo"],
    "raha": ["rha", "rahaa"], "rahi": ["rhi", "rahee", "rahii"], "rahe": ["rhe"],
    "kyunki": ["kyonki", "kyuki", "kyoki", "kyunkii"], "kyun": ["kyon", "kyu", "kyoon", "kyo"],
    "yeh": ["yah", "ye", "yahh"], "woh": ["vo", "wo", "vah", "voh"], "ki": ["kee", "kii"],
    "bhi": ["bhee", "bhii"], "hi": ["hee", "hii"], "toh": ["tho"], "aur": ["aor", "awr"],
    "accha": ["acha", "achha", "achchha", "achcha", "acchha"], "theek": ["thik", "theekh", "tik", "teek"],
    "kuch": ["kuchh", "kuchch"], "bahut": ["bohot", "bahot", "bohat", "bhot", "bahuth"],
    "abhi": ["abhee", "abhii"], "kaise": ["kese", "kaisay"], "aisa": ["esa", "aesa"],
    "waisa": ["vaisa", "wesa", "vesa"], "yaar": ["yar"], "kar": ["kr"], "karna": ["krna", "karnaa"],
    "karo": ["kro"], "matlab": ["mtlb", "matlb"], "sab": ["sb"], "tum": ["tm"], "hum": ["hm"],
    "paanch": ["panch"], "jaunga": ["jaaunga", "jaaoonga", "jaoonga"],
}
CANON_VARIANT = {v: k for k, vs in CANON.items() for v in vs}
CANON_VARIANT["mein"] = "main"  # 'main' (I) and 'mein' (in) are homographs in casual writing
CANON_KNOWN = set(CANON) | set(CANON_VARIANT)


def _load_english_vocab():
    try:
        with open("/usr/share/dict/words") as f:
            return {w.strip().lower() for w in f}
    except OSError:
        return None


ENGLISH_VOCAB = _load_english_vocab()


def skeleton(tok):
    """Phonetic fallback: collapse vowel length, doubled letters and a final nasal."""
    t = tok
    for a, b in (("aa", "a"), ("ee", "i"), ("ii", "i"), ("oo", "u"), ("uu", "u"), ("w", "v"), ("z", "j"),
                 ("q", "k"), ("ph", "f")):
        t = t.replace(a, b)
    t = re.sub(r"(.)\1+", r"\1", t)
    return re.sub(r"(?<=[aeiou])n$", "", t)


def fold_hinglish(t):
    t = CANON_VARIANT.get(t, t)
    if ENGLISH_VOCAB is not None and t.isascii() and t.isalpha() and len(t) > 3 \
            and t not in ENGLISH_VOCAB and t not in CANON_KNOWN:
        t = skeleton(t)  # only unknown (non-English) spellings; real English words are left alone
    return t


def fair_tokens(text, hinglish):
    out = []
    for t in base_tokens(text):
        t = NUMBER_WORDS.get(t, t)
        if hinglish:  # only fold Roman-Hindi variants where Hindi is expected ("he", "me" are English words)
            t = fold_hinglish(HINGLISH_VARIANTS.get(t, t))
        out.append(t)
    return out


def edits(ref, hyp):
    d = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        prev, d[0] = d[0], i
        for j, h in enumerate(hyp, 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (r != h))
    return d[len(hyp)]


def compute(rows):
    """Return ({category: {words, strict_wer, wer, cer}}, samples sorted worst-first)."""
    agg = defaultdict(lambda: [0, 0, 0, 0, 0])  # strict_e, fair_e, words, char_e, chars
    samples = []
    for r in rows:
        ref, hyp = r["reference"], r.get("hypothesis", "")
        s = edits(base_tokens(ref), base_tokens(hyp))
        hinglish = r["cat"] in ("hinglish", "short", "free")
        fr, fh = fair_tokens(ref, hinglish), fair_tokens(hyp, hinglish)
        f = edits(fr, fh)
        c = edits(list(" ".join(fr)), list(" ".join(fh)))
        for k in (r["cat"], "ALL"):
            a = agg[k]
            a[0] += s; a[1] += f; a[2] += len(fr); a[3] += c; a[4] += len(" ".join(fr))
        samples.append({"id": r["id"], "cat": r["cat"], "speaker": r.get("speaker"),
                        "errors": f, "words": len(fr), "reference": ref, "hypothesis": hyp})
    metrics = {k: {"words": a[2], "strict_wer": round(100 * a[0] / max(a[2], 1), 2),
                   "wer": round(100 * a[1] / max(a[2], 1), 2),
                   "cer": round(100 * a[3] / max(a[4], 1), 2)} for k, a in agg.items()}
    samples.sort(key=lambda x: (-x["errors"], x["id"]))
    return metrics, samples


def score(path, show):
    rows = [json.loads(l) for l in open(path) if l.strip()]
    metrics, samples = compute(rows)
    print(f"\n== {path}")
    print(f"{'category':10} {'words':>6} {'strict WER':>11} {'fair WER':>9} {'fair CER':>9}")
    for k in sorted(metrics, key=lambda k: (k == "ALL", k)):
        m = metrics[k]
        print(f"{k:10} {m['words']:6d} {m['strict_wer']:10.2f}% {m['wer']:8.2f}% {m['cer']:8.2f}%")
    for x in samples[:show]:
        print(f"  [{x['errors']}] {x['id']}\n      ref: {x['reference']}\n      hyp: {x['hypothesis']}")


if __name__ == "__main__":
    show = 0
    args = sys.argv[1:]
    if "--show" in args:
        k = args.index("--show"); show = int(args[k + 1]); del args[k:k + 2]
    for p in args:
        score(p, show)
