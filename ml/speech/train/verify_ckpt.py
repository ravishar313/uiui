#!/usr/bin/env python3
"""Load a checkpoint dir's model.safetensors into a stock ParakeetForTDT and score it.
python verify_ckpt.py <ckpt dir> [--manifest m.jsonl] [--max-clips N] [--file model_ema.safetensors]"""
import devutil
DEV = devutil.pick_device()
import argparse, sys, warnings
from pathlib import Path
import torch
from uiui_root import ROOT
warnings.filterwarnings("ignore")
sys.path.insert(0, str(Path(__file__).resolve().parent))
import modes, evaluate
from safetensors.torch import load_file
from transformers import ParakeetForTDT, ParakeetTDTConfig, AutoProcessor, GenerationConfig

ap = argparse.ArgumentParser(); ap.add_argument("dir"); ap.add_argument("--file", default="model.safetensors")
ap.add_argument("--manifest", default=ROOT + "/smoke-src/synthetic-manifest.jsonl"); ap.add_argument("--max-clips", type=int, default=0)
a = ap.parse_args(); d = Path(a.dir)
cfg = ParakeetTDTConfig.from_pretrained(d)
m = ParakeetForTDT(cfg)
print(m.load_state_dict(load_file(d / a.file), strict=True))
m.generation_config = GenerationConfig.from_pretrained(modes.tp.BASE)
proc = AutoProcessor.from_pretrained(modes.tp.BASE); m.to(DEV)
items = evaluate.pick(evaluate.load_manifest(a.manifest, None, None)[0], a.max_clips)
metrics, _, ms, _ = evaluate.evaluate(m, proc, items, DEV, 8)
print(f"{d.name}/{a.file}: {len(items)} clips, " + ", ".join(f"{k} {v['wer']}%" for k, v in sorted(metrics.items())))
