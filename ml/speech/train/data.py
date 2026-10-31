"""Manifest sources -> duration-bucketed, weighted, resumable batches of (mel, labels).

Manifest rows: {"id", "audio" (16 kHz mono WAV; relative paths resolve against the manifest), "reference"|"text", "speaker"?}.
Mel features are computed by the model's own ParakeetFeatureExtractor inside DataLoader workers, per batch (so the
per-feature normalisation sees the same padded batch the model sees at inference time).
"""
from __future__ import annotations
import hashlib, json, random, re, unicodedata
from pathlib import Path
import numpy as np
import torch
import augment as aug

CACHE = Path(__file__).resolve().parent / ".cache"


# ---- text normalisation hook ------------------------------------------------------------------------------------
def _lower(t): return t.lower()
def _lower_nopunct(t): return re.sub(r"\s+", " ", re.sub(r"[^\w' ]+", " ", t.lower())).strip()
def _nfkc(t): return unicodedata.normalize("NFKC", t).replace("’", "'")
NORMALISERS = {"none": lambda t: t, "nfkc": _nfkc, "lower": _lower, "lower_nopunct": _lower_nopunct}


def get_normaliser(spec):
    """'none' (default: keep case + punctuation as Phonon emits them) | 'nfkc' | 'lower' | 'lower_nopunct' |
    'module.path:function' for a custom hook."""
    spec = spec or "none"
    if spec in NORMALISERS: return NORMALISERS[spec]
    mod, fn = spec.split(":")
    import importlib
    return getattr(importlib.import_module(mod), fn)


# ---- manifest reading --------------------------------------------------------------------------------------------
def _durations(paths, key):
    """Duration (s) + sample rate per audio path, cached on disk."""
    CACHE.mkdir(exist_ok=True)
    f = CACHE / f"dur-{hashlib.md5(key.encode()).hexdigest()[:12]}.json"
    cache = json.loads(f.read_text()) if f.exists() else {}
    import soundfile as sf
    dirty = False
    out = []
    for p in paths:
        st = None
        try: st = Path(p).stat()
        except OSError: pass
        k = f"{p}|{st.st_size if st else 0}|{int(st.st_mtime) if st else 0}"
        if k not in cache:
            try:
                i = sf.info(p); cache[k] = [i.duration, i.samplerate, i.channels]
            except Exception: cache[k] = None
            dirty = True
        out.append(cache[k])
    if dirty: f.write_text(json.dumps(cache))
    return out


def load_manifest(path, max_secs=None, normaliser=None, log=print, name=None):
    path = Path(path).expanduser().resolve()
    rows = [json.loads(l) for l in path.read_text().splitlines() if l.strip()]
    base = path.parent
    apaths = [str(Path(r["audio"]) if Path(r["audio"]).is_absolute() else base / r["audio"]) for r in rows]
    dur = _durations(apaths, str(path))
    items, skipped = [], {"too_long": 0, "missing": 0, "bad_rate": 0, "empty_text": 0}
    for r, p, d in zip(rows, apaths, dur):
        text = r.get("reference", r.get("text", ""))
        if normaliser: text = normaliser(text)
        if d is None: skipped["missing"] += 1; continue
        if d[1] != 16000: skipped["bad_rate"] += 1; continue
        if not text.strip(): skipped["empty_text"] += 1; continue
        if max_secs and d[0] > max_secs: skipped["too_long"] += 1; continue
        items.append({"id": r.get("id", ""), "audio": p, "text": text, "dur": float(d[0]), "speaker": r.get("speaker"),
                      "cat": r.get("cat") or r.get("category")})
    log(f"manifest {name or path.name}: {len(items)} clips ({sum(i['dur'] for i in items) / 3600:.2f} h) kept of {len(rows)}; "
        f"skipped {skipped} (limit {max_secs}s)")
    return items, skipped


def read_wave(path):
    import soundfile as sf
    w, sr = sf.read(path, dtype="float32", always_2d=False)
    if w.ndim > 1: w = w.mean(-1)
    return w


# ---- batching ---------------------------------------------------------------------------------------------------
class BucketSampler:
    """Infinite, deterministic, resumable stream of index-batches into one concatenated item list.

    Clips are drawn from the sources by weight (each source cycles through its own shuffled permutation), collected
    into pools of `batch_size * pool_mult`, sorted by duration inside a pool and cut into batches, whose order is
    shuffled. Resume = same seed + skip `start` batches (cheap: only indices are generated)."""

    def __init__(self, source_ranges, weights, batch_size, seed=0, pool_mult=64, start=0):
        self.ranges, self.w = source_ranges, np.asarray(weights, float) / np.sum(weights)
        self.bs, self.seed, self.pool_mult, self.start = batch_size, seed, pool_mult, start
        self.durs = None  # set by owner

    def __iter__(self):
        rng = random.Random(self.seed)
        nrng = np.random.RandomState(self.seed)
        perms = [None] * len(self.ranges); pos = [0] * len(self.ranges)
        n = 0
        while True:
            pool = []
            for _ in range(self.bs * self.pool_mult):
                s = int(nrng.choice(len(self.ranges), p=self.w))
                lo, hi = self.ranges[s]
                if perms[s] is None or pos[s] >= len(perms[s]):
                    perms[s] = nrng.permutation(hi - lo) + lo; pos[s] = 0
                pool.append(int(perms[s][pos[s]])); pos[s] += 1
            pool.sort(key=lambda i: self.durs[i])
            batches = [pool[i:i + self.bs] for i in range(0, len(pool) - self.bs + 1, self.bs)]
            rng.shuffle(batches)
            for b in batches:
                if n >= self.start: yield b
                n += 1


class Collator:
    """Runs in DataLoader workers: read audio, mel (HF extractor), SpecAugment, tokenise."""

    def __init__(self, base, specaug, items, seed=0, normalised_already=True, augment=None, max_secs=None):
        self.base, self.spec, self.items, self.seed = str(base), specaug or {}, items, seed
        # waveform augmentation (train only: this class is only built by TrainData); None unless data.augment is enabled
        self.aug = aug.Augmenter(augment, max_secs) if aug.enabled(augment) else None
        self._fe = self._tok = None

    def _init(self):
        from transformers import AutoProcessor
        torch.set_num_threads(1)
        p = AutoProcessor.from_pretrained(self.base)
        self._fe, self._tok = p.feature_extractor, p.tokenizer

    def __call__(self, idxs):
        if self._fe is None: self._init()
        its = [self.items[i] for i in idxs]
        waves = [read_wave(i["audio"]) for i in its]
        if self.aug is not None:   # before the mel extractor; may change a clip's length (speed), never the transcript
            bk = aug.batch_key(idxs)
            waves = [self.aug(w, (bk, ix)) for w, ix in zip(waves, idxs)]
        inp = self._fe(waves, sampling_rate=16000, return_tensors="pt",
                       padding=True, return_attention_mask=True)
        feats, am = inp["input_features"], inp["attention_mask"]
        if self.spec.get("enabled", True):
            feats = self._specaug(feats, am.sum(-1))
        ids = [self._tok.encode(i["text"], add_special_tokens=False) for i in its]
        return {"feats": feats, "mask": am, "ids": ids, "secs": sum(i["dur"] for i in its), "idxs": list(idxs)}

    def _specaug(self, x, lens):
        s = self.spec
        nf, wf = s.get("freq_masks", 2), s.get("freq_width", 27)
        nt, wt = s.get("time_masks", 10), s.get("time_width", 0.05)
        x = x.clone()
        for b in range(x.shape[0]):
            L, F = int(lens[b]), x.shape[2]
            for _ in range(nf):
                w = random.randint(0, wf); f0 = random.randint(0, max(F - w, 0)); x[b, :, f0:f0 + w] = 0
            tw = max(int(wt * L), 1) if wt < 1 else int(wt)
            for _ in range(nt):
                w = random.randint(0, tw); t0 = random.randint(0, max(L - w, 0)); x[b, t0:t0 + w, :] = 0
        return x


def worker_init(_):
    info = torch.utils.data.get_worker_info()
    random.seed(1234 + info.id + int(torch.initial_seed() % 100000))


class TrainData:
    """Builds items from all sources and yields collated batches forever."""

    def __init__(self, cfg, base, seed, start_batch=0, log=print):
        d = cfg
        self.norm = get_normaliser(d.get("text_norm"))
        self.items, ranges, weights, self.skipped = [], [], [], {}
        for s in d["sources"]:
            its, sk = load_manifest(s["manifest"], d.get("max_secs", 10.0), self.norm, log, s.get("name"))
            if s.get("max_clips"): its = its[: s["max_clips"]]
            if not its: raise SystemExit(f"source {s['manifest']} has no usable clips")
            ranges.append((len(self.items), len(self.items) + len(its))); weights.append(float(s.get("weight", 1.0)))
            self.items += its
            for k, v in sk.items(): self.skipped[k] = self.skipped.get(k, 0) + v
        log(f"training data: {len(self.items)} clips, {sum(i['dur'] for i in self.items) / 3600:.2f} h, skipped total {self.skipped}")
        if aug.enabled(d.get("augment")): log(f"waveform augmentation ON: {json.dumps(d['augment'])} (sampler batches by original duration; speed changes clip length by 1/factor, capped at max_secs)")
        self.ranges = ranges   # [(start, end)) item range per source, in d["sources"] order
        self.sampler = BucketSampler(ranges, weights, d.get("batch_size", 8), seed, d.get("pool_mult", 64), start_batch)
        self.sampler.durs = [i["dur"] for i in self.items]
        nw = d.get("num_workers", 4)
        self.loader = torch.utils.data.DataLoader(
            _Idx(len(self.items)), batch_sampler=self.sampler, collate_fn=_Passthrough(Collator(base, d.get("specaugment"), self.items, augment=d.get("augment"), max_secs=d.get("max_secs", 10.0))),
            num_workers=nw, prefetch_factor=d.get("prefetch", 4) if nw else None, persistent_workers=False,
            worker_init_fn=worker_init if nw else None, multiprocessing_context="spawn" if nw else None)

    def __iter__(self): return iter(self.loader)


class _Idx(torch.utils.data.Dataset):
    def __init__(self, n): self.n = n
    def __len__(self): return self.n
    def __getitem__(self, i): return i


class _Passthrough:
    def __init__(self, c): self.c = c
    def __call__(self, idxs): return self.c(idxs)
