"""Post-training quantization check: snap a dense checkpoint's encoder linears to the five-value grid (the exporter's
--requantize), then score it on a config's eval sets in PyTorch.  Answers "what would this model score once shipped?"
without a Core ML export.  Usage: python ptq_eval.py <model.safetensors> <config.yaml> --name NAME [--dense | --int4]
--int4: snap every encoder linear to int4-g16 instead (per-16-row-group MSE-optimal scale, values in [-8, 7] * scale; see export/precision.py)."""
import argparse, sys
from pathlib import Path

import numpy as np
import torch
import yaml
from uiui_root import load_yaml
from safetensors.torch import load_file

ROOT = Path(__file__).resolve().parent
sys.path[:0] = [str(ROOT), str(ROOT.parent / "export"), str(ROOT.parent / "lab")]
import evaluate, modes                       # noqa: E402
from fivevalue import LINEAR_RE, requantize  # noqa: E402
from tracker import Run                      # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("weights"); ap.add_argument("config"); ap.add_argument("--name", required=True)
    ap.add_argument("--dense", action="store_true", help="skip the snap (control: dense score)")
    ap.add_argument("--int4", action="store_true", help="snap all 264 encoder linears to int4-g16 instead of five-value")
    a = ap.parse_args()
    cfg = load_yaml(a.config); E = cfg["eval"]
    model, proc = modes.tp.load()
    sd = load_file(a.weights)
    with Run(a.name, kind="eval", config={"weights": a.weights, "requantize": not a.dense, "int4": a.int4, "config": a.config},
             tags=["ptq", "eval"], notes="PyTorch eval; " + ("dense control" if a.dense else "encoder linears snapped to " + ("int4-g16" if a.int4 else "five-value"))) as run:
        if a.int4 and not a.dense:
            n, errs = 0, []
            for k in [k for k in sd if LINEAR_RE.match(k)]:
                w = sd[k].float().reshape(sd[k].shape[0], -1).cuda()
                q = modes.Int4Group(modes.fit_int4_scales(w).cuda())(w).detach()
                errs.append(float((q - w).norm() / w.norm())); n += 1
                sd[k] = q.reshape(sd[k].shape).to(sd[k].dtype).cpu()
            assert n == 264, f"expected 264 encoder linears, found {n}"
            run.note(f"int4-g16: snapped {n} linears; rel. L2 error mean {np.mean(errs):.4f} max {np.max(errs):.4f}")
        elif not a.dense:
            np_sd = {k: v.float().reshape(v.shape[0], -1).numpy() for k, v in sd.items() if LINEAR_RE.match(k)}   # conv1x1 is [O, I, 1]
            assert len(np_sd) == 264, f"expected 264 encoder linears, found {len(np_sd)}"
            requantize(np_sd, run.note)
            for k, v in np_sd.items(): sd[k] = torch.from_numpy(v).reshape(sd[k].shape).to(sd[k].dtype)
        run.note("load: " + str(model.load_state_dict(sd, strict=False)))
        model.to("cuda").eval()
        for name, items in evaluate.load_eval_sets(E["sets"], run.note).items():
            metrics, samples, ms, _ = evaluate.evaluate(model, proc, items, "cuda", E.get("batch_size", 8))
            run.log_eval(0, name, metrics, samples, decode_ms=ms)
            run.note(f"eval {name} ({len(items)} clips): " + ", ".join(f"{k} {v['wer']}%" for k, v in sorted(metrics.items())))


if __name__ == "__main__":
    main()
