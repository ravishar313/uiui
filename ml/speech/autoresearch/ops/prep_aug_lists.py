#!/usr/bin/env python3
"""Build noise.jsonl / babble.jsonl / rir.jsonl (path + seconds, 16 kHz mono) for train/augment.py.  CPU only, reads only below --raw.
   python3 -I prep_aug_lists.py --raw $UIUI_ML_ROOT/data/aug/raw --out $UIUI_ML_ROOT/data/aug [--noise-dirs ... ] 
Anything not 16 kHz mono is resampled to <out>/converted/ (WAV, PCM_16); files that cannot be read are skipped and counted."""
import argparse, json, subprocess, sys
from pathlib import Path
import numpy as np
import soundfile as sf

ap = argparse.ArgumentParser()
ap.add_argument("--raw", required=True); ap.add_argument("--out", required=True)
ap.add_argument("--rir-dirs", nargs="*", default=[]); ap.add_argument("--noise-dirs", nargs="*", default=[]); ap.add_argument("--babble-dirs", nargs="*", default=[])
a = ap.parse_args()
raw, out = Path(a.raw), Path(a.out)


def entry(p):
    """-> (path, seconds) of a 16 kHz mono version of p, or None."""
    try: i = sf.info(p)
    except Exception: return None
    if i.frames == 0: return None
    if i.samplerate == 16000 and i.channels == 1: return str(p), i.frames / 16000
    dst = out / "converted" / Path(p).relative_to(raw).with_suffix(".wav"); dst.parent.mkdir(parents=True, exist_ok=True)
    r = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", str(p), "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(dst)])
    if r.returncode: return None
    return str(dst), sf.info(dst).frames / 16000


def build(name, dirs, min_s=0.0):
    rows, bad, conv = [], 0, 0
    for d in dirs:
        for p in sorted(Path(d).rglob("*.wav")):
            e = entry(p)
            if e is None or e[1] < min_s: bad += 1; continue
            conv += e[0] != str(p); rows.append({"path": e[0], "seconds": round(e[1], 3)})
    (out / name).write_text("".join(json.dumps(r) + "\n" for r in rows))
    print(f"{name}: {len(rows)} files, {sum(r['seconds'] for r in rows) / 3600:.2f} h, skipped {bad}, converted {conv}")


if a.rir_dirs: build("rir.jsonl", a.rir_dirs)
if a.noise_dirs: build("noise.jsonl", a.noise_dirs, 0.5)
if a.babble_dirs: build("babble.jsonl", a.babble_dirs, 3.0)
