#!/usr/bin/env python3
"""CPU smoke + cost benchmark for waveform augmentation.  NEVER touches a GPU.
   CUDA_VISIBLE_DEVICES= python3 smoke_augment.py [--code DIR_WITH_train] [--batches 50] [--workers 4]
1. per-clip CPU cost of augment.Augmenter (single thread, in-process) per stage and for the full config, on real training clips
2. data pipeline (real HF mel extractor + SpecAugment + tokenise, DataLoader workers) for N batches with augmentation off vs on: batches/s, clips/s
3. five augmented wavs (+ originals) to $UIUI_ML_ROOT/data/aug/samples/"""
import argparse, json, os, sys, time
from pathlib import Path
UML = Path(os.environ.get("UIUI_ML_ROOT") or "workspace").resolve()
import numpy as np
import soundfile as sf

assert os.environ.get("CUDA_VISIBLE_DEVICES") == "", "run with CUDA_VISIBLE_DEVICES= (CPU only)"
ap = argparse.ArgumentParser(); ap.add_argument("--code", default=str(UML / "ar/code")); ap.add_argument("--batches", type=int, default=50)
ap.add_argument("--workers", type=int, default=4); ap.add_argument("--clips", type=int, default=300)
a = ap.parse_args()
sys.path.insert(0, str(Path(a.code) / "train"))
import torch
torch.set_num_threads(1)
import augment as A, data as D

def main():

    HOME = UML; AUG = HOME / "data/aug"; BASE = HOME / "trainability/hf/parakeet"
    FULL = {"prob": 0.5, "noise": {"prob": 0.6, "snr_db": [5, 25], "babble_prob": 0.3}, "rir": {"prob": 0.3}, "speed": {"prob": 0.3, "factors": [0.9, 1.1]},
            "gain_db": [-6, 6], "seed": 0, "noise_list": str(AUG / "noise.jsonl"), "babble_list": str(AUG / "babble.jsonl"), "rir_list": str(AUG / "rir.jsonl")}
    SRC = [("indicvoices", 0.3), ("cvindia_full", 0.4), ("librispeech", 0.3)]
    cfg_data = {"sources": [{"name": n, "manifest": str(HOME / f"data/manifests/{n}/train.jsonl"), "weight": w, "max_clips": 3000} for n, w in SRC],
                "batch_size": 6, "max_secs": 15.0, "num_workers": a.workers, "text_norm": "none", "specaugment": {"enabled": True}}

    # ---- 1. per-clip cost -------------------------------------------------------------------------------------------------
    items, _ = D.load_manifest(cfg_data["sources"][1]["manifest"], 15.0, None, lambda *x: None)
    items = items[:a.clips]
    waves = [D.read_wave(i["audio"]) for i in items]
    print(f"cost clips: {len(waves)}  mean {np.mean([len(w) for w in waves]) / 16000:.2f}s")
    def bench(name, cfg):
        g = A.Augmenter(cfg, 15.0)
        for k, w in enumerate(waves[:20]): g(w, (0, k))                  # warm file cache / RIR cache
        t = time.perf_counter()
        for r in range(3):
            for k, w in enumerate(waves): g(w, (r + 1, k))
        ms = (time.perf_counter() - t) / (3 * len(waves)) * 1000
        print(f"  {name:34s} {ms:7.2f} ms/clip", flush=True); return ms
    base = {"prob": 1.0, "seed": 0, **{k: FULL[k] for k in ("noise_list", "babble_list", "rir_list")}}
    bench("noise only (always, 30% babble)", {**base, "noise": {"prob": 1, "snr_db": [5, 25], "babble_prob": 0.3}})
    bench("babble only (always)", {**base, "noise": {"prob": 1, "snr_db": [5, 25], "babble_prob": 1.0}})
    bench("plain noise only (always)", {**base, "noise": {"prob": 1, "snr_db": [5, 25], "babble_prob": 0.0}})
    bench("rir only (always)", {**base, "rir": {"prob": 1}})
    bench("speed only (always, 0.9/1.1)", {**base, "speed": {"prob": 1, "factors": [0.9, 1.1]}})
    bench("gain only", {**base, "gain_db": [-6, 6]})
    full = bench("FULL config (prob 0.5 chain)", FULL)

    # ---- 3. samples ---------------------------------------------------------------------------------------------------------
    S = AUG / "samples"; S.mkdir(parents=True, exist_ok=True)
    kinds = [("noise_snr10", {"noise": {"prob": 1, "snr_db": [10, 10], "babble_prob": 0}}), ("babble_snr10", {"noise": {"prob": 1, "snr_db": [10, 10], "babble_prob": 1.0}}),
             ("reverb", {"rir": {"prob": 1}}), ("speed0.9", {"speed": {"prob": 1, "factors": [0.9]}}),
             ("all_noise_rir_speed_gain", {"noise": {"prob": 1, "snr_db": [8, 8], "babble_prob": 0.3}, "rir": {"prob": 1}, "speed": {"prob": 1, "factors": [1.1]}, "gain_db": [-6, -6]})]
    for n, (kind, over) in enumerate(kinds):
        w = waves[n * 7]; g = A.Augmenter({**base, **over, "seed": 5}, 15.0); o = g(w, (99, n))
        sf.write(S / f"{n + 1}_{kind}.wav", o, 16000, subtype="PCM_16"); sf.write(S / f"{n + 1}_{kind}_ORIGINAL.wav", w, 16000, subtype="PCM_16")
        print(f"  sample {n + 1}_{kind}.wav  {len(w) / 16000:.2f}s -> {len(o) / 16000:.2f}s  peak {np.abs(o).max():.3f}")

    # ---- 2. pipeline throughput ---------------------------------------------------------------------------------------------
    def pipeline(label, aug):
        d = {**cfg_data, **({"augment": aug} if aug else {})}
        td = D.TrainData(d, str(BASE), seed=1, log=lambda *x: None)
        it = iter(td); next(it); t = time.perf_counter(); secs = 0; n = 0; T = 0
        for _ in range(a.batches):
            b = next(it); secs += b["secs"]; n += len(b["idxs"]); T += b["feats"].shape[1]
        dt = time.perf_counter() - t
        print(f"  {label:8s} {a.batches / dt:6.2f} batches/s  {n / dt:7.1f} clips/s  {secs / dt:7.1f} audio-s/s  mean padded frames/batch {T / a.batches:.0f}", flush=True)
        return a.batches / dt
    print(f"pipeline: {a.batches} batches x 6, {a.workers} workers (spawn), CPU only")
    off = pipeline("off", None); on = pipeline("on", FULL)
    print(f"RESULT per-clip full-config {full:.2f} ms; pipeline on/off = {on / off:.2f}x")



if __name__ == "__main__": main()
