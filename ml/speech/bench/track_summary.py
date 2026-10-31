#!/usr/bin/env python
"""Register finished bench runs (those without a live-tracked bench-<run> entry) on the lab dashboard, from results.json."""
import sys, json, glob, os
from uiui_root import ROOT, SPEECH
sys.path.insert(0, SPEECH + "/lab")
from tracker import Run
B = ROOT + "/bench"
R = json.load(open(f"{B}/results.json")); EN = ["svarah-partial", "monsoon-en-in", "librispeech-clean", "fleurs-en"]
have = set()
for p in glob.glob(ROOT + "/runs/*/run.json"):
    try: have.add(json.load(open(p))["name"])
    except Exception: pass
for run, sets in R["results"].items():
    name = f"bench-{run}"
    if name in have: continue
    with Run(name, kind="eval", tags=["bench", "mac"], config={"summary_only": True, "meta": R["meta"].get(run)},
             notes="Mac benchmark summary (hypotheses in bench-mac/hyp); Devanagari romanized with romanize_v2") as t:
        for s, v in sets.items():
            cat = "en" if s in EN else "hinglish"
            tm = R["timing"].get(run, {}).get(s)
            ms = round(1000 * tm["decode_s"] / v["n"], 1) if tm else None
            t.log_eval(0, s, {"ALL": {"wer": v["wer"], "strict_wer": v["raw_wer_strict"], "cer": v["cer"], "words": v["words"]}}, [], decode_ms=ms)
            t.note(f"{s}: WER {v['wer']}% CER {v['cer']}%")
