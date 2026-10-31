"""Fast unit checks (no Core ML): python -m pytest tests  /  python tests/test_units.py"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from decoder_bin import pack6, unpack6, quantize_rows  # noqa: E402
from fivevalue import row_is_five_value, snap_rows, requantize  # noqa: E402
from checkpoint import _project_qat  # noqa: E402
from encoder_graph import pos_table, frames_for, sub_len  # noqa: E402


def test_pack6_roundtrip():
    q = np.random.default_rng(0).integers(-31, 32, size=(7, 13)).astype(np.int8)
    assert np.array_equal(unpack6(pack6(q), q.size).reshape(q.shape), q)


def test_decoder_quant_error_small():
    w = np.random.default_rng(1).normal(size=(64, 640)).astype(np.float32)
    q, s = quantize_rows(w)
    assert np.linalg.norm(q * s.astype(np.float32)[:, None] - w) / np.linalg.norm(w) < 0.05


def test_snap_makes_five_value_and_is_idempotent():
    w = np.random.default_rng(2).normal(size=(32, 1024)).astype(np.float32)
    assert not row_is_five_value(w).any()
    s, lo, hi = snap_rows(w)
    assert row_is_five_value(s).all()
    assert (np.abs(s) == 0).mean() > 0.2
    s2, _, _ = snap_rows(s)
    assert np.array_equal(s, s2) or np.abs(s2 - s).max() < 1e-3
    t = {"encoder.layers.0.feed_forward1.linear1.weight": s.copy()}
    rep = requantize(t, lambda *a: None)
    assert rep["encoder.layers.0.feed_forward1.linear1.weight"]["rows_snapped"] == 0
    assert np.array_equal(t["encoder.layers.0.feed_forward1.linear1.weight"], s)


def test_qat_projection():
    w = np.array([[0.01, 0.3, -0.31, 0.8, -0.75, 0.55]], np.float32)
    sd = {"m.parametrizations.weight.original": w, "m.parametrizations.weight.0.lo": np.array([[0.3]], np.float32),
          "m.parametrizations.weight.0.hi": np.array([[0.8]], np.float32)}
    out = _project_qat(sd)["m.weight"]
    assert np.allclose(out, [[0, 0.3, -0.3, 0.8, -0.8, 0.8]]), out


def test_frames():
    assert [frames_for(s) for s in (5, 10, 15, 35)] == [501, 1001, 1501, 3501]
    assert [sub_len(frames_for(s)) for s in (5, 10, 15, 35)] == [63, 126, 188, 438]
    assert pos_table(63).shape == (125, 1024)


if __name__ == "__main__":
    for n, f in list(globals().items()):
        if n.startswith("test_"):
            f(); print("ok", n)


# ---- decoder.bin: v2 int6 (unchanged) and v3 uncompressed float32 / float16 ----
import json  # noqa: E402
import struct  # noqa: E402
import pytest  # noqa: E402
from decoder_bin import write_decoder_bin, MATRICES, BIASES, unpack6  # noqa: E402

_SHAPES = {"decoder.embedding.weight": (8193, 640), "decoder.decoder_projector.weight": (640, 640), "joint.head.weight": (8198, 640),
           "decoder.decoder_projector.bias": (640,), "joint.head.bias": (8198,)}
_VOCAB = [f"t{i}" for i in range(8192)]


def _tensors(seed=0):
    rng = np.random.default_rng(seed)
    out = {}
    for n in MATRICES + BIASES:
        shape = _SHAPES.get(n) or ((2560, 640) if "weight" in n else (2560,))
        out[n] = (rng.normal(size=shape) * 0.1).astype(np.float32)
    return out


def _parse(path):
    buf = open(path, "rb").read()
    hlen = struct.unpack("<I", buf[:4])[0]
    h = json.loads(buf[4:4 + hlen])
    return buf, 4 + hlen, h


@pytest.mark.parametrize("dtype,npd", [("float32", "<f4"), ("float16", "<f2")])
def test_decoder_bin_v3_float_roundtrip_bit_exact(tmp_path, dtype, npd):
    from verify import verify_decoder_bin
    t = _tensors()
    p = tmp_path / "decoder.bin"
    stats = write_decoder_bin(p, t, {}, "0" * 64, vocab=_VOCAB, dtype=dtype)
    buf, body, h = _parse(p)
    assert h["format"] == "phonon2-decoder-bin-v3"
    assert {a["name"] for a in h["arrays"]} == set(MATRICES + BIASES)      # no .q / .scale arrays
    for a in h["arrays"]:
        assert a["dtype"] == dtype and a["offset"] % 64 == 0
        got = np.frombuffer(buf[body + a["offset"]: body + a["offset"] + a["bytes"]], npd).reshape(a["shape"])
        assert got.tobytes() == t[a["name"]].astype(npd).tobytes()
    if dtype == "float32":
        assert all(v == 0.0 for v in stats.values())                       # exactly the trained weights
    else:
        assert all(0 < v < 1e-3 for v in stats.values())
    assert verify_decoder_bin(p, t, lambda *_: None)["mismatched"] == []
    t2 = dict(t)
    t2["joint.head.weight"] = t["joint.head.weight"] + np.float32(1e-3)     # one differing matrix must be caught
    with pytest.raises(AssertionError):
        verify_decoder_bin(p, t2, lambda *_: None)


def test_decoder_bin_v2_default_unchanged_and_verified(tmp_path):
    from verify import verify_decoder_bin
    t = _tensors(1)
    p = tmp_path / "decoder.bin"
    write_decoder_bin(p, t, {}, "0" * 64, vocab=_VOCAB)
    _, _, h = _parse(p)
    assert h["format"] == "phonon2-decoder-bin-v2" and {a["dtype"] for a in h["arrays"]} == {"int6p", "float16"}
    assert verify_decoder_bin(p, t, lambda *_: None)["mismatched"] == []


SHIPPED = Path(__file__).resolve().parents[2].parent / "uiui" / "resources" / "Phonon" / "decoder.bin"


@pytest.mark.skipif(not SHIPPED.exists(), reason="shipped decoder.bin not present")
def test_v2_writer_reproduces_shipped_decoder_bin_byte_for_byte(tmp_path):
    buf, body, h = _parse(SHIPPED)
    arrays = {a["name"]: a for a in h["arrays"]}
    t, raw = {}, {}
    for n in MATRICES:
        a, s = arrays[n + ".q"], arrays[n + ".scale"]
        q = unpack6(buf[body + a["offset"]: body + a["offset"] + a["bytes"]], int(np.prod(a["shape"]))).reshape(a["shape"])
        sc = np.frombuffer(buf[body + s["offset"]: body + s["offset"] + s["bytes"]], "<f2").astype(np.float16)
        raw[n] = {"bits": 6, "q": q, "scale": sc}
        t[n] = q * sc.astype(np.float32)[:, None]
    for n in BIASES:
        a = arrays[n]
        t[n] = np.frombuffer(buf[body + a["offset"]: body + a["offset"] + a["bytes"]], "<f2").astype(np.float32).reshape(a["shape"])
    p = tmp_path / "decoder.bin"
    write_decoder_bin(p, t, raw, h["container_sha256"], vocab=h["vocab"])
    assert p.read_bytes() == SHIPPED.read_bytes()
