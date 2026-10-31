"""Five-value (0, +-lo, +-hi per output row) structure: detection, requantisation (snap), per-layer error."""
from __future__ import annotations

import re

import numpy as np

LINEAR_RE = re.compile(r"^encoder\.layers\.(\d+)\.(feed_forward[12]\.linear[12]|self_attn\.(q|k|v|o|relative_k)_proj|conv\.pointwise_conv[12])\.weight$")


def linear_names(tensors: dict) -> list:
    return sorted((k for k in tensors if LINEAR_RE.match(k)), key=lambda k: (int(LINEAR_RE.match(k).group(1)), k))


def row_is_five_value(w: np.ndarray) -> np.ndarray:
    """[O] bool: the row, rounded to fp16, holds only {0, +-lo, +-hi} (|nonzero| takes <= 2 distinct values)."""
    a = np.abs(w.astype(np.float16)).astype(np.float32)
    big = np.where(a > 0, a, np.inf)
    lo = big.min(axis=1)
    rest = np.where((a > 0) & (a != lo[:, None]), a, np.inf)
    hi = rest.min(axis=1)
    other = (a > 0) & (a != lo[:, None]) & (a != np.where(np.isfinite(hi), hi, 0)[:, None])
    return ~other.any(axis=1)


def snap_rows(w: np.ndarray, iters: int = 40):
    """Snap each row of w [O, I] to {0, +-lo, +-hi}: Lloyd's algorithm on |w| with the centre 0 fixed (3 clusters), lo/hi
    rounded to fp16.  Rows are sorted once so every iteration is O(log I) through prefix sums; 25 starts (zero fraction x
    large-cluster fraction) per row, the lowest squared error wins.  Thresholds are the QAT projector's (lo/2, (lo+hi)/2).
    Returns (snapped float32 [O, I], lo [O], hi [O])."""
    import torch
    w = np.asarray(w, np.float32)
    a = torch.from_numpy(np.abs(w))
    O, I = a.shape
    srt, _ = torch.sort(a, dim=1)
    z = torch.zeros(O, 1)
    cs = torch.cat([z, torch.cumsum(srt.double(), 1)], 1)          # prefix sums, [O, I+1]
    cq = torch.cat([z, torch.cumsum(srt.double() ** 2, 1)], 1)

    def stats(lo, hi):
        n0 = torch.searchsorted(srt, (lo * 0.5)[:, None].contiguous()).squeeze(1)
        n1 = torch.searchsorted(srt, ((lo + hi) * 0.5)[:, None].contiguous()).squeeze(1)
        g = lambda t, n: t.gather(1, n[:, None]).squeeze(1)
        s_lo, s_hi = g(cs, n1) - g(cs, n0), g(cs, torch.full_like(n1, I)) - g(cs, n1)
        c_lo, c_hi = (n1 - n0), (I - n1)
        return n0, n1, s_lo, s_hi, c_lo, c_hi

    best_cost = torch.full((O,), float("inf"), dtype=torch.float64)
    best = (torch.zeros(O), torch.ones(O))
    for zf in (0.3, 0.4, 0.5, 0.6, 0.7):
        for hf in (0.05, 0.1, 0.2, 0.3, 0.4):
            lo = srt[:, int(min(zf + (1 - zf - hf) / 2, 0.999) * (I - 1))].double()
            hi = srt[:, int((1 - hf / 2) * (I - 1))].double()
            lo = torch.clamp(lo, min=1e-9); hi = torch.maximum(hi, lo * 1.01)
            for _ in range(iters):
                n0, n1, s_lo, s_hi, c_lo, c_hi = stats(lo, hi)
                lo = torch.where(c_lo > 0, s_lo / c_lo.clamp(min=1), lo)
                hi = torch.where(c_hi > 0, s_hi / c_hi.clamp(min=1), hi)
            lo = lo.float().half().float().double(); hi = hi.float().half().float().double()
            n0, n1, s_lo, s_hi, c_lo, c_hi = stats(lo, hi)
            g = lambda t, n: t.gather(1, n[:, None]).squeeze(1)
            q0 = g(cq, n0)
            q_lo = g(cq, n1) - g(cq, n0)
            q_hi = g(cq, torch.full_like(n1, I)) - g(cq, n1)
            cost = q0 + (q_lo - 2 * lo * s_lo + c_lo * lo * lo) + (q_hi - 2 * hi * s_hi + c_hi * hi * hi)
            better = cost < best_cost
            best_cost = torch.where(better, cost, best_cost)
            best = (torch.where(better, lo.float(), best[0]), torch.where(better, hi.float(), best[1]))
    lo, hi = best
    mag = torch.where(a >= ((lo + hi) * 0.5)[:, None], hi[:, None], torch.where(a >= (lo * 0.5)[:, None], lo[:, None], torch.zeros(())))
    out = (torch.sign(torch.from_numpy(w)) * mag).numpy().astype(np.float32)
    return out, lo.numpy(), hi.numpy()


def requantize(tensors: dict, log=print, skip=()):
    """Snap every encoder linear row that is not already five-value.  Rows that already conform are left bit-identical.
    Returns a report {name: {"rows_snapped", "rel_err", ...}} and mutates `tensors`."""
    report = {}
    for k in linear_names(tensors):
        if k in skip:                     # 4-bit layers (precision.py) keep their int4 grid
            continue
        w = tensors[k]
        ok = row_is_five_value(w)
        entry = {"rows": int(w.shape[0]), "rows_already_five_value": int(ok.sum()), "rows_snapped": int((~ok).sum())}
        if (~ok).any():
            snapped, _lo, _hi = snap_rows(w[~ok])
            new = w.copy()
            new[~ok] = snapped
            err = float(np.linalg.norm(new - w) / max(np.linalg.norm(w), 1e-12))
            entry["rel_err"] = err
            entry["zero_frac"] = float((new == 0).mean())
            tensors[k] = new
        else:
            entry["rel_err"] = 0.0
        report[k] = entry
    snapped_layers = [k for k, v in report.items() if v["rows_snapped"]]
    errs = [report[k]["rel_err"] for k in snapped_layers]
    log(f"requantize: snapped {sum(v['rows_snapped'] for v in report.values())} rows in {len(snapped_layers)}/{len(report)} layers"
        + (f"; rel. L2 error mean {np.mean(errs):.4f} max {np.max(errs):.4f}" if errs else ""))
    return report


def non_five_value_layers(tensors: dict, skip=()) -> dict:
    out = {}
    for k in linear_names(tensors):
        if k in skip:
            continue
        ok = row_is_five_value(tensors[k])
        if not ok.all():
            out[k] = int((~ok).sum())
    return out
