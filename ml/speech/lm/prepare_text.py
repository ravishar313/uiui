"""Prepare BPE-token-id text for the n-gram LM (run where the manifests are).

Train data: Roman `reference` of every data/manifests/*/train.jsonl (never dev, never evalsets), tokenised with the model's own
SentencePiece/BPE exactly as train/data.py does (raw text, add_special_tokens=False).  Sentences that also occur in ANY dev / eval
reference (any `reference*` / `text` field, in either script) are dropped.  Optional PHINC (CC BY 4.0).
Also writes the train tokens-per-second statistics used by the repetition guard.

python lm/prepare_text.py --root $UIUI_ML_ROOT --out $UIUI_ML_ROOT/dec-dev/lmdata [--phinc dec-dev/data/phinc/PHINC.csv]
"""
from __future__ import annotations
import argparse, csv, glob, json, os, re, unicodedata
from pathlib import Path
import numpy as np
from uiui_root import ROOT

REF_KEYS = ("reference", "reference_raw", "reference_hybrid", "reference_punct", "text", "transcript", "reference_lexicon")


def key(t: str) -> str:
    t = unicodedata.normalize("NFKC", t).lower().replace("’", "'")
    return re.sub(r"\s+", " ", re.sub(r"[^\w' ]+", " ", t)).strip()


def rows(path):
    with open(path) as f:
        for l in f:
            if l.strip():
                try: yield json.loads(l)
                except json.JSONDecodeError: pass


def eval_keys(root: Path):
    files = sorted(set(glob.glob(str(root / "data/manifests/*/dev.jsonl")) + [str(root / "data/manifests/dev-mix.jsonl")]
                       + glob.glob(str(root / "data/evalsets-lexicon/*/*.jsonl")) + glob.glob(str(root / "evalsets/*/*.jsonl"))))
    keys, per = set(), {}
    for p in files:
        n = 0
        for r in rows(p):
            for k in REF_KEYS:
                v = r.get(k)
                if isinstance(v, str) and v.strip():
                    keys.add(key(v)); n += 1
        per[os.path.relpath(p, root)] = n
    keys.discard("")
    return keys, per


def clean_phinc(s: str) -> str:
    s = re.sub(r"https?://\S+|www\.\S+|…", " ", s)
    s = re.sub(r"@\w+", " ", s)
    s = re.sub(r"#(\w+)", r"\1", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s[:1].upper() + s[1:] if s else s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=ROOT)
    ap.add_argument("--out", required=True)
    ap.add_argument("--phinc")
    a = ap.parse_args()
    root, out = Path(a.root), Path(a.out); out.mkdir(parents=True, exist_ok=True)
    from transformers import AutoProcessor
    tok = AutoProcessor.from_pretrained(str(root / "trainability/hf/parakeet")).tokenizer
    ev, per = eval_keys(root)
    print(f"eval/dev reference keys: {len(ev)} from {len(per)} files")

    seen_ids, texts, secs, srcs = set(), [], [], []
    stats = {"manifests": {}, "dropped_dup_id": 0, "dropped_leak": 0, "dropped_empty": 0}
    for p in sorted(glob.glob(str(root / "data/manifests/*/train.jsonl"))):
        name = Path(p).parent.name
        n = kept = 0
        for r in rows(p):
            n += 1
            rid = r.get("id")
            if rid in seen_ids: stats["dropped_dup_id"] += 1; continue
            seen_ids.add(rid)
            t = (r.get("reference") or r.get("text") or "").strip()
            if not t: stats["dropped_empty"] += 1; continue
            ks = {key(t)} | {key(r[k]) for k in REF_KEYS if isinstance(r.get(k), str) and r[k].strip()}
            if ks & ev: stats["dropped_leak"] += 1; continue
            texts.append(t); secs.append(float(r.get("seconds") or 0)); srcs.append(name); kept += 1
        stats["manifests"][name] = {"rows": n, "kept": kept}
    print(stats)

    ids = tok(texts, add_special_tokens=False)["input_ids"]
    with open(out / "train_ids.txt", "w") as f:
        for x in ids: f.write(" ".join(map(str, x)) + "\n")
    n_tok = sum(map(len, ids))
    print(f"train sentences {len(ids)}, tokens {n_tok}")

    # tokens/sec statistics (guard cap)
    L = np.array([len(x) for x in ids], float); S = np.array(secs)
    ok = S > 0
    rate = L[ok] / S[ok]
    res = {"n_utts": int(ok.sum()), "hours": float(S[ok].sum() / 3600), "tokens": int(L.sum())}
    for nm, m in (("all", np.ones(ok.sum(), bool)), ("ge2s", S[ok] >= 2.0), ("ge3s", S[ok] >= 3.0)):
        r = rate[m]
        res[nm] = {"n": int(m.sum()), **{f"p{q}": float(np.percentile(r, q)) for q in (50, 90, 99, 99.9, 99.99)}, "max": float(r.max())}
    # pooled rate in windows is not available (no alignments); also the per-source p99.9 (>=2s)
    srcs = np.array(srcs)[ok]
    res["per_source_p99.9_ge2s"] = {s: float(np.percentile(rate[(srcs == s) & (S[ok] >= 2.0)], 99.9)) for s in sorted(set(srcs))
                                    if ((srcs == s) & (S[ok] >= 2.0)).sum() > 50}
    (out / "tokrate.json").write_text(json.dumps(res, indent=1))
    print(json.dumps(res, indent=1))

    if a.phinc:
        sents, dropped = [], 0
        with open(a.phinc, newline="") as f:
            for row in csv.DictReader(f):
                s = clean_phinc(row["Sentence"])
                if len(s.split()) < 2: continue
                if key(s) in ev: dropped += 1; continue
                sents.append(s)
        pid = tok(sents, add_special_tokens=False)["input_ids"]
        with open(out / "phinc_ids.txt", "w") as f:
            for x in pid: f.write(" ".join(map(str, x)) + "\n")
        print(f"phinc sentences {len(pid)} (dropped {dropped} leaking), tokens {sum(map(len, pid))}")
        stats["phinc"] = {"sentences": len(pid), "tokens": sum(map(len, pid)), "dropped_leak": dropped}
    stats["train_sentences"] = len(ids); stats["train_tokens"] = n_tok; stats["eval_keys"] = len(ev); stats["eval_files"] = per
    (out / "prepare_stats.json").write_text(json.dumps(stats, indent=1))


if __name__ == "__main__":
    main()
