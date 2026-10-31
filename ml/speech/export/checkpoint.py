"""Load a Phonon-2 / ParakeetForTDT checkpoint into plain numpy arrays under HF ParakeetForTDT parameter names.

Accepts
  * a Fermion container (`model.fermion`, format fermion-five-value-parakeet-v1): five-value and int6 records are expanded
    exactly; the raw codes are kept so the decoder tables can be repacked losslessly;
  * a torch state_dict `.pt`/`.pth`/`.bin` for ParakeetForTDT (a plain dict, or {"state_dict"|"model": dict}), e.g. a fine-tune.
    A `.safetensors` file is accepted too.
"""
from __future__ import annotations

import hashlib
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fermion_container import read_container  # noqa: E402


@dataclass
class Checkpoint:
    tensors: dict                     # HF name -> float32 ndarray (pointwise convs squeezed to [O, I])
    sha256: str                       # of the checkpoint file bytes (the bundle's container_sha256)
    source: str
    raw: dict = field(default_factory=dict)   # container record name -> raw codes (five_value / intN); empty for .pt
    int4: set = field(default_factory=set)    # weight names that were 4-bit qat parametrisations in a raw state_dict


def sha256_file(path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 22), b""):
            h.update(chunk)
    return h.hexdigest()


def _squeeze_pointwise(k: str, a: np.ndarray) -> np.ndarray:
    if a.ndim == 3 and a.shape[2] == 1 and re.search(r"\.conv\.pointwise_conv[12]\.weight$", k):
        return a[:, :, 0]
    return a


def load_checkpoint(path: str) -> Checkpoint:
    p = Path(path)
    sha = sha256_file(p)
    with open(p, "rb") as f:
        head = f.read(8)
    is_container = False
    if p.suffix == ".fermion":
        is_container = True
    elif p.suffix not in (".pt", ".pth", ".bin", ".safetensors"):
        # sniff: container = 8-byte length + JSON header with our format string
        with open(p, "rb") as f:
            n = int.from_bytes(f.read(8), "little")
            is_container = 0 < n < (1 << 28) and b"fermion-five-value-parakeet" in f.read(min(n, 4096))
    if is_container:
        tensors, _idx, raw = read_container(str(p), with_raw=True)
        out = {}
        for k, v in tensors.items():
            if k.endswith("num_batches_tracked"):
                continue
            out[k] = _squeeze_pointwise(k, np.ascontiguousarray(v.astype(np.float32)))
        return Checkpoint(out, sha, str(p), raw)
    if p.suffix == ".safetensors":
        from safetensors.numpy import load_file
        sd = load_file(str(p))
    else:
        import torch
        sd = torch.load(str(p), map_location="cpu", weights_only=True)
        for key in ("state_dict", "model"):
            if isinstance(sd, dict) and key in sd and isinstance(sd[key], dict):
                sd = sd[key]
        sd = {k: v.detach().float().numpy() for k, v in sd.items() if hasattr(v, "detach")}
    sd = {re.sub(r"^(model|module)\.", "", k): np.asarray(v, np.float32) for k, v in sd.items()}
    int4: set = set()
    sd = _project_qat(sd, int4)
    out = {}
    for k, v in sd.items():
        if k.endswith("num_batches_tracked"):
            continue
        out[k] = _squeeze_pointwise(k, np.ascontiguousarray(np.asarray(v, dtype=np.float32)))
    return Checkpoint(out, sha, str(p), {}, int4)


def _project_qat(sd: dict, int4: set | None = None) -> dict:
    """A state_dict saved from a model trained with qat.py (torch parametrizations) holds the latent weight
    `<m>.parametrizations.weight.original` and per-row `<m>.parametrizations.weight.0.lo/hi`; replace those by the projected
    five-value weight `<m>.weight` (nearest of {0, +-lo, +-hi}, thresholds lo/2 and (lo+hi)/2), exactly qat.FiveValue.forward."""
    suffix = ".parametrizations.weight.original"
    for k in [k for k in sd if k.endswith(suffix)]:
        base = k[: -len(suffix)]
        w = sd.pop(k)
        if base + ".parametrizations.weight.0.lut" in sd:         # lut4 grid (Lut4Group): nearest of 16 learned fp16 entries per 16 rows
            from precision import quantize_lut4_groups
            sd[base + ".weight"] = quantize_lut4_groups(w.reshape(w.shape[0], -1), sd.pop(base + ".parametrizations.weight.0.lut")).reshape(w.shape)
            if int4 is not None:
                int4.add(base + ".weight")
            continue
        if base + ".parametrizations.weight.0.scale" in sd:      # 4-bit layer (train/modes.py Int4Group): s_g * clip(round(w/s_g), -8, 7)
            from precision import quantize_int4_groups
            sd[base + ".weight"] = quantize_int4_groups(w.reshape(w.shape[0], -1), sd.pop(base + ".parametrizations.weight.0.scale")).reshape(w.shape)
            if int4 is not None:
                int4.add(base + ".weight")
            continue
        lo = np.abs(sd.pop(base + ".parametrizations.weight.0.lo")).reshape(-1, *([1] * (w.ndim - 1)))
        hi = np.abs(sd.pop(base + ".parametrizations.weight.0.hi")).reshape(-1, *([1] * (w.ndim - 1)))
        a = np.abs(w)
        mag = np.where(a < (lo + hi) * 0.5, lo, hi)
        mag = np.where(a < lo * 0.5, 0.0, mag)
        sd[base + ".weight"] = (np.copysign(mag, w)).astype(np.float32)
    return sd


def check_complete(t: dict, layers: int = 24) -> None:
    need = ["encoder.subsampling.linear.weight", "encoder_projector.weight", "joint.head.weight", "decoder.embedding.weight"]
    miss = [k for k in need if k not in t]
    for L in range(layers):
        for suffix in ("feed_forward1.linear1.weight", "self_attn.relative_k_proj.weight", "conv.norm.running_var",
                       "norm_out.weight", "self_attn.bias_u"):
            k = f"encoder.layers.{L}.{suffix}"
            if k not in t:
                miss.append(k)
    if miss:
        raise SystemExit(f"checkpoint is missing {len(miss)} tensors, e.g. {miss[:4]}")
