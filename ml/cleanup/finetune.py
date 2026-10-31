#!/usr/bin/env python
"""Fine-tune the uiui MiniLM punctuation/casing token classifier (PyTorch, MPS).

Reproduces the original recipe by default (training-config.json): mode last2 (encoder layers 10-11 +
classifier = 3,552,008 trainable params), AdamW lr 2e-5 wd 0.01, 2 epochs, batch 16, grad-clip 1.0,
CE(logits[:5], punct) + CE(logits[5:8], case), supervision only on the final SentencePiece piece of each
word (special / non-final / pad = -100), eager attention, NFKC-lowercased per-word input exactly like the app.

Extras: --unfreeze-layers N (or --mode all|head), --replay + --replay-share (general-English rehearsal),
--case-weight, --case-class-weights LOWER,CAP,UPPER, --mixed-case mask|cap, --pack-words N (concatenate
sentences into dictation-length windows), --schedule constant|linear, --warmup-frac.

Example (the one run in README):
  python finetune.py --init $UIUI_APP_ROOT/model-sources/MiniLM \\
     --train ../data/workplace/sentences_train.jsonl --replay data/general/replay_train.jsonl \\
     --replay-share 0.3 --out runs/ft1
Smoke:  python finetune.py --train sample/sentences_train.jsonl --max-rows 64 --epochs 1 --out runs/smoke
"""
import argparse, json, os, random, sys, time
from pathlib import Path

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
import numpy as np
import torch
import torch.nn.functional as F
from transformers import AutoModelForTokenClassification

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "speech" / "lab"))
from tracker import Run
from uiui_cleanup import Tokenizer, words_in, FP32_DIR
from tagging import tag_text, MIXED, CAP

IGN = -100


def load_rows(paths):
    rows = []
    for p in paths:
        rows += [json.loads(l) for l in open(p) if l.strip()]
    return rows


def encode_example(text, tok, mixed_case):
    """-> (ids, punct_labels, case_labels) with labels only on each word's final piece, or None."""
    tags = tag_text(text)
    ws = words_in(text)
    if not ws:
        return None
    ids, pl, cl = [0], [IGN], [IGN]
    for w, (orig, p, c) in zip(ws, tags):
        pcs = tok.encode(w.normalized)
        if not pcs:
            return None
        ids += pcs
        pl += [IGN] * (len(pcs) - 1) + [p]
        if c == MIXED:
            c = {"mask": IGN, "cap": CAP}[mixed_case]
        cl += [IGN] * (len(pcs) - 1) + [c]
    ids.append(2); pl.append(IGN); cl.append(IGN)
    return ids, pl, cl


def build(rows, tok, mixed_case, pack_words, rnd, pack_frac=1.0):
    """Encode; optionally pack consecutive (shuffled) rows into windows of <= pack_words words."""
    enc, skipped = [], 0
    for r in rows:
        e = encode_example(r["text"], tok, mixed_case)
        if e is None or len(e[0]) > 128:
            skipped += 1
            continue
        enc.append(e)
    if pack_words and pack_words > 0:
        rnd.shuffle(enc)
        k = int(len(enc) * pack_frac)
        singles, enc = enc[k:], enc[:k]   # the rest stay single-sentence windows
        packed, cur = list(singles), None
        for ids, pl, cl in enc:
            nw = sum(x != IGN for x in pl)
            if cur is not None and cur[3] + nw <= pack_words and len(cur[0]) + len(ids) - 2 <= 128:
                cur = (cur[0][:-1] + ids[1:], cur[1][:-1] + pl[1:], cur[2][:-1] + cl[1:], cur[3] + nw)
            else:
                if cur is not None: packed.append(cur[:3])
                cur = (ids, pl, cl, nw)
        if cur is not None: packed.append(cur[:3])
        enc = packed
    return enc, skipped


def collate(batch, device):
    n = max(len(b[0]) for b in batch)
    ids = torch.full((len(batch), n), 1, dtype=torch.long)
    mask = torch.zeros((len(batch), n), dtype=torch.long)
    pl = torch.full((len(batch), n), IGN, dtype=torch.long)
    cl = torch.full((len(batch), n), IGN, dtype=torch.long)
    for i, (a, p, c) in enumerate(batch):
        L = len(a)
        ids[i, :L] = torch.tensor(a); mask[i, :L] = 1
        pl[i, :L] = torch.tensor(p); cl[i, :L] = torch.tensor(c)
    return ids.to(device), mask.to(device), pl.to(device), cl.to(device)


def set_trainable(model, mode, unfreeze):
    for p in model.parameters():
        p.requires_grad = False
    layers = model.bert.encoder.layer
    if mode == "all":
        for p in model.parameters(): p.requires_grad = True
    else:
        n = {"head": 0, "last2": 2}.get(mode, unfreeze)
        if mode == "lastN": n = unfreeze
        for l in layers[len(layers) - n:] if n else []:
            for p in l.parameters(): p.requires_grad = True
        for p in model.classifier.parameters(): p.requires_grad = True
    return sum(p.numel() for p in model.parameters() if p.requires_grad)


@torch.no_grad()
def tag_metrics(model, data, device, bs=64):
    """Teacher-forced tag metrics on encoded windows: punct micro F1 (excl NONE), punct acc, case acc."""
    model.eval()
    pc = np.zeros((5, 5), int); cc = np.zeros((3, 3), int)
    for i in range(0, len(data), bs):
        ids, mask, pl, cl = collate(data[i:i + bs], device)
        lg = model(input_ids=ids, attention_mask=mask).logits
        pp = lg[..., :5].argmax(-1); cp = lg[..., 5:].argmax(-1)
        m = pl != IGN
        for g, p in zip(pl[m].tolist(), pp[m].tolist()): pc[g, p] += 1
        m = cl != IGN
        for g, p in zip(cl[m].tolist(), cp[m].tolist()): cc[g, p] += 1
    tp = sum(pc[k, k] for k in range(1, 5)); fp = pc[:, 1:].sum() - tp; fn = pc[1:, :].sum() - tp
    p = tp / max(tp + fp, 1); r = tp / max(tp + fn, 1)
    return {"punct_micro_f1": float(2 * p * r / max(p + r, 1e-9)), "punct_acc": float(np.trace(pc) / max(pc.sum(), 1)),
            "case_acc": float(np.trace(cc) / max(cc.sum(), 1))}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--init", default=str(FP32_DIR))
    ap.add_argument("--train", nargs="+", required=True)
    ap.add_argument("--replay", nargs="*", default=[])
    ap.add_argument("--replay-share", type=float, default=0.3, help="replay rows as a share of the TOTAL mixed set")
    ap.add_argument("--dev-frac", type=float, default=0.03, help="held out from each of train/replay for per-epoch dev + best selection")
    ap.add_argument("--mode", default="last2", choices=["head", "last2", "lastN", "all"])
    ap.add_argument("--unfreeze-layers", type=int, default=2, help="with --mode lastN")
    ap.add_argument("--lr", type=float, default=2e-5)
    ap.add_argument("--head-lr", type=float, default=None, help="optional separate LR for classifier")
    ap.add_argument("--epochs", type=int, default=2)
    ap.add_argument("--batch-size", type=int, default=16)
    ap.add_argument("--weight-decay", type=float, default=0.01)
    ap.add_argument("--grad-clip", type=float, default=1.0)
    ap.add_argument("--schedule", default="constant", choices=["constant", "linear"])
    ap.add_argument("--warmup-frac", type=float, default=0.0)
    ap.add_argument("--case-weight", type=float, default=1.0)
    ap.add_argument("--case-class-weights", default="1,1,1")
    ap.add_argument("--punct-class-weights", default="1,1,1,1,1", help="NONE,COMMA,PERIOD,QUESTION,EXCLAMATION CE weights")
    ap.add_argument("--mixed-case", default="mask", choices=["mask", "cap"])
    ap.add_argument("--pack-words", type=int, default=0)
    ap.add_argument("--pack-frac", type=float, default=1.0, help="share of rows concatenated into pack-words windows; the rest stay single sentences")
    ap.add_argument("--seed", type=int, default=20261024)
    ap.add_argument("--device", default="mps")
    ap.add_argument("--max-rows", type=int, default=0, help="smoke: cap rows per source")
    ap.add_argument("--track", default=None, help="lab dashboard run name (e.g. cleanup-ft3b); tags cleanup,mac")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    rnd = random.Random(a.seed); torch.manual_seed(a.seed); np.random.seed(a.seed)
    dev = "mps" if a.device == "mps" and torch.backends.mps.is_available() else "cpu"
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    tok = Tokenizer()

    def split(rows):
        rows = rows[:]; rnd.shuffle(rows)
        if a.max_rows: rows = rows[:a.max_rows]
        k = max(1, int(len(rows) * a.dev_frac)) if len(rows) > 20 else 0
        return rows[k:], rows[:k]
    wp_tr, wp_dev = split(load_rows(a.train))
    rp_all = load_rows(a.replay) if a.replay else []
    rp_tr, rp_dev = split(rp_all) if rp_all else ([], [])
    if rp_tr:
        n_rp = int(round(len(wp_tr) * a.replay_share / (1 - a.replay_share)))
        rnd.shuffle(rp_tr); rp_tr = rp_tr[:n_rp]
    train_rows = wp_tr + rp_tr
    tr, sk1 = build(train_rows, tok, a.mixed_case, a.pack_words, rnd, a.pack_frac)
    d_wp, _ = build(wp_dev, tok, a.mixed_case, 0, rnd)
    d_rp, _ = build(rp_dev, tok, a.mixed_case, 0, rnd)
    print(f"train: {len(wp_tr)} target + {len(rp_tr)} replay ({len(rp_tr)/max(len(train_rows),1):.0%}) -> {len(tr)} windows "
          f"(skipped {sk1}); dev target {len(d_wp)} replay {len(d_rp)}; device {dev}", flush=True)

    model = AutoModelForTokenClassification.from_pretrained(a.init, attn_implementation="eager").to(dev)
    ntrain = set_trainable(model, a.mode, a.unfreeze_layers)
    print(f"mode={a.mode} trainable params={ntrain:,}", flush=True)
    head = [p for n, p in model.named_parameters() if p.requires_grad and n.startswith("classifier")]
    body = [p for n, p in model.named_parameters() if p.requires_grad and not n.startswith("classifier")]
    groups = [{"params": body, "lr": a.lr}] if body else []
    groups.append({"params": head, "lr": a.head_lr or a.lr})
    opt = torch.optim.AdamW(groups, weight_decay=a.weight_decay)
    steps_per_epoch = (len(tr) + a.batch_size - 1) // a.batch_size
    total = steps_per_epoch * a.epochs
    base = [g["lr"] for g in opt.param_groups]
    trk = Run(a.track, kind="train", config=vars(a), total_steps=total, tags=["cleanup", "mac"],
              notes="MiniLM punct/case token classifier fine-tune (MPS)") if a.track else None

    def lr_at(step):
        w = int(a.warmup_frac * total)
        f = (step + 1) / w if w and step < w else 1.0
        if a.schedule == "linear": f *= max(0.0, (total - step) / max(total - w, 1)) if step >= w else 1.0
        return f
    cw = torch.tensor([float(x) for x in a.case_class_weights.split(",")], device=dev)
    pw = torch.tensor([float(x) for x in a.punct_class_weights.split(",")], device=dev)

    def run_dev(tag):
        res = {"target": tag_metrics(model, d_wp, dev) if d_wp else None,
               "replay": tag_metrics(model, d_rp, dev) if d_rp else None}
        model.train()
        return res
    log = {"args": vars(a), "trainable_params": ntrain, "windows": len(tr), "epochs": [],
           "baseline_dev": run_dev("base")}
    print("dev before:", json.dumps(log["baseline_dev"]), flush=True)
    best, step = None, 0
    model.train()
    for ep in range(1, a.epochs + 1):
        rnd.shuffle(tr); t0 = time.time(); tot = 0.0; n = 0
        for i in range(0, len(tr), a.batch_size):
            ids, mask, pl, cl = collate(tr[i:i + a.batch_size], dev)
            for g, b in zip(opt.param_groups, base): g["lr"] = b * lr_at(step)
            lg = model(input_ids=ids, attention_mask=mask).logits
            lp = F.cross_entropy(lg[..., :5].reshape(-1, 5), pl.reshape(-1), weight=pw, ignore_index=IGN)
            if (cl != IGN).any():
                lc = F.cross_entropy(lg[..., 5:].reshape(-1, 3), cl.reshape(-1), weight=cw, ignore_index=IGN)
            else:
                lc = lg.sum() * 0
            loss = lp + a.case_weight * lc
            opt.zero_grad(set_to_none=True); loss.backward()
            torch.nn.utils.clip_grad_norm_([p for g in opt.param_groups for p in g["params"]], a.grad_clip)
            opt.step(); step += 1
            tot += loss.item(); n += 1
            if trk and (step % 20 == 0): trk.log(step, loss=loss.item(), loss_punct=lp.item(), loss_case=float(lc), lr=opt.param_groups[0]["lr"], epoch=ep)
            if n % 200 == 0: print(f"  ep{ep} step {n}/{steps_per_epoch} loss {tot/n:.4f}", flush=True)
        wall = time.time() - t0
        d = run_dev(ep)
        rec = {"epoch": ep, "steps": step, "mean_loss": tot / n, "wall_seconds": round(wall, 1), "dev": d}
        log["epochs"].append(rec)
        if trk:
            for k in ("target", "replay"):
                if d[k]: trk.log_eval(step, f"dev-{k}", {f"epoch{ep}": d[k]})
        print(f"epoch {ep}: loss {tot/n:.4f} wall {wall:.1f}s dev {json.dumps(d)}", flush=True)
        ck = out / f"epoch{ep}"; model.save_pretrained(ck)
        sel = (d["target"]["punct_micro_f1"] + d["target"]["case_acc"]) if d["target"] else 0
        if best is None or sel > best[0]:
            best = (sel, ep)
    log["best_epoch"] = best[1]
    json.dump(log, open(out / "train_log.json", "w"), indent=1)
    # convenience copies: best -> out/best, last -> out/last
    import shutil
    for name, ep in (("best", best[1]), ("last", a.epochs)):
        if (out / name).exists(): shutil.rmtree(out / name)
        shutil.copytree(out / f"epoch{ep}", out / name)
    if trk: trk.finish()
    print(f"done. best epoch {best[1]} (dev selection: target punct F1 + case acc). checkpoints under {out}")


if __name__ == "__main__":
    main()
