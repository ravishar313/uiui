"""Phonon-2 encoder as a traceable torch module with the Core ML bundle's runtime interface.

Inputs (all float32, as the shipped bundle): mel [1,128,T] normalised log-mel zero padded to the function length;
m1 [1,1,T1,1], m2 [1,1,T2,1], m3 [1,1,T3,1] frame masks after each stride-2 conv; kmask [1,1,1,T3] additive key mask
(0 / -1e4); pos [1,2*T3-1,1024] relative-position table (only functions with `with_pos`).  Output enc [1,T3,640].

Numerical conventions reproduced from the shipped model (derived from its constants):
  * the residual stream is carried divided by RESIDUAL_SCALE (64) so it fits fp16: the subsampling linear, every
    residual-writing linear (ff linear2 with its 0.5, attention o_proj, conv pointwise2) and every norm_out except the
    last are multiplied by 1/64.  Every consumer is a LayerNorm, which is scale invariant.  1/64 and 0.5/64 are powers
    of two, so the scaling is exact in fp16 and keeps five-value LUTs exact;
  * BatchNorm is folded into the depthwise conv, convolution biases are absent (zeros);
  * relative-position keys relative_k_proj(pos) are constants for functions without `pos` (a centred slice of the
    15 s table), an in-graph linear on the `pos` input otherwise.
"""
from __future__ import annotations

import math

import numpy as np
import torch
import torch.nn.functional as F
from torch import nn

RESIDUAL_SCALE = 64.0
LN_EPS = 2.0 ** -24          # fp16's smallest subnormal; eps of the original (1e-5) is far below LayerNorm's signal here
SR, HOP = 16000, 160
LAYERS, HID, HEADS, HD, FF = 24, 1024, 8, 128, 4096


def frames_for(seconds: float) -> int:
    return 1 + int(round(seconds * SR)) // HOP


def sub_len(n: int) -> int:
    for _ in range(3):
        n = (n - 1) // 2 + 1
    return n


def pos_table(t3: int) -> np.ndarray:
    """[2*t3-1, 1024] float32: sin/cos interleaved, positions t3-1 ... -(t3-1) (Transcriber.posEmbedding)."""
    p = 2 * t3 - 1
    pos = (t3 - 1 - np.arange(p, dtype=np.float64))[:, None]
    inv = 10000.0 ** (-(2.0 * np.arange(512)) / 1024.0)
    f = pos * inv[None]
    out = np.empty((p, 1024), np.float64)
    out[:, 0::2], out[:, 1::2] = np.sin(f), np.cos(f)
    return out.astype(np.float32)


def prepare_weights(t: dict, s: float = 1.0 / RESIDUAL_SCALE) -> dict:
    """HF-named float32 tensors -> the scaled / folded tensors this graph consumes (names are graph-internal)."""
    g = {}
    f32 = lambda k: np.asarray(t[k], np.float32)
    for i, j in ((0, "c0"), (2, "d1"), (3, "p1"), (5, "d2"), (6, "p2")):
        g[f"sub.{j}.weight"] = f32(f"encoder.subsampling.layers.{i}.weight")
        g[f"sub.{j}.bias"] = f32(f"encoder.subsampling.layers.{i}.bias")
    g["sub.lin.weight"] = f32("encoder.subsampling.linear.weight") * s
    g["sub.lin.bias"] = f32("encoder.subsampling.linear.bias") * s
    for L in range(LAYERS):
        p, q = f"encoder.layers.{L}.", f"b{L}."
        for a, b in (("norm_feed_forward1", "n_ff1"), ("norm_self_att", "n_att"), ("norm_conv", "n_conv"), ("norm_feed_forward2", "n_ff2")):
            g[q + b + ".weight"], g[q + b + ".bias"] = f32(p + a + ".weight"), f32(p + a + ".bias")
        last = L == LAYERS - 1
        so = 1.0 if last else s
        g[q + "n_out.weight"], g[q + "n_out.bias"] = f32(p + "norm_out.weight") * so, f32(p + "norm_out.bias") * so
        for ff, tag in (("feed_forward1", "ff1"), ("feed_forward2", "ff2")):
            g[q + tag + ".l1"] = f32(f"{p}{ff}.linear1.weight")
            g[q + tag + ".l2"] = f32(f"{p}{ff}.linear2.weight") * (0.5 * s)
        for a in ("q", "k", "v"):
            g[q + "att." + a] = f32(f"{p}self_attn.{a}_proj.weight")
        g[q + "att.o"] = f32(p + "self_attn.o_proj.weight") * s
        g[q + "att.relk_w"] = f32(p + "self_attn.relative_k_proj.weight")
        g[q + "att.bias_u"] = f32(p + "self_attn.bias_u")
        g[q + "att.bias_v"] = f32(p + "self_attn.bias_v")
        g[q + "conv.pw1"] = f32(p + "conv.pointwise_conv1.weight")
        g[q + "conv.pw2"] = f32(p + "conv.pointwise_conv2.weight") * s
        gam, bet = f32(p + "conv.norm.weight"), f32(p + "conv.norm.bias")
        mu, var = f32(p + "conv.norm.running_mean"), f32(p + "conv.norm.running_var")
        fold = gam / np.sqrt(var + 1e-5)
        g[q + "conv.dw.weight"] = f32(p + "conv.depthwise_conv.weight") * fold[:, None, None]
        g[q + "conv.dw.bias"] = bet - mu * fold
    g["proj.weight"], g["proj.bias"] = f32("encoder_projector.weight"), f32("encoder_projector.bias")
    return g


def relative_key_table(w_relk: np.ndarray, t3_full: int) -> np.ndarray:
    """relative_k_proj of the full position table: [1, 8, 128, P] float32.

    The position table is built the way HF ParakeetEncoderRelPositionalEncoding builds it (float32 positions and inverse
    frequencies, torch sin/cos) and projected in float64, then rounded to fp16 by the caller.  Fermion's own constants are
    the same numbers up to ~0.1 % one-ulp flips in near-zero entries (their exact recipe is not recoverable)."""
    p = 2 * t3_full - 1
    pos = torch.arange(t3_full - 1, -t3_full, -1)
    inv = 1.0 / (10000 ** (torch.arange(0, HID, 2, dtype=torch.float) / HID))
    fr = pos[:, None].float() * inv
    pe = torch.stack([fr.sin(), fr.cos()], -1).reshape(p, HID).double().numpy()
    rk = pe @ w_relk.astype(np.float64).T                       # [P, 1024]
    return rk.reshape(-1, HEADS, HD).transpose(1, 2, 0)[None].astype(np.float32)


class EncoderFn(nn.Module):
    def __init__(self, g: dict, seconds: float, with_pos: bool, table_seconds: float = 15.0):
        super().__init__()
        self.T = frames_for(seconds)
        self.T3 = sub_len(self.T)
        self.with_pos = with_pos
        self.g = {}
        P = nn.Parameter
        mk = lambda k: P(torch.from_numpy(g[k]), requires_grad=False)
        for j in ("c0", "d1", "p1", "d2", "p2"):
            setattr(self, f"sub_{j}_w", mk(f"sub.{j}.weight")); setattr(self, f"sub_{j}_b", mk(f"sub.{j}.bias"))
        self.sub_lin_w, self.sub_lin_b = mk("sub.lin.weight"), mk("sub.lin.bias")
        self.proj_w, self.proj_b = mk("proj.weight"), mk("proj.bias")
        self.blocks = nn.ModuleList([_Block(g, L, self.T3, with_pos, table_seconds) for L in range(LAYERS)])

    def forward(self, mel, m1, m2, m3, kmask, pos=None):
        x = mel.transpose(1, 2).unsqueeze(1)                                   # [1,1,T,128]
        x = F.relu(F.conv2d(x, self.sub_c0_w, self.sub_c0_b, stride=2, padding=1)) * m1
        x = F.conv2d(x, self.sub_d1_w, self.sub_d1_b, stride=2, padding=1, groups=256) * m2
        x = F.relu(F.conv2d(x, self.sub_p1_w, self.sub_p1_b)) * m2
        x = F.conv2d(x, self.sub_d2_w, self.sub_d2_b, stride=2, padding=1, groups=256) * m3
        x = F.relu(F.conv2d(x, self.sub_p2_w, self.sub_p2_b)) * m3
        x = x.transpose(1, 2).reshape(1, self.T3, 4096)
        x = F.linear(x, self.sub_lin_w, self.sub_lin_b)
        fmask = m3[:, 0]                                                       # [1,T3,1]
        for b in self.blocks:
            x = b(x, kmask, fmask, pos)
        return F.linear(x, self.proj_w, self.proj_b)


class _Block(nn.Module):
    def __init__(self, g, L, T3, with_pos, table_seconds):
        super().__init__()
        q = f"b{L}."
        P = nn.Parameter
        mk = lambda k: P(torch.from_numpy(g[q + k]), requires_grad=False)
        self.T3 = T3
        for n in ("n_ff1", "n_att", "n_conv", "n_ff2", "n_out"):
            setattr(self, n + "_w", mk(n + ".weight")); setattr(self, n + "_b", mk(n + ".bias"))
        self.ff1_l1, self.ff1_l2, self.ff2_l1, self.ff2_l2 = mk("ff1.l1"), mk("ff1.l2"), mk("ff2.l1"), mk("ff2.l2")
        self.att_q, self.att_k, self.att_v, self.att_o = mk("att.q"), mk("att.k"), mk("att.v"), mk("att.o")
        self.bias_u = P(torch.from_numpy(g[q + "att.bias_u"]).reshape(1, HEADS, 1, HD), requires_grad=False)
        self.bias_v = P(torch.from_numpy(g[q + "att.bias_v"]).reshape(1, HEADS, 1, HD), requires_grad=False)
        self.pw1, self.pw2 = mk("conv.pw1"), mk("conv.pw2")
        self.dw_w, self.dw_b = mk("conv.dw.weight"), mk("conv.dw.bias")
        self.with_pos = with_pos
        if with_pos:
            self.relk_w = mk("att.relk_w")
        else:
            t3f = sub_len(frames_for(table_seconds))
            tab = relative_key_table(g[q + "att.relk_w"], t3f)                  # [1,8,128,2*t3f-1], the 15 s table
            c = t3f - 1
            tab = tab[..., c - (T3 - 1): c + T3]                                 # centred slice for this function's T3
            # NB: a per-function constant. Slicing a shared table in-graph (as the shipped model does) saves ~18 MB but needs
            # coremltools' const_elimination disabled, which leaves the rest of the graph unfoldable for the pruner.
            self.register_buffer("relk", torch.from_numpy(tab.astype(np.float16).astype(np.float32)))
        self.zeros_d = nn.Parameter(torch.zeros(HID), requires_grad=False)

    def forward(self, x, kmask, fmask, pos):
        ln = lambda h, n: F.layer_norm(h, (HID,), getattr(self, n + "_w"), getattr(self, n + "_b"), LN_EPS)
        h = ln(x, "n_ff1")
        x = x + F.linear(F.silu(F.linear(h, self.ff1_l1)), self.ff1_l2)
        h = ln(x, "n_att")
        T3 = self.T3
        q = F.linear(h, self.att_q).view(1, T3, HEADS, HD)
        k = F.linear(h, self.att_k).view(1, T3, HEADS, HD)
        v = F.linear(h, self.att_v).view(1, T3, HEADS, HD)
        q = q.transpose(1, 2)
        ac = (q + self.bias_u) @ k.permute(0, 2, 3, 1)                          # [1,8,T3,T3]
        if self.with_pos:
            relk = F.linear(pos, self.relk_w).view(1, 2 * T3 - 1, HEADS, HD).permute(0, 2, 3, 1)
        else:
            relk = self.relk.to(q.dtype)
        bd = (q + self.bias_v) @ relk                                           # [1,8,T3,2*T3-1]
        P = 2 * T3 - 1
        bd = F.pad(bd, (1, 0)).reshape(1, HEADS, P + 1, T3)[:, :, 1:].reshape(1, HEADS, T3, P)[..., :T3]
        a = torch.softmax((ac + bd) * (HD ** -0.5) + kmask, dim=-1)
        o = (a @ v.transpose(1, 2)).transpose(1, 2).reshape(1, T3, HID)
        x = x + F.linear(o, self.att_o)
        h = ln(x, "n_conv")
        h = F.linear(h, self.pw1)
        h = h[..., :HID] * torch.sigmoid(h[..., HID:])
        h = (h * fmask).transpose(1, 2)
        h = F.silu(F.conv1d(h, self.dw_w, self.dw_b, padding=4, groups=HID)).transpose(1, 2)
        x = x + F.linear(h, self.pw2)
        h = ln(x, "n_ff2")
        x = x + F.linear(F.silu(F.linear(h, self.ff2_l1)), self.ff2_l2)
        return ln(x, "n_out")


def example_inputs(seconds: float, with_pos: bool, dtype=torch.float32):
    T = frames_for(seconds)
    Ts = [T]
    for _ in range(3):
        Ts.append((Ts[-1] - 1) // 2 + 1)
    ins = [torch.zeros(1, 128, T, dtype=dtype)] + [torch.ones(1, 1, Ts[i], 1, dtype=dtype) for i in (1, 2, 3)] + [torch.zeros(1, 1, 1, Ts[3], dtype=dtype)]
    if with_pos:
        ins.append(torch.from_numpy(pos_table(Ts[3]))[None].to(dtype))
    return ins


def make_inputs(mel: np.ndarray, seconds: float, with_pos: bool) -> dict:
    """mel [128, n] -> the runtime input dict exactly as Transcriber.hostInputs builds it."""
    T = frames_for(seconds)
    n = mel.shape[1]
    lens, Ts = [n], [T]
    for _ in range(3):
        lens.append((lens[-1] - 1) // 2 + 1); Ts.append((Ts[-1] - 1) // 2 + 1)
    x = np.zeros((1, 128, T), np.float32); x[0, :, :n] = mel
    d = {"mel": x}
    for i, nm in enumerate(("m1", "m2", "m3")):
        m = np.zeros((1, 1, Ts[i + 1], 1), np.float32); m[:, :, :lens[i + 1]] = 1; d[nm] = m
    km = np.full((1, 1, 1, Ts[3]), -1e4, np.float32); km[..., :lens[3]] = 0; d["kmask"] = km
    if with_pos:
        d["pos"] = pos_table(Ts[3])[None]
    return d
