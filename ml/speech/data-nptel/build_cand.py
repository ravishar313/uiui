import pyarrow.feather as f, json, os, re
from uiui_root import ROOT, SPEECH
t=f.read_table(ROOT+"/data-nptel/man/opus/manifest_link.feather").to_pydict()
pure={json.loads(l)["text"] for l in open(ROOT+"/data-nptel/pure_cand.jsonl")}
idx={os.path.basename(l.strip()):l.strip() for l in open(ROOT+"/data-nptel/wavlist.txt")}
n=miss=dup=short=0; secs=0
with open(ROOT+"/data-nptel/cand.jsonl","w") as o:
    for lp,txt,d,old in zip(t["local_path"],t["txt"],t["duration"],t["old_name"]):
        p=idx.get(os.path.basename(old))
        if p is None: miss+=1; continue
        sz=os.path.getsize(p)
        if abs((sz-44)/32000-d)>0.3: short+=1; continue   # truncated/corrupt tail file
        if txt in pure: dup+=1; continue
        if not 1<=d<=15 or not txt.strip(): continue
        n+=1; secs+=d
        o.write(json.dumps(dict(id="nptel2020-"+os.path.basename(lp)[:-5],audio=p,text=txt,seconds=d),ensure_ascii=False)+"\n")
print("miss",miss);print("cand",n,"hours",secs/3600,"dup_with_pure",dup,"size_mismatch",short)
