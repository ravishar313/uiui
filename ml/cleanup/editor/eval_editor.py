#!/usr/bin/env python
"""Speech-model output alone vs + editor, on real eval transcripts (rows: id, cat, reference, hypothesis). Prints aggregates only.
Metrics: formatting on correctly recognised words (asr_eval/fmt_metrics.py) and word error rate of the final text
(locked fair_wer twer, so editor deletions are scored: deleting a filler the reference keeps counts as an error).

  python editor/eval_editor.py --rows ROWS.jsonl [--rows ...] --ckpt runs/editor1/best --out runs/editor1/eval.json
"""
import argparse, collections, json, re, sys
from pathlib import Path
HERE = Path(__file__).resolve().parent; ROOT = HERE.parent
sys.path.insert(0, str(ROOT)); sys.path.insert(0, str(HERE)); sys.path.insert(0, str(ROOT / "asr_eval"))
sys.path.insert(0, str(ROOT.parent / "speech" / "eval" / "evalx"))
import numpy as np, torch
from transformers import AutoModelForTokenClassification
import editor as E
from fmt_metrics import Agg
from fair_wer import twer
from uiui_cleanup import finalize_punctuation

ap = argparse.ArgumentParser()
ap.add_argument("--rows", nargs="+", required=True)
ap.add_argument("--ckpt", required=True)
ap.add_argument("--thr", type=float, default=0.5)
ap.add_argument("--out", required=True)
a = ap.parse_args()
m = AutoModelForTokenClassification.from_pretrained(a.ckpt, attn_implementation="eager").eval()
def predict(ids):
    with torch.no_grad(): return m(input_ids=torch.tensor([ids])).logits[0].float().numpy()
ed = E.Editor(predict, del_thr=a.thr)
res = {}
for path in a.rows:
    rows = [json.loads(l) for l in open(path) if l.strip()]
    aggs = collections.defaultdict(Agg); wer_rows = collections.defaultdict(list); changed = deleted = 0
    for r in rows:
        ref, hyp = r["reference"], r["hypothesis"]
        outs = {"raw": finalize_punctuation(hyp), "editor": ed.clean(hyp)}
        changed += outs["editor"] != outs["raw"]
        deleted += max(0, len(E.words_in(hyp)) - len(E.words_in(outs["editor"])))
        dp, dc = bool(re.search(r"[.,?!]", ref)), bool(re.search(r"[A-Z]", ref))
        for k, o in outs.items():
            for cat in (r["cat"], "ALL"):
                aggs[(k, cat)].add(ref, o, dp, dc)
                wer_rows[(k, cat)].append({"id": r["id"], "cat": "en", "reference": ref, "hypothesis": o})
    name = Path(path).stem; res[name] = {"rows": len(rows), "changed": changed, "words_deleted": deleted}
    for (k, cat), ag in sorted(aggs.items()):
        s = ag.summary(); mt, _ = twer(wer_rows[(k, cat)]); s["wer"] = round(mt["ALL"]["raw_wer"], 2); s["twer"] = round(mt["ALL"]["twer"], 2)
        res[name][f"{k}|{cat}"] = s
    keys = ["punct_f1", "comma_f1", "period_f1", "question_f1", "case_acc", "midsentence_cap", "wrongly_capitalised", "wer"]
    print(f"== {name}: rows {len(rows)}, changed {changed}, words deleted {deleted}")
    print("cat      pipe   " + " ".join(k[:11].rjust(11) for k in keys))
    for cat in sorted({c for (_, c) in aggs}):
        for k in ("raw", "editor"):
            s = res[name][f"{k}|{cat}"]; print(f"{cat:8} {k:6} " + " ".join(f"{s[x]:11}" for x in keys))
json.dump(res, open(a.out, "w"), indent=1)
