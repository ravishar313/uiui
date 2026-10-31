"""ECAPA speaker embeddings (CPU, 20 threads) for candidate clips. python spk_embed.py cand.jsonl out.npy [limit]"""
import sys, json, numpy as np, torch, soundfile as sf, time, os
from uiui_root import ROOT, SPEECH
torch.set_num_threads(16)
sys.path.insert(0,SPEECH+"/lab")
from speechbrain.inference.speaker import EncoderClassifier
rows=[json.loads(l) for l in open(sys.argv[1])]
if len(sys.argv)>3: rows=rows[:int(sys.argv[3])]
clf=EncoderClassifier.from_hparams(source="speechbrain/spkrec-ecapa-voxceleb",savedir=ROOT+"/data-nptel/ecapa",run_opts={"device":"cuda:0"})
out=np.zeros((len(rows),192),np.float32); B=128; t0=time.time()
from concurrent.futures import ThreadPoolExecutor
def rd(r): return sf.read(r["audio"],dtype="float32",stop=16000*6)[0]
with ThreadPoolExecutor(8) as ex, torch.no_grad():
    for s in range(0,len(rows),B):
        ws=list(ex.map(rd,rows[s:s+B])); L=np.array([len(w) for w in ws]); M=L.max()
        x=torch.zeros(len(ws),M)
        for i,w in enumerate(ws): x[i,:len(w)]=torch.from_numpy(w)
        e=clf.encode_batch(x,torch.from_numpy(L/M).float()).squeeze(1); out[s:s+len(ws)]=e.cpu().numpy()
        if (s//B)%50==0: print(s,len(rows),round((s+B)/(time.time()-t0),1),"clips/s",flush=True)
np.save(sys.argv[2],out)
