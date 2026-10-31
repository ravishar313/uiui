"""Opt-in int6 fake-quant of the decoder/joint matrices exactly as export/decoder_bin.py writes them (qat.decoder_int6: true).

Forward: per-row symmetric int6, scale = fp16(absmax/31), q = clip(rint(w/scale), -31, 31), w_q = q*scale (fp32); biases round-trip fp16.
Backward: straight-through to the latent fp32 weight (scale treated as a constant).  Parameter names, state_dict and checkpoints are
unchanged (the latent fp32 weights are saved; export quantises them as before).  Implemented by swapping the class of the existing modules
so that every reader of `.weight` (nn.Linear, F.embedding, fast_tdt's head.weight, tdt_decode's LSTM steps) sees the quantised value.
Matrices must stay in sync with export/decoder_bin.py MATRICES / BIASES."""
from __future__ import annotations
import torch
import torch.nn.functional as F
from torch import nn

MATRICES = ["decoder.embedding.weight", "decoder.lstm.weight_ih_l0", "decoder.lstm.weight_hh_l0", "decoder.lstm.weight_ih_l1",
            "decoder.lstm.weight_hh_l1", "decoder.decoder_projector.weight", "joint.head.weight"]
BIASES = ["decoder.lstm.bias_ih_l0", "decoder.lstm.bias_hh_l0", "decoder.lstm.bias_ih_l1", "decoder.lstm.bias_hh_l1",
          "decoder.decoder_projector.bias", "joint.head.bias"]


def fq_int6(w: torch.Tensor) -> torch.Tensor:
    """Bit-exact (fp32) mirror of decoder_bin.quantize_rows + dequantise; STE to w."""
    w32 = w.float()
    with torch.no_grad():
        scale = (w32.abs().amax(dim=1) / 31.0).half()
        s = scale.float().clamp_min(1e-12)[:, None]
        deq = torch.clamp(torch.round(w32 / s), -31, 31) * scale.float()[:, None]
    return w32 + (deq - w32).detach()


def fq_fp16(b: torch.Tensor) -> torch.Tensor:
    b32 = b.float()
    return b32 + (b32.half().float() - b32).detach()


class _Int6Linear(nn.Linear):
    def forward(self, x):
        return F.linear(x, fq_int6(self._parameters["weight"]), fq_fp16(self._parameters["bias"]))

    @property
    def weight(self): return fq_int6(self._parameters["weight"])   # readers that bypass forward (fast_tdt: head.weight)

    @property
    def bias(self): return fq_fp16(self._parameters["bias"])


class _Int6Embedding(nn.Embedding):
    def forward(self, ids):
        return F.embedding(ids, fq_int6(self._parameters["weight"]), self.padding_idx, self.max_norm, self.norm_type, self.scale_grad_by_freq, self.sparse)

    @property
    def weight(self): return fq_int6(self._parameters["weight"])


class _Int6LSTM(nn.LSTM):
    def forward(self, input, hx=None):
        assert input.dim() == 3 and self.proj_size == 0 and not self.bidirectional
        p = self._parameters
        flat = []
        for l in range(self.num_layers):
            flat += [fq_int6(p[f"weight_ih_l{l}"]), fq_int6(p[f"weight_hh_l{l}"]), fq_fp16(p[f"bias_ih_l{l}"]), fq_fp16(p[f"bias_hh_l{l}"])]
        if hx is None:
            z = input.new_zeros(self.num_layers, input.shape[0] if self.batch_first else input.shape[1], self.hidden_size)
            hx = (z, z)
        out = torch._VF.lstm(input, hx, flat, True, self.num_layers, self.dropout, self.training, False, self.batch_first)
        return out[0], (out[1], out[2])


def apply_decoder_int6(model, log=print):
    """Swap the classes of model.decoder.{embedding,lstm,decoder_projector} and model.joint.head in place."""
    d, j = model.decoder, model.joint
    d.embedding.__class__ = _Int6Embedding
    d.lstm.__class__ = _Int6LSTM
    d.decoder_projector.__class__ = _Int6Linear
    j.head.__class__ = _Int6Linear
    log("decoder_int6: fake-quant (per-row int6, fp16 scale, fp16 biases) on " + ", ".join(MATRICES))
