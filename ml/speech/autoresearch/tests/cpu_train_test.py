#!/usr/bin/env python3
"""CPU-only checks of the train.py additions (model.init_ckpt, train.max_minutes, final rows, --eval-only, distill) .  NEVER touches a GPU (CUDA_VISIBLE_DEVICES='').
    cd $UIUI_ML_ROOT/ar/code/train && CUDA_VISIBLE_DEVICES= python3 ../../tests/cpu_train_test.py
Scratch dir $UIUI_ML_ROOT/ar-test (tiny manifests of librispeech dev clips, 3 of 264 encoder linears as lut4 so the model builds in seconds)."""
import json, os, shutil, subprocess, sys, time
from pathlib import Path
import yaml

assert os.environ.get("CUDA_VISIBLE_DEVICES") == "", "run with CUDA_VISIBLE_DEVICES= (CPU only)"
HOME = Path(os.environ.get("UIUI_ML_ROOT") or "workspace").resolve(); T = HOME / "ar-test"; CODE = HOME / "ar/code/train"; PY = sys.executable
shutil.rmtree(T, ignore_errors=True); (T / "out").mkdir(parents=True)
rows = [json.loads(l) for l in open(HOME / "data/manifests/librispeech/dev.jsonl")]
rows = sorted([r for r in rows if r["seconds"] <= 4.5], key=lambda r: r["id"])
mk = lambda name, rs: (T / name).write_text("".join(json.dumps({"id": r["id"], "audio": r["audio"], "reference": r["reference"], "speaker": r["speaker"], "cat": "en"}) + "\n" for r in rs))
mk("train.jsonl", rows[:12]); mk("eval.jsonl", rows[12:16])
base = {"name": "cpu-test", "mode": "qat", "tags": ["test"], "data": {"sources": [{"name": "t", "manifest": str(T / "train.jsonl"), "weight": 1.0}], "batch_size": 2, "max_secs": 5.0, "num_workers": 0, "text_norm": "none"},
        "optim": {"lr": 1e-4, "warmup_steps": 1, "min_lr": 0.0, "accum": 1}, "train": {"total_steps": 2, "log_every": 1, "seed": 3}, "ema": {"enabled": True, "decay": 0.9}, "model": {"bn_eval": True},
        "qat": {"bits4": ["^encoder\\.layers\\.2[0-2]\\.feed_forward1\\.linear1$"], "bits4_init": "current", "bits4_grid": "lut4"}, "precision": "fp32",
        "eval": {"every": 10 ** 9, "at_start": False, "batch_size": 4, "sets": [{"name": "tiny", "manifest": str(T / "eval.jsonl")}]},
        "checkpoint": {"every": 10 ** 9, "every_minutes": 0, "keep_last": 1, "keep_optim": 1}, "out_dir": str(T / "out")}
env = dict(os.environ, UIUI_LAB_RUNS=str(T / "runs"), OMP_NUM_THREADS="8", MKL_NUM_THREADS="8")
fails = []


def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name + (f"   {extra}" if extra and not cond else ""), flush=True); (None if cond else fails.append(name))


def train(name, over, extra_args=(), expect_rc=0):
    cfg = json.loads(json.dumps(base))
    for k, v in over.items():
        d = cfg
        for p in k.split(".")[:-1]: d = d.setdefault(p, {})
        d[k.split(".")[-1]] = v
    cfg["run_id"] = name; cp = T / f"{name}.yaml"; cp.write_text(yaml.safe_dump(cfg)); t = time.time()
    p = subprocess.run(["nice", "-n", "19", PY, "train.py", "--config", str(cp), *extra_args], cwd=CODE, env=env, capture_output=True, text=True)
    (T / f"{name}.log").write_text(p.stdout + "\n" + p.stderr); wall = (time.time() - t) / 60
    check(f"{name}: exit {expect_rc}", p.returncode == expect_rc, (p.stdout + p.stderr)[-600:])
    return T / "out" / name, wall, p.stdout + p.stderr


# A: defaults identical (no new keys): trains 3 steps, final eval, no rows file, no final-step surprises
a, _, _ = train("A-default", {})
check("A: FINISHED at step 2 and step dir is resumable-format", (a / "FINISHED").read_text().strip() == "2" and (a / "step-0000002/COMPLETE").exists() and (a / "step-0000002/optim.pt").exists())
check("A: no rows file unless eval.save_rows", not list(a.glob("*.rows.jsonl")))
fa = json.loads((a / "final.json").read_text()); check("A: final.json says budget not hit", fa["budget_hit"] is False and fa["step"] == 2)
# B: eval-only on A's checkpoint gives hypotheses identical to A's own final eval (both EMA); and init load is exact
ck = a / "step-0000002"
b, _, _ = train("B-eval-only", {"model.init_ckpt": str(ck), "eval.save_rows": True}, ["--eval-only"])
a2, _, _ = train("A2-rows", {"eval.save_rows": True})        # same seed/config as A => same final model; rows persisted
ra = [json.loads(l) for l in open(a2 / "tiny.rows.jsonl")]; rb = [json.loads(l) for l in open(b / "tiny.rows.jsonl")]
check("B: rows have id/cat/reference/hypothesis", set(ra[0]) >= {"id", "cat", "reference", "hypothesis", "speaker"} and len(ra) == 4)
check("B: eval-only from init_ckpt reproduces the saved model's EMA hypotheses exactly", [r["hypothesis"] for r in ra] == [r["hypothesis"] for r in rb], f"{[r['hypothesis'] for r in ra][:2]} vs {[r['hypothesis'] for r in rb][:2]}")
# C: init_ckpt + max_minutes: fresh step counter/schedule, budget stops early, evaluation not counted, final eval + resumable save
c, wall, out = train("C-init-budget", {"model.init_ckpt": str(ck), "train.total_steps": 1000, "train.max_minutes": 0.15, "eval.every": 1, "eval.save_rows": True})
fc = json.loads((c / "final.json").read_text())
check("C: stopped by the wall-clock budget well before total_steps", fc["budget_hit"] and 1 <= fc["step"] < 1000, str(fc))
check("C: budget counts training only (eval every step, wall clock larger than budget)", fc["train_minutes"] >= 0.15 and wall > fc["train_minutes"] + 0.05, f"train {fc['train_minutes']} wall {wall:.2f}")
check("C: log shows init_ckpt load from EMA and fresh step counter", "init_ckpt" in out and '"source": "ema"' in out and "step 1/1000" in out)
check("C: final save is a resumable step dir that can be the next init_ckpt", (c / f"step-{fc['step']:07d}/COMPLETE").exists() and (c / f"step-{fc['step']:07d}/optim.pt").exists() and (c / "tiny.rows.jsonl").exists())
# D: chain: the experiment's output starts the next experiment; distillation still works (teacher = dense export of A)
d, _, out = train("D-chain-kd", {"model.init_ckpt": str(c / f"step-{fc['step']:07d}"), "train.total_steps": 2, "eval.save_rows": True, "precision": "bf16",   # teacher is bf16: needs autocast, as in production
                                 "distill": {"teacher": str(ck / "model.safetensors"), "enc_weight": 1.0, "logit_weight": 0.1, "temperature": 1.0, "layers": [11, 23]}})
check("D: distill terms logged with init_ckpt", "kd_enc" in out and "kd_logit" in out and (d / "FINISHED").exists())
# E: strict structure check
e, _, out = train("E-mismatch", {"model.init_ckpt": str(ck), "qat.bits4": ["^encoder\\.layers\\.1[0-2]\\.feed_forward1\\.linear1$"]}, expect_rc=1)
check("E: init_ckpt with different lut4 structure is refused", "parameter mismatch" in out, out[-300:])
print("\nFAILED: " + ", ".join(fails) if fails else "\nALL CPU TRAIN CHECKS PASSED"); sys.exit(1 if fails else 0)
