"""4-bit (int4, per-16-row-group scale) snap / LUT round-trip.  python -m pytest tests/test_int4.py"""
import json
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from precision import (GROUP, detect_bits4, fit_scales, hf_to_const, hf_to_graph_key, is_int4_grouped, max_group_levels,  # noqa: E402
                       quantize_int4_groups, write_precision_json)
from checkpoint import _project_qat  # noqa: E402
from fivevalue import non_five_value_layers, requantize  # noqa: E402
from convert import make_lut4_fn  # noqa: E402

NAME = "encoder.layers.3.feed_forward1.linear1.weight"


def _w(o=64, i=96, seed=0):
    return np.random.default_rng(seed).normal(size=(o, i)).astype(np.float32) * 0.05


def test_fit_and_snap_is_on_grid_and_idempotent():
    w = _w()
    s = fit_scales(w)
    q = quantize_int4_groups(w, s)
    assert q.dtype == np.float32 and max_group_levels(q) <= 16 and is_int4_grouped(q)
    assert not is_int4_grouped(w)
    assert np.array_equal(quantize_int4_groups(q, s), q)                          # idempotent
    ints = q / np.repeat(s, GROUP)[:, None]
    assert np.allclose(ints, np.rint(ints), atol=1e-4) and ints.min() >= -8 and ints.max() <= 7
    assert np.linalg.norm(q - w) / np.linalg.norm(w) < 0.12                        # 4-bit error on Gaussian weights ~ 0.1


def test_lut_roundtrip_bit_exact_through_fp16():
    w = _w(seed=1)
    s = fit_scales(w)
    q = quantize_int4_groups(w, s).astype(np.float16)
    fn = make_lut4_fn()
    back = np.empty_like(q)
    for g in range(q.shape[0] // GROUP):
        blk = q[g * GROUP:(g + 1) * GROUP]
        lut, idx = fn(blk)
        assert lut.shape == (16,) and idx.max() < 16
        back[g * GROUP:(g + 1) * GROUP] = lut[idx].reshape(blk.shape)
    assert np.array_equal(back, q)


def test_lut_rejects_off_grid_group():
    with pytest.raises(ValueError):
        make_lut4_fn()(_w(16, 64).astype(np.float16))


def test_pow2_scaling_keeps_grid():          # encoder_graph scales ff2/o/pw2 weights by 2^-k; the LUT stays <= 16 values
    q = quantize_int4_groups(_w(), fit_scales(_w()))
    assert max_group_levels(q * np.float32(0.5 / 64)) <= 16


def test_state_dict_projection_marks_int4():
    w = _w(32, 48, seed=2)
    s = fit_scales(w)
    base = NAME[:-len(".weight")]
    sd = {base + ".parametrizations.weight.original": w, base + ".parametrizations.weight.0.scale": s.reshape(-1, 1) * -1}
    hint = set()
    out = _project_qat(sd, hint)
    assert hint == {NAME} and np.array_equal(out[NAME], quantize_int4_groups(w, s))


def test_detect_sources(tmp_path):
    q = quantize_int4_groups(_w(), fit_scales(_w()))
    other = "encoder.layers.3.feed_forward1.linear2.weight"
    t = {NAME: q, other: _w(seed=5)}
    ck = str(tmp_path / "model.safetensors")
    log = lambda *a: None
    assert detect_bits4(t, ck, None, log) == {NAME: "weights (<= 16 values per 16-row group)"}   # from the weights
    from safetensors.numpy import save_file
    save_file({NAME[:-7] + ".bits4_scale": np.ones(4, np.float32)}, str(tmp_path / "qat_scales.safetensors"))
    assert detect_bits4(t, ck, None, log) == {NAME: "qat_scales.safetensors"}
    write_precision_json(tmp_path / "precision.json", [NAME])
    assert detect_bits4(t, ck, None, log) == {NAME: "precision.json"}
    write_precision_json(tmp_path / "precision.json", [other])                   # listed but not on the grid -> refused
    with pytest.raises(SystemExit):
        detect_bits4(t, ck, None, log)
    write_precision_json(tmp_path / "precision.json", [])
    assert detect_bits4(t, ck, None, log) == {}


def test_requantize_and_off_grid_skip_int4_layers():
    q = quantize_int4_groups(_w(), fit_scales(_w()))
    t = {NAME: q.copy()}
    assert NAME in non_five_value_layers(t) and non_five_value_layers(t, {NAME}) == {}
    requantize(t, lambda *a: None, skip={NAME})
    assert np.array_equal(t[NAME], q)


def test_name_maps():
    assert hf_to_const(NAME) == "blocks_3_ff1_l1_to_fp16"
    assert hf_to_const("encoder.layers.12.conv.pointwise_conv2.weight") == "blocks_12_pw2_to_fp16"
    assert hf_to_graph_key("encoder.layers.12.self_attn.o_proj.weight") == "b12.att.o"


def _toy_ml(ws):
    import torch
    import coremltools as ct

    class M(torch.nn.Module):
        def __init__(self):
            super().__init__()
            for n, w in ws.items():
                setattr(self, n, torch.nn.Parameter(torch.from_numpy(w), requires_grad=False))

        def forward(self, x):
            for n in ws:
                x = torch.nn.functional.linear(x, getattr(self, n))
            return x

    x = torch.zeros(1, 4, 1024)
    tr = torch.jit.trace(M().eval(), x)
    return ct.convert(tr, inputs=[ct.TensorType(name="x", shape=(1, 4, 1024), dtype=np.float32)], minimum_deployment_target=ct.target.macOS15,
                      compute_precision=ct.precision.FLOAT16, convert_to="mlprogram")


def _five(o, i, seed):
    r = np.random.default_rng(seed)
    lo, hi = r.uniform(.01, .02, (o, 1)), r.uniform(.03, .06, (o, 1))
    m = r.choice([0, 1, 2], size=(o, i), p=[.5, .3, .2])
    return (np.sign(r.normal(size=(o, i))) * np.where(m == 0, 0, np.where(m == 1, lo, hi))).astype(np.float32)


def test_compress_end_to_end_bit_exact_and_no_bits4_unchanged():
    """Core ML: 4-bit layers -> constexpr_lut_to_dense uint4 bit-exact; five-value layers -> sparse+6-bit as before."""
    pytest.importorskip("coremltools")
    from convert import compress
    from coremltools.converters.mil.frontend.milproto.load import load
    import coremltools as ct
    names = ("blocks_0_ff1_l1", "blocks_1_att_q")
    base = _five(1024, 1024, 0) + _w(1024, 1024, 9) * 0.3
    w4 = quantize_int4_groups(base, fit_scales(base))
    w5 = _five(1024, 1024, 1)
    ml = _toy_ml({names[0]: w4, names[1]: w5})
    out = compress(ml, lambda *a: None, bits4=["encoder.layers.0.feed_forward1.linear1.weight"])
    spec = out.get_spec()
    prog = load(spec, spec.specificationVersion, out.weights_dir)
    got = {}
    for op in prog.functions["main"].operations:
        if op.op_type in ("constexpr_lut_to_dense", "constexpr_sparse_to_dense"):
            got[op.outputs[0].name] = (op.op_type, op.materialized_val_inference(), op)
    assert got["blocks_0_ff1_l1_to_fp16_palettized"][0] == "constexpr_lut_to_dense"
    assert got["blocks_1_att_q_to_fp16_sparsified"][0] == "constexpr_sparse_to_dense"
    assert np.array_equal(got["blocks_0_ff1_l1_to_fp16_palettized"][1], w4.astype(np.float16))
    assert np.array_equal(got["blocks_1_att_q_to_fp16_sparsified"][1], w5.astype(np.float16))
    from coremltools.converters.mil.mil import types
    assert types.builtin_to_string(got["blocks_0_ff1_l1_to_fp16_palettized"][2].indices.dtype) == "uint4"
    # without bits4 the same compress call leaves both five-value layers sparse (same configs as before this change)
    ml2 = _toy_ml({names[0]: _five(1024, 1024, 7), names[1]: w5})
    out2 = compress(ml2, lambda *a: None)
    spec2 = out2.get_spec()
    p2 = load(spec2, spec2.specificationVersion, out2.weights_dir)
    ops2 = [o.op_type for o in p2.functions["main"].operations if o.op_type.startswith("constexpr")]
    assert ops2.count("constexpr_sparse_to_dense") == 2 and "constexpr_lut_to_dense" not in ops2


def test_training_module_matches_export_snap():
    """train/modes.py Int4Group / fit_int4_scales (torch) == export/precision.py (numpy): what is trained is what is exported."""
    torch = pytest.importorskip("torch")
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "train"))
    try:
        import modes
    except Exception as e:                                   # training deps (transformers, train_probe) not installed
        pytest.skip(f"train/modes.py not importable: {e}")
    w = torch.from_numpy(_w(64, 96, seed=3))
    s = modes.fit_int4_scales(w)
    assert np.allclose(s.numpy(), fit_scales(w.numpy()), rtol=1e-5)
    mod = modes.Int4Group(s)
    assert np.array_equal(mod(w).detach().numpy(), quantize_int4_groups(w.numpy(), s.numpy()))
    w.requires_grad_(True)
    mod(w).sum().backward()
    assert w.grad.abs().sum() > 0 and mod.scale.grad.abs().sum() > 0


def test_bits4_pattern_selection_round3_set():
    """Round-3 set: every linear of blocks 19-23 plus self_attn.o_proj everywhere -> 11*5 + 19 = 74 layers."""
    torch = pytest.importorskip("torch")
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "train"))
    try:
        import modes
    except Exception as e:
        pytest.skip(f"train/modes.py not importable: {e}")
    nn = torch.nn
    sub = lambda *ms: nn.ModuleDict(dict(ms))
    lin = lambda: nn.Linear(16, 16, bias=False)
    layers = nn.ModuleList([sub(("feed_forward1", sub(("linear1", lin()), ("linear2", lin()))), ("feed_forward2", sub(("linear1", lin()), ("linear2", lin()))),
                                ("self_attn", sub(*[(n, lin()) for n in ("q_proj", "k_proj", "v_proj", "o_proj", "relative_k_proj")])),
                                ("conv", sub(("pointwise_conv1", lin()), ("pointwise_conv2", lin())))) for _ in range(24)])
    model = nn.Module(); model.encoder = nn.Module(); model.encoder.layers = layers
    done = modes.apply_bits4(model, [r"^encoder\.layers\.(19|2[0-3])\.", r"self_attn\.o_proj"])
    assert len(done) == 74 and "encoder.layers.0.self_attn.o_proj" in done and "encoder.layers.0.self_attn.q_proj" not in done
    with pytest.raises(SystemExit):
        modes.apply_bits4(model, [r"nonexistent"])


# ---- lut4 grid: per-16-row-group 16-entry non-uniform LUT ----------------------------------------------------------
def _modes():
    pytest.importorskip("torch")
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "train"))
    try:
        import modes
    except Exception as e:
        pytest.skip(f"train/modes.py not importable: {e}")
    return modes


def test_lut4_fit_beats_uniform_and_is_fp16_16_values():
    modes = _modes()
    import torch
    w = torch.from_numpy(_w(64, 256, seed=11)) * torch.from_numpy(np.random.default_rng(1).standard_t(3, (64, 256)).astype(np.float32))
    lut = modes.fit_lut4(w)
    assert lut.shape == (4, 16) and torch.equal(lut, lut.half().float())
    q = modes.Lut4Group(lut)(w).detach()
    qi = modes.Int4Group(modes.fit_int4_scales(w))(w).detach()
    assert max_group_levels(q.numpy()) <= 16 and is_int4_grouped(q.numpy())
    assert (q - w).norm() < (qi - w).norm()                      # heavy tails: Lloyd-Max grid wins over the uniform one


def test_lut4_torch_matches_numpy_snap_and_trains_entries():
    modes = _modes()
    import torch
    from precision import quantize_lut4_groups
    w = torch.from_numpy(_w(32, 96, seed=4))
    mod = modes.Lut4Group(modes.fit_lut4(w))
    assert np.array_equal(mod(w).detach().numpy(), quantize_lut4_groups(w.numpy(), mod.lut.detach().numpy()))
    w.requires_grad_(True)
    (mod(w) ** 2).sum().backward()
    assert w.grad.abs().sum() > 0 and mod.lut.grad.abs().sum() > 0
    # entries given an unsorted / non-fp16 perturbation still export on a <= 16-value fp16 grid
    with torch.no_grad():
        mod.lut.add_(torch.randn_like(mod.lut) * 1e-3)
    q = mod(w.detach()).detach().numpy()
    assert max_group_levels(q) <= 16 and np.array_equal(q, q.astype(np.float16).astype(np.float32))


def test_lut4_lut_roundtrip_and_detection(tmp_path):
    modes = _modes()
    import torch
    w = _w(), 
    q = modes.Lut4Group(modes.fit_lut4(torch.from_numpy(w[0])))(torch.from_numpy(w[0])).detach().numpy()
    fn = make_lut4_fn()
    back = np.empty_like(q, np.float16)
    for g in range(q.shape[0] // GROUP):
        blk = q[g * GROUP:(g + 1) * GROUP].astype(np.float16)
        lut, idx = fn(blk)
        back[g * GROUP:(g + 1) * GROUP] = lut[idx].reshape(blk.shape)
    assert np.array_equal(back, q.astype(np.float16))
    t = {NAME: q}                                                    # detection from the weights works unchanged
    assert list(detect_bits4(t, str(tmp_path / "m.safetensors"), None, lambda *a: None)) == [NAME]
    from safetensors.numpy import save_file
    save_file({NAME[:-7] + ".bits4_lut": np.zeros((4, 16), np.float32)}, str(tmp_path / "qat_scales.safetensors"))
    assert detect_bits4(t, str(tmp_path / "m.safetensors"), None, lambda *a: None) == {NAME: "qat_scales.safetensors"}


def test_lut4_state_dict_projection():
    from precision import quantize_lut4_groups
    w = _w(32, 48, seed=2)
    lut = np.sort(np.random.default_rng(3).normal(size=(2, 16)).astype(np.float32) * 0.05, axis=1)
    base = NAME[:-len(".weight")]
    hint = set()
    out = _project_qat({base + ".parametrizations.weight.original": w, base + ".parametrizations.weight.0.lut": lut}, hint)
    assert hint == {NAME} and np.array_equal(out[NAME], quantize_lut4_groups(w, lut))


def test_compress_end_to_end_lut4_grid():
    """A lut4-grid weight (arbitrary 16 fp16 values per 16-row group) exports bit-exact through the same uint4 constexpr_lut_to_dense."""
    modes = _modes()
    import torch
    from convert import compress
    from coremltools.converters.mil.frontend.milproto.load import load
    from coremltools.converters.mil.mil import types
    w = torch.from_numpy(_five(1024, 1024, 5) + _w(1024, 1024, 8) * 0.3)
    q = modes.Lut4Group(modes.fit_lut4(w))(w).detach().numpy()
    out = compress(_toy_ml({"blocks_2_att_o": q}), lambda *a: None, bits4=["encoder.layers.2.self_attn.o_proj.weight"])
    spec = out.get_spec()
    prog = load(spec, spec.specificationVersion, out.weights_dir)
    ops = [o for o in prog.functions["main"].operations if o.op_type == "constexpr_lut_to_dense"]
    assert len(ops) == 1 and types.builtin_to_string(ops[0].indices.dtype) == "uint4"
    assert np.array_equal(ops[0].materialized_val_inference(), q.astype(np.float16))
