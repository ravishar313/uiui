"""Independent leakage check of the LM training text: decode each LM training sentence back to text and look it up (normalised) among
every dev / eval reference; also report 6-gram token coverage of each eval set by the LM text (diagnostic, natural phrase overlap is expected).
python lm/leak_check.py --root $UIUI_ML_ROOT --ids lmdata/train_ids.txt"""
import argparse, json, os, sys
from pathlib import Path
from uiui_root import ROOT
sys.path.insert(0, str(Path(__file__).resolve().parent))
from prepare_text import eval_keys, key, REF_KEYS
ap = argparse.ArgumentParser(); ap.add_argument("--root", default=ROOT); ap.add_argument("--ids", required=True)
a = ap.parse_args(); root = Path(a.root)
from transformers import AutoProcessor
tok = AutoProcessor.from_pretrained(str(root / "trainability/hf/parakeet")).tokenizer
ev, _ = eval_keys(root)
sents = [list(map(int, l.split())) for l in open(a.ids)]
hit = 0; lm_keys = set()
for i in range(0, len(sents), 20000):
    for t in tok.batch_decode(sents[i:i + 20000], skip_special_tokens=False, group_tokens=False):
        k = key(t); lm_keys.add(k)
        if k in ev: hit += 1
print(f"LM sentences {len(sents)}; eval/dev reference keys {len(ev)}; LM sentences whose decoded text equals a dev/eval reference: {hit}")
N = 6
grams = set()
for s in sents:
    for j in range(len(s) - N + 1): grams.add(tuple(s[j:j + N]))
sets = {"dev-mix": root / "data/manifests/dev-mix.jsonl", "hiacc": root / "data/evalsets-lexicon/hiacc/manifest.jsonl",
        "mucs": root / "data/evalsets-lexicon/mucs-hien-test/manifest.jsonl", "fleurs-hi": root / "data/evalsets-lexicon/fleurs-hi/manifest.jsonl",
        "svarah-partial": root / "evalsets/svarah-partial/manifest.jsonl", "monsoon-en-in": root / "evalsets/monsoon-en-in/manifest.jsonl",
        "librispeech-clean": root / "evalsets/librispeech-clean/manifest.jsonl"}
for n, p in sets.items():
    refs = [json.loads(l).get("reference", "") for l in open(p) if l.strip()]
    print(f"{n:18} exact-sentence overlap with LM text: {sum(key(r) in lm_keys for r in refs)} of {len(refs)} refs")
    ids = tok(refs, add_special_tokens=False)["input_ids"]
    tot = seen = full = 0
    for s in ids:
        g = [tuple(s[j:j + N]) for j in range(len(s) - N + 1)]
        tot += len(g); c = sum(x in grams for x in g); seen += c; full += (len(g) > 0 and c == len(g))
    print(f"{n:18} {len(refs)} refs; {N}-gram coverage by LM text {100 * seen / max(tot, 1):.1f}%; refs fully covered {full}")
