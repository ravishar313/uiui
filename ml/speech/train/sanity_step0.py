#!/usr/bin/env python3
"""Step-0 check: greedy PyTorch decode of the model a config builds (before any training) vs the shipped Core ML model's
transcripts (smoke-src/synthetic-hyp.jsonl).   python sanity_step0.py --config configs/smoke_lora.yaml [--dtype bfloat16]"""
import devutil
DEV = devutil.pick_device()
import argparse, json, sys, warnings
from pathlib import Path
import torch, yaml
from uiui_root import ROOT, load_yaml
warnings.filterwarnings("ignore")
sys.path.insert(0, str(Path(__file__).resolve().parent)); sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "eval" / "evalx"))
import modes, evaluate
from score import base_tokens, edits

ap = argparse.ArgumentParser()
ap.add_argument("--config", required=True); ap.add_argument("--set", action="append", default=[]); ap.add_argument("--dtype", default=None)
ap.add_argument("--shipped", default=ROOT + "/smoke-src/synthetic-hyp.jsonl")
ap.add_argument("--manifest", default=ROOT + "/smoke-src/synthetic-manifest.jsonl")
a = ap.parse_args()
cfg = load_yaml(a.config)
for kv in a.set:
    k, v = kv.split("=", 1); d = cfg; ks = k.split(".")
    for x in ks[:-1]: d = d.setdefault(x, {})
    d[ks[-1]] = yaml.safe_load(v)
dev = DEV
calib = None
if (cfg.get("surgery") or {}).get("add_blocks"):
    from data import TrainData
    calib = next(iter(TrainData(dict(cfg["data"], num_workers=0), modes.tp.BASE, 0, log=lambda *_: None)))
model, proc, info = modes.build_model(cfg, calib, dev)
print(info)
items, _ = evaluate.load_manifest(a.manifest, None, None)
hyps, ms = evaluate.transcribe(model, proc, items, dev, 8, getattr(torch, a.dtype) if a.dtype else None)
shipped = {json.loads(l)["id"]: json.loads(l)["hypothesis"] for l in open(a.shipped)}
exact = sum(h == shipped[i["id"]] for i, h in zip(items, hyps))
e = sum(edits(base_tokens(shipped[i["id"]]), base_tokens(h)) for i, h in zip(items, hyps))
n = sum(len(base_tokens(shipped[i["id"]])) for i in items)
print(f"{len(items)} clips, {ms:.0f} ms/clip, dtype {a.dtype or 'fp32'}: exact-string match {exact}/{len(items)}, word diff vs shipped {e}/{n} = {100 * e / n:.2f}%")
for i, h in zip(items, hyps):
    if h != shipped[i["id"]]: print(f"  {i['id']}\n    shipped: {shipped[i['id']]}\n    torch  : {h}")
