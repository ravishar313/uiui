"""Stage B: cluster ECAPA embeddings into pseudo-speakers, cap/select, split, move audio, write manifests. Run with sv python."""
import json, os, sys, random, numpy as np, collections, shutil
from uiui_root import ROOT, SPEECH
from sklearn.cluster import MiniBatchKMeans
W=ROOT+"/data-nptel/"; A=ROOT+"/data/audio/nptel2020/"; M=ROOT+"/data/manifests/nptel2020/"
K=int(os.environ.get("K",300)); CAP_H=1.0; TARGET_H=float(os.environ.get("TARGET_H",140))
rows=[json.loads(l) for l in open(W+"pass.jsonl")]; E=np.load(W+"pass_emb.npy"); assert len(E)==len(rows)
E=E/np.linalg.norm(E,axis=1,keepdims=True)
lab=MiniBatchKMeans(K,random_state=0,batch_size=4096,n_init=3).fit_predict(E)
rng=random.Random(0); by=collections.defaultdict(list)
for r,l in zip(rows,lab): r["speaker"]=f"nptel-spk{l:03d}"; by[r["speaker"]].append(r)
keep=[]
for s,rs in by.items():
    rng.shuffle(rs); t=0
    for r in rs:
        if t+r["seconds"]>CAP_H*3600: continue
        keep.append(r); t+=r["seconds"]
tot=sum(r["seconds"] for r in keep)/3600
if tot>TARGET_H:
    rng.shuffle(keep); acc=0; k2=[]
    for r in keep:
        if acc>=TARGET_H*3600: break
        k2.append(r); acc+=r["seconds"]
    keep=k2
tot=sum(r["seconds"] for r in keep)/3600
spk=sorted({r["speaker"] for r in keep}); rng.shuffle(spk)
dev_s=set(); dh=0
for s in spk:
    if dh>=0.02*tot: break
    dev_s.add(s); dh+=sum(r["seconds"] for r in keep if r["speaker"]==s)/3600
os.makedirs(M,exist_ok=True)
out={"train":[], "dev":[]}
for r in keep:
    sp="dev" if r["speaker"] in dev_s else "train"
    dst=f"{A}{sp}/{r[chr(105)+chr(100)][-12:-10]}/{r[chr(105)+chr(100)]}.wav"; os.makedirs(os.path.dirname(dst),exist_ok=True)
    shutil.move(r["audio"],dst)
    out[sp].append(dict(id=r["id"],audio=dst,reference=r["reference"],reference_raw=r["text"],speaker=r["speaker"],source="nptel2020",lang="en",seconds=r["seconds"],phonon_wer=r.get("phonon_wer")))
for sp,rs in out.items():
    with open(M+sp+".jsonl","w") as f:
        for r in rs: f.write(json.dumps(r,ensure_ascii=False)+"\n")
print({sp:(len(rs),round(sum(r["seconds"] for r in rs)/3600,2),len({r["speaker"] for r in rs})) for sp,rs in out.items()}, "total_h",round(tot,2))
