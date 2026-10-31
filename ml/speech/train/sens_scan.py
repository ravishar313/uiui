"""Five-value sensitivity scan: start from a dense checkpoint with every encoder linear snapped to five-value, then restore
one group of layers to dense at a time (each encoder block; each linear type across all blocks) and score dev-mix.  The WER
recovered per group (and per MB a 4-bit upgrade would cost) ranks candidates for qat.bits4.
Usage: python sens_scan.py <model.safetensors> <config.yaml> <out.json>"""
import json, re, sys, time
from pathlib import Path

import torch
import yaml
from uiui_root import load_yaml
from safetensors.torch import load_file

ROOT = Path(__file__).resolve().parent
sys.path[:0] = [str(ROOT), str(ROOT.parent / "export")]
import evaluate, modes                       # noqa: E402
from fivevalue import LINEAR_RE, snap_rows   # noqa: E402


def main():
    weights, config, out = sys.argv[1:4]
    E = load_yaml(config)["eval"]
    spec = next(s for s in E["sets"] if s["name"] == "dev-mix")
    items = evaluate.load_eval_sets([spec])["dev-mix"]
    model, proc = modes.tp.load()
    dense = load_file(weights)
    model.load_state_dict(dense, strict=False); model.to("cuda").eval()
    names = [k for k in dense if LINEAR_RE.match(k)]
    assert len(names) == 264, len(names)
    params = dict(model.named_parameters())
    snapped = {}
    t0 = time.time()
    for k in names:
        w = dense[k].float(); s = snap_rows(w.reshape(w.shape[0], -1).numpy())[0]
        snapped[k] = torch.from_numpy(s).reshape(w.shape)
    print(f"snapped 264 linears in {time.time() - t0:.0f}s", flush=True)

    def put(table, keys):
        with torch.no_grad():
            for k in keys: params[k].copy_(table[k].to(params[k].dtype))

    def score():
        m, *_ = evaluate.evaluate(model, proc, items, "cuda", E.get("batch_size", 16))
        return {c: m[c]["wer"] for c in ("ALL", "hinglish", "en") if c in m}

    res = {"dense": score()}
    put(snapped, names); res["all_snapped"] = score(); print("dense", res["dense"], "snapped", res["all_snapped"], flush=True)
    groups = {f"block{b:02d}": [k for k in names if int(LINEAR_RE.match(k).group(1)) == b] for b in range(24)}
    for t in ("feed_forward1", "feed_forward2", "self_attn.(q|k|v)_proj", "self_attn.o_proj", "self_attn.relative_k_proj", "conv.pointwise"):
        groups["type:" + t] = [k for k in names if re.search(t, k)]
    res["groups"] = {}
    for g, keys in groups.items():
        put(dense, keys); r = score(); put(snapped, keys)
        r["params_M"] = sum(dense[k].numel() for k in keys) / 1e6
        res["groups"][g] = r; print(g, r, flush=True)
        json.dump(res, open(out, "w"), indent=1)


if __name__ == "__main__":
    main()
