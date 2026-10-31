"""Checkpoints: step-N/{model.safetensors (+config.json, model_ema.safetensors), optim.pt, meta.json}, best/, pruning."""
from __future__ import annotations
import json, os, random, re, shutil
from pathlib import Path
import numpy as np
import torch
from safetensors.torch import save_file, load_file

from modes import export_state_dict, qat_scales


_STEP = re.compile(r"^step-\d+$")


def _fsync(p: Path):
    fd = os.open(p, os.O_RDONLY)
    try: os.fsync(fd)
    finally: os.close(fd)


def _publish(tmp: Path, final: Path):
    """COMPLETE marker last, fsync everything, atomic rename: a power cut leaves either the old state or a *.tmp dir that resume ignores."""
    (tmp / "COMPLETE").write_text("ok\n")
    for f in tmp.rglob("*"):
        if f.is_file(): _fsync(f)
    _fsync(tmp)
    os.rename(tmp, final)
    _fsync(final.parent)


def get_rng():
    return {"torch": torch.get_rng_state(), "cuda": torch.cuda.get_rng_state_all() if torch.cuda.is_available() else None,
            "numpy": np.random.get_state(), "python": random.getstate()}


def set_rng(r):
    torch.set_rng_state(r["torch"]); np.random.set_state(r["numpy"]); random.setstate(r["python"])
    if r.get("cuda") is not None and torch.cuda.is_available():
        try: torch.cuda.set_rng_state_all(r["cuda"])
        except Exception: pass


def reseed(seed):
    random.seed(seed); np.random.seed(seed % 2**32); torch.manual_seed(seed)


def cleanup(out: Path):
    """Drop half-written checkpoints (*.tmp) left by a crash; restore best/ if a crash hit between its two renames."""
    for p in out.glob("*.tmp"): shutil.rmtree(p, ignore_errors=True)
    if (out / "best.old").exists():
        if (out / "best" / "COMPLETE").exists(): shutil.rmtree(out / "best.old", ignore_errors=True)
        else: shutil.rmtree(out / "best", ignore_errors=True); os.rename(out / "best.old", out / "best")


def save_step(out: Path, step, model, opt, ema, state, cfg, mode, save_dtype="float32", extra=None):
    final = out / f"step-{step:07d}"
    if (final / "COMPLETE").exists(): return final
    d = final.with_name(final.name + ".tmp"); shutil.rmtree(d, ignore_errors=True); d.mkdir(parents=True)
    dt = getattr(torch, save_dtype)
    save_file(export_state_dict(model, dt), d / "model.safetensors", metadata={"format": "pt", "step": str(step)})
    model.config.save_pretrained(d)
    if mode == "qat": save_file(qat_scales(model), d / "qat_scales.safetensors")
    if ema is not None:
        with ema.swapped(model):
            save_file(export_state_dict(model, dt), d / "model_ema.safetensors", metadata={"format": "pt", "step": str(step)})
    blob = dict(state, step=step, opt=opt.state_dict() if opt is not None else None, **(extra or {}))
    if mode in ("lora", "qat"):   # dense modes reload model.safetensors; wrapped modes need the raw latent params
        blob["trainable"] = {n: p.detach().cpu() for n, p in model.named_parameters() if p.requires_grad}
    if ema is not None: blob["ema"] = {n: t.cpu() for n, t in ema.shadow.items()}
    torch.save(blob, d / "optim.pt.tmp"); (d / "optim.pt.tmp").replace(d / "optim.pt")
    (d / "meta.json").write_text(json.dumps({"step": step, "mode": mode, **{k: v for k, v in state.items() if k in ("best", "audio_secs")}}, indent=1))
    _publish(d, final)
    return final


def prune(out: Path, keep_last=2, keep_optim=2):
    dirs = sorted(p for p in out.glob("step-*") if _STEP.match(p.name) and (p / "COMPLETE").exists())
    for d in dirs[:-keep_last]: shutil.rmtree(d, ignore_errors=True)
    rest = dirs[-keep_last:]
    for d in rest[:max(len(rest) - keep_optim, 0)]: (d / "optim.pt").unlink(missing_ok=True)


def save_best(out: Path, model, ema_used, ema, cfg, meta, save_dtype="float32"):
    d = out / "best.tmp"; shutil.rmtree(d, ignore_errors=True); d.mkdir(parents=True)
    dt = getattr(torch, save_dtype)
    if ema_used:
        with ema.swapped(model): sd = export_state_dict(model, dt)
    else: sd = export_state_dict(model, dt)
    save_file(sd, d / "model.safetensors", metadata={"format": "pt", "step": str(meta["step"])})
    model.config.save_pretrained(d)
    (d / "meta.json").write_text(json.dumps(meta, indent=1))
    if (out / "best").exists(): os.rename(out / "best", out / "best.old")
    _publish(d, out / "best")
    shutil.rmtree(out / "best.old", ignore_errors=True)


def latest(out: Path):
    """Newest COMPLETE step checkpoint that can be resumed from."""
    for d in sorted((p for p in out.glob("step-*") if _STEP.match(p.name)), reverse=True):
        if (d / "COMPLETE").exists() and (d / "optim.pt").exists(): return d
    return None


def load_into(model, d: Path, mode, device):
    blob = torch.load(d / "optim.pt", map_location="cpu", weights_only=False)
    if mode in ("lora", "qat"):
        named = dict(model.named_parameters())
        with torch.no_grad():
            for n, t in blob["trainable"].items(): named[n].copy_(t.to(named[n].device))
    else:
        print("resume:", model.load_state_dict(load_file(d / "model.safetensors"), strict=True))
    model.to(device)
    return blob


def load_init(model, d: Path, mode, device, prefer="ema"):
    """autoresearch `model.init_ckpt`: copy a finished run's model state into the freshly built model (QAT/lut4 structure already applied).
    Strict: the trainable-parameter names/shapes must match exactly (latents, LUT/scale/lo/hi params), plus every non-parametrised buffer
    (BatchNorm stats) must be present.  prefer='ema' loads the EMA weights when the checkpoint has them: that is the model the final eval scored.
    Optimiser, LR schedule and step counter are NOT restored.  Returns a small info dict for the log."""
    d = Path(d)
    if not (d / "COMPLETE").exists(): raise SystemExit(f"init_ckpt {d}: no COMPLETE marker")
    assert prefer in ("ema", "raw"), prefer
    if mode in ("lora", "qat"):
        try: blob = torch.load(d / "optim.pt", map_location="cpu", weights_only=False, mmap=True)   # mmap: the optimiser state is never read
        except (RuntimeError, TypeError): blob = torch.load(d / "optim.pt", map_location="cpu", weights_only=False)
        src = "ema" if prefer == "ema" and blob.get("ema") else "trainable"
        sd = blob[src]
        named = dict(model.named_parameters()); want = {n for n, p in named.items() if p.requires_grad}
        miss, extra = sorted(want - set(sd)), sorted(set(sd) - want)
        if miss or extra: raise SystemExit(f"init_ckpt {d}: parameter mismatch, missing {miss[:3]} (+{len(miss)}), unexpected {extra[:3]} (+{len(extra)})")
        bad = [n for n in want if tuple(named[n].shape) != tuple(sd[n].shape)]
        if bad: raise SystemExit(f"init_ckpt {d}: shape mismatch, e.g. {bad[:3]}")
        with torch.no_grad():
            for n in want: named[n].copy_(sd[n].to(named[n].device, named[n].dtype))
        n_loaded = len(want); step = blob.get("step"); del blob, sd
        info = {"source": src, "params": n_loaded, "ckpt_step": step}
        fn = "model_ema.safetensors" if src == "ema" and (d / "model_ema.safetensors").exists() else "model.safetensors"
    else:
        fn = "model_ema.safetensors" if prefer == "ema" and (d / "model_ema.safetensors").exists() else "model.safetensors"
        res = model.load_state_dict(load_file(d / fn), strict=True)
        info = {"source": fn, "result": str(res)}
    persistent = set(model.state_dict())          # non-persistent buffers (e.g. rotary inv_freq) are not in any checkpoint
    bufs = {n: b for n, b in model.named_buffers() if ".parametrizations." not in n and n in persistent}
    if bufs:
        from safetensors import safe_open
        with safe_open(str(d / fn), "pt") as f:
            keys = set(f.keys()); lost = sorted(set(bufs) - keys)
            if lost: raise SystemExit(f"init_ckpt {d}/{fn}: missing buffers {lost[:3]} (+{len(lost)})")
            with torch.no_grad():
                for n, b in bufs.items(): b.copy_(f.get_tensor(n).to(b.device, b.dtype))
        info["buffers"] = len(bufs)
    model.to(device)
    return info


class EMA:
    def __init__(self, model, decay):
        self.decay = decay
        self.shadow = {n: p.detach().clone() for n, p in model.named_parameters() if p.requires_grad}

    @torch.no_grad()
    def update(self, model, step):
        d = min(self.decay, (1 + step) / (10 + step))   # warm-up so early steps are not dominated by the init
        named = dict(model.named_parameters())
        ps = [named[n] for n in self.shadow]
        torch._foreach_lerp_(list(self.shadow.values()), [p.detach() for p in ps], 1 - d)

    def swapped(self, model): return _Swap(self, model)


class _Swap:
    def __init__(self, ema, model): self.ema, self.model = ema, model
    def __enter__(self):
        named = dict(self.model.named_parameters())
        self.backup = {n: named[n].detach().clone() for n in self.ema.shadow}
        with torch.no_grad():
            for n, t in self.ema.shadow.items(): named[n].copy_(t)
    def __exit__(self, *a):
        named = dict(self.model.named_parameters())
        with torch.no_grad():
            for n, t in self.backup.items(): named[n].copy_(t)
        del self.backup
