#!/usr/bin/env python
"""Export a (fine-tuned) Phonon-2 checkpoint as a drop-in uiui/PhononCoreML bundle.

    export_bundle.py <checkpoint: model.fermion | ParakeetForTDT state_dict .pt> <out_dir> [options]

Writes <out_dir>/Phonon-2.mlmodelc (4-function multifunction program enc_5s/10s/15s/35s over one weight blob), decoder.bin
(phonon2-decoder-bin-v2), manifest.json (container_sha256 = sha256 of the checkpoint file), plus export_report.json.
Intermediates (per-function .mlpackage) go to <out_dir>/_work and are removed unless --keep-work.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

FUNCTIONS = [(5, False), (10, False), (15, False), (35, True)]     # seconds, takes `pos` input
DEFAULT_TEMPLATE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "assets")     # only the license / notice files are read from it


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def load_weights(args):
    import numpy as np
    from checkpoint import load_checkpoint, check_complete
    from encoder_graph import prepare_weights
    from fivevalue import requantize, non_five_value_layers
    from precision import detect_bits4
    ck = load_checkpoint(args.checkpoint)
    check_complete(ck.tensors)
    report = None
    if args.requantize_int4:      # PTQ of a dense / five-value model: every encoder linear becomes int4-g16 (format / speed check)
        from fivevalue import linear_names
        ck.bits4 = {k: "--requantize-int4" for k in linear_names(ck.tensors)}
    else:
        ck.bits4 = detect_bits4(ck.tensors, args.checkpoint, ck.int4, log)       # {weight name: how it was identified}
    bad = non_five_value_layers(ck.tensors, ck.bits4)
    log(f"checkpoint {ck.source}: {len(ck.tensors)} tensors, sha256 {ck.sha256[:16]}..., raw container records {len(ck.raw)}; "
        f"encoder linears off the five-value grid: {len(bad)} layers ({sum(bad.values())} rows)")
    if args.requantize_int4:
        snapped = Path(args.out) / "_work" / "snapped.npz"
        if args._build_fn is not None and snapped.exists():
            z = np.load(snapped)
            for k in z.files:
                ck.tensors[k.replace("|", ".")] = z[k]
        else:
            from precision import requantize_int4
            requantize_int4(ck.tensors, log)
            if args._build_fn is None:
                from fivevalue import linear_names
                snapped.parent.mkdir(parents=True, exist_ok=True)
                np.savez(snapped, **{k.replace(".", "|"): ck.tensors[k] for k in linear_names(ck.tensors)})
        ck.raw = {k: v for k, v in ck.raw.items() if not k.startswith("encoder.")}
        bad = non_five_value_layers(ck.tensors, ck.bits4)
    elif args.requantize:
        snapped = Path(args.out) / "_work" / "snapped.npz"
        if args._build_fn is not None and snapped.exists():       # children reuse the parent's snapped weights
            z = np.load(snapped)
            for k in z.files:
                ck.tensors[k.replace("|", ".")] = z[k]
        else:
            report = requantize(ck.tensors, log, skip=ck.bits4)
            if args._build_fn is None:
                from fivevalue import linear_names
                snapped.parent.mkdir(parents=True, exist_ok=True)
                np.savez(snapped, **{k.replace(".", "|"): ck.tensors[k] for k in linear_names(ck.tensors)})
        bad = non_five_value_layers(ck.tensors, ck.bits4)
        ck.raw = {k: v for k, v in ck.raw.items() if not k.startswith("encoder.")}
    elif bad and not args.allow_lossy:
        raise SystemExit(f"{len(bad)} encoder linears are not five-value (e.g. {next(iter(bad))}). Use --requantize to snap them "
                         f"to five values per row, or --allow-lossy to palettise them with a 6-bit k-means LUT instead.")
    return ck, prepare_weights(ck.tensors), report, bad


def build_function(args, seconds: int, with_pos: bool):
    from convert import convert_function, compress
    ck, g, _r, _b = load_weights(args)
    ml = convert_function(g, seconds, with_pos, log)
    ml = compress(ml, log, allow_lossy=args.allow_lossy, bits4=sorted(ck.bits4))
    path = Path(args.out) / "_work" / f"enc_{seconds}s.mlpackage"
    if path.exists():
        shutil.rmtree(path)
    ml.save(str(path))
    log(f"saved {path} ({du(path) / 1e6:.0f} MB)")


def bits4_size_estimate(tensors: dict, bits4: dict) -> dict:
    """Bytes of each 4-bit layer as stored: uint4 indices (O*I/2) + one 16-entry fp16 LUT per 16 output rows."""
    return {n: tensors[n].shape[0] * tensors[n].shape[1] // 2 + tensors[n].shape[0] // 16 * 16 * 2 for n in sorted(bits4)}


def du(p: Path) -> int:
    return sum(f.stat().st_size for f in Path(p).rglob("*") if f.is_file())


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("checkpoint")
    ap.add_argument("out")
    ap.add_argument("--requantize", action="store_true", help="snap encoder linears that are not five-value to {0,+-lo,+-hi} per row (dense fine-tunes)")
    ap.add_argument("--requantize-int4", action="store_true", help="PTQ: snap ALL encoder linears to int4-g16 (MSE-optimal group scales) and export them as 4-bit LUTs")
    ap.add_argument("--allow-lossy", action="store_true", help="palettise rows that are not five-value with a 6-bit k-means LUT (lossy; no exactness check for them)")
    ap.add_argument("--jobs", type=int, default=4, help="functions converted in parallel (default 4)")
    ap.add_argument("--functions", default="5,10,15,35", help="comma list of window seconds to include (default all four)")
    ap.add_argument("--keep-work", action="store_true")
    ap.add_argument("--decoder-dtype", default="int6p", choices=["int6p", "float32", "float16"],
                    help="decoder.bin matrix storage: int6p = format v2 (default, the shipped format); float32/float16 = uncompressed format v3")
    ap.add_argument("--decoder-only", action="store_true", help="write only decoder.bin + manifest.json + licences (reuse an existing Phonon-2.mlmodelc in <out>)")
    ap.add_argument("--skip-verify", action="store_true")
    ap.add_argument("--license-from", default=DEFAULT_TEMPLATE, help="bundle dir to copy license/notice files from (optional)")
    ap.add_argument("--_build-fn", type=int, default=None, help=argparse.SUPPRESS)
    args = ap.parse_args()
    args.out = str(Path(args.out).resolve())
    wanted = [int(x) for x in args.functions.split(",")]
    fns = [(s, p) for s, p in FUNCTIONS if s in wanted]
    if args._build_fn is not None:
        return build_function(args, args._build_fn, dict(FUNCTIONS)[args._build_fn])

    t_all = time.time()
    out = Path(args.out)
    work = out / "_work"
    out.mkdir(parents=True, exist_ok=True)
    work.mkdir(exist_ok=True)
    report = {"checkpoint": str(Path(args.checkpoint).resolve()), "requantize": args.requantize, "functions": [s for s, _ in fns]}

    ck, g, rq, bad = load_weights(args)
    report["off_grid_layers_after"] = len(bad)
    if ck.bits4:
        report["bits4_layers"] = sorted(ck.bits4)
        report["bits4_sources"] = sorted(set(ck.bits4.values()))
        report["bits4_estimated_bytes"] = bits4_size_estimate(ck.tensors, ck.bits4)
    if rq is not None:
        report["requantize_report"] = rq
    # 1. decoder.bin  (cheap, done first so a bad checkpoint fails early)
    from decoder_bin import write_decoder_bin
    dstats = write_decoder_bin(out / "decoder.bin", ck.tensors, ck.raw, ck.sha256, dtype=args.decoder_dtype)
    report["decoder_quant_rel_err"] = dstats
    log(f"decoder.bin written ({(out / 'decoder.bin').stat().st_size / 1e6:.1f} MB); container_sha256 {ck.sha256}")
    if not args.skip_verify and args.decoder_dtype != "int6p":
        from verify import verify_decoder_bin
        report["decoder_verify"] = verify_decoder_bin(out / "decoder.bin", ck.tensors, log)

    if not args.decoder_only:
        # 2. one conversion + compression per function, in parallel subprocesses
        t0 = time.time()
        procs = []
        pending = [s for s, _ in fns]
        running = []
        base = [sys.executable, str(HERE / "export_bundle.py"), args.checkpoint, str(out), "--jobs", "1"]
        if args.requantize:
            base.append("--requantize")
        if args.requantize_int4:
            base.append("--requantize-int4")
        if args.allow_lossy:
            base.append("--allow-lossy")
        logs = {}
        while pending or running:
            while pending and len(running) < max(1, args.jobs):
                s = pending.pop(0)
                lf = open(work / f"enc_{s}s.log", "w")
                running.append((s, subprocess.Popen(base + ["--_build-fn", str(s)], stdout=lf, stderr=subprocess.STDOUT), lf))
                log(f"started enc_{s}s (log {lf.name})")
            for item in list(running):
                s, p, lf = item
                if p.poll() is not None:
                    lf.close()
                    running.remove(item)
                    if p.returncode != 0:
                        print(open(work / f"enc_{s}s.log").read()[-3000:])
                        raise SystemExit(f"enc_{s}s failed")
                    log(f"finished enc_{s}s")
            time.sleep(2)
        report["convert_compress_s"] = round(time.time() - t0, 1)

        # 3. multifunction merge with shared weights
        import warnings
        warnings.filterwarnings("ignore")
        import coremltools as ct
        t0 = time.time()
        desc = ct.utils.MultiFunctionDescriptor()
        for s, _ in fns:
            desc.add_function(str(work / f"enc_{s}s.mlpackage"), src_function_name="main", target_function_name=f"enc_{s}s")
        desc.default_function_name = "enc_15s" if any(s == 15 for s, _ in fns) else f"enc_{fns[0][0]}s"
        pkg = work / "Phonon-2.mlpackage"
        if pkg.exists():
            shutil.rmtree(pkg)
        ct.utils.save_multifunction(desc, str(pkg))
        report["merge_s"] = round(time.time() - t0, 1)
        report["package_bytes"] = du(pkg)
        report["per_function_package_bytes"] = {f"enc_{s}s": du(work / f"enc_{s}s.mlpackage") for s, _ in fns}
        log(f"merged -> {pkg} {report['package_bytes'] / 1e6:.0f} MB (sum of single-function packages "
            f"{sum(report['per_function_package_bytes'].values()) / 1e6:.0f} MB)")

        # 4. exactness check of the stored LUTs
        if not args.skip_verify:
            from verify import verify_package
            t0 = time.time()
            from precision import hf_to_graph_key
            report["lut_verify"] = verify_package(str(pkg), g, log, strict=not args.allow_lossy, bits4={hf_to_graph_key(n) for n in ck.bits4})
            report["verify_s"] = round(time.time() - t0, 1)

        # 5. compile -> Phonon-2.mlmodelc
        mlc = out / "Phonon-2.mlmodelc"
        if mlc.exists():
            shutil.rmtree(mlc)
        tmp = work / "compiled"
        shutil.rmtree(tmp, ignore_errors=True)
        tmp.mkdir()
        t0 = time.time()
        if shutil.which("xcrun"):
            subprocess.run(["xcrun", "coremlcompiler", "compile", str(pkg), str(tmp)], check=True, capture_output=True)
            shutil.move(str(tmp / "Phonon-2.mlmodelc"), str(mlc))
            report["coremlcompiler_s"] = round(time.time() - t0, 1)
            report["mlmodelc_bytes"] = du(mlc)
            log(f"compiled {mlc} {report['mlmodelc_bytes'] / 1e6:.0f} MB in {report['coremlcompiler_s']} s")
        else:   # Linux: ship the .mlpackage; the Mac compiles it (export/compile_bundle.sh)
            dst = out / "Phonon-2.mlpackage"
            shutil.rmtree(dst, ignore_errors=True)
            shutil.copytree(pkg, dst)
            log(f"no xcrun: left {dst} uncompiled; run export/compile_bundle.sh <bundle> on the Mac")

    # 6. manifest.json
    man = json.load(open(HERE / "assets" / "manifest.template.json"))
    man["container_sha256"] = ck.sha256
    man["functions_s"] = [float(s) if False else s for s, _ in fns]
    man["pos_input"] = {str(s): bool(p) for s, p in fns}
    man["weights"] = ("exact five-value palettes (sparse-g16-6b: 1-bit zero mask + 64-entry fp16 LUT per 16 output rows), 16-bit float activations; "
                      "one weight blob shared by all functions; relative keys constant-folded per function (centred slices of the 15 s table; "
                      "relative_k_proj in-graph for the pos-input function)")
    man["export"] = {"tool": "speech/export/export_bundle.py", "checkpoint_sha256": ck.sha256, "requantize": bool(args.requantize),
                     "allow_lossy": bool(args.allow_lossy)}
    if args.decoder_dtype != "int6p":       # unchanged manifest for the default v2 export
        man["export"]["decoder_dtype"] = args.decoder_dtype
        man["decoder_bin"] = ("prediction network, joint and vocabulary: uncompressed " + args.decoder_dtype +
                              " matrices and biases (format v3), fp32 accumulate in the app")
    if ck.bits4:       # unchanged manifest for pure five-value exports
        man["export"]["bits4_layers"] = len(ck.bits4)
        man["weights"] += (f"; {len(ck.bits4)} encoder linears are exact 4-bit instead (int4 x per-16-row scale: 16-entry fp16 LUT per 16 output "
                           f"rows, uint4 indices, no zero mask)")
    with open(out / "manifest.json", "w") as f:
        json.dump(man, f, indent=1)
    # licences / notices (not needed by the runtime)
    lic = Path(args.license_from) if Path(args.license_from).exists() else HERE / "assets"
    for name in ("LICENSE-CODE-Apache-2.0.txt", "LICENSE-WEIGHTS-CC-BY-4.0.txt", "NOTICE"):
        if (lic / name).exists():
            shutil.copy(lic / name, out / name)
    report["total_s"] = round(time.time() - t_all, 1)
    (out / "export_report.json").write_text(json.dumps(report, indent=1))
    if not args.keep_work:
        shutil.rmtree(work, ignore_errors=True)
    log(f"done in {report['total_s']} s -> {out}")


if __name__ == "__main__":
    main()
