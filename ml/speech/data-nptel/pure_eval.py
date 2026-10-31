import json
from uiui_root import ROOT, SPEECH
rows=[]
for l in open(ROOT+"/data-nptel/pure_phonon.jsonl"):
    r=json.loads(l); rows.append(r)
cand={json.loads(l)["id"]:json.loads(l) for l in open(ROOT+"/data-nptel/pure_cand.jsonl")}
n=0
with open(ROOT+"/data/manifests/nptel2020/pure_eval.jsonl","w") as f:
    for r in rows:
        if not r["gold"].strip() or not r["reference"].strip(): continue
        c=cand[r["id"]]; n+=1
        f.write(json.dumps(dict(id=r["id"],audio=c["audio"],reference=r["reference"],reference_raw=r["gold"],cat="en",speaker="unknown",source="nptel2020-pure",lang="en",seconds=c["seconds"]),ensure_ascii=False)+"\n")
print("pure_eval rows",n,"dropped empty",len(rows)-n)
