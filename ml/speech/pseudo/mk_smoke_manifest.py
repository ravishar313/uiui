#!/usr/bin/env python3
"""SMOKE ONLY: build manifests from EVAL sets (svarah-partial, monsoon-en-in). Never train on these."""
import json, soundfile as sf, sys
from uiui_root import ROOT
E = ROOT + "/evalsets"
for s in ["svarah-partial", "monsoon-en-in"]:
    out = open(f"{ROOT}/pseudo/smoke/EVAL_ONLY.{s}.manifest.jsonl", "w")
    for l in open(f"{ROOT}/bench/subsets/{s}.jsonl"):   # the fixed 150-clip subsets
        r = json.loads(l); r["seconds"] = round(sf.info(r["audio"]).duration, 3)
        out.write(json.dumps({k: r[k] for k in ("id", "audio", "seconds", "reference")}) + "\n")
