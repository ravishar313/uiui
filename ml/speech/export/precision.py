"""Mixed-precision bookkeeping: which encoder linears are 4-bit (instead of five-value), and the exact 4-bit grid.

4-bit scheme ("int4-g16"): output rows are grouped in blocks of 16 (rows 16g..16g+15, all input columns).  Every group has one
learnable scale s_g and the weight is  w = s_g * q  with integer q in [-8, 7].  That is at most 16 distinct values per group, so
it is stored by the *same* Core ML mechanism the 6-bit tensors use: `palettize_weights(mode="custom", granularity=
"per_grouped_channel", group_size=16)` -> one fp16 LUT per 16 output rows (constexpr_lut_to_dense, iOS18 / macOS15 opset), with
nbits=4 -> 16 LUT entries, uint4 indices.  No zero-mask (pruning) for these layers: a mask costs 1 bit/weight, a 4-bit index 4.

How a checkpoint says which layers are 4-bit (`detect_bits4`, first match wins):
  1. `precision.json` next to the weights:  {"format": "uiui-precision-v1", "bits4": ["encoder.layers.3.feed_forward1.linear1.weight", ...]}
  2. `qat_scales.safetensors` next to the weights (train/ckpt.py already writes it in qat mode; modes.qat_scales adds a
     `<module>.bits4_scale` (int4 grid) or `<module>.bits4_lut` (lut4 grid) entry per 4-bit layer)  -> no train.py change needed;
  3. the weights themselves: a linear that is not five-value but has <= 16 distinct fp16 values in every 16-row group.
     (A raw state_dict with qat parametrisations is projected by checkpoint._project_qat and reported through (3)'s result.)
Whatever the source, export re-checks the <= 16 values per group property and refuses otherwise.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

import numpy as np

GROUP = 16
NBITS = 4
QMIN, QMAX = -8, 7
FORMAT = "uiui-precision-v1"

# HF weight name -> (layer, attribute used in the Core ML const names `blocks_<L>_<attr>_to_fp16`)
_HF_ATTR = [
    (re.compile(r"^encoder\.layers\.(\d+)\.feed_forward1\.linear1\.weight$"), "ff1_l1"),
    (re.compile(r"^encoder\.layers\.(\d+)\.feed_forward1\.linear2\.weight$"), "ff1_l2"),
    (re.compile(r"^encoder\.layers\.(\d+)\.feed_forward2\.linear1\.weight$"), "ff2_l1"),
    (re.compile(r"^encoder\.layers\.(\d+)\.feed_forward2\.linear2\.weight$"), "ff2_l2"),
    (re.compile(r"^encoder\.layers\.(\d+)\.self_attn\.q_proj\.weight$"), "att_q"),
    (re.compile(r"^encoder\.layers\.(\d+)\.self_attn\.k_proj\.weight$"), "att_k"),
    (re.compile(r"^encoder\.layers\.(\d+)\.self_attn\.v_proj\.weight$"), "att_v"),
    (re.compile(r"^encoder\.layers\.(\d+)\.self_attn\.o_proj\.weight$"), "att_o"),
    (re.compile(r"^encoder\.layers\.(\d+)\.self_attn\.relative_k_proj\.weight$"), "relk_w"),
    (re.compile(r"^encoder\.layers\.(\d+)\.conv\.pointwise_conv1\.weight$"), "pw1"),
    (re.compile(r"^encoder\.layers\.(\d+)\.conv\.pointwise_conv2\.weight$"), "pw2"),
]


def hf_to_const(name: str) -> str:
    """'encoder.layers.3.feed_forward1.linear1.weight' -> 'blocks_3_ff1_l1_to_fp16' (the fp16 const in the Core ML program)."""
    for rx, attr in _HF_ATTR:
        m = rx.match(name)
        if m:
            return f"blocks_{int(m.group(1))}_{attr}_to_fp16"
    raise KeyError(f"{name} is not an encoder linear")


def hf_to_graph_key(name: str) -> str:
    """-> encoder_graph / verify key, e.g. 'b3.ff1.l1'."""
    from verify import ATTR_TO_KEY
    for rx, attr in _HF_ATTR:
        m = rx.match(name)
        if m:
            return f"b{int(m.group(1))}.{ATTR_TO_KEY[attr]}"
    raise KeyError(name)


# ---- the grid ----------------------------------------------------------------------------------------------------
def group_values(w: np.ndarray) -> np.ndarray:
    """[O, I] -> [O/16, 16*I] (rows 16g..16g+15 of group g)."""
    assert w.shape[0] % GROUP == 0, f"{w.shape[0]} output rows is not a multiple of {GROUP}"
    return w.reshape(w.shape[0] // GROUP, -1)


def max_group_levels(w: np.ndarray) -> int:
    """Largest number of distinct fp16 values in any 16-row group of w [O, I]."""
    g = np.sort(group_values(np.asarray(w, np.float32).astype(np.float16)).astype(np.float32), axis=1)
    return int((np.diff(g, axis=1) != 0).sum(axis=1).max() + 1)


def is_int4_grouped(w: np.ndarray) -> bool:
    return w.ndim == 2 and w.shape[0] % GROUP == 0 and max_group_levels(w) <= 1 << NBITS


def quantize_int4_groups(w: np.ndarray, scale: np.ndarray) -> np.ndarray:
    """w [O, I], scale [O/16] -> s * clip(round(w / s), -8, 7) (float32), the training-time projection (round half to even)."""
    s = np.repeat(np.abs(np.asarray(scale, np.float32)), GROUP)[:, None]
    return (np.clip(np.rint(w / s), QMIN, QMAX) * s).astype(np.float32)


def quantize_lut4_groups(w: np.ndarray, lut: np.ndarray) -> np.ndarray:
    """w [O, I], lut [O/16, 16] -> nearest LUT entry per weight (lut rounded to fp16 first, as in training and in the Core ML LUT)."""
    l = np.sort(np.asarray(lut, np.float32).astype(np.float16).astype(np.float32), axis=1)
    g = group_values(np.asarray(w, np.float32))
    out = np.empty_like(g)
    for i in range(len(g)):
        mid = (l[i, 1:] + l[i, :-1]) * 0.5
        out[i] = l[i][np.searchsorted(mid, g[i])]
    return out.reshape(w.shape)


def fit_scales(w: np.ndarray, iters: int = 20) -> np.ndarray:
    """Per-group MSE-optimal scale for the int4 grid (grid search over absmax/{8..} multipliers, then alternating LS refinement)."""
    g = group_values(np.asarray(w, np.float32)).astype(np.float64)
    amax = np.abs(g).max(axis=1).clip(1e-12)
    best = np.full(len(g), np.inf)
    scale = amax / 8
    for mult in np.linspace(0.35, 1.0, 66):
        s = (amax * mult / 7.5)[:, None]
        err = ((np.clip(np.rint(g / s), QMIN, QMAX) * s - g) ** 2).sum(1)
        better = err < best
        best, scale = np.where(better, err, best), np.where(better, s[:, 0], scale)
    for _ in range(iters):
        q = np.clip(np.rint(g / scale[:, None]), QMIN, QMAX)
        den = (q * q).sum(1)
        scale = np.where(den > 0, (q * g).sum(1) / np.maximum(den, 1e-12), scale).clip(1e-12)
    return scale.astype(np.float32)


def requantize_int4(tensors: dict, log=print) -> dict:
    """PTQ: snap every encoder linear to int4-g16 with MSE-optimal group scales (torch, same algorithm as train/modes.fit_int4_scales).
    Mutates `tensors`; returns the linear names."""
    import torch
    from fivevalue import linear_names
    names, errs = linear_names(tensors), []
    for k in names:
        w = torch.from_numpy(np.asarray(tensors[k], np.float32))
        g = w.reshape(w.shape[0] // GROUP, -1).double()
        amax = g.abs().amax(1).clamp_min(1e-12)
        best = torch.full_like(amax, float("inf")); scale = amax / 8
        for mult in torch.linspace(0.35, 1.0, 66, dtype=torch.float64):
            s = (amax * mult / 7.5)[:, None]
            err = ((((g / s).round().clamp(QMIN, QMAX)) * s - g) ** 2).sum(1)
            better = err < best
            best = torch.where(better, err, best); scale = torch.where(better, s[:, 0], scale)
        for _ in range(20):
            q = (g / scale[:, None]).round().clamp(QMIN, QMAX)
            den = (q * q).sum(1)
            scale = torch.where(den > 0, (q * g).sum(1) / den.clamp_min(1e-12), scale).clamp_min(1e-12)
        out = quantize_int4_groups(w.numpy(), scale.float().numpy())
        errs.append(float(np.linalg.norm(out - w.numpy()) / max(np.linalg.norm(w.numpy()), 1e-12)))
        tensors[k] = out
    log(f"requantize-int4: snapped {len(names)} linears; rel. L2 error mean {np.mean(errs):.4f} max {np.max(errs):.4f}")
    return names


# ---- detection / sidecar -----------------------------------------------------------------------------------------
def write_precision_json(path, bits4) -> None:
    Path(path).write_text(json.dumps({"format": FORMAT, "bits4": sorted(bits4)}, indent=1))


def detect_bits4(tensors: dict, ckpt_path: str | None, extra: set | None = None, log=print) -> dict:
    """-> {weight name: source}.  See module docstring for the order.  `extra`: names already known from a raw state_dict."""
    from fivevalue import linear_names, row_is_five_value
    names = set(linear_names(tensors))
    found: dict = {}
    d = Path(ckpt_path).resolve().parent if ckpt_path else None
    pj = d / "precision.json" if d else None
    if pj is not None and pj.exists():
        spec = json.loads(pj.read_text())
        assert spec.get("format") == FORMAT, f"{pj}: unknown format {spec.get('format')}"
        found = {n: "precision.json" for n in spec["bits4"]}
    elif d is not None and (d / "qat_scales.safetensors").exists():
        from safetensors import safe_open
        with safe_open(str(d / "qat_scales.safetensors"), "numpy") as f:
            found = {k.rsplit(".bits4_", 1)[0] + ".weight": "qat_scales.safetensors" for k in f.keys() if k.endswith((".bits4_scale", ".bits4_lut"))}
    for n in extra or ():
        found.setdefault(n, "state_dict parametrisation")
    if not found and not (pj is not None and pj.exists()):
        for n in sorted(names):                       # (3) from the weights
            w = tensors[n]
            if not row_is_five_value(w).all() and is_int4_grouped(w):
                found[n] = "weights (<= 16 values per 16-row group)"
    unknown = sorted(set(found) - names)
    if unknown:
        raise SystemExit(f"bits4 layers not in the checkpoint's encoder linears: {unknown[:3]}")
    for n in sorted(found):
        lv = max_group_levels(tensors[n])
        if lv > 1 << NBITS:
            raise SystemExit(f"{n} is listed as 4-bit but a 16-row group holds {lv} distinct values (> 16)")
    if found:
        log(f"4-bit layers: {len(found)} ({', '.join(sorted(set(found.values())))})")
    return found
