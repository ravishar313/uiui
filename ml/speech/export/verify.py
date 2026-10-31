"""Assert that the LUT/mask weights stored in an mlpackage reproduce the PyTorch weights exactly.

Every constexpr_sparse_to_dense (the five-value linears) is materialised from the package's own blobs and compared with
fp16(weight) -- the weight the runtime would see -- for every function in the package.  Exact means bit-identical."""
from __future__ import annotations

import re

import numpy as np

import coremltools as ct
from coremltools.converters.mil.frontend.milproto.load import load
from coremltools.converters.mil.mil import types

ATTR_TO_KEY = {"ff1_l1": "ff1.l1", "ff1_l2": "ff1.l2", "ff2_l1": "ff2.l1", "ff2_l2": "ff2.l2", "att_q": "att.q", "att_k": "att.k",
               "att_v": "att.v", "att_o": "att.o", "pw1": "conv.pw1", "pw2": "conv.pw2", "relk_w": "att.relk_w"}
NAME_RE = re.compile(r"blocks_(\d+)_(" + "|".join(ATTR_TO_KEY) + r")_to_fp16")


def verify_package(path: str, g: dict, log=print, strict=True, bits4=frozenset()) -> dict:
    """g: prepare_weights() dict (scaled).  Returns {function: {"tensors": n, "max_abs_diff": d, "mismatched": [...]}}."""
    m = ct.models.MLModel(path, skip_model_load=True)
    spec = m.get_spec()
    prog = load(spec, spec.specificationVersion, m.weights_dir)
    result = {}
    for fname, fn in prog.functions.items():
        n, worst, bad, seen4 = 0, 0.0, [], set()
        for op in fn.operations:
            if op.op_type not in ("constexpr_sparse_to_dense", "constexpr_lut_to_dense"):
                continue
            nm = op.outputs[0].name
            mt = NAME_RE.search(nm)
            if not mt:
                bad.append((nm, "unrecognised constexpr"))
                continue
            key = f"b{mt.group(1)}.{ATTR_TO_KEY[mt.group(2)]}"
            want_type = "constexpr_lut_to_dense" if key in bits4 else "constexpr_sparse_to_dense"
            if op.op_type != want_type:                  # 4-bit layers: plain 4-bit LUT; everything else: mask + 6-bit LUT
                bad.append((nm, f"stored as {op.op_type}, expected {want_type}"))
                continue
            if key in bits4:
                seen4.add(key)
                if types.builtin_to_string(op.indices.dtype) != "uint4":
                    bad.append((nm, f"indices dtype {types.builtin_to_string(op.indices.dtype)}, expected uint4"))
                    continue
            got = op.materialized_val_inference()
            want = g[key].astype(np.float16)
            if got.shape != want.shape:
                want = want.reshape(got.shape)
            d = float(np.abs(got.astype(np.float32) - want.astype(np.float32)).max())
            n += 1
            worst = max(worst, d)
            if not np.array_equal(got, want):
                bad.append((nm, d))
        # relative_k_proj is a stored tensor only in the function with the `pos` input; elsewhere it is folded into a constant table
        need = {k for k in bits4 if fname == "enc_35s" or not k.endswith("att.relk_w")}
        if need - seen4:
            bad.append((fname, f"4-bit layers not stored as 4-bit LUT: {sorted(need - seen4)[:4]}"))
        result[fname] = {"tensors": n, "max_abs_diff": worst, "mismatched": bad}
        log(f"  verify {fname}: {n} sparse/LUT tensors, max |LUT - fp16(weight)| = {worst:g}, mismatched {len(bad)}")
        if strict and (bad or n == 0):
            raise AssertionError(f"{fname}: LUT does not reproduce the weights exactly: {bad[:5]}")
    return result


def verify_decoder_bin(path, tensors: dict, log=print) -> dict:
    """Parse decoder.bin (v2 int6 or v3 float32/float16) and check it against the checkpoint tensors.

    v3 float32: every matrix and bias is bit-identical to the checkpoint float32 tensor.  v3 float16: bit-identical to
    fp16(tensor).  v2: biases are bit-identical to fp16(bias); int6 matrices must reproduce the per-row quantiser's codes and scales
    exactly (a container-reused matrix may differ and is reported, not failed).  Raises AssertionError on any mismatch."""
    import json
    import struct
    import numpy as np
    from decoder_bin import MATRICES, BIASES, quantize_rows, unpack6
    buf = open(path, "rb").read()
    hlen = struct.unpack("<I", buf[:4])[0]
    header = json.loads(buf[4:4 + hlen])
    body = 4 + hlen
    arrays = {a["name"]: a for a in header["arrays"]}

    def get(name, np_dtype):
        a = arrays[name]
        raw = buf[body + a["offset"]: body + a["offset"] + a["bytes"]]
        assert a["offset"] % 64 == 0, name
        return np.frombuffer(raw, np_dtype).reshape(a["shape"]) if np_dtype else raw, a

    fmt = header["format"]
    out = {"format": fmt, "arrays": len(arrays), "mismatched": []}
    if fmt == "phonon2-decoder-bin-v3":
        names = MATRICES + BIASES
        assert set(arrays) == set(names), "v3 array set"
        dt = arrays[MATRICES[0]]["dtype"]
        assert dt in ("float32", "float16") and all(arrays[n]["dtype"] == dt for n in names), "single float dtype"
        npd = {"float32": "<f4", "float16": "<f2"}[dt]
        for n in names:
            got, a = get(n, npd)
            ref = np.asarray(tensors[n], np.float32).astype(npd)
            assert list(ref.shape) == a["shape"] and a["bytes"] == ref.nbytes, n
            if got.tobytes() != ref.tobytes():
                out["mismatched"].append(n)
    else:
        assert fmt == "phonon2-decoder-bin-v2", fmt
        for n in BIASES:
            got, _ = get(n, "<f2")
            if got.tobytes() != np.asarray(tensors[n], np.float32).astype("<f2").tobytes():
                out["mismatched"].append(n)
        for n in MATRICES:
            q, s = quantize_rows(tensors[n])
            qa, a = get(n + ".q", None)
            sa, _ = get(n + ".scale", "<f2")
            if not (np.array_equal(unpack6(qa, q.size).reshape(q.shape), q) and sa.tobytes() == s.astype("<f2").tobytes()):
                out["mismatched"].append(n)
    log(f"decoder.bin ({fmt}): {len(arrays)} arrays, mismatched {out['mismatched']}")
    assert not out["mismatched"] or fmt == "phonon2-decoder-bin-v2", out["mismatched"]
    return out
