"""Greedy-decode candidate clips with the shipped Phonon-2 PyTorch model; write wer/hyp/reference per clip.
python phonon_filter.py cand.jsonl out.jsonl [--batch 16] [--min-free-gb 10] [--gpu 0]"""
import argparse, json, os, re, sys, time, difflib, subprocess
from uiui_root import ROOT, SPEECH
sys.path.insert(0, SPEECH+"/trainability/scripts"); sys.path.insert(0, SPEECH+"/eval/evalx"); sys.path.insert(0, SPEECH+"/lab")
ap = argparse.ArgumentParser(); ap.add_argument("cand"); ap.add_argument("out")
ap.add_argument("--batch", type=int, default=16); ap.add_argument("--min-free-gb", type=float, default=10); ap.add_argument("--gpu", type=int, default=-1); ap.add_argument("--cpu", action="store_true"); ap.add_argument("--threads", type=int, default=8); ap.add_argument("--shard", default="0/1")
a = ap.parse_args()
def free():
    r = subprocess.run(["nvidia-smi", "--query-gpu=memory.free", "--format=csv,noheader,nounits"], capture_output=True, text=True).stdout.split()
    return [int(x) / 1024 for x in r]
gpu = 0
if a.cpu: os.environ["CUDA_VISIBLE_DEVICES"] = ""
else: os.environ["CUDA_VISIBLE_DEVICES"] = "0"
import torch, soundfile as sf
from torch.nn.utils import parametrize
import train_probe as tp, score
from tracker import Run
NUM = score.NUMBER_WORDS
def key(w):
    t = score.base_tokens(w)
    return "".join(NUM.get(x, x) for x in t)
def fix_surface(w):
    core = re.sub(r"[^A-Za-z]", "", w)
    if len(core) > 4 and core.isupper(): w = w.lower()
    return w
def merge(gold, hyp):   # verbatim from speech/data/english_relabel.py
    hs = [(fix_surface(w), key(w)) for w in hyp.split()]
    hs = [(s, k) for s, k in hs if k]
    gw = [(w, key(w)) for w in gold.split()]
    gw = [(w, k) for w, k in gw if k]
    sm = difflib.SequenceMatcher(None, [k for _, k in hs], [k for _, k in gw], autojunk=False)
    out = []; P = ".,?!;:"
    for op, a0, a1, b0, b1 in sm.get_opcodes():
        if op == "equal": out += [s for s, _ in hs[a0:a1]]
        elif op in ("replace", "insert"):
            seg = [re.sub(r"[^\w\x27]", "", w.lower()) for w, _ in gw[b0:b1]]
            if op == "replace" and hs[a1 - 1][0][-1] in P: seg[-1] += hs[a1 - 1][0][-1]
            out += seg
        elif op == "delete":
            if out and hs[a1 - 1][0][-1] in P and out[-1][-1] not in P: out[-1] += hs[a1 - 1][0][-1]
    if not out: return ""
    r = " ".join(out); r = re.sub(r"[,;:]$", ".", r); r = re.sub(r"\bi\b", "I", r)
    return r[0].upper() + r[1:]
k, n_ = map(int, a.shard.split("/")); rows = [r for i, r in enumerate(map(json.loads, open(a.cand))) if i % n_ == k]
done = set()
if os.path.exists(a.out): done = {json.loads(l)["id"] for l in open(a.out)}
todo = sorted([r for r in rows if r["id"] not in done], key=lambda r: r["seconds"])
run = Run(f"nptel2020-phonon-filter-cpu{a.shard.replace(chr(47),chr(111))}", kind="data", total_steps=len(rows), tags=["data", "nptel2020"], notes=f"Phonon greedy-decode WER filter, gpu {gpu}", run_id=None)
torch.set_num_threads(a.threads); model, proc = tp.load(); model.to("cuda").eval()
t0 = time.time(); n = len(done); f = open(a.out, "a")
with torch.no_grad():
    for s in range(0, len(todo), a.batch):
        b = todo[s:s + a.batch]
        wavs = [sf.read(r["audio"], dtype="float32")[0] for r in b]
        inp = proc.feature_extractor(wavs, sampling_rate=16000, return_tensors="pt", padding=True, return_attention_mask=True)
        with parametrize.cached():
            out = model.generate(input_features=inp["input_features"].to("cuda"), attention_mask=inp["attention_mask"].to("cuda"))
        hyps = proc.batch_decode(getattr(out, "sequences", out), skip_special_tokens=True)
        for r, h in zip(b, hyps):
            h = h.strip(); g = r["text"]
            gt = score.fair_tokens(g, False)
            wer = score.edits(gt, score.fair_tokens(h, False)) / max(1, len(gt))
            f.write(json.dumps(dict(id=r["id"], wer=round(wer, 4), hyp=h, gold=g, reference=merge(g, h)), ensure_ascii=False) + "\n")
        f.flush(); n += len(b)
        run.log(n, rows_per_s=round((n - len(done)) / (time.time() - t0), 1))
run.note(f"{n} clips decoded"); run.finish()
