#!/usr/bin/env python3
"""Spelling-tolerant Roman-Hinglish scoring ("T-WER"), independent of score.py's selection metric.

twer(rows) -> (metrics, samples)   rows need: id, cat, reference, hypothesis   (same row format as score.compute)

Per category and ALL:
  words       reference words
  raw_wer     strict: lowercase, punctuation removed (score.base_tokens), exact token match
  twer_loose  upper bound: also folds vowel-length/doubled-letter tail spellings (can hide real errors; see loose_key)
  twer        both reference and hypothesis mapped through the attested-variant map (roman_variants.canon)
  cer         character error rate on the raw (strict) token stream
  cer_canon   same on the canonical token stream
  fw_*        function-word bucket, measured on the canonical stream (so hai/hain, ke/ka, par/pe stay errors):
                fw_ref        reference words that are function words
                fw_errors     edits touching a function word (ref word is one for sub/del, hyp word for ins;
                              for subs, a function word on either side counts)
                fw_pts        fw_errors / words * 100 = how many T-WER points come from function words
                fw_share      fw_errors / total edits
                fw_rate       fw_errors / fw_ref
                fw_top        most frequent (ref -> hyp) function-word confusions, "" = deletion/insertion

The variant map only folds spellings of the same word. Variants of protected, grammatically distinct words
(hai/hain, ke/ka/ki, par/pe, kar/ke, mein/main, kaha/kahan, gender/number forms) are never merged.
Categories folded: hinglish/short/free (override with hinglish_cats). Others use the raw tokens for T-WER too.

CLI: python3 fair_wer.py hyp.jsonl [...] [--no-eval-only] [--show N]
"""
import json
import os
import re
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from roman_variants import FUNCTION_WORDS, PROTECTED, default_map  # noqa: E402
from score import NUMBER_WORDS, base_tokens  # noqa: E402  (import only; score.py is owned elsewhere)

HINGLISH_CATS = ("hinglish", "short", "free")


def loose_key(tok):
    """Optional AGGRESSIVE fold for the long tail (vowel length, doubled letters, ph/f, z/j, w/v). It can hide real
    errors (kal/kaal, man/maan, paas/pas), so it is reported only as an upper bound on spelling slack: twer_loose."""
    if len(tok) < 4 or tok in PROTECTED or tok in FUNCTION_WORDS or not tok.isalpha():
        return tok
    t = tok.replace("ph", "f").replace("w", "v").replace("z", "j")
    t = re.sub(r"aa+", "a", t); t = re.sub(r"ee+|ii+", "i", t); t = re.sub(r"oo+|uu+", "u", t)
    return re.sub(r"([^aeiou])\1+", r"\1", t)


def tokens(text):
    return [NUMBER_WORDS.get(t, t) for t in base_tokens(text)]


def align(ref, hyp):
    """Levenshtein alignment -> list of (op, ref_word, hyp_word); op in ok/sub/del/ins."""
    n, m = len(ref), len(hyp)
    d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1):
        d[i][0] = i
    for j in range(m + 1):
        d[0][j] = j
    for i in range(1, n + 1):
        ri = ref[i - 1]
        for j in range(1, m + 1):
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (ri != hyp[j - 1]))
    ops, i, j = [], n, m
    while i or j:
        if i and j and d[i][j] == d[i - 1][j - 1] + (ref[i - 1] != hyp[j - 1]):
            ops.append(("ok" if ref[i - 1] == hyp[j - 1] else "sub", ref[i - 1], hyp[j - 1])); i -= 1; j -= 1
        elif i and d[i][j] == d[i - 1][j] + 1:
            ops.append(("del", ref[i - 1], "")); i -= 1
        else:
            ops.append(("ins", "", hyp[j - 1])); j -= 1
    return ops[::-1]


def edit_count(a, b):
    return sum(op != "ok" for op, _, _ in align(a, b))


def char_edits(a, b):
    d = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        p, d[0] = d[0], i
        for j, y in enumerate(b, 1):
            p, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, p + (x != y))
    return d[-1]


def is_fw_error(op, r, h):
    if op == "ins":
        return h in FUNCTION_WORDS
    if op == "del":
        return r in FUNCTION_WORDS
    return op == "sub" and (r in FUNCTION_WORDS or h in FUNCTION_WORDS)


def twer(rows, hinglish_cats=HINGLISH_CATS, use_eval_only=True):
    vm = default_map(use_eval_only)
    acc = defaultdict(lambda: Counter())
    conf = defaultdict(Counter)
    samples = []
    for r in rows:
        cat = r["cat"]
        rr, hh = tokens(r["reference"]), tokens(r.get("hypothesis", ""))
        raw = align(rr, hh)
        raw_err = sum(op != "ok" for op, _, _ in raw)
        if cat in hinglish_cats:
            cr, ch = vm.canon_tokens(rr), vm.canon_tokens(hh)
        else:
            cr, ch = rr, hh
        ops = align(cr, ch)
        err = sum(op != "ok" for op, _, _ in ops)
        loose = edit_count([loose_key(t) for t in cr], [loose_key(t) for t in ch]) if cat in hinglish_cats else err
        fw = [(op, a, b) for op, a, b in ops if op != "ok" and is_fw_error(op, a, b)]
        c_raw = char_edits(" ".join(rr), " ".join(hh))
        c_can = char_edits(" ".join(cr), " ".join(ch))
        for k in (cat, "ALL"):
            a = acc[k]
            a["words"] += len(rr); a["raw"] += raw_err; a["twer"] += err; a["loose"] += loose
            a["chars"] += len(" ".join(rr)); a["c_raw"] += c_raw
            a["chars_c"] += len(" ".join(cr)); a["c_can"] += c_can
            a["fw_ref"] += sum(w in FUNCTION_WORDS for w in cr); a["fw_err"] += len(fw)
            for op, x, y in fw:
                conf[k][(x, y)] += 1
        samples.append({"id": r["id"], "cat": cat, "raw_errors": raw_err, "twer_errors": err, "words": len(rr),
                        "reference": r["reference"], "hypothesis": r.get("hypothesis", "")})
    metrics = {}
    for k, a in acc.items():
        w = max(a["words"], 1)
        metrics[k] = {
            "words": a["words"],
            "raw_wer": round(100 * a["raw"] / w, 2),
            "twer": round(100 * a["twer"] / w, 2),
            "twer_loose": round(100 * a["loose"] / w, 2),
            "cer": round(100 * a["c_raw"] / max(a["chars"], 1), 2),
            "cer_canon": round(100 * a["c_can"] / max(a["chars_c"], 1), 2),
            "fw_ref": a["fw_ref"], "fw_errors": a["fw_err"],
            "fw_pts": round(100 * a["fw_err"] / w, 2),
            "fw_share": round(100 * a["fw_err"] / max(a["twer"], 1), 1),
            "fw_rate": round(100 * a["fw_err"] / max(a["fw_ref"], 1), 2),
            "fw_top": [f"{x or '-'}>{y or '-'} x{n}" for (x, y), n in conf[k].most_common(12)],
        }
    samples.sort(key=lambda s: (-s["twer_errors"], s["id"]))
    return metrics, samples


def main(argv):
    show, use_eval_only = 0, True
    args = list(argv)
    if "--show" in args:
        i = args.index("--show"); show = int(args[i + 1]); del args[i:i + 2]
    if "--no-eval-only" in args:
        args.remove("--no-eval-only"); use_eval_only = False
    for p in args:
        rows = [json.loads(l) for l in open(p) if l.strip()]
        m, samples = twer(rows, use_eval_only=use_eval_only)
        print(f"\n== {p}  (eval-only Dakshina data {'on' if use_eval_only else 'off'})")
        print(f"{'category':10} {'words':>6} {'raw WER':>8} {'T-WER':>7} {'loose':>7} {'CER':>6} {'fw pts':>7} {'fw share':>9} {'fw rate':>8}")
        for k in sorted(m, key=lambda k: (k == "ALL", k)):
            x = m[k]
            print(f"{k:10} {x['words']:6d} {x['raw_wer']:7.2f}% {x['twer']:6.2f}% {x['twer_loose']:6.2f}% {x['cer']:5.2f}% {x['fw_pts']:6.2f} {x['fw_share']:8.1f}% {x['fw_rate']:7.2f}%")
        print("top function-word confusions (ALL):", "; ".join(m["ALL"]["fw_top"]))
        for s in samples[:show]:
            print(f"  [{s['twer_errors']}] {s['id']}\n      ref: {s['reference']}\n      hyp: {s['hypothesis']}")


if __name__ == "__main__":
    main(sys.argv[1:])
