import json,random,os
from uiui_root import ROOT, SPEECH
R=ROOT+"/evalsets"
SETS=["svarah-partial","monsoon-en-in","librispeech-clean","fleurs-en","mucs-hien-test","hiacc","fleurs-hi"]
for s in SETS:
    rows=[json.loads(l) for l in open(f"{R}/{s}/manifest.jsonl") if l.strip()]
    rows.sort(key=lambda r:r["id"])
    random.Random(20261027).shuffle(rows)
    sub=sorted(rows[:150],key=lambda r:r["id"])
    open(f"{ROOT}/bench/subsets/{s}.jsonl","w").write("".join(json.dumps(r,ensure_ascii=False)+"\n" for r in sub))
    print(s,len(sub))
