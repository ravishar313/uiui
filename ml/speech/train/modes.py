"""Model construction for the four training modes + layer surgery + HF-loadable export."""
from __future__ import annotations
import copy, os, sys
from pathlib import Path
import torch
from torch import nn

TRAINABILITY = Path(__file__).resolve().parent.parent / "trainability"
sys.path.insert(0, str(TRAINABILITY / "scripts"))
import train_probe as tp              # load(), LoRALinear, apply_lora (reviewed probe code)
from fermion_container import read_container
from qat import apply_qat, export_five_value  # noqa: F401
from torch.nn.utils import parametrize


GROUP, QMIN, QMAX = 16, -8, 7


class Int4Group(nn.Module):
    """4-bit weight grid for QAT: rows in blocks of 16, one learnable scale per block, w = s * clamp(round(w_latent / s), -8, 7).
    Straight-through to the latent weight (zero outside the clamp range), LSQ gradient to the scale.  Exports exactly as a Core ML
    16-entry fp16 LUT per 16 output rows (constexpr_lut_to_dense, uint4): see export/precision.py.  `scale` is 1-D, so train.py's
    optimiser puts it in the no-weight-decay group."""
    def __init__(self, scale):
        super().__init__()
        self.scale = nn.Parameter(scale.float().reshape(-1).clone())

    def forward(self, w):
        s = self.scale.abs().clamp_min(1e-8).repeat_interleave(GROUP)[:, None]
        c = (w.reshape(w.shape[0], -1) / s).clamp(QMIN, QMAX)
        return (s * (c + (c.round() - c).detach())).reshape(w.shape)


class Lut4Group(nn.Module):
    """Non-uniform 4-bit grid: one learnable 16-entry LUT per block of 16 rows.  Forward = nearest entry (straight-through to the latent
    weight, the chosen entry gets the gradient); entries are rounded to fp16 (straight-through) so the exported Core ML LUT
    (constexpr_lut_to_dense, uint4, fp16 entries) reproduces the weights bit for bit.  `lut` is 2-D [G, 16] (weight-decay group; use
    wd 0 or accept the pull toward 0)."""
    def __init__(self, lut):
        super().__init__()
        self.lut = nn.Parameter(lut.float().clone())

    def table(self):
        l = self.lut + (self.lut.half().float() - self.lut).detach()     # fp16-exact, straight-through
        return torch.sort(l, dim=1).values                                  # sorted: nearest entry = bucket between midpoints

    def forward(self, w):
        v = w.detach().reshape(w.shape[0] // GROUP, -1)
        l = self.table()
        mid = ((l[:, 1:] + l[:, :-1]) * 0.5).detach().contiguous()
        idx = torch.searchsorted(mid, v.contiguous())
        q = torch.gather(l, 1, idx)
        return (q.reshape(w.shape) + (w - w.detach()))


def fit_lut4(w, iters=30):
    """Per-16-row-group 16-entry LUT by 1-D Lloyd-Max (k-means).  Two starts per group, the lower final error wins: the 16 mid-quantiles
    of the group's weights, and the MSE-optimal uniform int4 grid (so the result is never worse than int4-g16 before fp16 rounding;
    Lloyd only ever lowers the error).  Entries are fp16-rounded and sorted. w [O, I] -> [O/16, 16]."""
    g = w.detach().float().reshape(w.shape[0] // GROUP, -1)
    G = g.shape[0]

    def lloyd(cent):
        for _ in range(iters):
            cent = torch.sort(cent, dim=1).values
            idx = torch.searchsorted(((cent[:, 1:] + cent[:, :-1]) * 0.5).contiguous(), g)
            sums = torch.zeros(G, 16).scatter_add_(1, idx, g)
            cnt = torch.zeros(G, 16).scatter_add_(1, idx, torch.ones_like(g))
            cent = torch.where(cnt > 0, sums / cnt.clamp_min(1), cent)
        cent = torch.sort(cent.half().float(), dim=1).values
        idx = torch.searchsorted(((cent[:, 1:] + cent[:, :-1]) * 0.5).contiguous(), g)
        return cent, (torch.gather(cent, 1, idx) - g).pow(2).sum(1)

    starts = [torch.quantile(g, (torch.arange(16, dtype=torch.float32) + 0.5) / 16, dim=1).T.contiguous(),
              fit_int4_scales(g.reshape(w.shape[0], -1))[:, None] * torch.arange(QMIN, QMAX + 1, dtype=torch.float32)[None]]
    (c0, e0), (c1, e1) = lloyd(starts[0]), lloyd(starts[1])
    return torch.where((e1 < e0)[:, None], c1, c0)


def fit_int4_scales(w):
    """Per-16-row-group MSE-optimal scale for the int4 grid (torch). w [O, I] -> [O/16]."""
    g = w.detach().float().reshape(w.shape[0] // GROUP, -1)
    amax = g.abs().amax(1).clamp_min(1e-12)
    best = torch.full_like(amax, float("inf")); scale = amax / 8
    for mult in torch.linspace(0.35, 1.0, 66):
        s = (amax * mult / 7.5)[:, None]
        err = ((((g / s).round().clamp(QMIN, QMAX)) * s - g) ** 2).sum(1)
        better = err < best
        best = torch.where(better, err, best); scale = torch.where(better, s[:, 0], scale)
    for _ in range(20):
        q = (g / scale[:, None]).round().clamp(QMIN, QMAX)
        den = (q * q).sum(1)
        scale = torch.where(den > 0, (q * g).sum(1) / den.clamp_min(1e-12), scale).clamp_min(1e-12)
    return scale


def select_bits4(model, patterns):
    """Module names of encoder linears matched by `patterns` (regexes, re.search against the module name and against 'name.weight', so
    both `^encoder\\.layers\\.(19|2[0-3])\\.` and `self_attn\\.o_proj` work; anchor exact names with $).  A pattern that matches
    nothing is an error (a typo must not silently drop layers)."""
    import re
    import importlib.util                                          # export/fivevalue.py by path: export/ must not shadow train/ modules
    sp = importlib.util.spec_from_file_location("fivevalue_ro", Path(__file__).resolve().parent.parent / "export" / "fivevalue.py")
    fv = importlib.util.module_from_spec(sp); sp.loader.exec_module(fv)
    rx = [re.compile(p) for p in patterns]
    hit = [0] * len(rx); done = []
    for name, _mod in model.named_modules():
        if not fv.LINEAR_RE.match(name + ".weight"): continue
        m = [i for i, r in enumerate(rx) if r.search(name) or r.search(name + ".weight")]
        for i in m: hit[i] += 1
        if m: done.append(name)
    dead = [p for p, h in zip(patterns, hit) if not h]
    if dead: raise SystemExit(f"qat.bits4: no encoder linear matches {dead}")
    return sorted(done)


def apply_bits4(model, patterns, log=print, names=None, grid="int4"):
    """Turn the selected encoder linears into 4-bit Int4Group layers, scales fitted (MSE-optimal per 16-row group) to the module's
    current weight: the five-value projection if apply_qat parametrised it, else the plain weight (bits4_init: current).
    Returns the sorted list of converted module names."""
    done = []
    for name in names if names is not None else select_bits4(model, patterns):
        mod = model.get_submodule(name)
        assert mod.weight.shape[0] % GROUP == 0, name
        w = mod.weight.detach().clone()
        if parametrize.is_parametrized(mod, "weight"): parametrize.remove_parametrizations(mod, "weight", leave_parametrized=True)
        mod.weight = nn.Parameter(w.reshape(mod.weight.shape))
        w2 = w.reshape(w.shape[0], -1)
        g = Lut4Group(fit_lut4(w2.cpu())) if grid == "lut4" else Int4Group(fit_int4_scales(w2))
        parametrize.register_parametrization(mod, "weight", g.to(w.device))
        done.append(name)
    return sorted(done)


class _Cfg(dict):
    __getattr__ = dict.get


def set_dropouts(model, dropout, activation_dropout, attention_dropout):
    enc = model.encoder
    enc.dropout = dropout
    enc.config.dropout = dropout; enc.config.activation_dropout = activation_dropout; enc.config.attention_dropout = attention_dropout
    for L in enc.layers:
        L.self_attn.attention_dropout = attention_dropout
        for ff in (L.feed_forward1, L.feed_forward2): ff.activation_dropout = activation_dropout


# ---- surgery -----------------------------------------------------------------------------------------------------
def drop_blocks(model, idxs):
    keep = [L for i, L in enumerate(model.encoder.layers) if i not in set(idxs)]
    assert len(keep) < len(model.encoder.layers), f"drop_blocks {idxs} matched nothing"
    model.encoder.layers = nn.ModuleList(keep)
    _sync_layers(model)


def _sync_layers(model):
    n = len(model.encoder.layers)
    model.encoder.config.num_hidden_layers = n
    model.config.encoder_config.num_hidden_layers = n
    for i, L in enumerate(model.encoder.layers): L.self_attn.layer_idx = i


def add_blocks(model, m, init="copy_last", calib_batch=None, device="cpu"):
    """Append m standard conformer blocks. Residual branch outputs (ff1.linear2, o_proj, conv pointwise2, ff2.linear2) are
    zeroed so the block is x -> LayerNorm_out(x). norm_out is then set to g*normalised + b with g, b chosen so the block
    is ~identity on the encoder's output (calibrated on `calib_batch` if given, else g=1, b=0).
    Exact identity is impossible because every Parakeet block ends in a LayerNorm; the residual error is reported."""
    from transformers.models.parakeet.modeling_parakeet import ParakeetEncoderBlock
    ecfg = model.config.encoder_config
    new = []
    for _ in range(m):
        blk = copy.deepcopy(model.encoder.layers[-1]) if init == "copy_last" else ParakeetEncoderBlock(ecfg, 0)
        with torch.no_grad():
            for lin in (blk.feed_forward1.linear2, blk.self_attn.o_proj, blk.conv.pointwise_conv2, blk.feed_forward2.linear2):
                lin.weight.zero_()
                if getattr(lin, "bias", None) is not None: lin.bias.zero_()
            blk.norm_out.weight.fill_(1.0); blk.norm_out.bias.zero_()
        for p in blk.parameters(): p.requires_grad_(True)
        new.append(blk)
    if calib_batch is not None and new:
        model.to(device).eval()
        with torch.no_grad():
            h = model.encoder(input_features=calib_batch["feats"].to(device), attention_mask=calib_batch["mask"].to(device)).last_hidden_state
            msk = calib_batch["mask"].to(device)
            mask = _frame_mask(model, msk, h.shape[1])
            x = h[mask]
            mu, sd = x.mean(-1), x.std(-1, unbiased=False)
            g = float(sd.mean())
            b = (x - (x - mu[:, None]) / (sd[:, None] + 1e-5) * g).mean(0)   # per-channel least-squares offset
            err = ((x - mu[:, None]) / (sd[:, None] + 1e-5) * g + b - x).pow(2).mean().sqrt() / x.pow(2).mean().sqrt()
            print(f"add_blocks calibration: identity relative RMS error {float(err):.4f}")
            for blk in new:
                blk.norm_out.weight.fill_(g); blk.norm_out.bias.copy_(b)
        model.cpu()
    model.encoder.layers.extend(new)
    _sync_layers(model)
    return len(new)


def _frame_mask(model, am, T):
    return model.encoder._get_output_attention_mask(am, target_length=T).bool()


# ---- build -------------------------------------------------------------------------------------------------------
def build_model(cfg, calib_batch=None, device="cuda", log=print):
    """-> model (on `device`, train mode off), info dict."""
    mode = cfg["mode"]; mc = cfg.get("model", {}); sg = cfg.get("surgery", {}) or {}
    model, proc = tp.load(layerdrop=mc.get("layerdrop", 0.0))
    info = {"mode": mode}
    if mc.get("init_weights"):                             # continue from a previous HF-loadable safetensors
        from safetensors.torch import load_file
        log(f"init weights from {mc['init_weights']}: " + str(model.load_state_dict(load_file(mc["init_weights"]), strict=False)))
    if mode == "qat":
        raw = read_container(str(tp.CONTAINER), with_raw=True)[2]
        qc = cfg.get("qat") or {}
        b4 = qc.get("bits4") or []
        b4init = qc.get("bits4_init", "container")
        assert b4init in ("container", "current"), f"qat.bits4_init must be container|current, got {b4init}"
        b4grid = qc.get("bits4_grid", "int4")
        assert b4grid in ("int4", "lut4"), f"qat.bits4_grid must be int4|lut4, got {b4grid}"
        sel = select_bits4(model, b4) if b4 else []
        if b4init == "current":     # int4 scales from the weights loaded so far (e.g. model.init_weights = a dense checkpoint)
            raw = {k: v for k, v in raw.items() if k not in set(sel)}     # those layers skip the five-value container grid entirely
        model.to(device).eval()
        with torch.no_grad():
            x = torch.randn(1, 300, 128, device=device)
            before = model.get_audio_features(input_features=x).pooler_output          # the model as loaded (container or init_weights)
            info["qat_modules"] = apply_qat(model, raw); model.to(device)
            after = model.get_audio_features(input_features=x).pooler_output
        info["qat_identity_maxdiff"] = float((before - after).abs().max())
        del raw
        log(f"qat: {info['qat_modules']} five-value modules, step-0 identity max|diff| {info['qat_identity_maxdiff']:.3g}")
        if b4:
            with torch.no_grad():
                info["bits4"] = apply_bits4(model, b4, names=sel, grid=b4grid); model.to(device)
                after4 = model.get_audio_features(input_features=x).pooler_output
            info["bits4_init"] = b4init; info["bits4_grid"] = b4grid
            info["bits4_step0_maxdiff"] = float((before - after4).abs().max())
            info["bits4_step0_rel_rms"] = float((before - after4).pow(2).mean().sqrt() / before.pow(2).mean().sqrt())
            log(f"qat: {len(info['bits4'])} layers 4-bit (int4 x per-16-row scale, init {b4init}); step-0 encoder output vs the model as loaded: "
                f"max|diff| {info['bits4_step0_maxdiff']:.3g}, rel RMS {info['bits4_step0_rel_rms']:.4g}")
    if sg.get("drop_blocks"):
        drop_blocks(model, sg["drop_blocks"]); info["dropped"] = sg["drop_blocks"]
    for p in model.parameters(): p.requires_grad_(mode in ("full", "qat"))
    if mode == "decoder":
        for m in (model.decoder, model.joint): [p.requires_grad_(True) for p in m.parameters()]
        assert not sg.get("add_blocks"), "add_blocks is not supported in decoder mode (encoder is frozen)"
    elif mode == "lora":
        lc = cfg.get("lora", {})
        info["lora_modules"] = tp.apply_lora(model, top=lc.get("top_k", 8), r=lc.get("r", 16))
        for mod in model.modules():
            if isinstance(mod, tp.LoRALinear):
                mod.s = lc.get("alpha", 2 * lc.get("r", 16)) / lc.get("r", 16)
                mod.a.requires_grad_(True); mod.b.requires_grad_(True)
        if lc.get("train_decoder", False):
            for m in (model.decoder, model.joint): [p.requires_grad_(True) for p in m.parameters()]
    elif mode == "full":
        fb = cfg.get("full", {}).get("freeze_bottom", 0)
        if fb:
            for p in model.encoder.subsampling.parameters(): p.requires_grad_(False)
            for L in model.encoder.layers[:fb]: [p.requires_grad_(False) for p in L.parameters()]
        info["frozen_bottom"] = fb
    elif mode != "qat":
        raise SystemExit(f"unknown mode {mode}")
    if sg.get("add_blocks"):
        info["added_blocks"] = add_blocks(model, sg["add_blocks"], sg.get("init", "copy_last"),
                                          calib_batch if sg.get("calibrate", True) else None, device)
    partial = any(not p.requires_grad for p in model.encoder.parameters())
    mps_pitfall = partial and torch.device(device).type == "mps"
    att = 0.0 if mps_pitfall else mc.get("attention_dropout", 0.0)
    if mps_pitfall and mc.get("attention_dropout", 0.0): log("attention dropout forced to 0: encoder is partly frozen (MPS pitfall)")
    set_dropouts(model, mc.get("dropout", 0.1), mc.get("activation_dropout", 0.1), att)
    model.to(device)
    info["trainable"] = sum(p.numel() for p in model.parameters() if p.requires_grad)
    info["total"] = sum(p.numel() for p in model.parameters())
    info["encoder_frozen"] = not any(p.requires_grad for p in model.encoder.parameters())
    return model, proc, info


def attach_train_mode(model, encoder_frozen, bn_eval=True):
    """model.restore_train_mode(): train() but BatchNorm kept in eval (running stats frozen) and a fully frozen encoder in eval.
    Without this, the conformer conv BatchNorms drift on SpecAugment'ed / zero-padded batches (wrecks WER within ~100 steps)."""
    def fn():
        model.train()
        if bn_eval:
            for m in model.modules():
                if isinstance(m, nn.modules.batchnorm._BatchNorm): m.eval()
        if encoder_frozen: model.encoder.eval()
    model.restore_train_mode = fn
    return fn


# ---- export ------------------------------------------------------------------------------------------------------
@torch.no_grad()
def export_state_dict(model, dtype=torch.float32):
    """State dict with stock ParakeetForTDT key names: LoRA merged, QAT projected values written as dense weights."""
    sd = {}
    lora = {n: m for n, m in model.named_modules() if isinstance(m, tp.LoRALinear)}
    par = {n: m for n, m in model.named_modules() if parametrize.is_parametrized(m, "weight")}
    for k, v in model.state_dict().items():
        if ".parametrizations.weight." in k: continue
        if any(k.startswith(n + ".") and k[len(n) + 1:] in ("a", "b") for n in lora): continue
        for n in lora:
            if k.startswith(n + ".base."): k = n + "." + k[len(n) + 6:]
        sd[k] = v
    for n, m in lora.items():
        sd[n + ".weight"] = m.base.weight.float() + (m.b.float() @ m.a.float()) * m.s
    for n, m in par.items():
        sd[n + ".weight"] = m.weight.detach()
    return {k: (v.detach().to(dtype) if v.is_floating_point() else v.detach()).cpu().contiguous() for k, v in sd.items()}


def qat_scales(model):
    out = {}
    for n, m in model.named_modules():
        if parametrize.is_parametrized(m, "weight"):
            f = m.parametrizations.weight[0]
            if isinstance(f, Lut4Group):
                out[n + ".bits4_lut"] = f.table().detach().reshape(-1, 16).cpu().contiguous(); continue
            if isinstance(f, Int4Group):                     # sidecar for export/precision.py: marks the layer as 4-bit
                out[n + ".bits4_scale"] = f.scale.detach().abs().reshape(-1).cpu().contiguous(); continue
            out[n + ".lo"] = f.lo.detach().abs().reshape(-1).cpu().contiguous(); out[n + ".hi"] = f.hi.detach().abs().reshape(-1).cpu().contiguous()
    return out
