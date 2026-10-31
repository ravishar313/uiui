"""Write manifests/pilot.yaml, manifests/samples_50.txt and manifests/stats.json from the final manifests."""
import json, random, glob, os, sys, yaml
sys.path.insert(0, os.path.dirname(__file__))
from common import DATA
M = DATA / "manifests"
LIC = {
    "indicvoices": "CC-BY-4.0 (AI4Bharat IndicVoices; HF gated, terms accepted)",
    "mucs": "OpenSLR 104 lists CC-BY-SA-4.0 (share-alike); the HF mirror dianavdavidson/MUCS-Hinglish labels it cc-by-4.0. Treat as share-alike. Excludable via source=mucs",
    "kathbath": "CC-BY-4.0 (AI4Bharat Kathbath, HF gated, terms accepted)",
    "shrutilipi": "CC-BY-4.0 (AI4Bharat Shrutilipi, HF gated, terms accepted); All India Radio news audio",
    "librispeech": "CC-BY-4.0 (LibriSpeech train-clean-100, openslr/librispeech_asr)",
    "cvindia": "CC0-1.0 (Mozilla Common Voice English, Indian-accent subset via WillHeld/india_accent_cv)",
    "nptel": "NPTEL lectures (CC BY-SA on YouTube per NPTEL); HF mirror skbose/indian-english-nptel-v0 states no license. Treat as share-alike / verify before commercial use",
}
GROUP = {"indicvoices": "hinglish", "mucs": "hinglish", "kathbath": "hinglish", "shrutilipi": "hinglish",
         "cvindia": "indian_english", "nptel": "indian_english", "librispeech": "rehearsal_english"}
# target share of training mix per group, split inside a group proportionally to hours
SHARE = {"hinglish": 0.55, "indian_english": 0.30, "rehearsal_english": 0.15}
stats, rnd = {}, random.Random(11)
lines = []
for s in GROUP:
    sm = M / s / "summary.json"
    if not sm.exists(): continue
    stats[s] = json.load(open(sm))
    rows = [json.loads(l) for l in open(M / s / "train.jsonl")]
    lines.append(f"\n=== {s} ({len(rows)} train rows) ===")
    for r in rnd.sample(rows, min(50, len(rows))):
        lines.append(f"[{r['id']} {r['seconds']:.1f}s] {r['reference']}" + (f"\n      raw: {r['reference_raw']}" if r["lang"] == "hinglish" else ""))
open(M / "samples_50.txt", "w").write("\n".join(lines))
json.dump(stats, open(M / "stats.json", "w"), indent=1)
OPTIONAL = {"nptel"}  # license undecided: tagged, kept out of default mix
ghours = {g: sum(stats[s]["train"]["hours"] for s in stats if GROUP[s] == g and s not in OPTIONAL) for g in SHARE}
src = []
for s, st in stats.items():
    g = GROUP[s]
    w = 0.0 if s in OPTIONAL else SHARE[g] * st["train"]["hours"] / ghours[g]
    src.append(dict(name=s, group=g, lang="hinglish" if g == "hinglish" else "en", train=f"data/manifests/{s}/train.jsonl",
                    dev=f"data/manifests/{s}/dev.jsonl", train_hours=st["train"]["hours"], dev_hours=st["dev"]["hours"],
                    weight=round(w, 4), license=LIC[s], default_enabled=(s not in OPTIONAL), exclude_flag=("share-alike: drop with source != mucs" if s == "mucs" else "NEEDS LICENSE DECISION (no stated license on HF mirror); weight 0 by default" if s == "nptel" else None)))
yaml.safe_dump(dict(description="Phonon-2 fine-tuning pilot mix. weights sum to 1; sample sources proportionally to weight, then rows uniformly within source.",
                    eval_only_do_not_train=["lahaja", "svarah", "monsoon", "evalsets/*"], sources=src),
               open(M / "pilot.yaml", "w"), sort_keys=False, allow_unicode=True)
tot = sum(st["train"]["hours"] for st in stats.values())
print("total train hours", round(tot, 1), {g: round(h, 1) for g, h in ghours.items()})
