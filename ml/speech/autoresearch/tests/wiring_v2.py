#!/usr/bin/env python3
"""v2 wiring check of runner_lib + select_v2 + locked v2 sets with the stub trainer.  CPU only, no GPU, no job file, no process is signalled, never touches a real AR home.
    AR_STAGE=$UIUI_ML_ROOT/ar-v2-stage python3 wiring_v2.py
AR_STAGE = a scratch AR home holding locked/ (v2 sets locked with lock.py), code/train/evaluate.py and code/lab/tracker.py.  Everything runs in AR_STAGE + '-wiring'.
Only well-behaved experiments are run (the kill / hang / reboot scenarios of dryrun.py are not repeated here: that file is the v1 dry-run and signals processes)."""
import json, os, shutil, subprocess, sys
from pathlib import Path
import yaml

HERE = Path(__file__).resolve().parent
STAGE = Path(os.environ["AR_STAGE"]).expanduser().resolve(); DRY = Path(str(STAGE) + "-wiring"); PY = sys.executable
fails = []


def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name + (f"  {extra}" if extra and not cond else "")); (None if cond else fails.append(name))


def tsv(p):
    L = Path(p).read_text().splitlines(); return [dict(zip(L[0].split("\t"), l.split("\t"))) for l in L[1:]]


subprocess.run(["chmod", "-R", "u+w", str(DRY)], check=False); shutil.rmtree(DRY, ignore_errors=True)
shutil.copytree(STAGE, DRY, symlinks=True)
for f in ("runner_lib.py",): shutil.copy(HERE.parent / f, DRY / f)
(DRY / "tests").mkdir(); shutil.copy(HERE / "stub_train.py", DRY / "tests/stub_train.py"); (DRY / "runs").mkdir()
(DRY / "init/step-0000001").mkdir(parents=True); (DRY / "init/step-0000001/COMPLETE").write_text("ok\n"); (DRY / "init/step-0000001/quality.json").write_text('{"err": 0.30}')
allowed = json.loads((DRY / "locked/allowed_train.json").read_text())
base = {"name": "base", "mode": "qat", "data": {"sources": [{"name": "a", "manifest": allowed[0], "weight": 1.0}], "batch_size": 2}, "optim": {"lr": 1e-5}, "train": {"total_steps": 10}, "model": {}, "eval": {"batch_size": 16}}
(DRY / "base.yaml").write_text(yaml.safe_dump(base))
env = dict(os.environ, AR_HOME=str(DRY), AR_PY=PY, AR_TRAIN_CMD=f"{PY} {DRY}/tests/stub_train.py", UIUI_LAB_RUNS=str(DRY / "runs"), AR_TIMEOUT_EXTRA_MIN="5")


def q(name, desc, delta=0.0, mode="ok", extra=None):
    d = {"description": desc, "base": str(DRY / "base.yaml"), "overrides": {"stub": {"delta": delta, "mode": mode}, "train": {"max_minutes": 5}}}
    if extra: d.update(extra)
    (DRY / "queue").mkdir(exist_ok=True); (DRY / "queue" / f"{name}.yaml").write_text(yaml.safe_dump(d))


def run_one():
    return subprocess.run([PY, str(DRY / "runner_lib.py"), "run-one"], env=env, capture_output=True, text=True).returncode


subprocess.check_call([PY, str(DRY / "runner_lib.py"), "init-best", "--config", str(DRY / "base.yaml"), "--ckpt", str(DRY / "init/step-0000001")], env=env)
EXP = [("001-improve", dict(delta=-0.10)), ("002-same", dict()), ("003-worse", dict(delta=0.10)), ("004-deva", dict(delta=-0.10, mode="deva")), ("005-runaway", dict(delta=-0.10, mode="runaway")),
       ("006-improve", dict(delta=-0.08)), ("007-improve", dict(delta=-0.05))]
for n, kw in EXP: q(n, f"exp {n}", **kw)
q("008-baddata", "non-allowed manifest", extra={"overrides": {"stub": {}, "data": {"sources": [{"name": "legacy", "manifest": str(Path(os.environ.get("UIUI_ML_ROOT") or "workspace").resolve() / "data/manifests/cvindia/train.jsonl"), "weight": 1.0}]}}})
rcs = []
while True:
    rc = run_one(); rcs.append(rc)
    if rc != 0 or len(rcs) > 20: break
check("runner finished the queue (exit 10 = empty)", rcs[-1] == 10 and len(rcs) == 10, str(rcs))
R = {x["exp_id"]: x for x in tsv(DRY / "results.tsv")}
COLS = ["exp_id", "commit", "S", "en_in_wer", "cm_wer", "work_wer", "hi_wer", "native_wer", "d_S", "ci_S", "runaways", "peak_gb", "minutes", "status", "description", "term_acc", "cm_fw_pts"]
check("results.tsv header", open(DRY / "results.tsv").readline().rstrip("\n").split("\t") == COLS)
for k, v in {"baseline": "keep", "001-improve": "keep", "002-same": "discard", "003-worse": "discard", "004-deva": "discard", "005-runaway": "discard", "006-improve": "keep", "007-improve": "keep",
             "008-baddata": "crash"}.items(): check(f"status {k} = {v}", R.get(k, {}).get("status") == v, str(R.get(k)))
b = R["baseline"]
check("baseline row has S and all five cat WERs", all(b[c] not in ("", "None") for c in ("S", "en_in_wer", "cm_wer", "work_wer", "hi_wer", "native_wer")), str(b))
check("improving experiment: ci_S upper < 0 and d_S < 0", float(R["001-improve"]["ci_S"].split(",")[1]) < 0 and float(R["001-improve"]["d_S"]) < 0, str(R["001-improve"]))
check("term_acc and cm_fw_pts logged", R["001-improve"]["term_acc"] not in ("", "None") and R["001-improve"]["cm_fw_pts"] not in ("", "None"), str(R["001-improve"]))
check("S improves monotonically with the stub", float(R["001-improve"]["S"]) < float(b["S"]) and float(R["006-improve"]["S"]) < float(R["001-improve"]["S"]))
v = json.load(open(DRY / "out/ar-001-improve/verdict.json"))
check("verdict.json: per-cat table, weights, guards, terms", set(v["per_cat"]) == {"en_in", "cm", "work", "hi", "native"} and abs(sum(v["weights_used"].values()) - 1) < 1e-6 and "terms" in v["guards"] and v["terms"]["n_terms"] > 0, str(list(v)))
check("deva leakage -> sanity discard", any("devanagari" in x for x in json.load(open(DRY / "done/004-deva.result.json"))["verdict"]["reasons"]))
check("runaway -> sanity discard", any("runaway" in x for x in json.load(open(DRY / "done/005-runaway.result.json"))["verdict"]["reasons"]))
check("bad data manifest rejected", "not in locked/allowed_train.json" in R["008-baddata"]["description"])
bj = json.load(open(DRY / "best.json")); check("best.json = 007-improve", bj["exp_id"] == "007-improve" and "S" in bj["hold"] and "S" in bj["sel_wer"], str(bj.get("exp_id")))
kt = {x["exp_id"]: x for x in tsv(DRY / "kept.tsv")}
check("kept.tsv rows", list(kt) == ["baseline", "001-improve", "006-improve", "007-improve"], str(list(kt)))
check("kept.tsv header", open(DRY / "kept.tsv").readline().rstrip("\n").split("\t") == ["exp_id", "commit", "kept_n", "sel_S", "hold_S", "d_hold_S", "hold_en_in_wer", "hold_cm_wer", "hold_work_wer", "hold_hi_wer",
                                                                                          "hold_native_wer", "hiacc", "mucs-hien-test", "fleurs-hi", "librispeech-clean", "description"])
check("hold S logged for every kept", all(kt[k]["hold_S"] not in ("", "None") for k in kt) and float(kt["001-improve"]["d_hold_S"]) < 0, str(kt["001-improve"]))
check("test sets on kept_n % 3 == 0 only (baseline, 3rd kept)", kt["baseline"]["hiacc"] != "" and kt["001-improve"]["hiacc"] == "" and kt["007-improve"]["hiacc"] != "" and "svarah-partial" not in kt["baseline"])
vm = (DRY / "out/ar-006-improve/vibe.md").read_text(); check("vibe.md has cat column and flags changes", "| cat |" in vm and "| * |" in vm and "fixed clips" in vm)
tr = json.load(open(DRY / "runs/ar-001-improve/run.json")); check("tracker summary carries S", tr["summary"]["autoresearch"]["status"] == "keep" and tr["summary"]["autoresearch"]["S"] is not None)
print("\nFAILED: " + ", ".join(fails) if fails else "\nALL V2 WIRING CHECKS PASSED"); sys.exit(1 if fails else 0)
