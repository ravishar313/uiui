"""Writer for decoder.bin, formats phonon2-decoder-bin-v2 (int6, default) and phonon2-decoder-bin-v3 (uncompressed float32/float16).

v2: 4-byte LE header length, JSON header, then 64-byte aligned arrays.

Matrices are per-row symmetric int6 (codes -31..31, two's complement in 6 bits, packed 4 codes -> 3 bytes little-endian
bit order) with fp16 row scales; biases are fp16.  Layout and key order reproduce the shipped file byte for byte when the
source is the same container.

v3 (--decoder-dtype float32|float16): every matrix is stored uncompressed under its own name (no .q/.scale arrays), shape [rows, cols],
little-endian IEEE floats; biases use the same dtype.  float32 is exactly the checkpoint's weights.  The app decodes these with its
FP32 path (fp32 accumulate); layout/alignment (64 bytes) and header keys otherwise match v2."""
from __future__ import annotations

import json
import struct
from pathlib import Path

import numpy as np

ASSETS = Path(__file__).resolve().parent / "assets"
MATRICES = ["decoder.embedding.weight",
            "decoder.lstm.weight_ih_l0", "decoder.lstm.weight_hh_l0", "decoder.lstm.weight_ih_l1", "decoder.lstm.weight_hh_l1",
            "decoder.decoder_projector.weight", "joint.head.weight"]
BIASES = ["decoder.lstm.bias_ih_l0", "decoder.lstm.bias_hh_l0", "decoder.lstm.bias_ih_l1", "decoder.lstm.bias_hh_l1",
          "decoder.decoder_projector.bias", "joint.head.bias"]
SPECIAL_RULE = "drop pieces <|...|>, <unk>, <pad>; '▁' -> space"


def quantize_rows(w: np.ndarray):
    """Per-row symmetric int6: scale = fp16(absmax/31), q = round(w/scale) in [-31, 31]."""
    w = np.asarray(w, np.float32)
    scale = (np.abs(w).max(axis=1) / 31.0).astype(np.float16)
    s = np.maximum(scale.astype(np.float32), 1e-12)[:, None]
    q = np.clip(np.rint(w / s), -31, 31).astype(np.int8)
    return q, scale


def pack6(q: np.ndarray) -> bytes:
    flat = (q.astype(np.int16).reshape(-1) & 63).astype(np.uint32)
    pad = (-len(flat)) % 4
    if pad:
        flat = np.concatenate([flat, np.zeros(pad, np.uint32)])
    g = flat.reshape(-1, 4)
    word = g[:, 0] | (g[:, 1] << 6) | (g[:, 2] << 12) | (g[:, 3] << 18)
    return np.stack([word & 255, (word >> 8) & 255, (word >> 16) & 255], axis=1).astype(np.uint8).tobytes()


def unpack6(buf: bytes, n: int) -> np.ndarray:
    b = np.frombuffer(buf, np.uint8).reshape(-1, 3).astype(np.uint32)
    word = b[:, 0] | (b[:, 1] << 8) | (b[:, 2] << 16)
    u = np.stack([(word >> s) & 63 for s in (0, 6, 12, 18)], axis=1).reshape(-1)[:n].astype(np.int16)
    return np.where(u >= 32, u - 64, u).astype(np.int8)


FLOAT_DTYPES = {"float32": "<f4", "float16": "<f2"}


def write_decoder_bin(path, tensors: dict, raw: dict, container_sha256: str, vocab: list | None = None, dtype: str = "int6p") -> dict:
    """tensors: HF-named float32 arrays; raw: container raw records (int6 q/scale reused verbatim when present)."""
    assert dtype == "int6p" or dtype in FLOAT_DTYPES, dtype
    vocab = vocab if vocab is not None else json.load(open(ASSETS / "vocab.json"))
    assert len(vocab) == 8192
    arrays, blobs, off = [], [], 0
    stats = {}

    def add(name, dtype, shape, data):
        nonlocal off
        arrays.append({"name": name, "dtype": dtype, "shape": list(shape), "offset": off, "bytes": len(data)})
        blobs.append((off, data))
        off = (off + len(data) + 63) // 64 * 64

    if dtype in FLOAT_DTYPES:
        for n in MATRICES + BIASES:
            t = np.asarray(tensors[n], np.float32)
            assert np.isfinite(t).all(), n
            data = np.ascontiguousarray(t.astype(FLOAT_DTYPES[dtype])).tobytes()
            if n in MATRICES:    # float32: exact; float16: relative rounding error
                back = np.frombuffer(data, FLOAT_DTYPES[dtype]).astype(np.float32).reshape(t.shape)
                stats[n] = float(np.linalg.norm(back - t) / max(np.linalg.norm(t), 1e-12))
            add(n, dtype, t.shape, data)
    for n in (MATRICES if dtype == "int6p" else []):
        r = raw.get(n)
        if r is not None and r.get("bits") == 6:
            q, scale = r["q"], r["scale"]
            stats[n] = 0.0
        else:
            q, scale = quantize_rows(tensors[n])
            err = np.linalg.norm(q * scale.astype(np.float32)[:, None] - tensors[n]) / max(np.linalg.norm(tensors[n]), 1e-12)
            stats[n] = float(err)
        assert q.shape == tensors[n].shape and int(np.abs(q).max()) <= 31
        add(n + ".q", "int6p", q.shape, pack6(q))
        add(n + ".scale", "float16", scale.shape, scale.astype("<f2").tobytes())
    for n in (BIASES if dtype == "int6p" else []):
        add(n, "float16", tensors[n].shape, tensors[n].astype("<f2").tobytes())
    header = {"format": "phonon2-decoder-bin-v2" if dtype == "int6p" else "phonon2-decoder-bin-v3", "arrays": arrays, "vocab": vocab, "durations": [0, 1, 2, 3, 4],
              "blank": 8192, "max_symbols": 10, "V": 8193, "E": 640, "H": 640, "nhead": 8198,
              "container_sha256": container_sha256, "special_rule": SPECIAL_RULE}
    hb = json.dumps(header).encode()
    with open(path, "wb") as f:
        f.write(struct.pack("<I", len(hb)))
        f.write(hb)
        pos = 0
        for o, data in blobs:
            f.write(b"\0" * (o - pos))
            f.write(data)
            pos = o + len(data)
    return stats
