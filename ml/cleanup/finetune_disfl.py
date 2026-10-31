#!/usr/bin/env python
"""Multitask fine-tune of runs/ft3/best with a 9th logit: P(DELETE) per word (final piece), BCE loss.
Logits 0-7 = unchanged punct (0-4) / case (5-7). Mixed data: synthetic disfluency records (data/disfl/train.jsonl)
+ the ft3 clean mix (all del=0) so punct/case quality is rehearsed. Mac MPS. Never logs text.

  python finetune_disfl.py --out runs/disfl1
"""
import argparse, json, os, random, sys, time
from pathlib import Path

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
import numpy as np
import torch
import torch.nn.functional as F
from transformers import AutoModelForTokenClassification

from uiui_cleanup import Tokenizer
import finetune as ft
from finetune import IGN, load_rows, encode_example, collate as _unused

HERE = Path(__file__).parent


def encode_disfl(r, tok):
    ids, pl, cl, dl = [0], [IGN], [IGN], [IGN]
    for w, d, p, c in zip(r["words"], r["del"], r["punct"], r["case"]):
        pcs = tok.encode(w)
        if not pcs:
            return None
        ids += pcs
        pad = [IGN] * (len(pcs) - 1)
        pl += pad + [p]; cl += pad + [c]; dl += pad + [d]
    ids.append(2); pl.append(IGN); cl.append(IGN); dl.append(IGN)
    return ids, pl, cl, dl


def encode_clean(text, tok):
    e = encode_example(text, tok, "mask")
    if e is None:
        return None
    ids, pl, cl = e
    dl = [0 if x != IGN else IGN for x in pl]
    return ids, pl, cl, dl


def pack(enc, max_words, rnd, frac=0.9):
    rnd.shuffle(enc)
    k = int(len(enc) * frac)
    singles, enc = enc[k:], enc[:k]
    out, cur = list(singles), None
    for ids, pl, cl, dl in enc:
        nw = sum(x != IGN for x in pl)
        if cur is not None and cur[4] + nw <= max_words and len(cur[0]) + len(ids) - 2 <= 128:
            cur = (cur[0][:-1] + ids[1:], cur[1][:-1] + pl[1:], cur[2][:-1] + cl[1:], cur[3][:-1] + dl[1:], cur[4] + nw)
        else:
            if cur is not None: out.append(cur[:4])
            cur = (ids, pl, cl, dl, nw)
    if cur is not None: out.append(cur[:4])
    return out


def collate(batch, dev):
    n = max(len(b[0]) for b in batch)
    ids = torch.full((len(batch), n), 1, dtype=torch.long)
    mask = torch.zeros((len(batch), n), dtype=torch.long)
    lab = [torch.full((len(batch), n), IGN, dtype=torch.long) for _ in range(3)]
    for i, b in enumerate(batch):
        L = len(b[0])
        ids[i, :L] = torch.tensor(b[0]); mask[i, :L] = 1
        for k in range(3):
            lab[k][i, :L] = torch.tensor(b[1 + k])
    return ids.to(dev), mask.to(dev), *[x.to(dev) for x in lab]


def expand_head(model, seed=0):
    old = model.classifier
    new = torch.nn.Linear(old.in_features, 9)
    g = torch.Generator().manual_seed(seed)
    with torch.no_grad():
        new.weight[:8] = old.weight
        new.bias[:8] = old.bias
        new.weight[8] = torch.randn(old.in_features, generator=g) * 0.02
        new.bias[8] = -3.0
    model.classifier = new
    model.config.num_labels = 9
    model.num_labels = 9
    return model


@torch.no_grad()
def dev_metrics(model, data, dev, thr=0.5, bs=64):
    model.eval()
    pc = np.zeros((5, 5), int); cc = np.zeros((3, 3), int)
    tp = fp = fn = keep = fd = 0
    for i in range(0, len(data), bs):
        ids, mask, pl, cl, dl = collate(data[i:i + bs], dev)
        lg = model(input_ids=ids, attention_mask=mask).logits
        pp, cp = lg[..., :5].argmax(-1), lg[..., 5:8].argmax(-1)
        pd = (torch.sigmoid(lg[..., 8]) > thr).long()
        for lab, pr, M in ((pl, pp, pc), (cl, cp, cc)):
            m = lab != IGN
            for g, p in zip(lab[m].tolist(), pr[m].tolist()): M[g, p] += 1
        m = dl != IGN
        g, p = dl[m], pd[m]
        tp += int(((g == 1) & (p == 1)).sum()); fp += int(((g == 0) & (p == 1)).sum()); fn += int(((g == 1) & (p == 0)).sum())
        keep += int((g == 0).sum())
    t = sum(pc[k, k] for k in range(1, 5)); f_p = pc[:, 1:].sum() - t; f_n = pc[1:, :].sum() - t
    p_ = t / max(t + f_p, 1); r_ = t / max(t + f_n, 1)
    dp, dr = tp / max(tp + fp, 1), tp / max(tp + fn, 1)
    model.train()
    return {"punct_f1": float(2 * p_ * r_ / max(p_ + r_, 1e-9)), "case_acc": float(np.trace(cc) / max(cc.sum(), 1)),
            "del_p": dp, "del_r": dr, "del_f1": 2 * dp * dr / max(dp + dr, 1e-9), "fdr": fp / max(keep, 1)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--init", default=str(HERE / "runs/ft3/best"))
    ap.add_argument("--disfl", default=str(HERE / "data/disfl/train.jsonl"))
    ap.add_argument("--clean", nargs="*", default=["data/natural/train_nat_plus_slot.jsonl", "data/hinglish/train_hinglish_x2.jsonl"])
    ap.add_argument("--replay", default="data/general/replay_train.jsonl")
    ap.add_argument("--replay-share", type=float, default=0.3)
    ap.add_argument("--clean-cap", type=int, default=9000, help="max clean (all-keep) rows from the ft3 mix")
    ap.add_argument("--lr", type=float, default=2e-5)
    ap.add_argument("--head-lr", type=float, default=1e-3)
    ap.add_argument("--epochs", type=int, default=3)
    ap.add_argument("--bs", type=int, default=16)
    ap.add_argument("--del-weight", type=float, default=2.0)
    ap.add_argument("--pos-weight", type=float, default=1.0, help="BCE positive weight (<1 favours precision)")
    ap.add_argument("--pack-words", type=int, default=40)
    ap.add_argument("--seed", type=int, default=20261028)
    ap.add_argument("--device", default="mps")
    ap.add_argument("--max-rows", type=int, default=0)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    rnd = random.Random(a.seed); torch.manual_seed(a.seed)
    dev = "mps" if a.device == "mps" and torch.backends.mps.is_available() else "cpu"
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    tok = Tokenizer()
    dis = load_rows([a.disfl]); rnd.shuffle(dis)
    cl_rows = load_rows([HERE / c for c in a.clean]); rnd.shuffle(cl_rows); cl_rows = cl_rows[:a.clean_cap]
    n_rp = int(round((len(dis) + len(cl_rows)) * a.replay_share / (1 - a.replay_share)))
    rp_rows = load_rows([HERE / a.replay]); rnd.shuffle(rp_rows); rp_rows = rp_rows[:n_rp]
    if a.max_rows:
        dis, cl_rows, rp_rows = dis[:a.max_rows], cl_rows[:a.max_rows], rp_rows[:a.max_rows]
    kd = max(1, int(0.03 * len(dis))); kc = max(1, int(0.03 * len(cl_rows)))
    enc_dis = [e for e in (encode_disfl(r, tok) for r in dis) if e and len(e[0]) <= 128]
    enc_cl = [e for e in (encode_clean(r["text"], tok) for r in cl_rows + rp_rows) if e and len(e[0]) <= 128]
    dev_set = enc_dis[:kd] + enc_cl[:kc]
    train = pack(enc_dis[kd:] + enc_cl[kc:], a.pack_words, rnd)
    print(f"disfl rows {len(dis)} clean {len(cl_rows)} replay {len(rp_rows)} -> {len(train)} windows, dev {len(dev_set)}, device {dev}", flush=True)

    model = AutoModelForTokenClassification.from_pretrained(a.init, attn_implementation="eager")
    model = expand_head(model).to(dev).train()
    # the new DELETE row needs a much larger LR than the pretrained body (it starts at ~0); rows 0-7 of the head are frozen
    model.classifier.weight.register_hook(lambda g: torch.cat([torch.zeros_like(g[:8]), g[8:]]))
    model.classifier.bias.register_hook(lambda g: torch.cat([torch.zeros_like(g[:8]), g[8:]]))
    body = [p for n, p in model.named_parameters() if not n.startswith("classifier")]
    opt = torch.optim.AdamW([{"params": body, "lr": a.lr, "weight_decay": 0.01},
                             {"params": list(model.classifier.parameters()), "lr": a.head_lr, "weight_decay": 0.0}])
    base_lr = [a.lr, a.head_lr]
    steps = (len(train) + a.bs - 1) // a.bs; total = steps * a.epochs; warm = int(0.05 * total)
    log = {"args": vars(a), "windows": len(train), "epochs": []}
    posw = torch.tensor(a.pos_weight, device=dev)
    step = 0
    for ep in range(1, a.epochs + 1):
        rnd.shuffle(train); t0 = time.time(); tot = 0.0; n = 0
        for i in range(0, len(train), a.bs):
            ids, mask, pl, cl, dl = collate(train[i:i + a.bs], dev)
            f = (step + 1) / warm if step < warm else max(0.0, (total - step) / max(total - warm, 1))
            for g, b in zip(opt.param_groups, base_lr): g["lr"] = b * f
            lg = model(input_ids=ids, attention_mask=mask).logits
            lp = F.cross_entropy(lg[..., :5].reshape(-1, 5), pl.reshape(-1), ignore_index=IGN)
            lc = F.cross_entropy(lg[..., 5:8].reshape(-1, 3), cl.reshape(-1), ignore_index=IGN) if (cl != IGN).any() else lg.sum() * 0
            m = dl != IGN
            ld = F.binary_cross_entropy_with_logits(lg[..., 8][m], dl[m].float(), pos_weight=posw)
            loss = lp + lc + a.del_weight * ld
            opt.zero_grad(set_to_none=True); loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            opt.step(); step += 1; tot += loss.item(); n += 1
            if n % 200 == 0: print(f"  ep{ep} {n}/{steps} loss {tot/n:.4f}", flush=True)
        d = dev_metrics(model, dev_set, dev)
        log["epochs"].append({"epoch": ep, "loss": tot / n, "wall": round(time.time() - t0, 1), "dev": d})
        print(f"epoch {ep} loss {tot/n:.4f} wall {time.time()-t0:.0f}s dev {json.dumps({k: round(v,4) for k,v in d.items()})}", flush=True)
        model.save_pretrained(out / f"epoch{ep}")
    import shutil
    for name in ("best", "last"):
        if (out / name).exists(): shutil.rmtree(out / name)
        shutil.copytree(out / f"epoch{a.epochs}", out / name)
    json.dump(log, open(out / "train_log.json", "w"), indent=1)
    print("done")


if __name__ == "__main__":
    main()
