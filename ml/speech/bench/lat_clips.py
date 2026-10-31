import json, soundfile as sf, random
from uiui_root import ROOT, SPEECH
random.seed(1)
B=ROOT+"/bench"
rows=[]
for s in ["svarah-partial","monsoon-en-in","librispeech-clean","fleurs-en"]:
    for l in open(f"{B}/subsets/{s}.jsonl"):
        r=json.loads(l); r["set"]=s; r["dur"]=sf.info(r["audio"]).duration; rows.append(r)
bk={"3s":(2.5,3.5),"8s":(7,9),"15s":(13,16)}
out={}
for k,(lo,hi) in bk.items():
    c=[r for r in rows if lo<=r["dur"]<=hi]; random.shuffle(c); out[k]=c[:30]
    print(k,len(c),{s:sum(1 for r in c[:30] if r["set"]==s) for s in set(r["set"] for r in c)})
json.dump(out,open(f"{B}/latency_clips.json","w"))
