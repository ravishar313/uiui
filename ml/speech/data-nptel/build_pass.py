"""Pick NPTEL clips whose subtitle agrees with Phonon (interior WER <= 0.2 after trimming <=2 unmatched edge words), write pass.jsonl."""
import json, re, difflib
from uiui_root import ROOT, SPEECH
W=ROOT+"/data-nptel/"
cand={}
for l in open(W+"cand.jsonl"):
    d=json.loads(l); cand[d["id"]]=d
def k(w): return re.sub(r"[^a-z0-9]","",w.lower())
n=0; h=0; trimmed=0
with open(W+"pass.jsonl","w") as o:
    for f in ["cand_cpu0.jsonl","cand_cpu1.jsonl","cand_phonon.jsonl","cand_gpu.jsonl"]:
        for l in open(W+f):
            try: r=json.loads(l)
            except Exception: continue
            ref=r.get("reference") or ""; hyp=r.get("hyp") or ""
            rw=ref.split(); hk=[k(w) for w in hyp.split() if k(w)]
            rk=[k(w) for w in rw]
            if not rw or not hk: continue
            sm=difflib.SequenceMatcher(None,hk,rk,autojunk=False); bl=[b for b in sm.get_matching_blocks() if b.size]
            if not bl: continue
            s=bl[0].b; e=bl[-1].b+bl[-1].size
            lead=s if bl[0].a==0 else 0; tail=(len(rk)-e) if bl[-1].a+bl[-1].size==len(hk) else 0
            if lead>2 or tail>2: continue
            words=rw[lead:len(rw)-tail]
            core=[x for x in rk[lead:len(rk)-tail]]
            sm2=difflib.SequenceMatcher(None,hk,core,autojunk=False)
            err=sum(max(a1-a0,b1-b0) for op,a0,a1,b0,b1 in sm2.get_opcodes() if op!="equal")
            wer=err/max(len(core),1)
            if wer>0.2 or len(words)<3: continue
            c=cand[r["id"]]; text=" ".join(words)
            if text and text[0].islower(): text=text[0].upper()+text[1:]
            trimmed+= (lead+tail)>0
            o.write(json.dumps(dict(id=r["id"],audio=c["audio"],text=c["text"],reference=text,seconds=c["seconds"],phonon_wer=round(wer,4)),ensure_ascii=False)+"\n"); n+=1; h+=c["seconds"]
print("pass",n,"hours",round(h/3600,1),"edge-trimmed",trimmed)
