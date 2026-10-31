"""python lm/compare_hyps.py dirA dirB  -> per set: number of clips whose hypothesis text differs."""
import json, sys
from pathlib import Path
a, b = Path(sys.argv[1]), Path(sys.argv[2])
for f in sorted(a.glob("*.jsonl")):
    if not (b / f.name).exists(): continue
    A = {r["id"]: r for r in map(json.loads, f.read_text().splitlines())}
    B = {r["id"]: r for r in map(json.loads, (b / f.name).read_text().splitlines())}
    d = [i for i in A if A[i]["hypothesis"] != B[i]["hypothesis"]]
    print(f"{f.stem:18} {len(A)} clips, {len(d)} hypotheses differ", d[:5])
