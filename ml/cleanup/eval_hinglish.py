#!/usr/bin/env python
"""Hinglish-focused comparison: shipped vs ft2 vs ft3 (or any ckpt specs) on several gold sets.

Spec format: NAME=onnx[:path]  |  NAME=torch:path.   Example:
  python eval_hinglish.py --spec shipped=onnx --spec ft2=torch:runs/ft2/best --spec ft3=torch:runs/ft3/best \\
      --set hinglish_heldout=data/hinglish/eval_hinglish.jsonl --set natural_eval=data/natural/natural_eval.jsonl \\
      --set general_regression=data/general/regression_eval.jsonl --out runs/compare_hinglish

Metrics per (model, set, mode):
  hindi_false_caps  Hindi-lexicon tokens (data/hinglish/hindi_lexicon.txt) that are lowercase in gold, not sentence-initial
                    in gold, but CAP or UPPER in the output (also split: UPPER only). Only rows with mix=hinglish count.
  question_f1       per-class F1 of QUESTION (word-level, from eval_cleanup.Agg) for the whole set; hinglish rows alone in
                    the natural_eval split as `question_f1_hinglish_rows`.
  acronym_exact, proper_noun_cap, case_acc, punct_f1  as in eval_cleanup.py
  weekday_month_cap gold Monday..Sunday/January..December (mid-sentence) output exactly capitalised.
Modes: `app` = the app port (finalize forces '.'), `label` = --label-mode (model terminal punctuation kept).
"""
import argparse, json, sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "speech" / "lab"))
from tracker import Run
from uiui_cleanup import make_cleaner
from tagging import strip_input, tag_text, LOWER, CAP, UPPER, MIXED
from eval_cleanup import Agg, _ws

LEX = {w.strip() for w in open(Path(__file__).parent / "data/hinglish/hindi_lexicon.txt") if w.strip()}
SEEN_ACR = set()
for _f in ("data/hinglish/train_hinglish.jsonl", "data/natural/train_nat_plus_slot.jsonl"):
    for _l in open(Path(__file__).parent / _f):
        for _w, _p, _c in tag_text(json.loads(_l)["text"]):
            if _c == UPPER: SEEN_ACR.add(_w)
DAYS = {"monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"}
MONTHS = {"january", "february", "march", "april", "june", "july", "august", "september", "october", "november", "december"}  # "may" is ambiguous


def run(cl, rows, mode):
    ag, ag_h = Agg(), Agg()
    c = defaultdict(int)
    fails = defaultdict(int)
    skipped = 0
    for r in rows:
        gold = _ws(r["text"])
        inp = strip_input(gold)
        out = cl.clean(inp, label_mode=(mode != "app"), hinglish_questions=(mode == "label+hq"))
        gt, pt = tag_text(gold), tag_text(out)
        if len(gt) != len(pt) or any(g[0].lower() != p[0].lower() for g, p in zip(gt, pt)):
            skipped += 1
            continue
        ag.add_sentence(gold, out, gt, pt, out)
        if r.get("mix") == "hinglish":
            ag_h.add_sentence(gold, out, gt, pt, out)
        hing = r.get("mix") == "hinglish"
        for i, (g, p) in enumerate(zip(gt, pt)):
            start = i == 0 or gt[i - 1][1] in (2, 3, 4)
            w = g[0].lower()
            if hing and not start and g[2] == LOWER and w in LEX:
                c["hi_n"] += 1
                if p[2] != LOWER:
                    c["hi_false"] += 1
                    fails[f"{g[0]}->{p[0]}"] += 1
                if p[2] == UPPER: c["hi_upper"] += 1
            if g[2] == UPPER:
                u = "acr_seen" if g[0] in SEEN_ACR else "acr_unseen"
                c[u + "_n"] += 1; c[u + "_ok"] += p[0] == g[0]
            if not start and (w in DAYS or w in MONTHS) and g[2] == CAP:
                c["dm_n"] += 1
                c["dm_ok"] += p[0] == g[0]
    rep, rep_h = ag.report(), ag_h.report()
    rate = lambda a, b: round(c[a] / c[b], 4) if c[b] else None
    return {"rows": len(rows), "align_skipped": skipped,
            "hindi_false_caps": {"rate": rate("hi_false", "hi_n"), "upper_rate": rate("hi_upper", "hi_n"), "n": c["hi_n"]},
            "top_hindi_false_caps": sorted(fails.items(), key=lambda x: -x[1])[:15],
            "acronym_exact_seen_in_training": {"rate": rate("acr_seen_ok", "acr_seen_n"), "n": c["acr_seen_n"]},
            "acronym_exact_unseen": {"rate": rate("acr_unseen_ok", "acr_unseen_n"), "n": c["acr_unseen_n"]},
            "weekday_month_cap": {"rate": rate("dm_ok", "dm_n"), "n": c["dm_n"]},
            "question_f1": rep["punct_per_class"]["QUESTION"]["f1"], "question_p": rep["punct_per_class"]["QUESTION"]["precision"],
            "question_r": rep["punct_per_class"]["QUESTION"]["recall"], "question_n": rep["punct_per_class"]["QUESTION"]["support"],
            "question_f1_hinglish_rows": rep_h["punct_per_class"]["QUESTION"]["f1"] if c["hi_n"] else None,
            "acronym_exact": rep["acronym_exact"], "proper_noun_cap": rep["propernoun_cap_exact"],
            "case_acc": rep["case_accuracy_nonmixed"], "punct_f1": rep["punct_micro_f1_excl_none"],
            "period_f1": rep["punct_per_class"]["PERIOD"]["f1"], "comma_f1": rep["punct_per_class"]["COMMA"]["f1"],
            "sentence_exact": rep["sentence_exact_string"],
            "top_acronym_failures": rep["top_acronym_failures"][:8], "top_propernoun_failures": rep["top_propernoun_failures"][:8]}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--spec", action="append", required=True)
    ap.add_argument("--set", action="append", required=True)
    ap.add_argument("--modes", default="app,label")
    ap.add_argument("--device", default="cpu")
    ap.add_argument("--track", default=None, help="lab dashboard run name, e.g. cleanup-eval-ft3b")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    sets = {s.split("=", 1)[0]: [json.loads(l) for l in open(s.split("=", 1)[1]) if l.strip()] for s in a.set}
    res = {}
    trk = Run(a.track, kind="eval", config={"specs": a.spec, "sets": a.set, "modes": a.modes}, tags=["cleanup", "mac"]) if a.track else None
    for spec in a.spec:
        name, rest = spec.split("=", 1)
        be, _, path = rest.partition(":")
        cl = make_cleaner(be, path or None, a.device)
        for sname, rows in sets.items():
            for mode in a.modes.split(","):
                res.setdefault(name, {}).setdefault(sname, {})[mode] = run(cl, rows, mode)
                m = res[name][sname][mode]
                if trk:
                    flat = {"hindi_false_caps": m["hindi_false_caps"]["rate"], "question_f1": m["question_f1"], "acronym_exact": m["acronym_exact"]["rate"],
                            "proper_noun_cap": m["proper_noun_cap"]["rate"], "case_acc": m["case_acc"], "punct_f1": m["punct_f1"], "weekday_month_cap": m["weekday_month_cap"]["rate"]}
                    trk.log_eval(0, f"{name}/{sname}", {mode: flat})
                print(f"{name:8}{sname:20}{mode:9} hiFalseCap={m['hindi_false_caps']['rate']} Q-F1={m['question_f1']} "
                      f"acro={m['acronym_exact']['rate']} pn={m['proper_noun_cap']['rate']} case={m['case_acc']} punct={m['punct_f1']}", flush=True)
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    if trk: trk.finish()
    json.dump(res, open(out / "compare.json", "w"), indent=1, ensure_ascii=False)


if __name__ == "__main__":
    main()
