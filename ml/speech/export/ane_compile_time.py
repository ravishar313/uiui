#!/usr/bin/env python
"""Cold Neural Engine compile time per function: copy the bundle's mlmodelc to a fresh path (the ANE cache is keyed on the
path), then time MLModel load + first prediction for each function.   ane_compile_time.py <bundle> [--copy-to DIR]"""
import argparse, shutil, sys, time, uuid
from pathlib import Path
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parent))
import coremltools as ct
from encoder_graph import example_inputs, make_inputs

ap = argparse.ArgumentParser(); ap.add_argument("bundle"); ap.add_argument("--copy-to", default="/tmp/ane_cold")
a = ap.parse_args()
dst = Path(a.copy_to) / uuid.uuid4().hex[:8]
dst.mkdir(parents=True)
src = Path(a.bundle) / "Phonon-2.mlmodelc"
shutil.copytree(src, dst / "Phonon-2.mlmodelc")
tot = 0.0
for s, pos in ((5, False), (10, False), (15, False), (35, True)):
    t = time.time()
    m = ct.models.CompiledMLModel(str(dst / "Phonon-2.mlmodelc"), compute_units=ct.ComputeUnit.CPU_AND_NE, function_name=f"enc_{s}s")
    tl = time.time() - t
    mel = np.zeros((128, s * 100 - 1), np.float32)
    inp = make_inputs(mel, s, pos)
    t = time.time(); m.predict(inp); tp = time.time() - t
    tot += tl + tp
    print(f"enc_{s}s: load {tl:.1f} s, first predict {tp:.2f} s")
print(f"total cold {tot:.1f} s")
shutil.rmtree(dst, ignore_errors=True)
