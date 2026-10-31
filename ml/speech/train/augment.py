"""Waveform-level augmentation for ASR training: background noise / babble at a sampled SNR, room reverb, Kaldi-style
speed perturbation and gain.  Pure numpy/scipy/soundfile, CPU only, runs inside DataLoader workers on 16 kHz mono float32.

Config (`data.augment`; absent, `enabled: false` or `prob: 0` => no Augmenter is built and the pipeline is untouched):

    augment: {prob: 0.5, noise: {prob: 0.6, snr_db: [5, 25], babble_prob: 0.3}, rir: {prob: 0.3},
              speed: {prob: 0.3, factors: [0.9, 1.1]}, gain_db: [-6, 6], seed: 0,
              noise_list: .../noise.jsonl, babble_list: .../babble.jsonl, rir_list: .../rir.jsonl}

Semantics
- `prob` gates the whole chain per clip; each stage then fires with its own prob.  Order: speed -> reverb -> noise -> gain -> clip.
- speed.factors: discrete choices (Kaldi uses 0.9/1.0/1.1); resampling, so pitch and tempo change together; factor f gives
  duration / f.  Choices that would push the clip past `max_secs` (the data.max_secs cap) are not used for that clip.
- rir: a random impulse response, direct-path aligned (output starts at the RIR peak, so no added delay), output length ==
  input length, output RMS rescaled to the dry RMS (level preserved).
- noise: with prob `babble_prob` the noise is babble (3-5 RMS-normalised speech segments summed), else one noise clip; random
  start offset in long files, looped when shorter than the clip; scaled so that mean-power SNR over the whole clip equals the
  sampled uniform snr_db.  Silent speech or silent noise => noise skipped.
- gain_db: uniform dB gain on the final mix; then hard clip to [-1, 1].
Randomness: every clip draws from default_rng([seed, clip index, hash(batch indices)]), so a batch is reproducible from
(seed, batch) regardless of which worker handles it (resume-safe) and never touches python's/numpy's global RNG (SpecAugment's
stream is unchanged).
"""
from __future__ import annotations
import json, zlib
from fractions import Fraction
from pathlib import Path
import numpy as np

SR = 16000
_EPS = 1e-10


def enabled(cfg) -> bool:
    return bool(cfg) and cfg.get("enabled", True) and float(cfg.get("prob", 0)) > 0


def _read_list(path):
    rows = []
    for l in Path(path).expanduser().read_text().splitlines():
        if l.strip():
            r = json.loads(l); rows.append((str(r["path"]), float(r["seconds"])))
    if not rows: raise ValueError(f"empty augmentation list {path}")
    return rows


def _power(x): return float(np.mean(np.square(x, dtype=np.float64))) if len(x) else 0.0


class Augmenter:
    def __init__(self, cfg, max_secs=None):
        c = cfg
        self.seed = int(c.get("seed", 0)); self.prob = float(c.get("prob", 0)); self.max_secs = max_secs
        n = c.get("noise") or {}; r = c.get("rir") or {}; s = c.get("speed") or {}
        self.noise_p = float(n.get("prob", 0)); self.snr = tuple(n.get("snr_db", (5, 25))); self.babble_p = float(n.get("babble_prob", 0))
        self.rir_p = float(r.get("prob", 0)); self.rir_max = int(float(r.get("max_secs", 1.0)) * SR)
        self.speed_p = float(s.get("prob", 0)); self.factors = [float(f) for f in s.get("factors", (0.9, 1.1))]
        self.gain = tuple(c["gain_db"]) if c.get("gain_db") else None
        self.babble_n = tuple(c.get("babble_speakers", (3, 5)))
        self.paths = {"noise": c.get("noise_list"), "babble": c.get("babble_list"), "rir": c.get("rir_list")}
        if self.noise_p > 0 and self.babble_p < 1 and not self.paths["noise"]: raise ValueError("augment.noise_list required (noise.prob>0)")
        if self.noise_p > 0 and self.babble_p > 0 and not self.paths["babble"]: raise ValueError("augment.babble_list required (babble_prob>0)")
        if self.rir_p > 0 and not self.paths["rir"]: raise ValueError("augment.rir_list required (rir.prob>0)")
        if self.snr[0] > self.snr[1]: raise ValueError("augment.noise.snr_db must be [lo, hi]")
        self._lists = {}; self._rir_cache = {}
        self._ratios = {f: _ratio(f) for f in self.factors}
        for k, p in self.paths.items():   # fail at construction (in the main process), not inside a worker
            need = {"noise": self.noise_p > 0 and self.babble_p < 1, "babble": self.noise_p > 0 and self.babble_p > 0, "rir": self.rir_p > 0}[k]
            if need: self._lists[k] = _read_list(p)

    # ---- lists / files ------------------------------------------------------------------------------------------
    def _pick(self, kind, rng):
        lst = self._lists[kind]; return lst[int(rng.integers(len(lst)))]

    def _segment(self, path, secs, n, rng):
        """n samples of an audio file: random start inside long files, looped (random phase) if shorter than n."""
        import soundfile as sf
        with sf.SoundFile(path) as f:
            total = f.frames
            if total >= n:
                f.seek(int(rng.integers(total - n + 1))); x = f.read(n, dtype="float32", always_2d=True)
            else:
                x = f.read(dtype="float32", always_2d=True)
        x = x.mean(-1) if x.shape[1] > 1 else x[:, 0]
        if len(x) < n:
            if len(x) == 0: return None
            x = np.roll(x, -int(rng.integers(len(x))))
            x = np.tile(x, -(-n // len(x)))[:n]
        return x

    def _rir(self, rng):
        path, secs = self._pick("rir", rng)
        h = self._rir_cache.get(path)
        if h is None:
            import soundfile as sf
            h, _ = sf.read(path, dtype="float32", always_2d=True); h = h.mean(-1)
            pk = int(np.argmax(np.abs(h))); h = h[pk:pk + self.rir_max].copy()   # direct-path aligned, truncated
            if len(self._rir_cache) < 4096: self._rir_cache[path] = h
        return h

    # ---- stages -------------------------------------------------------------------------------------------------
    def speed(self, w, f):
        from scipy.signal import resample_poly
        up, down = self._ratios[f]
        return resample_poly(w, up, down).astype(np.float32, copy=False)

    def reverb(self, w, h):
        from scipy.signal import oaconvolve
        if not np.any(h): return w
        out = oaconvolve(w, h.astype(np.float32), mode="full")[:len(w)].astype(np.float32)
        p0, p1 = _power(w), _power(out)
        return out * np.float32(np.sqrt(p0 / p1)) if p1 > _EPS else w

    def noise(self, w, rng):
        n = len(w); ps = _power(w)
        if ps < _EPS or n == 0: return w
        if self.babble_p > 0 and rng.random() < self.babble_p:
            k = int(rng.integers(self.babble_n[0], self.babble_n[1] + 1)); z = np.zeros(n, np.float32)
            for _ in range(k):
                p, s = self._pick("babble", rng); x = self._segment(p, s, n, rng)
                if x is None: continue
                px = _power(x)
                if px > _EPS: z += x * np.float32(1 / np.sqrt(px))
        else:
            p, s = self._pick("noise", rng); z = self._segment(p, s, n, rng)
            if z is None: return w
        pn = _power(z)
        if pn < _EPS: return w
        snr = float(rng.uniform(*self.snr))
        return w + z * np.float32(np.sqrt(ps / (pn * 10 ** (snr / 10))))

    # ---- entry point --------------------------------------------------------------------------------------------
    def __call__(self, wave, key):
        """wave: float32 mono 16 kHz.  key: ints identifying the clip (e.g. (batch_hash, item_index)); returns float32 (maybe different length)."""
        rng = np.random.default_rng([self.seed & 0xFFFFFFFF, *[int(k) & 0xFFFFFFFF for k in key]])
        if rng.random() >= self.prob: return wave
        w = wave
        if self.speed_p > 0 and rng.random() < self.speed_p:
            ok = [f for f in self.factors if not self.max_secs or len(w) / f / SR <= self.max_secs]
            if ok: w = self.speed(w, ok[int(rng.integers(len(ok)))])
        if self.rir_p > 0 and rng.random() < self.rir_p: w = self.reverb(w, self._rir(rng))
        if self.noise_p > 0 and rng.random() < self.noise_p: w = self.noise(w, rng)
        if self.gain: w = w * np.float32(10 ** (rng.uniform(*self.gain) / 20))
        return np.clip(w, -1.0, 1.0)


def _ratio(f):
    r = Fraction(1.0 / f).limit_denominator(32)   # new_len = len * up/down = len / f
    return r.numerator, r.denominator


def batch_key(idxs): return zlib.crc32(",".join(map(str, idxs)).encode())
