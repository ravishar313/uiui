#!/usr/bin/env python3
"""Filter Whisper pseudo-labels into a training manifest.

  python pl_filter.py --whisper out.jsonl --ours hyp.jsonl --out train.jsonl --report report.json [--wer 0.15]
  python pl_filter.py --whisper out.jsonl --whisper-only --out train.jsonl --report report.json

Agreement mode (default): keep a clip iff all hold
  normalized WER(whisper_text, ours) <= --wer (0.15)   [normalization: NFKC, lowercase, punctuation stripped,
                                                        digit-grouping commas removed, spelled-out 0-20 -> digits]
  avg_logprob >= -0.5, compression_ratio <= 2.4, no_speech_prob <= 0.5, words/sec in [0.8, 5.0]
  no hallucination marker in the Whisper text.
Whisper-only mode (--whisper-only, no second hypothesis): stricter defaults
  avg_logprob >= -0.25, compression_ratio <= 2.0, no_speech_prob <= 0.2, words/sec in [1.0, 4.5],
  and at least --min-words (3) words; the same hallucination markers. Every threshold has an override flag.

Hallucination markers: repeated n-grams (a 1-gram 6x, 2-gram 4x or 3/4-gram 3x in a row), known subtitle/outro
phrases ("thank you for watching", "subtitles by", "amara.org", "please subscribe", ...), any letter outside
Latin script (Devanagari, CJK, Arabic, Cyrillic, ...). Output rows: id, audio, reference (= Whisper text as
emitted, cased + punctuated), seconds, source, pl_agreement (1 - WER vs ours; null in whisper-only mode).
Rows with a `reference` field in the Whisper file (only the EVAL smoke tests have it) are used for the report's
true-reference WER and are NOT copied to the training manifest.
"""
import argparse, json, re, sys, unicodedata
from collections import Counter

p = argparse.ArgumentParser()
p.add_argument("--whisper", required=True)
p.add_argument("--ours", help="jsonl with id, hypothesis")
p.add_argument("--whisper-only", action="store_true")
p.add_argument("--out", required=True)
p.add_argument("--report", required=True)
p.add_argument("--source", default="pseudo-whisper-large-v3")
p.add_argument("--wer", type=float, default=0.15)
p.add_argument("--min-logprob", type=float)
p.add_argument("--max-compression", type=float)
p.add_argument("--max-no-speech", type=float)
p.add_argument("--min-wps", type=float)
p.add_argument("--max-wps", type=float)
p.add_argument("--min-words", type=int)
a = p.parse_args()
if not a.whisper_only and not a.ours: p.error("need --ours or --whisper-only")

D = dict(lp=-0.5, cr=2.4, ns=0.5, wmin=0.8, wmax=5.0, minw=1)
if a.whisper_only: D = dict(lp=-0.25, cr=2.0, ns=0.2, wmin=1.0, wmax=4.5, minw=3)
T = dict(lp=a.min_logprob if a.min_logprob is not None else D["lp"], cr=a.max_compression or D["cr"],
         ns=a.max_no_speech if a.max_no_speech is not None else D["ns"], wmin=a.min_wps or D["wmin"],
         wmax=a.max_wps or D["wmax"], minw=a.min_words or D["minw"])

NUMW = {w: str(i) for i, w in enumerate("zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty".split())}
def norm(t):
    t = unicodedata.normalize("NFKC", t).lower().replace("’", "'")
    t = re.sub(r"(?<=\d),(?=\d{3})", "", t)
    t = re.sub(r"[^\w' ]+", " ", t)
    return [NUMW.get(w.strip("'"), w.strip("'")) for w in t.split() if w.strip("'")]

def wer(ref, hyp):
    if not ref: return 0.0 if not hyp else 1.0
    prev = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        cur = [i]
        for j, h in enumerate(hyp, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r != h)))
        prev = cur
    return prev[-1] / len(ref)

PHRASES = ["thank you for watching", "thanks for watching", "thank you so much for watching", "please subscribe", "subscribe to",
           "like and subscribe", "subtitles by", "subtitled by", "subtitles made by", "captions by", "captioned by", "amara.org",
           "transcribed by", "translated by", "www.", "http", ".com", "see you in the next", "see you next time", "bye bye",
           "(music)", "[music]", "♪", "[applause]", "(applause)", "[blank_audio]", "copyright", "all rights reserved",
           "thank you for listening", "mbc", "subtitle"]
def nonlatin(t):
    for c in t:
        if c.isalpha() and not ("LATIN" in unicodedata.name(c, "")): return True
    return False
def rep_ngram(w):
    for m, need in ((1, 6), (2, 4), (3, 3), (4, 3)):
        for i in range(0, len(w) - m * need + 1):
            u = w[i:i + m]
            if all(w[i + j * m:i + (j + 1) * m] == u for j in range(need)): return True
    return False
def halluc(text):
    low = text.lower()
    if nonlatin(text): return "non_latin_script"
    if any(ph in low for ph in PHRASES): return "subtitle_credit_phrase"
    if rep_ngram(norm(text)): return "repeated_ngram"
    return None

ours = {}
if a.ours:
    for l in open(a.ours):
        r = json.loads(l); ours[r["id"]] = r.get("hypothesis", r.get("hypothesis_raw", ""))

rej = Counter(); kept = []; n = 0; true_k = []; true_all = []
for l in open(a.whisper):
    r = json.loads(l); n += 1
    text = r["whisper_text"].strip(); w = norm(text); dur = r.get("duration") or r.get("seconds") or 0
    why = []
    if not text or not w: why.append("empty")
    h = halluc(text) if text else None
    if h: why.append(h)
    if r["avg_logprob"] < T["lp"]: why.append("low_avg_logprob")
    if r["compression_ratio"] > T["cr"]: why.append("high_compression_ratio")
    if r["no_speech_prob"] > T["ns"]: why.append("high_no_speech_prob")
    if dur and w and not (T["wmin"] <= len(w) / dur <= T["wmax"]): why.append("words_per_sec_out_of_range")
    if len(w) < T["minw"]: why.append("too_few_words")
    agree = None
    if not a.whisper_only:
        if r["id"] not in ours: why.append("no_second_hypothesis")
        else:
            e = wer(w, norm(ours[r["id"]])); agree = round(1 - e, 4)
            if e > a.wer: why.append("disagrees_with_ours")
    if "reference" in r and not why:
        true_k.append((norm(r["reference"]), w))
    if "reference" in r: true_all.append((norm(r["reference"]), w))
    if why:
        rej[why[0]] += 1   # first-listed reason; "reasons_any" below counts every reason
        for x in why: rej["any:" + x] += 1
        continue
    kept.append({"id": r["id"], "audio": r["audio"], "reference": text, "seconds": r.get("seconds", dur),
                 "source": a.source, "pl_agreement": agree})

def corpus_wer(pairs):
    err = sum(wer(ref, hyp) * len(ref) for ref, hyp in pairs); tot = sum(len(ref) for ref, _ in pairs)
    return round(100 * err / tot, 2) if tot else None

with open(a.out, "w") as f:
    for k in kept: f.write(json.dumps(k, ensure_ascii=False) + "\n")
rep = {"mode": "whisper-only" if a.whisper_only else f"agreement(wer<={a.wer})", "thresholds": T, "rows": n, "kept": len(kept),
       "keep_rate": round(len(kept) / max(n, 1), 4), "kept_hours": round(sum(k["seconds"] for k in kept) / 3600, 3),
       "reject_first_reason": {k: v for k, v in rej.items() if not k.startswith("any:")},
       "reject_any_reason": {k[4:]: v for k, v in rej.items() if k.startswith("any:")}}
if true_all:
    rep["true_ref_wer_kept_pct"] = corpus_wer(true_k); rep["true_ref_wer_all_pct"] = corpus_wer(true_all)
json.dump(rep, open(a.report, "w"), indent=1)
print(json.dumps(rep, indent=1))
