#!/usr/bin/env python
"""Acceptance comparison of two Phonon bundles with the native evaluator.

  accept.py <shipped bundle> <our bundle> <manifest.jsonl> [--sample N --seed S] [--out DIR]

Runs phonon-eval on both bundles (serially, so timings are not contended), then reports: texts identical, every diff,
WER of each (strict, via eval/score.py), median per-clip decode_ms, ANE first-load time."""
import argparse
import json
import os
import random
import statistics
import subprocess
import sys
import time
from pathlib import Path

EVAL = Path(__file__).resolve().parent.parent / "eval" / "evalx"
BIN = Path(os.environ.get("PHONON_EVAL_BIN") or "phonon-eval")
sys.path.insert(0, str(EVAL))
from score import compute  # noqa: E402  (read only)


def run(bundle, manifest, out):
    t = time.time()
    r = subprocess.run([str(BIN), str(bundle), str(manifest), str(out)], capture_output=True, text=True)
    wall = time.time() - t
    if r.returncode:
        raise SystemExit(r.stderr[-2000:])
    return [json.loads(l) for l in Path(out).read_text().splitlines() if l.strip()], wall, r.stdout.strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ship"); ap.add_argument("ours"); ap.add_argument("manifest")
    ap.add_argument("--sample", type=int, default=0); ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--out", default="/tmp/accept")
    a = ap.parse_args()
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    man = Path(a.manifest)
    if a.sample:
        rows = [json.loads(l) for l in man.read_text().splitlines() if l.strip()]
        random.Random(a.seed).shuffle(rows)
        man = out / "sample_manifest.jsonl"
        man.write_text("\n".join(json.dumps(r) for r in rows[: a.sample]) + "\n")
        # absolute audio paths required (manifest moved)
        base = Path(a.manifest).parent
        fixed = []
        for l in man.read_text().splitlines():
            r = json.loads(l)
            if not r["audio"].startswith("/"):
                r["audio"] = str(base / r["audio"])
            fixed.append(json.dumps(r))
        man.write_text("\n".join(fixed) + "\n")
    res = {}
    for name, b in (("shipped", a.ship), ("ours", a.ours)):
        rows, wall, so = run(b, man, out / f"{name}.jsonl")
        res[name] = rows
        print(f"{name}: {so}; wall {wall:.1f} s (includes first-load ANE compile)")
    s, o = res["shipped"], res["ours"]
    diffs = [(x["id"], x["hypothesis"], y["hypothesis"], x.get("reference")) for x, y in zip(s, o) if x["hypothesis"] != y["hypothesis"]]
    print(f"clips {len(s)}; identical text {len(s) - len(diffs)}/{len(s)}")
    for d in diffs:
        print(f"  DIFF {d[0]}\n    ref : {d[3]}\n    ship: {d[1]}\n    ours: {d[2]}")
    for name in ("shipped", "ours"):
        m, _ = compute(res[name])
        ms = [r.get("decode_ms", 0) for r in res[name]]
        print(name, "WER", {k: f"strict {v['strict_wer']} / fair {v['wer']}" for k, v in sorted(m.items())}, "median decode_ms", statistics.median(ms), "mean", round(statistics.mean(ms), 1))
    json.dump({"diffs": diffs}, open(out / "diffs.json", "w"), indent=1)


if __name__ == "__main__":
    main()
