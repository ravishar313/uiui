"""Stage A (run after filter): write pass.jsonl (filler-stripped WER<0.15, non-empty) then ECAPA-embed pass clips -> pass_emb.npy"""
import json, sys, subprocess
from uiui_root import ROOT, SPEECH
sys.path.insert(0,SPEECH+"/data-nptel"); sys.path.insert(0,SPEECH+"/eval/evalx")
import passrate as P
cand={}
for l in open("cand.jsonl"):
    r=json.loads(l); cand[r["id"]]=r
d=P.load(["cand_phonon.jsonl","cand_cpu*.jsonl"])
n=0
with open("pass.jsonl","w") as o:
    for i,r in d.items():
        w2=P.wer2(r["gold"],r["hyp"])
        if w2<0.15 and r["reference"].strip() and r["gold"].strip():
            c=cand[i]; n+=1
            o.write(json.dumps(dict(id=i,audio=c["audio"],text=c["text"],seconds=c["seconds"],wer=r["wer"],wer_nofiller=round(w2,4),reference=r["reference"],hyp=r["hyp"]),ensure_ascii=False)+"\n")
print("decoded",len(d),"pass",n)
