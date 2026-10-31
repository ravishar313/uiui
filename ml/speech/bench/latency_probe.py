#!/usr/bin/env python
"""Batch-1 dictation latency: audio already in memory (16 kHz float32 numpy) -> final text, warm.
Usage: latency_probe.py BACKEND   (hf-qwen06-fp16 | hf-qwen06-bf16 | hf-w3turbo-fp16 | mlx-qwen06-bf16 | mlx-qwen06-4bit | mlx-w3turbo-fp16 | mlx-w3turbo-4bit)
Clips: latency_clips.json (30 per bucket ~3/8/15 s from local eval sets). Writes results/latency.<backend>.json."""
import sys, os, json, time, resource, statistics
from uiui_root import ROOT, SPEECH
os.environ["HF_HOME"] = ROOT + "/bench/hf"
sys.path[:0] = [SPEECH + "/lab"]
import numpy as np, soundfile as sf, librosa
B = ROOT + "/bench"
be = sys.argv[1]
clips = json.load(open(f"{B}/latency_clips.json"))
def load(p):
    a, sr = sf.read(p, dtype="float32")
    if a.ndim > 1: a = a.mean(1)
    return librosa.resample(a, orig_sr=sr, target_sr=16000) if sr != 16000 else a
aud = {k: [load(r["audio"]) for r in v] for k, v in clips.items()}
extra = {}
t0 = time.time()
if be.startswith("hf-"):
    import torch
    from transformers import AutoProcessor
    dt = torch.bfloat16 if "bf16" in be else torch.float16
    dev = "mps"
    if "qwen06" in be:
        from transformers import Qwen3ASRForConditionalGeneration
        proc = AutoProcessor.from_pretrained("Qwen/Qwen3-ASR-0.6B-hf")
        model = Qwen3ASRForConditionalGeneration.from_pretrained("Qwen/Qwen3-ASR-0.6B-hf", torch_dtype=dt).to(dev).eval()
        def run(a):
            inp = proc.apply_transcription_request([a], language="English").to(dev, dt)
            with torch.no_grad(): out = model.generate(**inp, max_new_tokens=256, do_sample=False)
            r = proc.decode(out[:, inp["input_ids"].shape[1]:], return_format="transcription_only")
            torch.mps.synchronize(); return r[0] if isinstance(r, list) else r
    else:
        from transformers import WhisperForConditionalGeneration
        proc = AutoProcessor.from_pretrained("openai/whisper-large-v3-turbo")
        model = WhisperForConditionalGeneration.from_pretrained("openai/whisper-large-v3-turbo", torch_dtype=dt).to(dev).eval()
        def run(a):
            f = proc.feature_extractor([a], sampling_rate=16000, return_tensors="pt").input_features.to(dev, dt)
            with torch.no_grad(): ids = model.generate(f, task="transcribe", language="en", num_beams=1, do_sample=False, max_new_tokens=220)
            r = proc.batch_decode(ids, skip_special_tokens=True)[0]; torch.mps.synchronize(); return r
    def fw_peak(): return torch.mps.driver_allocated_memory() / 2**20
elif be.startswith("mlx-qwen06"):
    import mlx.core as mx
    from mlx_audio.stt.utils import load
    repo = "mlx-community/Qwen3-ASR-0.6B-" + ("4bit" if "4bit" in be else "bf16")
    model = load(repo); extra["repo"] = repo
    def run(a):
        r = model.generate(mx.array(a), language="English", temperature=0.0, max_tokens=256)
        return r.text if hasattr(r, "text") else str(r)
    def fw_peak(): return mx.get_peak_memory() / 2**20
else:
    import mlx.core as mx, mlx_whisper
    repo = "mlx-community/whisper-large-v3-turbo" + ("-q4" if "4bit" in be else "")
    extra["repo"] = repo
    def run(a):
        return mlx_whisper.transcribe(a, path_or_hf_repo=repo, language="en", temperature=0.0, condition_on_previous_text=False,
                                      verbose=None, fp16=True, word_timestamps=False)["text"]
    def fw_peak(): return mx.get_peak_memory() / 2**20
print("loaded", be, f"{time.time()-t0:.1f}s", flush=True)
res = {}
for k, A in aud.items():
    for a in A[:3]: run(a)                        # warm-up (not timed)
    ts, texts = [], []
    for a in A:
        t = time.perf_counter(); txt = run(a); ts.append(1000 * (time.perf_counter() - t)); texts.append(txt.strip())
    s = sorted(ts)
    res[k] = {"median_ms": round(statistics.median(ts), 1), "p90_ms": round(s[int(0.9 * len(s)) - 1], 1) if False else round(float(np.percentile(ts, 90)), 1),
              "mean_dur_s": round(float(np.mean([len(a) / 16000 for a in A])), 2), "n": len(ts), "sample": texts[:2]}
    print(k, res[k], flush=True)
    res[k]["texts"] = texts
peak_rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 2**20   # bytes on macOS
out = {"backend": be, "load_s": round(time.time() - t0, 1), "peak_rss_mb": round(peak_rss, 0), "framework_peak_mb": round(fw_peak(), 0), "buckets": res, **extra}
os.makedirs(f"{B}/results", exist_ok=True)
json.dump(out, open(f"{B}/results/latency.{be}.json", "w"), indent=1, ensure_ascii=False)
print("peak_rss_mb", out["peak_rss_mb"], "framework_peak_mb", out["framework_peak_mb"])
