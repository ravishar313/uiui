"""Rebuild an init_ckpt-loadable dir (optim.pt with ema/trainable) from model_ema.safetensors + qat_scales for a QAT checkpoint saved without optim.pt.
original latent := folded (already 4-bit) weight; lut := saved bits4_lut.  Originals are symlinked, never modified."""
import sys, os, torch
from pathlib import Path
from safetensors import safe_open
src, dst = Path(sys.argv[1]), Path(sys.argv[2]); dst.mkdir(parents=True, exist_ok=True)
for f in src.iterdir():
    if f.name != "optim.pt" and not (dst / f.name).exists(): os.symlink(f, dst / f.name)
sd = {}
with safe_open(str(src / "model_ema.safetensors"), "pt") as f: w = {k: f.get_tensor(k) for k in f.keys()}
with safe_open(str(src / "qat_scales.safetensors"), "pt") as f: q = {k: f.get_tensor(k) for k in f.keys()}
names = sys.argv[3].split(",") if len(sys.argv) > 3 else None
ref = torch.load(sys.argv[4], map_location="cpu", weights_only=False, mmap=True)["ema"] if len(sys.argv) > 4 else None
keys = list(ref) if ref is not None else None
import json; keys = keys or json.load(open(sys.argv[3]))
for n in keys:
    if ".parametrizations.weight.original" in n: sd[n] = w[n.replace(".parametrizations.weight.original", ".weight")]
    elif ".parametrizations.weight.0.lut" in n: sd[n] = q[n.replace(".parametrizations.weight.0.lut", ".bits4_lut")]
    else: sd[n] = w[n]
torch.save({"ema": sd, "trainable": sd, "step": None}, dst / "optim.pt")
if ref is not None:
    lut_d = max((sd[n].float() - ref[n].float()).abs().max().item() for n in keys if n.endswith(".0.lut"))
    oth_d = max((sd[n].float() - ref[n].float()).abs().max().item() for n in keys if ".parametrizations." not in n)
    print("lut maxdiff", lut_d, "non-qat maxdiff", oth_d)
print("wrote", dst / "optim.pt", len(sd))
