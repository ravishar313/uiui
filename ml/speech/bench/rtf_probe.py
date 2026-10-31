import os, sys, json, time, subprocess
from uiui_root import ROOT, SPEECH
os.environ["HF_HOME"] = ROOT + "/bench/hf"
B = ROOT + "/bench"
import soundfile as sf
rows = [json.loads(l) for l in open(f"{B}/subsets/monsoon-en-in.jsonl")][:20]
aud = sum(sf.info(r["audio"]).duration for r in rows)
# reuse run_hf internals via exec with BS=1 and patched paths would be heavy; instead time inline per model
import torch
sys.argv = ["x"]
out = {}
code = open(SPEECH + "/bench/run_hf.py").read()
head = code.split("print(\"loaded\"")[0]   # model loading + run() definition
for key, mode in [("parakeet","auto"),("w3turbo","en"),("swift","en"),("qwen06","auto"),("qwen17","auto"),("prime","en"),("w3","en")]:
    sys.argv = ["run_hf.py", key, mode]
    g = {"__name__": "probe"}
    exec(compile(head, "probe", "exec"), g)
    load, run = g["load"], g["run"]
    auds = [load(r["audio"]) for r in rows]
    run([auds[0]])                      # warm-up
    t = time.time()
    for a in auds: run([a])
    if torch.backends.mps.is_available(): torch.mps.synchronize()
    out[f"{key}-{mode}"] = round(aud / (time.time() - t), 1)
    print(key, mode, out[f"{key}-{mode}"], flush=True)
    g["trk"].finish() if "trk" in g else None
    del g; import gc; gc.collect(); torch.mps.empty_cache()
json.dump(out, open(f"{B}/rtf_probe.json", "w"), indent=1)
