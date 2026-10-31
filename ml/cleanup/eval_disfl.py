#!/usr/bin/env python
"""Evaluate DELETE-head quality: filler P/R, repetition/repair accuracy, false-deletion rate on content tokens.
  python eval_disfl.py --ckpt runs/disfl1/best --out runs/disfl1/eval_disfl [--thr 0.5]
Sets: data/disfl/eval.jsonl (held-out natural_eval/hinglish eval sentences with injected disfluencies + eval-only templates),
data/disfl/eval_clean.jsonl (untouched natural_eval + hinglish eval: every deletion is false), data/disfl/hand_eval.txt (EVAL-ONLY, hand-written).
Token metrics are on the raw model output (before the app's structured-text gate, which would skip those sentences)."""
import argparse, json, re, sys
from collections import Counter, defaultdict
from pathlib import Path
import numpy as np
from disfl_cleaner import DisflCleaner
from uiui_cleanup import words_in, is_structured

HERE = Path(__file__).parent
CATS = ("filler", "rep", "repair")


def load(p): return [json.loads(l) for l in open(p)]


def hand_records(path, exclude=frozenset()):
    recs = []
    for ln, l in enumerate(open(path)):
        l = l.rstrip("\n")
        if not l or l.startswith("#"): continue
        body, tag = l.rsplit("|", 1)
        words, dels, cats = [], [], []
        pos = 0
        for m in re.finditer(r"\[\[(.*?)\]\]|([^\[]+)", body):
            seg = m.group(1) if m.group(1) is not None else m.group(2)
            d = 1 if m.group(1) is not None else 0
            for w in seg.split():
                words.append(w); dels.append(d)
                cats.append({"F": "filler", "R": "rep", "P": "repair", "X": "filler"}.get(tag, "filler") if d else None)
        if " ".join(words) in exclude: continue
        recs.append({"id": f"hand-{ln}", "kind": "hand_" + tag, "words": words, "del": dels, "cat": cats, "mix": "?"})
    return recs


def probs(cl, recs):
    out, skipped = [], 0
    for r in recs:
        text = " ".join(r["words"])
        if is_structured(text):
            skipped += 1; continue
        ws = words_in(text)
        if [w.normalized for w in ws] != r["words"]:
            skipped += 1; continue
        words, preds, dp = cl.tags(text)
        out.append((r, dp))
    return out, skipped


def rep_canon(r, p):
    """Deleting either copy of an immediate repetition gives identical text: if exactly one copy of a doubled block is
    deleted in the prediction but the other copy in gold, count it as correct (rewrite p to gold in that region)."""
    g = [bool(x) for x in r["del"]]; w = r["words"]; n = len(g); p = p.copy()
    for k in (1, 2, 3):
        for i in range(n - 2 * k + 1):
            if w[i:i + k] == w[i + k:i + 2 * k] and r["cat"][i] == "rep" or (w[i:i + k] == w[i + k:i + 2 * k] and r["cat"][i + k] == "rep"):
                a, b = g[i:i + k], g[i + k:i + 2 * k]
                pa, pb = list(p[i:i + k]), list(p[i + k:i + 2 * k])
                if (all(a) and not any(b) and not any(pa) and all(pb)) or (all(b) and not any(a) and all(pa) and not any(pb)):
                    p[i:i + 2 * k] = g[i:i + 2 * k]
    return p


def metrics(items, thr):
    tp = fp = fn = keep = 0
    cat_tot, cat_hit = Counter(), Counter()
    fd_kind, keep_kind = Counter(), Counter()
    ex = defaultdict(lambda: [0, 0])
    fdsent = Counter(); nsent = Counter()
    for r, dp in items:
        g = np.array(r["del"]); p = dp > thr
        if p.all() or p.sum() > 0.5 * len(p): p = np.zeros_like(p)   # same safety rule as DisflCleaner
        p = rep_canon(r, p)
        tp += int((g & p).sum()); fp += int((~g.astype(bool) & p).sum()); fn += int((g.astype(bool) & ~p).sum())
        kt = int((g == 0).sum()); keep += kt; keep_kind[r["kind"]] += kt; fd_kind[r["kind"]] += int(((g == 0) & p).sum())
        for c, gd, pd in zip(r["cat"], g, p):
            if c: cat_tot[c] += 1; cat_hit[c] += int(pd)
        nsent[r["kind"]] += 1
        fdsent[r["kind"]] += int(((g == 0) & p).any())
        # sentence-level exactness of the kept word sequence, grouped by which categories the sentence contains
        key = "+".join(sorted({c for c in r["cat"] if c})) or "none"
        ex[key][0] += int((g.astype(bool) == p).all()); ex[key][1] += 1
    P = tp / max(tp + fp, 1); R = tp / max(tp + fn, 1)
    return {"thr": thr, "precision": P, "recall": R, "f1": 2 * P * R / max(P + R, 1e-9), "false_del_rate_all_keep_tokens": fp / max(keep, 1),
            "false_del_tokens": fp, "keep_tokens": keep,
            "recall_by_cat": {c: cat_hit[c] / cat_tot[c] for c in cat_tot}, "n_by_cat": dict(cat_tot),
            "fdr_by_kind": {k: fd_kind[k] / max(keep_kind[k], 1) for k in keep_kind},
            "sentences_with_false_del_by_kind": {k: fdsent[k] / nsent[k] for k in nsent},
            "sentence_exact_by_cats": {k: {"acc": v[0] / v[1], "n": v[1]} for k, v in ex.items()}}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", required=True); ap.add_argument("--out", required=True)
    ap.add_argument("--thr", type=float, default=0.5)
    ap.add_argument("--sweep", default="0.3,0.5,0.7,0.8,0.9,0.95")
    ap.add_argument("--fails", type=int, default=25)
    a = ap.parse_args()
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    cl = DisflCleaner(a.ckpt, a.thr)
    res = {}
    sets = {"synthetic_eval": load(HERE / "data/disfl/eval.jsonl"), "clean_eval": load(HERE / "data/disfl/eval_clean.jsonl"),
            "hand_eval": hand_records(HERE / "data/disfl/hand_eval.txt", {" ".join(r["words"]) for r in load(HERE / "data/disfl/train.jsonl")})}
    cache = {}
    for name, recs in sets.items():
        items, sk = probs(cl, recs); cache[name] = items
        res[name] = {"n": len(items), "skipped_structured_or_misaligned": sk, "at_thr": metrics(items, a.thr),
                     "sweep": [metrics(items, float(t)) for t in a.sweep.split(",")]}
    # combined: precision/recall over synthetic + hand; FDR over all content tokens incl. the clean set
    allitems = cache["synthetic_eval"] + cache["hand_eval"] + cache["clean_eval"]
    res["all_sets"] = {"at_thr": metrics(allitems, a.thr), "sweep": [metrics(allitems, float(t)) for t in a.sweep.split(",")]}
    json.dump(res, open(out / "metrics.json", "w"), indent=1)
    # failures (hand + synthetic) : words only, no user data (synthetic/hand-written text)
    fails = []
    for name in ("hand_eval", "synthetic_eval"):
        for r, dp in cache[name]:
            p = dp > a.thr
            if p.all() or p.sum() > 0.5 * len(p): p = np.zeros_like(p)
            p = rep_canon(r, p)
            if (np.array(r["del"]).astype(bool) != p).any():
                fails.append({"set": name, "kind": r["kind"], "input": " ".join(w if not d and not q else ("[[%s]]" % w if d and q else ("{MISS %s}" % w if d else "{FALSE %s}" % w)) for w, d, q in zip(r["words"], r["del"], p))})
    json.dump(fails, open(out / "failures.json", "w"), indent=1, ensure_ascii=False)
    m = res["all_sets"]["at_thr"]
    print(json.dumps({k: (round(v, 4) if isinstance(v, float) else v) for k, v in m.items() if k in ("precision", "recall", "f1", "false_del_rate_all_keep_tokens")}))
    for n in ("synthetic_eval", "clean_eval", "hand_eval"):
        m = res[n]["at_thr"]
        print(n, res[n]["n"], "P %.3f R %.3f FDR %.4f" % (m["precision"], m["recall"], m["false_del_rate_all_keep_tokens"]), {k: round(v, 3) for k, v in m["recall_by_cat"].items()})


if __name__ == "__main__":
    main()
