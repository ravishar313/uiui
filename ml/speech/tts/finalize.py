import json,re,sys,collections
from uiui_root import ROOT
raw,out=sys.argv[1],sys.argv[2]
def norm(t): return re.sub(r"\s+"," ",re.sub(r"[^a-z0-9₹$ ]"," ",t.lower().replace("'",""))).strip()
ref=[]
for f in ["dev-sel","dev-hold","vibe"]:
    ref+=[norm(json.loads(l)["reference"]) for l in open(f"{ROOT}/ar/locked/{f}.jsonl")]
exact=set(ref); grams=set()
for r in ref:
    t=r.split()
    for i in range(len(t)-5): grams.add(tuple(t[i:i+6]))
rows=[json.loads(l) for l in open(raw)]
keep=[];ex=ov=0
for r in rows:
    n=norm(r["text"]); t=n.split()
    if n in exact: ex+=1; continue
    if any(tuple(t[i:i+6]) in grams for i in range(len(t)-5)): ov+=1; continue
    keep.append(r)
print("raw",len(rows),"dropped exact",ex,"dropped 6gram",ov,"kept",len(keep))
# recheck
bad=sum(1 for r in keep if norm(r["text"]) in exact or any(tuple(norm(r["text"]).split()[i:i+6]) in grams for i in range(len(norm(r["text"]).split())-5)))
print("residual leaks (exact or 6-gram) =",bad, "| eval refs checked:",len(ref))
for i,r in enumerate(keep):
    r["id"]=f"num-{i+1:06d}"
with open(out,"w") as f:
    for r in keep: f.write(json.dumps({k:r[k] for k in ("id","text","speak","mix","terms","ntype")},ensure_ascii=False)+"\n")
