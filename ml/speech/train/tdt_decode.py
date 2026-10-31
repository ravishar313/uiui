"""Batched greedy TDT decoding for ParakeetForTDT, with optional n-gram LM shallow fusion and a repetition guard.

With no LM and no guard the decoder is the same algorithm as transformers' `model.generate` (greedy, ParakeetTDTGenerationMixin) and the
app's PilotTDT.cpp, so that a C++ port of the LM / guard is a straight translation.  The step, for one utterance, is:

    state: t (encoder frame), nsym (non-blank symbols emitted at this frame), pred (LSTM h/c + projected output, advanced only on a
           non-blank emission; initial = LSTM(emb[blank]) from zeros)
    while t < T:
        z      = relu(enc[t] + pred)               # joint
        lg     = head(z);  tok = argmax(lg[:V]);  dur = durations[argmax(lg[V:])]      # V = 8193, blank = V-1 = 8192
        advance = 1 if (tok == blank and dur == 0) else dur                              # blank never stays on a frame
        if tok != blank:   emit (tok, frame t, dur);  pred.step(tok)                    # LSTM + decoder_projector
        if advance == 0:   nsym += 1; if nsym >= max_symbols: advance = 1                # PilotTDT stepTiming(); HF generate has no cap
        if advance > 0:    nsym = 0
        t += advance

Fusion (NGPU-LM greedy two-stage, as NeMo tdt_label_looping.py): if the raw argmax is blank keep blank (and its duration); otherwise
pick argmax over NON-blank tokens of  log p_asr(y) + lam * ln p_lm(y | h) + beta  among the top-`topk` non-blank candidates; the LM
history h advances only when a non-blank token is committed.  The duration comes from the unchanged duration logits.
`fusion="joint"` instead lets the fused best non-blank compete with blank (blank gets no LM score).

Guard (all off by default, see GuardConfig): n-gram repeat ban, tokens-per-second cap, same-token zero-duration cap.

Everything is run under torch.no_grad on whatever device the model is on.  Never logs audio or text beyond what the caller prints.
"""
from __future__ import annotations
import contextlib, math, os, time
from dataclasses import dataclass, field, asdict
from pathlib import Path

import torch
import torch.nn.functional as F

LN10 = math.log(10.0)


# ---------------------------------------------------------------------------------------------------------------------
# configs
@dataclass
class GuardConfig:
    """Repetition guard.  enabled=False => everything below is ignored."""
    enabled: bool = False
    # (a) n-gram repeat: forbid starting the (max_repeats+1)-th consecutive copy of any n-gram, n in [ngram_min, ngram_max]
    ngram_min: int = 3
    ngram_max: int = 6
    max_repeats: int = 3
    action: str = "ban"            # "ban": emit blank instead (decoding continues, remaining audio is still read); "stop": end the row
    # (b) tokens per second of audio: stop emitting once emitted >= max_tps * audio_seconds + rate_slack  (0 = off)
    max_tps: float = 0.0
    rate_slack: float = 8.0
    # (c) same token again at duration 0 on the same frame: allow this many extra copies, then treat as blank (advance one frame)
    zero_dur_repeat: int = 0       # -1 = off


@dataclass
class DecodeConfig:
    max_symbols: int | None = 10   # PilotTDT/NeMo: 10.  None = no cap (what transformers' TDT generate does)
    stop_on_eos: bool = False      # transformers generate stops a row when argmax == eos_token_id (3); PilotTDT does not
    blank_bonus: float = 0.0       # added to the blank logit before the argmax (positive = fewer insertions)
    # LM fusion
    lm_weight: float = 0.0         # lambda; 0 = no LM
    length_bonus: float = 0.0      # beta, added to every fused non-blank score
    topk: int = 16                 # non-blank candidates rescored by the LM per step
    fusion: str = "two_stage"      # "two_stage" (NGPU-LM greedy) | "joint"
    guard: GuardConfig = field(default_factory=GuardConfig)


@dataclass
class Hyp:
    tokens: list
    frames: list
    durations: list
    stats: dict = field(default_factory=dict)


# ---------------------------------------------------------------------------------------------------------------------
# model loading / encoder
def repo_root() -> Path:
    from uiui_root import ROOT
    return Path(ROOT)


def default_base() -> Path:
    for r in (repo_root(),):
        p = r / "trainability" / "hf" / "parakeet"
        if p.exists(): return p
    raise FileNotFoundError("trainability/hf/parakeet not found; set UIUI_ML_ROOT")


def load_model(safetensors_path: str, base: str | None = None):
    """Stock ParakeetForTDT with weights from an HF-loadable safetensors (as written by train/modes.export_state_dict)."""
    from transformers import ParakeetForTDT, ParakeetTDTConfig, AutoProcessor, GenerationConfig
    from safetensors.torch import load_file
    base = str(base or default_base())
    cfg = ParakeetTDTConfig.from_pretrained(base)
    cfg.encoder_config.layerdrop = 0.0
    model = ParakeetForTDT(cfg)
    res = model.load_state_dict(load_file(safetensors_path), strict=False)
    assert not res.missing_keys and not res.unexpected_keys, (res.missing_keys[:5], res.unexpected_keys[:5])
    model.generation_config = GenerationConfig.from_pretrained(base)
    return model.eval(), AutoProcessor.from_pretrained(base)


@torch.no_grad()
def encode_batch(model, proc, waves, device="cpu"):
    """Encoder + projector exactly as `generate` does it -> (pooler_output [B,T,H] , valid lengths [B])."""
    inp = proc.feature_extractor(waves, sampling_rate=16000, return_tensors="pt", padding=True, return_attention_mask=True)
    out = model.get_audio_features(input_features=inp["input_features"].to(device), attention_mask=inp["attention_mask"].to(device),
                                   output_attention_mask=True)
    lens = out.attention_mask.sum(-1) if out.attention_mask is not None else torch.full((len(waves),), out.pooler_output.shape[1])
    return out.pooler_output, lens


# ---------------------------------------------------------------------------------------------------------------------
# guard
def _repeats(seq, x, n, k):
    """True if emitting x would start the (k+1)-th consecutive copy of an n-gram, i.e. seq already ends with k identical n-grams
    and x equals their first token."""
    need = n * k
    if len(seq) < need or x != seq[-n]:          # cheap prefilter: x must equal the first token of the last block
        return False
    blk = seq[-n:]
    return all(seq[len(seq) - need + i:len(seq) - need + i + n] == blk for i in range(0, need, n))


class _RowGuard:
    __slots__ = ("emitted", "zr", "stopped", "ev_rep", "ev_rate", "ev_zero")

    def __init__(self):
        self.emitted, self.zr, self.stopped = [], 0, False
        self.ev_rep = self.ev_rate = self.ev_zero = 0


# ---------------------------------------------------------------------------------------------------------------------
class TDTDecoder:
    def __init__(self, model, device="cpu"):
        self.m, self.dev = model, device
        c = model.config
        self.V = c.vocab_size                    # 8193 = 8192 tokens + blank
        self.blank = c.blank_token_id
        self.eos = model.generation_config.eos_token_id
        self.durs = torch.tensor(list(c.durations), device=device)
        self.H = c.decoder_hidden_size
        self.L = c.num_decoder_layers
        assert self.blank == self.V - 1, "blank is expected to be the last token id"

    # prediction network: one LSTM step per row in `rows` (bool mask over the batch), full batch computed like HF and masked
    def _pred_step(self, tokens, h, c, dec_out, rows):
        d = self.m.decoder
        o, (h2, c2) = d.lstm(d.embedding(tokens)[:, None, :], (h, c))
        o = d.decoder_projector(o)[:, 0]
        r = rows
        return (torch.where(r[None, :, None], h2, h), torch.where(r[None, :, None], c2, c), torch.where(r[:, None], o, dec_out))

    @torch.no_grad()
    def decode(self, enc, lens, cfg: DecodeConfig | None = None, lm=None, secs=None):
        """enc [B,T,H] float (encoder_projector output), lens [B] valid frames, secs [B] audio seconds (only for the rate cap).
        -> list[Hyp]"""
        cfg = cfg or DecodeConfig()
        m, dev, V, BL = self.m, self.dev, self.V, self.blank
        B, Tm, _ = enc.shape
        enc = enc.to(dev); lens = lens.to(dev).long()
        h = torch.zeros(self.L, B, self.H, device=dev); c = torch.zeros_like(h)
        dec_out = torch.zeros(B, self.H, device=dev)
        allrows = torch.ones(B, dtype=torch.bool, device=dev)
        h, c, dec_out = self._pred_step(torch.full((B,), BL, device=dev), h, c, dec_out, allrows)
        t = torch.zeros(B, dtype=torch.long, device=dev)
        nsym = torch.zeros(B, dtype=torch.long, device=dev)
        done = torch.zeros(B, dtype=torch.bool, device=dev)
        hyps = [Hyp([], [], []) for _ in range(B)]
        gc = cfg.guard if cfg.guard.enabled else None
        rg = [_RowGuard() for _ in range(B)] if gc else None
        use_lm = lm is not None and cfg.lm_weight != 0.0
        lm_states = [lm.init_state() for _ in range(B)] if use_lm else None
        n_lm_lookups = 0; t_lm = 0.0; n_steps_lm = 0
        ar = torch.arange(B, device=dev)
        secs = [float(x) for x in secs] if secs is not None else [None] * B
        # safety bound on loop steps.  Without a symbol cap a duration-0 loop at one frame never advances t; transformers' generate then
        # stops at max_length = max_symbols_per_step * (padded encoder frames), counting the start token, hence the "- 1".
        step = 0; step_limit = (10 * Tm - 1) if cfg.max_symbols is None else (cfg.max_symbols + 1) * Tm + 1
        while True:
            active = (t < lens) & ~done
            step += 1
            if not bool(active.any()) or step > step_limit: break
            e = enc[ar, t.clamp(max=Tm - 1)]
            lg = m.joint.head(F.relu(e + dec_out))
            tl, dl = lg[:, :V], lg[:, V:]
            if cfg.blank_bonus: tl = tl.clone(); tl[:, BL] += cfg.blank_bonus
            tok = tl.argmax(-1)
            dur = self.durs[dl.argmax(-1)]
            keep_blank = None
            # ---- LM fusion on rows whose raw argmax is non-blank (blank decision is the acoustic one) ----------------------
            if use_lm:
                if cfg.fusion == "joint":
                    cand_rows = active.nonzero()[:, 0].tolist()      # every active row: best fused non-blank may beat blank
                else:
                    cand_rows = (active & (tok != BL)).nonzero()[:, 0].tolist()
                if cand_rows:
                    logp = F.log_softmax(tl.float(), dim=-1)
                    k = cfg.topk
                    tv, ti = logp[cand_rows][:, :BL].topk(k, dim=-1)
                    tv, ti = tv.tolist(), ti.tolist()
                    new_tok = tok.tolist(); t0 = time.perf_counter(); n_steps_lm += len(cand_rows)
                    for j, b in enumerate(cand_rows):
                        best, bi = -1e30, -1
                        for a, y in zip(tv[j], ti[j]):
                            s = a + cfg.lm_weight * lm.score(lm_states[b], y) + cfg.length_bonus
                            if s > best: best, bi = s, y
                        n_lm_lookups += k
                        if cfg.fusion == "joint":
                            if best > float(logp[b, BL]): new_tok[b] = bi
                            else: new_tok[b] = BL
                        else:
                            new_tok[b] = bi
                    t_lm += time.perf_counter() - t0
                    tok = torch.tensor(new_tok, device=dev)
            # ---- guard ----------------------------------------------------------------------------------------------------
            if gc:
                tk, dk, ac = tok.tolist(), dur.tolist(), active.tolist()
                ns = nsym.tolist(); changed = False
                for b in range(B):
                    if not ac[b] or tk[b] == BL: continue
                    g, x = rg[b], tk[b]
                    if gc.max_tps > 0 and secs[b] is not None and len(g.emitted) >= gc.max_tps * secs[b] + gc.rate_slack:
                        g.ev_rate += 1; g.stopped = True; tk[b] = BL; changed = True; continue
                    if any(_repeats(g.emitted, x, n, gc.max_repeats) for n in range(gc.ngram_min, gc.ngram_max + 1)):
                        g.ev_rep += 1; tk[b] = BL; changed = True
                        if gc.action == "stop": g.stopped = True
                        continue
                    if gc.zero_dur_repeat >= 0 and dk[b] == 0 and ns[b] > 0 and g.emitted and g.emitted[-1] == x:
                        if g.zr >= gc.zero_dur_repeat:
                            g.ev_zero += 1; tk[b] = BL; changed = True; continue
                        g.zr += 1
                if changed: tok = torch.tensor(tk, device=dev)
                stopped = torch.tensor([r.stopped for r in rg], device=dev)
                done = done | stopped
            if cfg.stop_on_eos and self.eos is not None:
                is_eos = (tok == self.eos) & active
                # HF: the eos token is appended to the sequence, the row then finishes
                done = done | is_eos
            # ---- timing (PilotTDT stepTiming) -------------------------------------------------------------------------------
            blank = tok == BL
            adv = torch.where(blank & (dur == 0), torch.ones_like(dur), dur)
            sym = torch.where(adv == 0, nsym + 1, torch.zeros_like(nsym))
            if cfg.max_symbols is not None:
                capped = (adv == 0) & (sym >= cfg.max_symbols)
                adv = torch.where(capped, torch.ones_like(adv), adv)
                sym = torch.where(capped, torch.zeros_like(sym), sym)
            emit = active & ~blank
            if bool(emit.any()):
                er = emit.nonzero()[:, 0].tolist(); tkl = tok.tolist(); dl_ = dur.tolist(); tt = t.tolist()
                for b in er:
                    hy = hyps[b]; hy.tokens.append(tkl[b]); hy.frames.append(tt[b]); hy.durations.append(dl_[b])
                    if gc: rg[b].emitted.append(tkl[b])
                    if use_lm: lm_states[b] = lm.advance(lm_states[b], tkl[b])
                h, c, dec_out = self._pred_step(tok, h, c, dec_out, emit)
            if gc:
                moved = (adv > 0) & active
                for b in moved.nonzero()[:, 0].tolist(): rg[b].zr = 0
            t = torch.where(active, t + adv, t)
            nsym = torch.where(active, sym, nsym)
        if gc or use_lm:
            for b in range(B):
                if gc: hyps[b].stats = {"rep": rg[b].ev_rep, "rate": rg[b].ev_rate, "zero": rg[b].ev_zero}
            if hyps: hyps[0].stats = {**hyps[0].stats, "_lm_lookups": n_lm_lookups, "_lm_secs": t_lm, "_lm_steps": n_steps_lm}
        return hyps


# convenience -----------------------------------------------------------------------------------------------------------
def ids_to_text(proc, hyps):
    return [h.strip() for h in proc.batch_decode([h.tokens for h in hyps], skip_special_tokens=True)]
