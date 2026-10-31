#!/usr/bin/env python3
"""Where does a step go?  python profile_step.py --config configs/bench_10s_gpu.yaml [--set mode=full] [--steps 20]
Reports mean ms per step for: data wait (DataLoader), forward encoder+decoder, joint gather, CPU lattice, backward, optimizer."""
import argparse, sys, time
from pathlib import Path
import torch, yaml
from uiui_root import load_yaml
sys.path.insert(0, str(Path(__file__).resolve().parent))
import modes, devutil, train as T_
from data import TrainData
from fast_tdt import fused_joint_gather, TDTLatticeLoss
from torch.nn.utils import parametrize

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--config", required=True); ap.add_argument("--set", action="append", default=[]); ap.add_argument("--steps", type=int, default=20)
    a = ap.parse_args(); cfg = load_yaml(a.config)
    for s in a.set: T_.deep_set(cfg, *s.split("=", 1))
    dev = devutil.pick_device()
    data = TrainData(cfg["data"], T_.BASE, 0); it = iter(data)
    model, proc, info = modes.build_model(cfg, None, dev); model.train()
    blank, vocab, durs = model.config.blank_token_id, model.config.vocab_size, list(model.config.durations)
    params = [p for p in model.parameters() if p.requires_grad]; opt = torch.optim.AdamW(params, lr=1e-6)
    acc = {k: 0.0 for k in ("data", "enc+dec fwd", "joint gather", "lattice (cpu)", "backward", "optimizer")}
    def tick(): devutil.synchronize(dev); return time.perf_counter()
    for i in range(a.steps + 3):
        t0 = tick(); b = next(it); t1 = tick()
        feats, am, labels, lab_len, dec_in = T_.make_batch(b, blank, dev)
        with torch.autocast(dev.type, dtype=torch.bfloat16), parametrize.cached():
            enc = model.get_audio_features(input_features=feats, attention_mask=am); dh = model.decoder(dec_in); t2 = tick()
            lb, ll, ld = fused_joint_gather(enc.pooler_output, dh, labels, model.joint.head, vocab, 0.02, cfg["train"].get("joint_chunk", 32)); t3 = tick()
            losses = TDTLatticeLoss.apply(lb, ll, ld, durs, enc.attention_mask.sum(-1), lab_len); t4 = tick()
            loss = losses.sum() / lab_len.sum()
        loss.backward(); t5 = tick(); opt.step(); opt.zero_grad(set_to_none=True); t6 = tick()
        if i >= 3:
            for k, v in zip(acc, (t1 - t0, t2 - t1, t3 - t2, t4 - t3, t5 - t4, t6 - t5)): acc[k] += v
    tot = sum(acc.values())
    for k, v in acc.items(): print(f"{k:14s} {1000 * v / a.steps:8.1f} ms  {100 * v / tot:5.1f}%")
    print(f"total {1000 * tot / a.steps:.1f} ms/step")


if __name__ == "__main__":
    main()
