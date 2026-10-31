"""Knowledge distillation from a frozen dense teacher into the (QAT) student.   cfg block (absent => nothing changes):

  distill: {teacher: <safetensors>, enc_weight: 1.0, logit_weight: 0.0, temperature: 1.0, layers: [11, 23]}

(a) encoder KD: scale-free MSE over valid frames, mean over {final encoder output} + `layers` (block outputs).
    Per term: mean((s-t)^2) / mean(t^2), so the weight does not depend on the activation scale of a block.
(b) logit KD: KL(teacher || student) on the joint's token and duration distributions (both temperature-scaled, x T^2),
    averaged over valid (t,u) lattice points. Computed chunk-wise inside the same checkpointed T-chunk loop as the TDT
    gather, so the [B,T,U+1,V] logits are never alive at once (the teacher chunk is recomputed in backward, no_grad).
Teacher is a plain Python attribute (not an nn.Module of LossStep) so DDP neither wraps nor broadcasts it; every rank holds a copy."""
from __future__ import annotations
import torch
from torch.utils.checkpoint import checkpoint
import modes
from fast_tdt import TDTLatticeLoss


def _rel_mse(s, t, m):
    s, t = s[m].float(), t[m].float()
    return (s - t).pow(2).mean() / t.pow(2).mean().clamp_min(1e-6)


def _chunk_kd(enc, dec, labels, hw, hb, enc_t, dec_t, tw, tb, tmask, vocab, sigma, temp):
    h = torch.relu(enc[:, :, None, :] + dec[:, None, :, :])
    logits = torch.nn.functional.linear(h, hw, hb).float()
    tok = logits[..., :vocab]
    lse = torch.logsumexp(tok, -1)
    lb = tok[..., vocab - 1] - lse - sigma
    idx = labels[:, None, :, None].expand(-1, tok.shape[1], -1, 1)
    ll = tok[:, :, :-1, :].gather(-1, idx).squeeze(-1) - lse[:, :, :-1] - sigma
    ld = torch.log_softmax(logits[..., vocab:], -1)
    with torch.no_grad():
        lt = torch.nn.functional.linear(torch.relu(enc_t[:, :, None, :] + dec_t[:, None, :, :]), tw, tb).float()
    kl = 0.0
    for sl, tl in ((tok, lt[..., :vocab]), (logits[..., vocab:], lt[..., vocab:])):
        lps, lpt = torch.log_softmax(sl / temp, -1), torch.log_softmax(tl / temp, -1)
        kl = kl + (lpt.exp() * (lpt - lps)).sum(-1)               # B,t,U+1
    return lb, ll, ld, (kl * tmask).sum() * temp * temp


class Distiller:
    def __init__(self, dcfg, dev, log=print):
        self.enc_w = float(dcfg.get("enc_weight", 1.0)); self.logit_w = float(dcfg.get("logit_weight", 0.0))
        self.temp = float(dcfg.get("temperature", 1.0)); self.layers = list(dcfg.get("layers") or [])
        from safetensors.torch import load_file
        teacher, _ = modes.tp.load(layerdrop=0.0)
        unexpected = 0
        if dcfg["teacher"] != "base":   # "base" = the original parakeet-tdt-0.6b-v3 weights as tp.load returns them
            res = teacher.load_state_dict(load_file(dcfg["teacher"]), strict=False)
            assert not res.missing_keys, f"teacher is missing {len(res.missing_keys)} keys, e.g. {res.missing_keys[:3]}"
            unexpected = len(res.unexpected_keys)
        # per-sample selection: train.py sets self.mask ([B] bool on device) per batch when distill.only_kd_sources is on
        self.mask = None
        log(f"distill teacher {dcfg['teacher']}: unexpected={unexpected}  enc_w={self.enc_w} logit_w={self.logit_w} T={self.temp} layers={self.layers}"
            f"  only_kd_sources={bool(dcfg.get('only_kd_sources'))}")
        teacher = teacher.to(dev).to(torch.bfloat16).eval()
        for p in teacher.parameters(): p.requires_grad_(False)
        self.teacher = teacher
        self._t, self._s = {}, {}
        for i in self.layers: teacher.encoder.layers[i].register_forward_hook(self._hook(self._t, i))

    @staticmethod
    def _hook(store, i):
        def f(_m, _a, out): store[i] = out[0] if isinstance(out, tuple) else out
        return f

    def attach_student(self, model):
        assert len(model.encoder.layers) == len(self.teacher.encoder.layers) or not self.layers, "layers KD needs equal block counts"
        for i in self.layers: model.encoder.layers[i].register_forward_hook(self._hook(self._s, i))

    def loss(self, m, enc, dh, feats, am, dec_in, labels, Ts, Us, vocab, durs, sigma, chunk):
        """-> total loss (TDT + weighted KD) and a dict of detached components."""
        sm = self.mask
        if sm is not None and not bool(sm.any()):   # no KD sample in this batch: plain TDT, teacher not run
            from fast_tdt import fused_joint_gather
            self._s.clear()
            lb, ll, ld = fused_joint_gather(enc.pooler_output, dh, labels, m.joint.head, vocab, sigma, chunk)
            ls = TDTLatticeLoss.apply(lb, ll, ld, list(durs), Ts, Us)
            tdt = ls.sum() / Us.sum().to(ls.dtype); z = tdt.detach().new_zeros(())
            return tdt, {"tdt": tdt.detach(), "kd_enc": z, "kd_logit": z, "kd_frac": z}
        with torch.no_grad():
            te = self.teacher.get_audio_features(input_features=feats, attention_mask=am)
            dh_t = self.teacher.decoder(dec_in) if self.logit_w > 0 else None
        fm = enc.attention_mask.bool()
        if sm is not None: fm = fm & sm[:, None]
        terms = [_rel_mse(enc.last_hidden_state, te.last_hidden_state, fm)] + [_rel_mse(self._s[i], self._t[i], fm) for i in self.layers]
        self._s.clear(); self._t.clear()
        kd_enc = torch.stack(terms).mean()
        head = m.joint.head
        if self.logit_w > 0:
            B, T = enc.pooler_output.shape[:2]; U1 = dh.shape[1]
            tmask = ((torch.arange(T, device=Ts.device)[None, :, None] < Ts[:, None, None]) &
                     (torch.arange(U1, device=Ts.device)[None, None, :] < (Us + 1)[:, None, None])).float()
            if sm is not None: tmask = tmask * sm[:, None, None].float()
            th = self.teacher.joint.head
            outs = [checkpoint(_chunk_kd, enc.pooler_output[:, s:s + chunk], dh, labels, head.weight, head.bias,
                               te.pooler_output[:, s:s + chunk], dh_t, th.weight, th.bias, tmask[:, s:s + chunk], vocab, sigma, self.temp,
                               use_reentrant=False) for s in range(0, T, chunk)]
            lb, ll, ld = (torch.cat([o[i] for o in outs], 1) for i in range(3))
            kd_logit = sum(o[3] for o in outs) / tmask.sum().clamp_min(1)
        else:
            from fast_tdt import fused_joint_gather
            lb, ll, ld = fused_joint_gather(enc.pooler_output, dh, labels, head, vocab, sigma, chunk)
            kd_logit = enc.pooler_output.new_zeros(())
        ls = TDTLatticeLoss.apply(lb, ll, ld, list(durs), Ts, Us)
        tdt = ls.sum() / Us.sum().to(ls.dtype)
        total = tdt + self.enc_w * kd_enc + self.logit_w * kd_logit
        kd_frac = sm.float().mean() if sm is not None else tdt.detach().new_ones(())
        return total, {"tdt": tdt.detach(), "kd_enc": kd_enc.detach(), "kd_logit": kd_logit.detach(), "kd_frac": kd_frac}
