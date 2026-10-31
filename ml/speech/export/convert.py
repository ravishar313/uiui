"""torch encoder function -> Core ML mlprogram (fp16 compute, fp32 I/O) -> exact five-value compression."""
from __future__ import annotations

import time
import warnings

import numpy as np
import torch

warnings.filterwarnings("ignore")
import coremltools as ct  # noqa: E402
import coremltools.optimize.coreml as cto  # noqa: E402

from encoder_graph import EncoderFn, example_inputs, frames_for, sub_len  # noqa: E402
from precision import hf_to_const  # noqa: E402

DENSE_KEEP = ("sub_lin_w",)           # large but not five-value (container int6): stays dense fp16, as shipped
MIN_ELEMS = 1_000_000                 # every five-value linear has >= 2^20 elements; everything else is smaller


def convert_function(g: dict, seconds: float, with_pos: bool, log=print):
    fn = EncoderFn(g, seconds, with_pos).eval()
    ex = example_inputs(seconds, with_pos)
    names = ["mel", "m1", "m2", "m3", "kmask"] + (["pos"] if with_pos else [])
    t0 = time.time()
    with torch.no_grad():
        traced = torch.jit.trace(fn, tuple(ex), check_trace=False)
    log(f"  traced {seconds:g}s in {time.time() - t0:.1f}s")
    t0 = time.time()
    ml = ct.convert(traced, inputs=[ct.TensorType(name=n, shape=tuple(e.shape), dtype=np.float32) for n, e in zip(names, ex)],
                    outputs=[ct.TensorType(name="enc", dtype=np.float32)], minimum_deployment_target=ct.target.macOS15,
                    compute_precision=ct.precision.FLOAT16, convert_to="mlprogram")
    log(f"  converted {seconds:g}s in {time.time() - t0:.1f}s")
    return ml


def _kmeans_lut(flat, nz, k=64, iters=12):
    """Lossy fallback: 1-D k-means (64 centres, fp16) over the non-zero values of one 16-row group."""
    vals = flat[flat != 0].astype(np.float32)
    srt = np.sort(vals)
    cent = srt[np.linspace(0, len(srt) - 1, k).astype(int)].astype(np.float64)
    for _ in range(iters):
        cent = np.unique(cent)
        mids = (cent[1:] + cent[:-1]) / 2
        lab = np.searchsorted(mids, vals)
        sums = np.bincount(lab, weights=vals, minlength=len(cent))
        cnt = np.bincount(lab, minlength=len(cent))
        cent = np.where(cnt > 0, sums / np.maximum(cnt, 1), cent)
    cent = np.unique(cent.astype(np.float16).astype(np.float32))
    lut = np.zeros(64, np.float16)
    lut[: len(cent)] = cent[:64]
    mids = (cent[1:] + cent[:-1]) / 2
    idx = np.where(flat != 0, np.searchsorted(mids, flat.astype(np.float32)), 0)
    return lut, idx.astype(np.uint8)


def make_lut_fn(allow_lossy: bool):
    def lut_fn(val):
        """LUT for one group of 16 output rows (dense view incl. zeros): <= 64 distinct non-zero values -> uint6 indices into a
        64-entry fp16 LUT.  Zeros are carried by the sparse mask, not by LUT entries (index 0 is a placeholder for them)."""
        flat = np.ascontiguousarray(val).reshape(-1)
        nz = np.unique(flat[flat != 0].astype(np.float32))      # fp32: np.unique on float16 returns duplicates in numpy 2.4.6
        if len(nz) > 64:
            if allow_lossy:
                return _kmeans_lut(flat, nz)
            raise ValueError(f"{len(nz)} distinct non-zero values in a 16-row group (> 64): tensor is not five-value")
        lut = np.zeros(64, dtype=val.dtype)
        lut[: len(nz)] = nz
        idx = np.searchsorted(nz, flat.astype(np.float32)) if len(nz) else np.zeros(flat.shape, np.int64)
        idx = np.where(flat != 0, np.minimum(idx, max(len(nz) - 1, 0)), 0)
        return lut, idx.astype(np.uint8)
    return lut_fn


def make_lut4_fn():
    def lut_fn(val):
        """4-bit LUT for one group of 16 output rows: <= 16 distinct values (zero is an ordinary entry; no sparse mask) ->
        uint4 indices into a 16-entry fp16 LUT.  Same call shape / return layout as the 6-bit lut_fn above."""
        flat = np.ascontiguousarray(val).reshape(-1).astype(np.float32)      # NB: np.unique on float16 is wrong in numpy 2.4.6; fp32 is exact
        vals = np.unique(flat)
        if len(vals) > 16:
            raise ValueError(f"{len(vals)} distinct values in a 16-row group (> 16): tensor is not on the int4 grid")
        lut = np.zeros(16, dtype=val.dtype)
        lut[: len(vals)] = vals.astype(val.dtype)
        return lut, np.searchsorted(vals, flat).astype(np.uint8)
    return lut_fn


def compress(ml, log=print, allow_lossy=False, bits4=()):
    """Prune exact zeros (1-bit mask) and palettise the non-zeros per 16 output rows into a 64-entry fp16 LUT with uint6
    indices (the shipped layout).  Lossless iff every 16-row group holds <= 64 distinct non-zero values (five-value
    rows hold 4); verify.py checks the stored result against the source weights."""
    t0 = time.time()
    skip = {n: None for n in _const_names(ml, DENSE_KEEP)}
    prune_skip, pal_cfgs = dict(skip), dict(skip)
    if bits4:      # mixed precision: no zero-mask; "custom" mode takes nbits from the LUT size (16 entries -> uint4)
        found = _exact_const_names(ml, [hf_to_const(n) for n in bits4])
        missing = {c for c in (hf_to_const(n) for n in bits4) if "_relk_w_" not in c} - set(found)   # relative_k_proj is a folded constant in functions without `pos`
        if missing:
            raise RuntimeError(f"4-bit layers not found as consts in the program: {sorted(missing)[:3]}")
        for n in found:
            prune_skip[n] = None
            pal_cfgs[n] = cto.OpPalettizerConfig(mode="custom", lut_function=make_lut4_fn(), granularity="per_grouped_channel",
                                                 group_size=16, weight_threshold=MIN_ELEMS)
    prune = cto.OptimizationConfig(global_config=cto.OpThresholdPrunerConfig(threshold=1e-7, minimum_sparsity_percentile=0.0, weight_threshold=MIN_ELEMS),
                                   op_name_configs=prune_skip)
    sp = cto.prune_weights(ml, prune)
    pal = cto.OptimizationConfig(global_config=cto.OpPalettizerConfig(mode="custom", lut_function=make_lut_fn(allow_lossy), granularity="per_grouped_channel",
                                                                     group_size=16, weight_threshold=MIN_ELEMS),
                                 op_name_configs=pal_cfgs)
    out = cto.palettize_weights(sp, pal, joint_compression=True)
    log(f"  compressed in {time.time() - t0:.1f}s")
    return out


def _exact_const_names(ml, names):
    want = set(names)
    p = ml.get_spec().mlProgram
    f = p.functions["main"]
    return [o.outputs[0].name for o in f.block_specializations[f.opset].operations if o.type == "const" and o.outputs[0].name in want]


def _const_names(ml, needles):
    p = ml.get_spec().mlProgram
    f = p.functions["main"]
    ops = f.block_specializations[f.opset].operations
    out = []
    for o in ops:
        if o.type == "const":
            nm = o.outputs[0].name
            if any(n in nm for n in needles):
                out.append(nm)
    return out
