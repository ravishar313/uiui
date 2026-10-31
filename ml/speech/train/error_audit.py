"""Where do Hinglish errors come from?  Transcribe an eval set, align hyp/ref words, and split the errors into
spelling variants (same consonant skeleton), real substitutions, deletions and insertions.  CPU by default.
Usage: python error_audit.py <model.safetensors> <manifest.jsonl> [--cat hinglish] [--device cpu] [--n 400]"""
import argparse, re, sys
from collections import Counter
from pathlib import Path

import torch
from safetensors.torch import load_file

ROOT = Path(__file__).resolve().parent
sys.path[:0] = [str(ROOT), str(ROOT.parent / "eval" / "evalx")]
import evaluate, modes                       # noqa: E402
from score import compute                    # noqa: E402

SUBS = [("ph", "f"), ("kh", "k"), ("gh", "g"), ("chh", "c"), ("ch", "c"), ("jh", "j"), ("th", "t"), ("dh", "d"), ("bh", "b"),
        ("sh", "s"), ("w", "v"), ("z", "j"), ("q", "k"), ("x", "ks"), ("c", "k"), ("y", "i")]


def norm(w):
    return re.sub(r"[^a-z0-9]", "", w.lower())


def skeleton(w):
    w = norm(w)
    if len(w) <= 2: return w
    for a, b in SUBS: w = w.replace(a, b)
    w = w[0] + re.sub(r"[aeiouh]", "", w[1:])            # keep the first letter, drop vowels and stray h
    return re.sub(r"(.)\1+", r"\1", w)                    # collapse doubles


def align(r, h):
    """Levenshtein word alignment -> list of (op, ref_word, hyp_word)."""
    n, m = len(r), len(h)
    d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1): d[i][0] = i
    for j in range(m + 1): d[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (r[i - 1] != h[j - 1]))
    ops, i, j = [], n, m
    while i or j:
        if i and j and d[i][j] == d[i - 1][j - 1] + (r[i - 1] != h[j - 1]):
            ops.append(("ok" if r[i - 1] == h[j - 1] else "sub", r[i - 1], h[j - 1])); i -= 1; j -= 1
        elif i and d[i][j] == d[i - 1][j] + 1: ops.append(("del", r[i - 1], "")); i -= 1
        else: ops.append(("ins", "", h[j - 1])); j -= 1
    return ops[::-1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("weights"); ap.add_argument("manifest")
    ap.add_argument("--cat", default="hinglish"); ap.add_argument("--device", default="cpu"); ap.add_argument("--n", type=int, default=400)
    a = ap.parse_args()
    torch.set_num_threads(8)
    model, proc = modes.tp.load()
    model.load_state_dict(load_file(a.weights), strict=False); model.to(a.device).eval()
    items = [it for it in evaluate.load_eval_sets([{"name": "x", "manifest": a.manifest}])["x"] if it["cat"] == a.cat][:a.n]
    hyps, _ = evaluate.transcribe(model, proc, items, a.device, 8)
    rows = [{"id": it["id"], "cat": it["cat"], "reference": it["text"], "hypothesis": h, "speaker": it["speaker"]} for it, h in zip(items, hyps)]
    m, _ = compute(rows)
    c, ex = Counter(), {"spelling": [], "sub": [], "del": [], "ins": []}
    nref = 0
    for row in rows:
        r = [norm(w) for w in row["reference"].split() if norm(w)]; h = [norm(w) for w in row["hypothesis"].split() if norm(w)]
        nref += len(r)
        for op, rw, hw in align(r, h):
            if op == "sub":
                op = "spelling" if skeleton(rw) == skeleton(hw) else "sub"
            c[op] += 1
            if op in ex and len(ex[op]) < 25: ex[op].append((rw, hw))
    err = c["spelling"] + c["sub"] + c["del"] + c["ins"]
    print(f"clips {len(rows)}  ref words {nref}  scorer: {m.get(a.cat, m['ALL'])}")
    print(f"plain WER (no folding) {100 * err / nref:.1f}%  ->  spelling-blind WER {100 * (err - c['spelling']) / nref:.1f}%")
    for k in ("spelling", "sub", "del", "ins"):
        print(f"  {k:9s} {c[k]:5d}  {100 * c[k] / nref:5.1f}% of ref words  {100 * c[k] / max(err, 1):5.1f}% of errors")
    for k in ("spelling", "sub", "del", "ins"):
        print(f"{k} examples:", "; ".join(f"{x}->{y}" if k in ("sub", "spelling") else (x or y) for x, y in ex[k][:25]))


if __name__ == "__main__":
    main()
