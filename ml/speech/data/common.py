"""Shared helpers for the data pipeline (ingest: decode -> 16k mono PCM16 wav -> stage rows)."""
import io, json, os, subprocess, sys, time, hashlib
from math import gcd
from pathlib import Path
import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

from uiui_root import ROOT, SPEECH
DATA = Path(ROOT) / "data"
sys.path.insert(0, SPEECH + "/lab")
from tracker import Run  # noqa: E402

MIN_S, MAX_S = 0.5, 15.0


def decode(b, path_hint=""):
    """bytes -> (float32 mono, sr). soundfile first, ffmpeg fallback (mp3 etc.)."""
    try:
        x, sr = sf.read(io.BytesIO(b), dtype="float32", always_2d=True)
    except Exception:
        p = subprocess.run(["ffmpeg", "-v", "error", "-i", "pipe:0", "-f", "f32le", "-ac", "1", "-ar", "16000", "pipe:1"],
                           input=b, capture_output=True)
        if p.returncode or not p.stdout:
            raise RuntimeError("decode failed")
        return np.frombuffer(p.stdout, dtype=np.float32), 16000
    return x.mean(axis=1), sr


def to16k(x, sr):
    if sr != 16000:
        g = gcd(sr, 16000)
        x = resample_poly(x, 16000 // g, sr // g).astype(np.float32)
    return x


def spk_is_dev(speaker, source, pct=2):
    h = int(hashlib.md5(f"{source}|{speaker}".encode()).hexdigest(), 16)
    return h % 100 < pct


class Ingest:
    """Writes wavs under data/audio/<source>/ and rows to data/stage/<source>/rows.jsonl; resumable by shard."""
    def __init__(self, source, total_items, notes=""):
        self.source = source
        self.adir = DATA / "audio" / source
        self.sdir = DATA / "stage" / source
        self.adir.mkdir(parents=True, exist_ok=True)
        self.sdir.mkdir(parents=True, exist_ok=True)
        self.rows = open(self.sdir / "rows.jsonl", "a")
        self.stats_path = self.sdir / "stats.json"
        self.stats = json.loads(self.stats_path.read_text()) if self.stats_path.exists() else \
            dict(seen=0, kept=0, too_short=0, too_long=0, decode_fail=0, no_text=0, excluded=0, seconds=0.0, shards_done=[])
        self.done = set(self.stats["shards_done"])
        self.t0 = time.time()
        self.n0 = self.stats["seen"]
        self.run = Run(f"ingest-{source}", kind="data", total_steps=total_items, tags=["data", source], notes=notes)
        self.excl_spk = set()
        ep = DATA.parent / "evalsets"
        for m in ep.glob("*/manifest.jsonl"):
            for l in open(m):
                try:
                    s = json.loads(l).get("speaker")
                except Exception:
                    continue
                if s and s != "unknown":
                    self.excl_spk.add(str(s))

    def add(self, uid, audio_bytes, text, speaker, extra=None, array=None, sr=None):
        st = self.stats
        st["seen"] += 1
        if not text or not text.strip():
            st["no_text"] += 1; return
        if str(speaker) in self.excl_spk:
            st["excluded"] += 1; return
        try:
            if array is None:
                x, sr = decode(audio_bytes)
            else:
                x = array
            x = to16k(x, sr)
        except Exception:
            st["decode_fail"] += 1; return
        d = len(x) / 16000
        if d < MIN_S:
            st["too_short"] += 1; return
        if d > MAX_S:
            st["too_long"] += 1; return
        pk = np.clip(np.abs(x).max(), 1e-9, None)
        if pk < 1e-3:
            st["decode_fail"] += 1; return
        p = self.adir / f"{uid}.wav"
        sf.write(p, x, 16000, subtype="PCM_16")
        row = dict(id=uid, audio=str(p), text=text, speaker=str(speaker), source=self.source, seconds=round(d, 3))
        if extra:
            row.update(extra)
        self.rows.write(json.dumps(row, ensure_ascii=False) + "\n")
        st["kept"] += 1
        st["seconds"] += d

    def shard_done(self, name):
        self.rows.flush()
        self.stats["shards_done"].append(name)
        self.stats_path.write_text(json.dumps(self.stats, indent=1))
        el = time.time() - self.t0
        self.run.log(self.stats["seen"], rows=self.stats["kept"], hours=self.stats["seconds"] / 3600,
                     rows_per_s=(self.stats["seen"] - self.n0) / max(el, 1))
        self.run.note(f"{name} done: kept {self.stats['kept']} rows, {self.stats['seconds']/3600:.2f} h; "
                      f"short {self.stats['too_short']} long {self.stats['too_long']} fail {self.stats['decode_fail']}")

    def finish(self):
        self.rows.close()
        self.stats_path.write_text(json.dumps(self.stats, indent=1))
        self.run.finish()
