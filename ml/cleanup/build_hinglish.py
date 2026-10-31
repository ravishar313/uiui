"""Build data/hinglish/{train,eval}_hinglish.jsonl from the hand-written txt files + natural_train hinglish lines."""
import json, glob, sys
from pathlib import Path
D = Path(__file__).parent / "data/hinglish"
def rd(p): return [l.strip() for l in open(p) if l.strip()]
tr = []
for p in sorted(glob.glob(str(D / "train_hand_*.txt"))): tr += rd(p)
ev = rd(D / "eval_hand.txt")
norm = lambda s: " ".join(s.lower().split())
evs = {norm(s) for s in ev}
nat = [json.loads(l) for l in open(Path(__file__).parent / "data/natural/natural_train.jsonl")]
nat_h = [r["text"] for r in nat if r.get("mix") == "hinglish"]
seen, out_tr = set(), []
for s in tr:
    k = norm(s)
    if k in evs or k in seen: continue
    seen.add(k); out_tr.append(s)
ev_out, seen2 = [], set()
for s in ev:
    k = norm(s)
    if k in seen or k in seen2: continue
    seen2.add(k); ev_out.append(s)
print("hand train", len(out_tr), "eval", len(ev_out), "natural hinglish", len(nat_h), "dropped train dup/overlap", len(tr)-len(out_tr))
with open(D / "train_hinglish.jsonl", "w") as f:
    for i, s in enumerate(out_tr): f.write(json.dumps({"id": f"hh-{i:05d}", "text": s, "mix": "hinglish", "source": "hand"}, ensure_ascii=False) + "\n")
with open(D / "eval_hinglish.jsonl", "w") as f:
    for i, s in enumerate(ev_out): f.write(json.dumps({"id": f"hev-{i:05d}", "text": s, "mix": "hinglish", "source": "hand_eval"}, ensure_ascii=False) + "\n")
