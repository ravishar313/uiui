"""Clip-level paired bootstrap of the fair-WER difference between two dump dirs (runs/f-base vs runs/f-o6 ...).
python lm/delta_ci.py runs/f-base runs/f-o6 [sets...]"""
import json, sys, os
from pathlib import Path
import numpy as np
from uiui_root import SPEECH
sys.path.insert(0, SPEECH + "/eval/evalx")
from score import compute
a, b = Path(sys.argv[1]), Path(sys.argv[2])
sets = sys.argv[3:] or [p.stem for p in sorted(a.glob("*.jsonl"))]
rng = np.random.RandomState(0)
for s in sets:
    def per(d):
        rows = [json.loads(l) for l in (d / f"{s}.jsonl").read_text().splitlines()]
        _, samples = compute(rows)
        m = {x["id"]: (x["errors"], x["words"]) for x in samples}
        return m
    A, B = per(a), per(b)
    ids = sorted(A)
    ea, eb, w = (np.array([A[i][0] for i in ids]), np.array([B[i][0] for i in ids]), np.array([A[i][1] for i in ids]))
    d = 100 * (eb.sum() - ea.sum()) / w.sum()
    bs = []
    for _ in range(2000):
        ix = rng.randint(0, len(ids), len(ids)); bs.append(100 * (eb[ix].sum() - ea[ix].sum()) / w[ix].sum())
    lo, hi = np.percentile(bs, [2.5, 97.5])
    print(f"{s:18} dWER {d:+.2f}  95% CI [{lo:+.2f}, {hi:+.2f}]  clips better/worse/same {(eb < ea).sum()}/{(eb > ea).sum()}/{(eb == ea).sum()}")
