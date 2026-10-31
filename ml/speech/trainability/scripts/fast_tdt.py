"""Memory-lean TDT loss for Parakeet-TDT training on MPS.

1. fused_joint_gather: joint (relu(enc+dec) -> head) evaluated in T-chunks under activation checkpointing; only the
   per-(t,u) blank / label / duration log-probs survive, so the [B,T,U+1,8198] logits never live at once.
2. TDTLatticeLoss: alpha/beta over those small tensors on CPU (numba), exact arc-posterior gradients.
Matches transformers.loss.loss_tdt.tdt_loss (same lattice: labels may not land on t=T; terminal = blank arcs).
"""
from __future__ import annotations
import numpy as np
import numba
import torch
from torch.utils.checkpoint import checkpoint

NEG = -1e30


@numba.njit(cache=True)
def _lse2(a, b):
    if a < b: a, b = b, a
    if b <= NEG: return a
    return a + np.log1p(np.exp(b - a))


@numba.njit(parallel=True, cache=True)
def _tdt(lb, ll, ld, durs, Ts, Us):
    B, Tm, Um1, D = ld.shape
    losses = np.zeros(B)
    glb = np.zeros_like(lb); gll = np.zeros_like(ll); gld = np.zeros_like(ld)
    for b in numba.prange(B):
        T = Ts[b]; U = Us[b]
        al = np.full((T, U + 1), NEG); be = np.full((T, U + 1), NEG)
        al[0, 0] = 0.0
        for t in range(T):
            for u in range(U + 1):
                if t == 0 and u == 0: continue
                acc = NEG
                for i in range(D):
                    d = durs[i]; s = t - d
                    if s < 0: continue
                    if d > 0: acc = _lse2(acc, al[s, u] + lb[b, s, u] + ld[b, s, u, i])
                    if u > 0: acc = _lse2(acc, al[s, u - 1] + ll[b, s, u - 1] + ld[b, s, u - 1, i])
                al[t, u] = acc
        for t in range(T - 1, -1, -1):
            for u in range(U, -1, -1):
                acc = NEG
                for i in range(D):
                    d = durs[i]; e = t + d
                    if d > 0:
                        if e < T: acc = _lse2(acc, lb[b, t, u] + ld[b, t, u, i] + be[e, u])
                        elif e == T and u == U: acc = _lse2(acc, lb[b, t, u] + ld[b, t, u, i])
                    if u < U and e < T: acc = _lse2(acc, ll[b, t, u] + ld[b, t, u, i] + be[e, u + 1])
                be[t, u] = acc
        logp = be[0, 0]
        losses[b] = -logp
        for t in range(T):
            for u in range(U + 1):
                a = al[t, u]
                if a <= NEG: continue
                for i in range(D):
                    d = durs[i]; e = t + d
                    if d > 0:
                        x = NEG
                        if e < T: x = a + lb[b, t, u] + ld[b, t, u, i] + be[e, u]
                        elif e == T and u == U: x = a + lb[b, t, u] + ld[b, t, u, i]
                        if x > NEG:
                            p = np.exp(x - logp); glb[b, t, u] -= p; gld[b, t, u, i] -= p
                    if u < U and e < T:
                        x = a + ll[b, t, u] + ld[b, t, u, i] + be[e, u + 1]
                        p = np.exp(x - logp); gll[b, t, u] -= p; gld[b, t, u, i] -= p
    return losses, glb, gll, gld


class TDTLatticeLoss(torch.autograd.Function):
    @staticmethod
    def forward(ctx, lb, ll, ld, durs, Ts, Us):
        f = lambda x: x.detach().float().cpu().double().numpy()   # never cast to float64 on MPS
        losses, glb, gll, gld = _tdt(f(lb), f(ll), f(ld), np.asarray(durs, np.int64),
                                     Ts.cpu().numpy().astype(np.int64), Us.cpu().numpy().astype(np.int64))
        dev, dt = lb.device, lb.dtype
        ctx.save_for_backward(*(torch.from_numpy(g).to(dt).to(dev) for g in (glb, gll, gld)))
        return torch.from_numpy(losses).to(dt).to(dev)

    @staticmethod
    def backward(ctx, g):
        glb, gll, gld = ctx.saved_tensors
        return glb * g[:, None, None], gll * g[:, None, None], gld * g[:, None, None, None], None, None, None


def _chunk(enc, dec, labels, head_w, head_b, vocab, sigma):
    h = torch.relu(enc[:, :, None, :] + dec[:, None, :, :])               # B,t,U+1,H
    logits = torch.nn.functional.linear(h, head_w, head_b)
    if logits.dtype in (torch.float16, torch.bfloat16): logits = logits.float()   # B,t,U+1,V+D
    tok = logits[..., :vocab]
    lse = torch.logsumexp(tok, -1)
    lb = tok[..., vocab - 1] - lse - sigma                                 # blank is the last token id
    idx = labels[:, None, :, None].expand(-1, tok.shape[1], -1, 1)
    ll = tok[:, :, :-1, :].gather(-1, idx).squeeze(-1) - lse[:, :, :-1] - sigma
    ld = torch.log_softmax(logits[..., vocab:], -1)
    return lb, ll, ld


def fused_joint_gather(enc, dec, labels, head, vocab, sigma=0.0, chunk=16):
    outs = [checkpoint(_chunk, enc[:, s:s + chunk], dec, labels, head.weight, head.bias, vocab, sigma, use_reentrant=False)
            for s in range(0, enc.shape[1], chunk)]
    return [torch.cat(x, 1) for x in zip(*outs)]


def tdt_loss_lean(enc, dec, labels, Ts, Us, head, vocab, durations, sigma=0.0, chunk=16, reduction="mean_volume"):
    """enc [B,T,H] projected encoder, dec [B,U+1,H] prediction net (blank-prefixed), labels [B,U] (pad any valid id)."""
    lb, ll, ld = fused_joint_gather(enc, dec, labels, head, vocab, sigma, chunk)
    losses = TDTLatticeLoss.apply(lb, ll, ld, list(durations), Ts, Us)
    if reduction == "mean_volume": return losses.sum() / Us.sum().to(losses.dtype)
    if reduction == "none": return losses
    return losses.mean()


if __name__ == "__main__":   # parity vs transformers' reference TDT loss
    from transformers.loss.loss_tdt import tdt_loss
    torch.manual_seed(0)
    B, T, U, H, V, durs = 3, 9, 4, 8, 7, [0, 1, 2, 3, 4]
    enc = torch.randn(B, T, H, dtype=torch.float64, requires_grad=True)
    dec = torch.randn(B, U + 1, H, dtype=torch.float64, requires_grad=True)
    head = torch.nn.Linear(H, V + len(durs)).double()
    labels = torch.randint(0, V - 1, (B, U))
    Ts = torch.tensor([9, 7, 5]); Us = torch.tensor([4, 2, 3])
    for b in range(B): labels[b, Us[b]:] = V - 1
    ref_logits = head(torch.relu(enc[:, :, None] + dec[:, None]))
    ref = tdt_loss(ref_logits[..., :V], ref_logits[..., V:], labels.int(), Ts.int(), Us.int(), V - 1, durs, sigma=0.02, reduction="none")
    ours = tdt_loss_lean(enc, dec, labels, Ts, Us, head, V, durs, sigma=0.02, chunk=4, reduction="none")
    print("loss ref", ref.detach().numpy(), "ours", ours.detach().numpy())
    g1 = torch.autograd.grad(ref.sum(), [enc, dec, head.weight]); g2 = torch.autograd.grad(ours.sum(), [enc, dec, head.weight])
    print("max |dgrad|", [float((a - b).abs().max()) for a, b in zip(g1, g2)])
