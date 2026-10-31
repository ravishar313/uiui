#!/usr/bin/env python
"""Evaluate the uiui cleanup model on gold (punctuated, cased) sentences.

Input rows: {"id", "text", optional "mix" (en|hinglish), "field", "register", ...}.
Per sentence: gold text -> strip punctuation + lowercase (Phonon-style ASR output) -> full app pipeline
(450-byte segments, MiniLM, `accepted` guards, terminal-punctuation finalize) -> compare word by word
with the gold, using the app's own word regex so alignment is exact.

Usage:
  python eval_cleanup.py --gold ../data/workplace/sentences_eval.jsonl --out runs/baseline_workplace
  python eval_cleanup.py --gold data/general/regression_eval.jsonl --backend torch --ckpt runs/ft1/best --out runs/ft1/eval_general
Flags: --backend onnx|torch, --ckpt (onnx file or HF dir; default = shipped), --device cpu|mps,
       --no-gate (skip `accepted` structured-text guards), --no-finalize (skip terminal-punct fallback),
       --split-by mix,field,register, --worst N.
"""
import argparse, json, time
from collections import Counter, defaultdict
from pathlib import Path
import regex as re
import numpy as np

from uiui_cleanup import make_cleaner, PUNCT_NAMES, CASE_NAMES, accepted
from tagging import strip_input, tag_text, MIXED, CAP, UPPER, LOWER

SPECIAL = {
    "colon_numeric(1:1,10:30)": re.compile(r"(?<![\w:])\d+:\d+(?![\w:])"),
    "ampersand(P&L,R&D)": re.compile(r"(?<!\w)[A-Za-z]{1,4}&[A-Za-z]{1,4}(?!\w)"),
    "rupee(₹5 lakh)": re.compile(r"₹\s?\d[\d,.]*(?:\s?(?:lakh|crore|cr|Cr|k|L))?"),
}
_ws = lambda s: re.sub(r"\s+", " ", s).strip()


class Agg:
    def __init__(self):
        self.pc = np.zeros((5, 5), int)      # gold x pred
        self.cc = np.zeros((3, 3), int)
        self.c = Counter()
        self.acr_fail, self.pn_fail, self.mixed_seen = Counter(), Counter(), Counter()

    def add_sentence(self, gold, pred, gtags, ptags, out_text):
        c = self.c
        c["sentences"] += 1
        c["exact_string"] += _ws(gold) == _ws(pred)
        punct_ok = all(g[1] == p[1] for g, p in zip(gtags, ptags))
        case_ok = all(g[2] == p[2] for g, p in zip(gtags, ptags) if g[2] != MIXED)
        c["exact_tags_punct"] += punct_ok
        c["exact_tags_case"] += case_ok
        c["exact_tags_all"] += punct_ok and case_ok
        for i, (g, p) in enumerate(zip(gtags, ptags)):
            self.pc[g[1], p[1]] += 1
            start = i == 0 or gtags[i - 1][1] in (2, 3, 4)
            w = g[0]
            if g[2] == MIXED:
                c["mixed_n"] += 1
                c["mixed_exact"] += p[0] == w
                c["mixed_capitalised_first_letter"] += p[0][:1] == w[:1]
                self.mixed_seen[w] += p[0] != w
                continue
            self.cc[g[2], p[2] if p[2] != MIXED else 0] += 1
            if g[2] == UPPER:
                c["acronym_n"] += 1
                ok = p[0] == w
                c["acronym_exact"] += ok
                if not ok: self.acr_fail[f"{w} -> {p[0]}"] += 1
            if g[2] == CAP and not start and w != "I" and not w.startswith("I'"):
                c["propernoun_n"] += 1
                ok = p[0] == w
                c["propernoun_exact"] += ok
                if not ok: self.pn_fail[f"{w} -> {p[0]}"] += 1
            if g[2] == CAP and start:
                c["sentstart_cap_n"] += 1
                c["sentstart_cap_ok"] += p[0] == w
            if g[2] == LOWER and not start:
                c["lower_n"] += 1
                c["lower_overcap"] += p[2] != LOWER
        for name, rx in SPECIAL.items():
            for m in rx.finditer(gold):
                c[f"special:{name}:n"] += 1
                c[f"special:{name}:exact"] += _ws(m.group(0)) in _ws(out_text)

    def report(self):
        c, pc = self.c, self.pc
        r = {"sentences": c["sentences"], "words": int(pc.sum())}
        f1s = {}
        for k, name in enumerate(PUNCT_NAMES):
            tp = pc[k, k]; fp = pc[:, k].sum() - tp; fn = pc[k, :].sum() - tp
            p = tp / (tp + fp) if tp + fp else 0.0; rc = tp / (tp + fn) if tp + fn else 0.0
            f1s[name] = {"f1": round(2 * p * rc / (p + rc), 4) if p + rc else 0.0, "precision": round(p, 4),
                         "recall": round(rc, 4), "support": int(pc[k, :].sum())}
        r["punct_per_class"] = f1s
        tp = sum(pc[k, k] for k in range(1, 5)); fp = pc[:, 1:].sum() - tp; fn = pc[1:, :].sum() - tp
        p = tp / (tp + fp) if tp + fp else 0.0; rc = tp / (tp + fn) if tp + fn else 0.0
        r["punct_micro_f1_excl_none"] = round(2 * p * rc / (p + rc), 4) if p + rc else 0.0
        r["punct_accuracy"] = round(float(np.trace(pc) / max(pc.sum(), 1)), 4)
        r["case_accuracy_nonmixed"] = round(float(np.trace(self.cc) / max(self.cc.sum(), 1)), 4)
        r["case_confusion_gold_x_pred(LOWER,CAP,UPPER)"] = self.cc.tolist()
        r["punct_confusion_gold_x_pred"] = pc.tolist()
        rate = lambda a, b: round(c[a] / c[b], 4) if c[b] else None
        r["acronym_exact"] = {"rate": rate("acronym_exact", "acronym_n"), "n": c["acronym_n"]}
        r["propernoun_cap_exact"] = {"rate": rate("propernoun_exact", "propernoun_n"), "n": c["propernoun_n"]}
        r["sentence_start_cap"] = {"rate": rate("sentstart_cap_ok", "sentstart_cap_n"), "n": c["sentstart_cap_n"]}
        r["lowercase_word_overcapitalised_rate"] = {"rate": rate("lower_overcap", "lower_n"), "n": c["lower_n"]}
        r["mixed_case_forms(iPhone,GitHub)"] = {"exact_rate": rate("mixed_exact", "mixed_n"),
                                               "first_letter_right": rate("mixed_capitalised_first_letter", "mixed_n"),
                                               "n": c["mixed_n"],
                                               "note": "model cannot emit internal capitals; needs personal-dictionary restoration"}
        for name in SPECIAL:
            r[f"special {name}"] = {"exact_rate": rate(f"special:{name}:exact", f"special:{name}:n"), "n": c[f"special:{name}:n"]}
        r["sentence_exact_string"] = rate("exact_string", "sentences")
        r["sentence_exact_tags_all"] = rate("exact_tags_all", "sentences")
        r["sentence_exact_tags_punct"] = rate("exact_tags_punct", "sentences")
        r["sentence_exact_tags_case"] = rate("exact_tags_case", "sentences")
        r["top_acronym_failures"] = self.acr_fail.most_common(25)
        r["top_propernoun_failures"] = self.pn_fail.most_common(25)
        return r


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--gold", required=True)
    ap.add_argument("--backend", default="onnx", choices=["onnx", "torch"])
    ap.add_argument("--ckpt", default=None)
    ap.add_argument("--device", default="cpu")
    ap.add_argument("--no-gate", action="store_true")
    ap.add_argument("--no-finalize", action="store_true")
    ap.add_argument("--label-mode", action="store_true", help="label-formatting mode (keep model terminal punctuation)")
    ap.add_argument("--hinglish-questions", action="store_true", help="with --label-mode: Hinglish '?' tail heuristic")
    ap.add_argument("--split-by", default="mix")
    ap.add_argument("--worst", type=int, default=100)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--out", default=None, help="output dir (metrics.json, worst.jsonl, predictions.jsonl)")
    a = ap.parse_args()

    rows = [json.loads(l) for l in open(a.gold) if l.strip()]
    if a.limit: rows = rows[:a.limit]
    cl = make_cleaner(a.backend, a.ckpt, a.device)
    splits = [s for s in a.split_by.split(",") if s]
    aggs = defaultdict(Agg)
    aggs["ALL"]
    errs, preds, align_fail, gated = [], [], 0, 0
    t0 = time.time()
    for r in rows:
        gold = _ws(r["text"])
        inp = strip_input(gold)
        out = cl.clean(inp, finalize=not a.no_finalize, gate=not a.no_gate, label_mode=a.label_mode,
                       hinglish_questions=a.hinglish_questions)
        gated += (accepted(inp, inp) is None)
        gt, pt = tag_text(gold), tag_text(out)
        if len(gt) != len(pt) or any(g[0].lower() != p[0].lower() for g, p in zip(gt, pt)):
            align_fail += 1
            continue
        keys = ["ALL"] + [f"{s}={r[s]}" for s in splits if s in r]
        for k in keys:
            aggs[k].add_sentence(gold, out, gt, pt, out)
        nerr = sum(g[1] != p[1] for g, p in zip(gt, pt)) + sum(g[2] != p[2] for g, p in zip(gt, pt) if g[2] != MIXED)
        errs.append((nerr, r["id"], gold, out, inp))
        preds.append({"id": r["id"], "input": inp, "pred": out, "gold": gold, **{s: r.get(s) for s in splits}})
    rep = {"gold": a.gold, "backend": a.backend, "ckpt": a.ckpt or "shipped", "gate": not a.no_gate,
           "finalize": not a.no_finalize, "rows": len(rows), "alignment_failures": align_fail,
           "input_rejected_by_structured_guard": gated, "seconds": round(time.time() - t0, 1),
           "results": {k: v.report() for k, v in sorted(aggs.items())}}
    if a.out:
        out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
        json.dump(rep, open(out / "metrics.json", "w"), indent=1, ensure_ascii=False)
        with open(out / "worst.jsonl", "w") as f:
            for n, i, g, p, inp in sorted(errs, key=lambda x: -x[0])[:a.worst]:
                f.write(json.dumps({"id": i, "errors": n, "gold": g, "pred": p, "input": inp}, ensure_ascii=False) + "\n")
        with open(out / "predictions.jsonl", "w") as f:
            for p in preds: f.write(json.dumps(p, ensure_ascii=False) + "\n")
    # compact print
    print(f"rows={len(rows)} align_fail={align_fail} structured_guard_skips={gated} {rep['seconds']}s  [{a.backend} {rep['ckpt']}]")
    hdr = f"{'split':18}{'n':>6}{'punctF1':>9}{'PER':>6}{'COM':>6}{'QUE':>6}{'caseAcc':>9}{'acroEx':>8}{'(n)':>6}{'propN':>7}{'(n)':>6}{'sentEx':>8}{'tagsEx':>8}"
    print(hdr)
    f = lambda x: "  -  " if x is None else f"{x*100:5.1f}"
    for k, v in rep["results"].items():
        pcl = v["punct_per_class"]
        print(f"{k:18}{v['sentences']:6}{f(v['punct_micro_f1_excl_none']):>9}{f(pcl['PERIOD']['f1']):>6}{f(pcl['COMMA']['f1']):>6}"
              f"{f(pcl['QUESTION']['f1']):>6}{f(v['case_accuracy_nonmixed']):>9}{f(v['acronym_exact']['rate']):>8}{v['acronym_exact']['n']:>6}"
              f"{f(v['propernoun_cap_exact']['rate']):>7}{v['propernoun_cap_exact']['n']:>6}{f(v['sentence_exact_string']):>8}{f(v['sentence_exact_tags_all']):>8}")
    for n, i, g, p, inp in sorted(errs, key=lambda x: -x[0])[:5]:
        print(f"\n[{i}] errs={n}\n  gold: {g}\n  pred: {p}")


if __name__ == "__main__":
    main()
