#!/usr/bin/env python
"""Run one HF ASR model over the fixed 150-clip subsets. Usage: run_hf.py KEY MODE [sets...]
KEY: parakeet|w3|w3turbo|prime|swift|qwen06|qwen17 ; MODE: auto|en  (language handling; parakeet ignores)
Writes hyp/<KEY>-<MODE>.<set>.jsonl (hypothesis_raw = model output as is) -- resumable."""
import sys, os, json, time
from uiui_root import ROOT, SPEECH
os.environ.setdefault("HF_HOME", ROOT + "/bench/hf")
sys.path[:0] = [SPEECH + "/lab", SPEECH + "/eval/evalx", SPEECH + "/data"]
import re
from tracker import Run
from fair_wer import twer
from romanize_v2 import romanize_v2
DEVA = re.compile(r"[\u0900-\u097F]")
import numpy as np, torch, soundfile as sf, librosa
B = ROOT + "/bench"
SETS = ["svarah-partial", "monsoon-en-in", "librispeech-clean", "fleurs-en", "mucs-hien-test", "hiacc", "fleurs-hi"]
REPO = {"parakeet": "nvidia/parakeet-tdt-0.6b-v3", "w3": "openai/whisper-large-v3", "w3turbo": "openai/whisper-large-v3-turbo",
        "prime": "Oriserve/Whisper-Hindi2Hinglish-Prime", "swift": "Oriserve/Whisper-Hindi2Hinglish-Swift",
        "qwen06": "Qwen/Qwen3-ASR-0.6B-hf", "qwen17": "Qwen/Qwen3-ASR-1.7B-hf"}
key, mode = sys.argv[1], sys.argv[2]
sets = sys.argv[3:] or SETS
dev = "mps" if torch.backends.mps.is_available() else "cpu"
dt = torch.float16 if dev == "mps" and key != "parakeet" else torch.float32
BS = int(os.environ.get("BS", "8"))

def load(p):
    a, sr = sf.read(p, dtype="float32")
    if a.ndim > 1: a = a.mean(1)
    if sr != 16000: a = librosa.resample(a, orig_sr=sr, target_sr=16000)
    return a

t0 = time.time()
if key.startswith("w") or key in ("prime", "swift"):
    from transformers import WhisperForConditionalGeneration, WhisperProcessor
    proc = WhisperProcessor.from_pretrained(REPO[key])
    model = WhisperForConditionalGeneration.from_pretrained(REPO[key], torch_dtype=dt).to(dev).eval()
    def run(auds):
        f = proc.feature_extractor(auds, sampling_rate=16000, return_tensors="pt").input_features.to(dev, dt)
        kw = dict(task="transcribe", num_beams=1, do_sample=False, max_new_tokens=220)
        if mode == "en": kw["language"] = "en"
        with torch.no_grad(): ids = model.generate(f, **kw)
        return proc.batch_decode(ids, skip_special_tokens=True)
elif key == "parakeet":
    from transformers import AutoModelForTDT, AutoProcessor
    proc = AutoProcessor.from_pretrained(REPO[key])
    model = AutoModelForTDT.from_pretrained(REPO[key], torch_dtype=dt).to(dev).eval()
    def run(auds):
        inp = proc(auds, sampling_rate=16000, return_tensors="pt").to(dev)
        with torch.no_grad(): out = model.generate(**inp)
        seq = out.sequences if hasattr(out, "sequences") else out
        return proc.batch_decode(seq, skip_special_tokens=True)
else:
    from transformers import Qwen3ASRForConditionalGeneration, AutoProcessor
    proc = AutoProcessor.from_pretrained(REPO[key])
    model = Qwen3ASRForConditionalGeneration.from_pretrained(REPO[key], torch_dtype=dt).to(dev).eval()
    def run(auds):
        inp = proc.apply_transcription_request(auds, language="English" if mode == "en" else None).to(dev, dt)
        with torch.no_grad(): out = model.generate(**inp, max_new_tokens=256, do_sample=False)
        out = out[:, inp["input_ids"].shape[1]:]
        return proc.decode(out, return_format="transcription_only")
print("loaded", key, mode, dev, dt, f"{time.time()-t0:.1f}s", flush=True)
nparams = sum(p.numel() for p in model.parameters())
trk = Run(f"bench-{key}-{mode}", kind="eval", tags=["bench", "mac"], config={"repo": REPO[key], "mode": mode, "device": dev, "dtype": str(dt), "batch": BS, "clips_per_set": 150},
          notes="Mac benchmark vs shipped Phonon; Devanagari output romanized with romanize_v2 before scoring")
try:
    for s in sets:
        outp = f"{B}/hyp/{key}-{mode}.{s}.jsonl"
        if os.path.exists(outp): print("skip", outp); continue
        rows = [json.loads(l) for l in open(f"{B}/subsets/{s}.jsonl")]
        auds = [load(r["audio"]) for r in rows]
        order = sorted(range(len(rows)), key=lambda i: len(auds[i]))
        hyp = [None] * len(rows); wall_total = 0.0
        for i in range(0, len(order), BS):
            idx = order[i:i + BS]
            t = time.time()
            res = run([auds[j] for j in idx])
            if dev == "mps": torch.mps.synchronize()
            wall_total += time.time() - t
            for j, h in zip(idx, res): hyp[j] = h
        aud_s = sum(len(a) for a in auds) / 16000
        with open(outp, "w") as f:
            for r, h in zip(rows, hyp):
                r = dict(r); r["hypothesis_raw"] = h.strip(); f.write(json.dumps(r, ensure_ascii=False) + "\n")
        print(json.dumps({"model": key, "mode": mode, "set": s, "audio_s": round(aud_s, 1), "decode_s": round(wall_total, 1),
                          "rtfx": round(aud_s / wall_total, 2), "batch": BS, "params": nparams}), flush=True)
        rr = [{"id": r["id"], "cat": r["cat"], "reference": r["reference"],
               "hypothesis": romanize_v2(h, style="eval") if DEVA.search(h) else h} for r, h in zip(rows, hyp)]
        m, smp = twer(rr)
        trk.log_eval(0, s, {c: {"wer": v["raw_wer"] if c == "en" or s in SETS[:4] else v["twer"], "strict_wer": v["raw_wer"], "cer": v["cer"], "words": v["words"]} for c, v in m.items()},
                     smp[:50], decode_ms=round(1000 * wall_total / len(rows), 1))
        trk.note(f"{s}: {aud_s:.0f}s audio, {wall_total:.1f}s decode, WER {m['ALL']['raw_wer'] if s in SETS[:4] else m['ALL']['twer']}%")
        with open(f"{B}/hyp/timing.jsonl", "a") as f:
            f.write(json.dumps({"model": key, "mode": mode, "set": s, "audio_s": round(aud_s, 1), "decode_s": round(wall_total, 1), "batch": BS, "params": nparams}) + "\n")
except BaseException as e:
    trk.fail(repr(e)); raise
else:
    trk.finish()
