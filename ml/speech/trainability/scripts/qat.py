"""Five-value quantisation-aware training for Phonon-2's 264 encoder linears.

Each row r holds values in {0, ±lo_r, ±hi_r}. A latent fp32 weight is projected to that alphabet in every forward pass
(nearest value; thresholds lo/2 and (lo+hi)/2), gradients reach the latent weight straight-through and reach lo/hi
through the masked magnitudes (LSQ-style). Initialised from the container, the projection is the identity, so step 0
reproduces Phonon-2 exactly.
"""
import torch
from torch import nn
from torch.nn.utils import parametrize


class FiveValue(nn.Module):
    def __init__(self, lo, hi, shape):
        super().__init__()
        extra = (1,) * (len(shape) - 1)
        self.lo = nn.Parameter(lo.float().reshape(-1, *extra).clone())
        self.hi = nn.Parameter(hi.float().reshape(-1, *extra).clone())

    def forward(self, w):
        lo, hi = self.lo.abs(), self.hi.abs()
        a = w.detach().abs()
        mag = torch.where(a < (lo + hi) * 0.5, lo, hi)
        mag = torch.where(a < lo * 0.5, torch.zeros_like(mag), mag)
        return torch.copysign(mag, w.detach()) + (w - w.detach())


def apply_qat(model, raw):
    """raw: read_container(with_raw=True)[2]; attaches FiveValue to every five-value module."""
    n = 0
    for name, r in raw.items():
        if "sign" not in r: continue
        mod = model.get_submodule(name)
        parametrize.register_parametrization(mod, "weight", FiveValue(torch.from_numpy(r["lo"]).to(mod.weight.device), torch.from_numpy(r["hi"]).to(mod.weight.device), mod.weight.shape))
        n += 1
    return n


def export_five_value(mod):
    """-> (sign int8, is_hi bool, lo, hi) for a parametrised module, i.e. what the container / Core ML LUT stores."""
    with torch.no_grad():
        p = mod.parametrizations.weight; w = p.original; f = p[0]
        q = f(w)
        lo, hi = f.lo.abs().reshape(-1), f.hi.abs().reshape(-1)
        return torch.sign(q).to(torch.int8), (q.abs() >= (lo + hi).reshape(-1, *(1,) * (q.dim() - 1)) * 0.5), lo, hi
