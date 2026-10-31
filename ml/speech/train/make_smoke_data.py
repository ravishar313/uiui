#!/usr/bin/env python3
"""Smoke-test data: tile the 70 synthetic TTS clips into ~9.5 s clips (transcript = concatenation) -> $UIUI_ML_ROOT/smoke10s/manifest.jsonl.
Only for exercising the loop at the real 8 x 10 s shape; never for a model we ship."""
import json, random, sys
from pathlib import Path
import numpy as np, soundfile as sf
from uiui_root import ROOT
src = Path(ROOT) / "smoke-src"; out = Path(ROOT) / "smoke10s"; (out / "audio").mkdir(parents=True, exist_ok=True)
rows = [json.loads(l) for l in open(src / "synthetic-manifest.jsonl")]
wav = {r["id"]: sf.read(src / r["audio"], dtype="float32")[0] for r in rows}
rng = random.Random(0); n = int(sys.argv[1]) if len(sys.argv) > 1 else 96; man = []
for k in range(n):
    ws, ts, tot = [], [], 0
    while True:
        r = rng.choice(rows); w = wav[r["id"]]
        if tot + len(w) > 9.6 * 16000: break
        ws.append(w); ts.append(r["reference"]); tot += len(w)
    p = out / "audio" / f"cat{k:03d}.wav"; sf.write(p, np.concatenate(ws), 16000)
    man.append({"id": f"cat{k:03d}", "audio": str(p), "reference": " ".join(ts), "cat": "en"})
(out / "manifest.jsonl").write_text("\n".join(json.dumps(m) for m in man) + "\n"); print(n, "clips ->", out)
