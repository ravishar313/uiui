"""Official select_v2 S (dev-sel + dev-hold) for full-run checkpoints, via runner_lib.eval_only."""
import sys, json
from pathlib import Path
from uiui_root import load_yaml
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "autoresearch"))
import runner_lib as R
base = load_yaml(sys.argv[1]); out = Path(sys.argv[2]); L = R.locked_sets()
for ck in sys.argv[3:]:
    exp = "full1028-" + Path(ck).name; rows = out / exp
    if not (rows / "dev-hold.rows.jsonl").exists():
        ok, mins = R.eval_only(exp, base, ck, [L["dev-sel"], L["dev-hold"]], rows, out / f"{exp}.log")
        if not ok: print(exp, "EVAL FAILED", flush=True); continue
    print(json.dumps({"ckpt": ck, "sel": R.set_scores(rows / "dev-sel.rows.jsonl"), "hold": R.set_scores(rows / "dev-hold.rows.jsonl")}), flush=True)
print("SCORE_DONE", flush=True)
