"""Forward+backward probe of Phonon-2 (dense-expanded five-value container) with HF ParakeetForTDT + TDT loss on MPS.

python -I scripts/train_probe.py --mode {sanity,full,full_bf16,full_ckpt,lora,dec} [--batch 8] [--secs 10]
"""
from __future__ import annotations
import argparse, json, re, sys, time, resource, os
from pathlib import Path
import numpy as np
import torch
from torch import nn

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from fermion_container import read_container  # reviewed copy of the HF repo's reader

BASE = ROOT / "hf/parakeet"
CONTAINER = ROOT / "ckpt/phonon2/model.fermion"


def state_dict():
    tensors, index = read_container(str(CONTAINER))
    sd = {}
    for k, v in tensors.items():
        if k.endswith("num_batches_tracked"):
            v32 = float(np.asarray(v, np.float32).reshape(-1)[0])
            sd[k] = torch.tensor(int(v32) if np.isfinite(v32) else 0, dtype=torch.int64)
            continue
        a = np.ascontiguousarray(v.astype(np.float32))
        if a.ndim == 2 and re.search(r"\.conv\.pointwise_conv[12]\.weight$", k):
            a = a[:, :, None]
        sd[k] = torch.from_numpy(a)
    return sd


def load(layerdrop=0.0):
    from transformers import ParakeetForTDT, ParakeetTDTConfig, AutoProcessor, GenerationConfig
    cfg = ParakeetTDTConfig.from_pretrained(BASE)
    cfg.encoder_config.layerdrop = layerdrop
    cfg.encoder_config.attention_dropout = float(os.environ.get("ATT_DROPOUT", "0.1"))
    m = ParakeetForTDT(cfg)
    missing, unexpected = m.load_state_dict(state_dict(), strict=False)
    assert not missing and not unexpected, (missing[:5], unexpected[:5])
    m.generation_config = GenerationConfig.from_pretrained(BASE)
    return m, AutoProcessor.from_pretrained(BASE)


class LoRALinear(nn.Module):
    def __init__(self, base: nn.Linear, r=16, alpha=32):
        super().__init__()
        self.base = base
        self.a = nn.Parameter(torch.randn(r, base.in_features) * (1 / base.in_features) ** 0.5)
        self.b = nn.Parameter(torch.zeros(base.out_features, r))
        self.s = alpha / r

    def forward(self, x):
        return self.base(x) + (x @ self.a.t() @ self.b.t()) * self.s


def apply_lora(model, top=8, r=16):
    layers = model.encoder.layers
    n = 0
    for li in range(len(layers) - top, len(layers)):
        L = layers[li]
        for parent, names in ((L.self_attn, ("q_proj", "k_proj", "v_proj", "o_proj")),
                              (L.feed_forward1, ("linear1", "linear2")), (L.feed_forward2, ("linear1", "linear2"))):
            for nm in names:
                setattr(parent, nm, LoRALinear(getattr(parent, nm), r=r)); n += 1
    return n


def audio_batch(batch, secs):
    import soundfile as sf
    texts = json.load(open(ROOT / "data/ci/expected_texts.json"))
    clips = []
    for k in sorted(texts):
        w, sr = sf.read(ROOT / f"data/ci/{k}.flac", dtype="float32"); assert sr == 16000
        clips.append((w, texts[k]))
    waves, labels = [], []
    n = int(secs * 16000)
    for i in range(batch):  # tile clips to `secs`, transcript = concatenation of the clips used
        w, t = [], []
        j = i
        while sum(len(x) for x in w) < n:
            cw, ct = clips[j % len(clips)]; w.append(cw); t.append(ct); j += 1
        waves.append(np.concatenate(w)[:n]); labels.append(" ".join(t))
    return waves, labels


def mem():
    return {"mps_driver_GB": round(torch.mps.driver_allocated_memory() / 1e9, 2),
            "mps_current_GB": round(torch.mps.current_allocated_memory() / 1e9, 2),
            "maxrss_GB": round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e9, 2)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", required=True)
    ap.add_argument("--batch", type=int, default=8)
    ap.add_argument("--secs", type=float, default=10.0)
    ap.add_argument("--steps", type=int, default=4)
    ap.add_argument("--max-label", type=int, default=0, help="truncate labels to N tokens (0 = full)")
    ap.add_argument("--loss", default="lean", choices=["lean", "hf"])
    a = ap.parse_args()
    dev = torch.device("mps")
    t0 = time.perf_counter()
    model, proc = load()
    print("load_s", round(time.perf_counter() - t0, 1), "params", sum(p.numel() for p in model.parameters()))
    tok = proc.tokenizer

    if a.mode == "sanity":
        import soundfile as sf
        texts = json.load(open(ROOT / "data/ci/expected_texts.json"))
        model.eval().to(dev)
        for k, ref in sorted(texts.items()):
            w, _ = sf.read(ROOT / f"data/ci/{k}.flac", dtype="float32")
            inp = proc([w], sampling_rate=16000, return_tensors="pt")
            with torch.no_grad():
                out = model.generate(input_features=inp["input_features"].to(dev), attention_mask=inp["attention_mask"].to(dev))
            seq = getattr(out, "sequences", out)
            hyp = proc.batch_decode(seq, skip_special_tokens=True)[0].strip()
            print(k, "MATCH" if hyp == ref else "DIFF", "|", hyp)
        return

    from transformers.loss.loss_tdt import tdt_loss
    from fast_tdt import tdt_loss_lean
    cfg = model.config
    blank = cfg.blank_token_id
    if a.mode.startswith("lora"):
        for p in model.parameters(): p.requires_grad_(False)
        print("lora modules", apply_lora(model, top=8, r=16))
    elif a.mode.startswith("dec"):
        for p in model.encoder.parameters(): p.requires_grad_(False)
    if a.mode.startswith("qat"):
        from qat import apply_qat
        raw = read_container(str(CONTAINER), with_raw=True)[2]
        model.to(dev).eval()
        with torch.no_grad():
            x = torch.randn(1, 300, 128, device=dev)
            before = model.get_audio_features(input_features=x).pooler_output
            print("five-value modules parametrised", apply_qat(model, raw)); model.to(dev)
            after = model.get_audio_features(input_features=x).pooler_output
        print("qat identity max|diff|", float((before - after).abs().max()), "scale", float(before.abs().max()))
        del raw
    if a.mode == "full_ckpt":
        model.gradient_checkpointing_enable(gradient_checkpointing_kwargs={"use_reentrant": False})
    model.to(dev).train()
    trainable = [p for p in model.parameters() if p.requires_grad]
    print("trainable params", sum(p.numel() for p in trainable))
    opt = torch.optim.AdamW(trainable, lr=1e-5, betas=(0.9, 0.98), weight_decay=1e-3)

    waves, texts = audio_batch(a.batch, a.secs)
    inp = proc.feature_extractor(waves, sampling_rate=16000, return_tensors="pt", padding=True, return_attention_mask=True)
    ids = [tok.encode(t, add_special_tokens=False) for t in texts]
    if a.max_label: ids = [x[: a.max_label] for x in ids]
    U = max(len(x) for x in ids)
    labels = torch.full((a.batch, U), blank, dtype=torch.long)
    for i, x in enumerate(ids): labels[i, : len(x)] = torch.tensor(x)
    lab_len = torch.tensor([len(x) for x in ids])
    dec_in = torch.cat([torch.full((a.batch, 1), blank, dtype=torch.long), labels], 1)
    feats = inp["input_features"].to(dev); am = inp["attention_mask"].to(dev)
    labels, lab_len, dec_in = labels.to(dev), lab_len.to(dev), dec_in.to(dev)
    print("features", tuple(feats.shape), "labels U", U)
    autocast = a.mode.endswith("_bf16")

    times, mems = [], []
    for step in range(a.steps):
        torch.mps.synchronize(); t = time.perf_counter()
        from torch.nn.utils import parametrize as _pz
        with torch.autocast("mps", dtype=torch.bfloat16, enabled=autocast), _pz.cached():
            enc = model.get_audio_features(input_features=feats, attention_mask=am)
            dh = model.decoder(dec_in)
            Tlen = enc.attention_mask.sum(-1)
            if a.loss == "hf":
                logits = model.joint(encoder_hidden_states=enc.pooler_output[:, :, None, :],
                                     decoder_hidden_states=dh[:, None, :, :])
                loss = tdt_loss(logits[..., : cfg.vocab_size], logits[..., cfg.vocab_size:], labels.int(), Tlen.int(), lab_len.int(),
                                blank, list(cfg.durations), sigma=0.02, reduction="mean_volume")
            else:
                loss = tdt_loss_lean(enc.pooler_output, dh, labels, Tlen, lab_len, model.joint.head, cfg.vocab_size,
                                     list(cfg.durations), sigma=0.02, chunk=32)
        torch.mps.synchronize(); tf = time.perf_counter() - t
        m_fwd = mem()
        loss.backward()
        opt.step(); opt.zero_grad(set_to_none=True)
        torch.mps.synchronize(); dt = time.perf_counter() - t
        times.append(dt); mems.append(m_fwd)
        print(f"step {step} loss {loss.item():.4f} fwd {tf:.2f}s total {dt:.2f}s T={int(Tlen.max())} mem_after_fwd {m_fwd} after_step {mem()}", flush=True)
    res = {"mode": a.mode, "loss": a.loss, "batch": a.batch, "secs": a.secs, "U": U, "T": int(Tlen.max()),
           "s_per_step_median_after_warmup": round(float(np.median(times[1:])), 2),
           "peak_mps_driver_GB": max(m["mps_driver_GB"] for m in mems), "maxrss_GB": mem()["maxrss_GB"],
           "trainable": sum(p.numel() for p in trainable), "torch": torch.__version__}
    print("RESULT", json.dumps(res))
    with open(ROOT / "results.jsonl", "a") as f: f.write(json.dumps(res) + "\n")


if __name__ == "__main__":
    main()
