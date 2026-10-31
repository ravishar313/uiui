"""Stress source for the repetition guard: the dense teacher with every encoder linear snapped to 4 bits (int4-g16 or a 16-entry
LUT per 16 rows, as the shipped model), encoded on CPU and cached like lm/run_decode.py encode.  The decoder/joint stay as in the
teacher, so the cache is decoded with the teacher checkpoint.  Imports train/modes.py read-only (set PYTHONDONTWRITEBYTECODE=1).

python lm/ptq_stress.py --grid int4|lut4 --sets name=manifest --out cache-ptq-int4
"""
import argparse, importlib.util, os, sys, time
from pathlib import Path
import torch

HERE = Path(__file__).resolve().parent
from uiui_root import ROOT as _R, SPEECH
ROOT = Path(_R); SP = Path(SPEECH)
sys.path[:0] = [str(HERE), str(HERE.parent / "train")]
import run_decode as rd                       # noqa: E402
from tdt_decode import load_model, encode_batch   # noqa: E402


def snap(model, grid):
    sys.path.insert(0, str(SP / "trainability" / "scripts"))
    spec = importlib.util.spec_from_file_location("modes_ro", SP / "train" / "modes.py")
    modes = importlib.util.module_from_spec(spec); sys.modules["modes_ro"] = modes; spec.loader.exec_module(modes)
    sp = importlib.util.spec_from_file_location("fivevalue_ro", SP / "export" / "fivevalue.py")
    fv = importlib.util.module_from_spec(sp); sp.loader.exec_module(fv)
    n = 0
    with torch.no_grad():
        for name, mod in model.named_modules():
            if not fv.LINEAR_RE.match(name + ".weight"): continue
            w = mod.weight.detach().float(); w2 = w.reshape(w.shape[0], -1)
            if grid == "int4":
                q = modes.Int4Group(modes.fit_int4_scales(w2))(w2)
            else:
                q = modes.Lut4Group(modes.fit_lut4(w2))(w2)
            mod.weight.copy_(q.detach().reshape(w.shape)); n += 1
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", default=str(ROOT / "train/out/1027-044123-teacher-dense-r2/best/model.safetensors"))
    ap.add_argument("--grid", choices=["int4", "lut4"], required=True)
    ap.add_argument("--sets", required=True); ap.add_argument("--out", required=True); ap.add_argument("--threads", type=int, default=12)
    ap.add_argument("--bs", type=int, default=8)
    a = ap.parse_args()
    torch.set_num_threads(a.threads)
    model, proc = load_model(a.ckpt)
    print("snapped", snap(model, a.grid), "linears to", a.grid, flush=True)
    Path(a.out).mkdir(parents=True, exist_ok=True)
    for name, mf in rd.parse_sets(a.sets).items():
        items = rd.read_items(mf)
        order = sorted(range(len(items)), key=lambda i: items[i]["secs"]); enc = [None] * len(items); t0 = time.time()
        for s in range(0, len(order), a.bs):
            ids = order[s:s + a.bs]
            po, lens = encode_batch(model, proc, [rd.read_wave(items[i]["audio"]) for i in ids])
            for j, i in enumerate(ids): enc[i] = po[j, :int(lens[j])].clone()
        torch.save({"items": items, "enc": enc}, Path(a.out) / f"{name}.pt")
        print(f"{name}: {len(items)} clips {time.time() - t0:.0f}s", flush=True)


if __name__ == "__main__":
    main()
