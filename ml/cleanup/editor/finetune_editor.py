#!/usr/bin/env python
"""Train the dictation editor (see editor.py) from disfl3 (9 logits) on:
  pairs  = (ASR hypothesis, reference) rows from the current speech model over training audio (formatted input)
  disfl  = synthetic disfluency records (formatted input, fillers/repeats -> DELETE)
  text   = ft3 gold text mix + replay (UNformatted input, the old cleanup task, so non-formatting ASRs keep working)
All layers; 7 new marker embeddings. Mac MPS. Never logs text.

  python editor/finetune_editor.py --pairs editor/data/pairs.rows.jsonl --out runs/editor1
"""
import argparse, json, os, random, shutil, sys, time
from pathlib import Path

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
import numpy as np
import torch
import torch.nn.functional as F
from transformers import AutoModelForTokenClassification

HERE = Path(__file__).resolve().parent; ROOT = HERE.parent
sys.path.insert(0, str(ROOT)); sys.path.insert(0, str(HERE))
import editor as E                                  # noqa: E402
from uiui_cleanup import Tokenizer                  # noqa: E402
from tagging import tag_text                        # noqa: E402
from finetune_disfl import collate, dev_metrics     # noqa: E402

IGN = E.IGN


def load(p): return [json.loads(l) for l in open(p) if l.strip()]


def pack(enc, max_ids, rnd, frac):
    """Join consecutive (shuffled) examples into windows of <= max_ids ids (multi-sentence dictation); 1-frac stay single."""
    rnd.shuffle(enc); k = int(len(enc) * frac); out, cur = list(enc[k:]), None
    for e in enc[:k]:
        if cur is not None and len(cur[0]) + len(e[0]) - 2 <= max_ids and rnd.random() < 0.7:
            cur = tuple(a[:-1] + b[1:] for a, b in zip(cur, e))
        else:
            if cur is not None: out.append(cur)
            cur = e
    if cur is not None: out.append(cur)
    return out


def widen(model, seed=0):
    """+7 marker rows: marks start from ',' / '.' embeddings, case markers from the mean, small noise."""
    emb = model.get_input_embeddings().weight.data
    g = torch.Generator().manual_seed(seed)
    mean = emb[4:32000].mean(0)
    init = {32000: emb[4], 32001: emb[5], 32002: emb[5], 32003: emb[5], 32004: mean, 32005: mean, 32006: mean}
    model.resize_token_embeddings(E.VOCAB)
    new = model.get_input_embeddings().weight.data
    for i, v in init.items(): new[i] = v + torch.randn(v.shape, generator=g) * 0.02
    return model


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--init", default=str(ROOT / "runs/disfl3/best"))
    ap.add_argument("--pairs", required=True)
    ap.add_argument("--pairs-cap", type=int, default=0)
    ap.add_argument("--disfl", default=str(ROOT / "data/disfl/train.jsonl"))
    ap.add_argument("--disfl-repeat", type=int, default=2)
    ap.add_argument("--text", nargs="*", default=["data/natural/train_nat_plus_slot.jsonl", "data/hinglish/train_hinglish_x2.jsonl", "data/general/replay_train.jsonl"])
    ap.add_argument("--lr", type=float, default=3e-5)
    ap.add_argument("--epochs", type=int, default=2)
    ap.add_argument("--bs", type=int, default=32)
    ap.add_argument("--del-weight", type=float, default=2.0)
    ap.add_argument("--pack-ids", type=int, default=110)
    ap.add_argument("--pack-frac", type=float, default=0.5)
    ap.add_argument("--seed", type=int, default=20261029)
    ap.add_argument("--device", default="mps")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    rnd = random.Random(a.seed); torch.manual_seed(a.seed)
    dev = "mps" if a.device == "mps" and torch.backends.mps.is_available() else "cpu"
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    tok = Tokenizer()

    pairs = load(a.pairs); rnd.shuffle(pairs)
    if a.pairs_cap: pairs = pairs[:a.pairs_cap]
    # a reference without any mark (15% of NPTEL) would teach the editor to strip the ASR's punctuation
    pairs = [r for r in pairs if any(ch in ".,?!" for ch in r["reference"])]
    enc_p = [e for e in (E.pair_example(r["hypothesis"], r["reference"], tok) for r in pairs) if e and len(e[0]) <= 128]
    dis = load(a.disfl)
    enc_d = [e for _ in range(a.disfl_repeat) for e in (E.disfl_example(r, tok, rnd) for r in dis) if e and len(e[0]) <= 128]
    txt = [r for p in a.text for r in load(ROOT / p)]
    enc_t = [e for e in (E.text_example(r["text"], tok, tag_text) for r in txt) if e and len(e[0]) <= 128]
    kp, kd, kt = max(1, len(enc_p) // 50), max(1, len(enc_d) // 50), max(1, len(enc_t) // 50)
    dev_sets = {"pairs": enc_p[:kp], "disfl": enc_d[:kd], "text": enc_t[:kt]}
    train = pack(enc_p[kp:] + enc_d[kd:] + enc_t[kt:], a.pack_ids, rnd, a.pack_frac)
    stats = {"pairs_rows": len(pairs), "pairs_ex": len(enc_p), "disfl_ex": len(enc_d), "text_ex": len(enc_t), "windows": len(train),
             "pair_labels": {k: int(sum(sum(1 for x in e[i] if x != IGN) for e in enc_p)) for k, i in (("punct", 1), ("case", 2), ("del", 3))},
             "pair_deletes": int(sum(sum(1 for x in e[3] if x == 1) for e in enc_p))}
    print(json.dumps(stats), f"device {dev}", flush=True)

    model = AutoModelForTokenClassification.from_pretrained(a.init, attn_implementation="eager")
    assert model.config.num_labels == 9
    model = widen(model, a.seed).to(dev).train()
    opt = torch.optim.AdamW(model.parameters(), lr=a.lr, weight_decay=0.01)
    steps = (len(train) + a.bs - 1) // a.bs; total = steps * a.epochs; warm = int(0.05 * total); step = 0
    log = {"args": vars(a), "stats": stats, "epochs": []}
    base = {k: dev_metrics(model, v, dev) for k, v in dev_sets.items()}
    log["dev_init"] = base; print("init dev", json.dumps({k: {m: round(x, 4) for m, x in v.items()} for k, v in base.items()}), flush=True)
    for ep in range(1, a.epochs + 1):
        rnd.shuffle(train); t0 = time.time(); tot = 0.0; n = 0
        for i in range(0, len(train), a.bs):
            ids, mask, pl, cl, dl = collate(train[i:i + a.bs], dev)
            f = (step + 1) / warm if step < warm else max(0.0, (total - step) / max(total - warm, 1))
            for g in opt.param_groups: g["lr"] = a.lr * f
            lg = model(input_ids=ids, attention_mask=mask).logits
            lp = F.cross_entropy(lg[..., :5].reshape(-1, 5), pl.reshape(-1), ignore_index=IGN)
            lc = F.cross_entropy(lg[..., 5:8].reshape(-1, 3), cl.reshape(-1), ignore_index=IGN) if (cl != IGN).any() else lg.sum() * 0
            m = dl != IGN
            ld = F.binary_cross_entropy_with_logits(lg[..., 8][m], dl[m].float()) if m.any() else lg.sum() * 0
            loss = lp + lc + a.del_weight * ld
            opt.zero_grad(set_to_none=True); loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0); opt.step()
            step += 1; tot += loss.item(); n += 1
            if n % 500 == 0: print(f"  ep{ep} {n}/{steps} loss {tot/n:.4f} {time.time()-t0:.0f}s", flush=True)
        d = {k: dev_metrics(model, v, dev) for k, v in dev_sets.items()}
        log["epochs"].append({"epoch": ep, "loss": tot / n, "wall": round(time.time() - t0, 1), "dev": d})
        print(f"epoch {ep} loss {tot/n:.4f} wall {time.time()-t0:.0f}s dev", json.dumps({k: {m: round(x, 4) for m, x in v.items()} for k, v in d.items()}), flush=True)
        model.save_pretrained(out / f"epoch{ep}")
    for name in ("best", "last"):
        if (out / name).exists(): shutil.rmtree(out / name)
        shutil.copytree(out / f"epoch{a.epochs}", out / name)
    json.dump(log, open(out / "train_log.json", "w"), indent=1)
    print("done")


if __name__ == "__main__":
    main()
