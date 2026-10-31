#!/usr/bin/env python3
"""Pseudo-label audio with openai/whisper-large-v3 (English forced, greedy).

Input manifest jsonl rows: id, audio, seconds[, reference]. Output jsonl rows:
  id, audio, seconds, whisper_text, avg_logprob, no_speech_prob, compression_ratio, duration, decode
[, reference passthrough] (reference is only carried for eval smoke tests).

Decoding modes (--mode):
  greedy    num_beams=1, temperature 0 (no sampling)
  guard     greedy + no_repeat_ngram_size (default 5) + mild repetition_penalty
  fallback  (default) greedy first; rows whose text looks degenerate (compression_ratio > --cr-fallback
            or a repeated n-gram) are re-decoded once with the guard; the better-scoring one is kept.
            `decode` records which path produced the text ("greedy" or "guard").

Resumable: ids already present in --out are skipped. Sharded: --shard k/n takes rows i where i % n == k
(after sorting by id, so shards are stable). Checkpoint: output file is appended + flushed every --ckpt rows.
Run:  python pl_whisper.py --manifest m.jsonl --out out.shard0.jsonl --shard 0/1 --batch 32
"""
import argparse, json, os, sys, time, zlib, re
import numpy as np

p = argparse.ArgumentParser()
p.add_argument("--manifest", required=True)
p.add_argument("--out", required=True)
p.add_argument("--model", default="openai/whisper-large-v3")
p.add_argument("--shard", default="0/1")
p.add_argument("--batch", type=int, default=16)
p.add_argument("--ckpt", type=int, default=200, help="flush/checkpoint every N rows")
p.add_argument("--mode", choices=["greedy", "guard", "fallback"], default="fallback")
p.add_argument("--device", default=None, help="cuda|mps|cpu (default: auto)")
p.add_argument("--dtype", default=None, help="fp16|fp32 (default fp16 on cuda/mps)")
p.add_argument("--no-repeat-ngram", type=int, default=5)
p.add_argument("--cr-fallback", type=float, default=2.0)
p.add_argument("--max-new-tokens", type=int, default=220)
p.add_argument("--limit", type=int, default=0, help="debug: only first N rows of the shard")
p.add_argument("--audio-root", default=None, help="prefix for relative audio paths (default: manifest dir)")
a = p.parse_args()

import torch, soundfile as sf
from transformers import WhisperForConditionalGeneration, WhisperProcessor

dev = a.device or ("cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu")
dt = {"fp16": torch.float16, "fp32": torch.float32}[a.dtype or ("fp16" if dev in ("cuda", "mps") else "fp32")]
k, n = map(int, a.shard.split("/"))
root = a.audio_root or os.path.dirname(os.path.abspath(a.manifest))

rows = [json.loads(l) for l in open(a.manifest) if l.strip()]
rows.sort(key=lambda r: r["id"])
rows = [r for i, r in enumerate(rows) if i % n == k]
done = set()
if os.path.exists(a.out):
    for l in open(a.out):
        try: done.add(json.loads(l)["id"])
        except Exception: pass   # truncated last line from a crash: row is redone
todo = [r for r in rows if r["id"] not in done]
if a.limit: todo = todo[:a.limit]
print(f"shard {k}/{n}: {len(rows)} rows, {len(done)} done, {len(todo)} todo, device={dev} dtype={dt}", flush=True)
if not todo: sys.exit(0)

proc = WhisperProcessor.from_pretrained(a.model)
model = WhisperForConditionalGeneration.from_pretrained(a.model, torch_dtype=dt).to(dev).eval()
tok = proc.tokenizer
sot = tok.convert_tokens_to_ids("<|startoftranscript|>")
nospeech = tok.convert_tokens_to_ids("<|nospeech|>")
if nospeech is None or nospeech == tok.unk_token_id:
    nospeech = tok.convert_tokens_to_ids("<|nocaptions|>")

def load(r):
    path = r["audio"] if os.path.isabs(r["audio"]) else os.path.join(root, r["audio"])
    x, sr = sf.read(path, dtype="float32")
    if x.ndim > 1: x = x.mean(1)
    if sr != 16000:
        import librosa
        x = librosa.resample(x, orig_sr=sr, target_sr=16000)
    return x

def comp_ratio(t):
    b = t.encode()
    return len(b) / max(1, len(zlib.compress(b))) if b else 0.0

def repeated_ngram(t, n=4, reps=3):
    w = re.sub(r"[^\w\s']", " ", t.lower()).split()
    for m in (1, 2, 3, 4):   # unit length m repeated; require >= reps*max(n/m,1)... simple: unit repeated `reps+1`x for 1-gram>=6
        need = 6 if m == 1 else 4 if m == 2 else 3
        for i in range(0, len(w) - m * need + 1):
            u = w[i:i + m]
            if all(w[i + j * m:i + (j + 1) * m] == u for j in range(need)): return True
    return False

@torch.no_grad()
def decode(auds, guard):
    """Returns texts, avg_logprob (teacher-forced over text tokens + EOT, like openai-whisper), no_speech_prob."""
    feats = proc.feature_extractor(auds, sampling_rate=16000, return_tensors="pt").input_features.to(dev, dt)
    kw = dict(language="en", task="transcribe", num_beams=1, do_sample=False, max_new_tokens=a.max_new_tokens, return_timestamps=False)
    if guard: kw.update(no_repeat_ngram_size=a.no_repeat_ngram, repetition_penalty=1.1)
    seqs = model.generate(feats, **kw)
    if not torch.is_tensor(seqs): seqs = seqs.sequences
    texts = [t.strip() for t in tok.batch_decode(seqs, skip_special_tokens=True)]
    # teacher-forced scoring (generate(output_scores) is broken for Whisper in transformers 5.21)
    enc = model.model.encoder(feats).last_hidden_state
    nsp = torch.softmax(model(encoder_outputs=(enc,), decoder_input_ids=torch.full((len(auds), 1), sot, device=dev)).logits[:, -1].float(), -1)[:, nospeech].cpu().tolist()
    # generate() returns text tokens only (no prompt/EOT), padded with EOT/pad: rebuild prompt + text + EOT
    gen = seqs.to(dev)
    prompt = torch.tensor([sot, tok.convert_tokens_to_ids("<|en|>"), tok.convert_tokens_to_ids("<|transcribe|>"),
                           tok.convert_tokens_to_ids("<|notimestamps|>")], device=dev)
    eot = tok.eos_token_id
    B = len(auds)
    full = torch.cat([prompt[None].expand(B, -1), gen, torch.full((B, 1), eot, device=dev)], 1)
    lg = model(encoder_outputs=(enc,), decoder_input_ids=full[:, :-1]).logits.float()
    lp = torch.log_softmax(lg, -1).gather(2, full[:, 1:, None])[:, :, 0][:, len(prompt) - 1:]   # text tokens + one EOT
    avg = []
    for b in range(B):
        g = gen[b]
        stop = (g >= eot).nonzero()                  # first EOT/pad/special in the generated part
        nt = stop[0, 0].item() if len(stop) else len(g)
        avg.append(float(lp[b, :nt + 1].mean()))     # nt text tokens + EOT (at index nt)
    return texts, avg, nsp

todo.sort(key=lambda r: r.get("seconds", 0))
fout = open(a.out, "a")
t0 = time.time(); nrow = 0; since = 0; audio_s = 0.0
for i in range(0, len(todo), a.batch):
    chunk = todo[i:i + a.batch]
    auds = [load(r) for r in chunk]
    auds = [x[:30 * 16000] for x in auds]            # whisper window is 30 s; manifests should be <= 30 s
    modes = "guard" if a.mode == "guard" else "greedy"
    texts, lps, nsp = decode(auds, modes == "guard")
    how = [modes] * len(chunk)
    if a.mode == "fallback":
        redo = [j for j, t in enumerate(texts) if comp_ratio(t) > a.cr_fallback or repeated_ngram(t)]
        if redo:
            t2, l2, _ = decode([auds[j] for j in redo], True)
            for j, tt, ll in zip(redo, t2, l2):
                if repeated_ngram(tt) <= repeated_ngram(texts[j]):   # guard output no worse on repetition
                    texts[j], lps[j], how[j] = tt, ll, "guard"
    for r, x, t, lp, ns, h in zip(chunk, auds, texts, lps, nsp, how):
        dur = len(x) / 16000
        o = {"id": r["id"], "audio": r["audio"], "seconds": r.get("seconds", round(dur, 3)), "whisper_text": t,
             "avg_logprob": round(lp, 4), "no_speech_prob": round(ns, 4), "compression_ratio": round(comp_ratio(t), 3),
             "duration": round(dur, 3), "decode": h}
        if "reference" in r: o["reference"] = r["reference"]
        fout.write(json.dumps(o, ensure_ascii=False) + "\n")
        audio_s += dur
    nrow += len(chunk); since += len(chunk)
    if since >= a.ckpt:
        fout.flush(); os.fsync(fout.fileno()); since = 0
        print(f"{nrow}/{len(todo)} rows, {audio_s/(time.time()-t0):.1f}x realtime", flush=True)
fout.flush(); os.fsync(fout.fileno()); fout.close()
print(f"done {nrow} rows, {audio_s:.0f}s audio in {time.time()-t0:.0f}s ({audio_s/(time.time()-t0):.1f}x realtime)", flush=True)
