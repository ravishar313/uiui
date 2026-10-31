import json, glob, sys
from uiui_root import ROOT, SPEECH
sys.path.insert(0,SPEECH+"/eval/evalx"); import score
F={"uh","um","uhm","umm","hmm","mm","mhm","er","erm","ah","uh-huh"}
def wer2(g,h):
    gt=score.fair_tokens(g,False); ht=[t for t in score.fair_tokens(h,False) if t not in F]
    return score.edits(gt,ht)/max(1,len(gt))
def load(pats):
    d={}
    for p in pats:
        for f in glob.glob(p):
            for l in open(f):
                try: r=json.loads(l)
                except Exception: continue
                d[r["id"]]=r
    return d
if __name__=="__main__":
    secs={json.loads(l)["id"]:json.loads(l)["seconds"] for l in open("cand.jsonl")}
    d=load(["cand_phonon.jsonl","cand_cpu*.jsonl"])
    n=len(d); h=sum(secs[i] for i in d)/3600
    s=[r for r in d.values() if r["wer"]<0.15]; f=[r for r in d.values() if wer2(r["gold"],r["hyp"])<0.15]
    print("decoded",n,"hours",round(h,1),"strict pass",len(s)/n,round(sum(secs[r["id"]] for r in s)/3600,1),"h; filler-stripped pass",len(f)/n,round(sum(secs[r["id"]] for r in f)/3600,1),"h")
