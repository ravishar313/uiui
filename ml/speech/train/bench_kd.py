#!/usr/bin/env python3
"""KD overhead/smoke bench: fwd+bwd (+ plain SGD, no Adam/EMA state, so it fits in a small GPU budget) on real batches.
python bench_kd.py --config configs/smoke_kd.yaml [--no-kd] [--steps 40] [--batch 2] [--logit-weight w] [--lr 1e-3]"""
import argparse, sys, time, math
from pathlib import Path
import torch, yaml
from uiui_root import load_yaml
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import train as T_, modes, devutil, distill
from torch.nn.utils import parametrize
from data import TrainData

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True); ap.add_argument("--no-kd", action="store_true")
    ap.add_argument("--steps", type=int, default=40); ap.add_argument("--batch", type=int, default=None)
    ap.add_argument("--logit-weight", type=float, default=None); ap.add_argument("--enc-weight", type=float, default=None)
    ap.add_argument("--fixed", action="store_true", help="reuse the first batch every step (overfit check: losses must fall)")
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--train-top", type=int, default=0, help="memory-saving: only the top K encoder blocks (+decoder/joint) train")
    a = ap.parse_args()
    cfg = load_yaml(a.config); dev = torch.device("cuda", 0)
    if a.batch: cfg["data"]["batch_size"] = a.batch
    if a.logit_weight is not None: cfg["distill"]["logit_weight"] = a.logit_weight
    if a.enc_weight is not None: cfg["distill"]["enc_weight"] = a.enc_weight
    torch.manual_seed(0)
    data = iter(TrainData(cfg["data"], T_.BASE, 0, start_batch=0, log=print))
    model, proc, info = modes.build_model(cfg, None, dev, print)
    blank, vocab, durs = model.config.blank_token_id, model.config.vocab_size, list(model.config.durations)
    kd = None
    if not a.no_kd:
        kd = distill.Distiller(cfg["distill"], dev, print); kd.attach_student(model)
    fwd = T_.LossStep(model, False, vocab, durs, 0.02, cfg["train"].get("joint_chunk", 8), kd)
    modes.attach_train_mode(model, False, True)()
    if a.train_top:
        for p in model.encoder.parameters(): p.requires_grad_(False)
        for L in model.encoder.layers[-a.train_top:]: [p.requires_grad_(True) for p in L.parameters()]
    params = [p for p in model.parameters() if p.requires_grad]
    opt = torch.optim.SGD(params, lr=a.lr)
    torch.cuda.reset_peak_memory_stats(dev); times = []; hist = []
    for s in range(a.steps):
        b = b0 if (a.fixed and s) else next(data); b0 = b; feats, am, labels, ll, di = T_.make_batch(b, blank, dev)
        devutil.synchronize(dev); t0 = time.perf_counter()
        with torch.autocast("cuda", dtype=torch.bfloat16), parametrize.cached():
            loss = fwd(feats, am, labels, ll, di)
        loss.backward(); gn = torch.nn.utils.clip_grad_norm_(params, 1.0)
        if math.isfinite(float(gn)): opt.step()
        opt.zero_grad(set_to_none=True); devutil.synchronize(dev); times.append(time.perf_counter() - t0)
        hist.append((float(loss), {k: float(v) for k, v in fwd.kd_stats.items()}))
        if s % 5 == 0 or s == a.steps - 1: print(f"step {s} loss {hist[-1][0]:.4f} {hist[-1][1]} gn {float(gn):.2f} {times[-1]:.2f}s", flush=True)
    w = times[5:] or times
    print(f"RESULT kd={not a.no_kd} batch={cfg['data']['batch_size']} mean_step_s={sum(w)/len(w):.3f} peak_gb={torch.cuda.max_memory_allocated(dev)/1e9:.2f}")


if __name__ == "__main__":
    main()
