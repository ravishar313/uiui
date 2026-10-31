"""Re-romanize the Hinglish eval sets with the SAME lexicon -> data/evalsets-lexicon/<set>/manifest.jsonl (evalsets/ untouched)."""
import json, os, sys
sys.path.insert(0, os.path.dirname(__file__))
import romlib
from common import DATA
EV = DATA.parent / "evalsets"
for s in ["mucs-hien-test", "hiacc", "fleurs-hi"]:
    src = {}
    for l in open(EV / s / "source_references.jsonl"):
        r = json.loads(l); src[r["id"]] = r["source"]
    out = DATA / "evalsets-lexicon" / s
    out.mkdir(parents=True, exist_ok=True)
    n = ch = 0
    with open(out / "manifest.jsonl", "w") as f:
        for l in open(EV / s / "manifest.jsonl"):
            r = json.loads(l)
            old = r["reference"]
            raw = src.get(r["id"])
            r["reference_hybrid"] = old
            if raw is not None:
                r["reference"] = romlib.roman(raw, "eval")
                r["reference_raw"] = raw
            n += 1; ch += r["reference"] != old
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(s, n, "rows;", ch, "references differ from hybrid;", "missing source:", n - len(src))
print("OOV words (not in lexicon):", len(romlib.OOV))
