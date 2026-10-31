#!/usr/bin/env python3
"""Runner dry-run, CPU only, stub trainer (no torch, no GPU, no job file).   python3 $UIUI_ML_ROOT/ar/tests/dryrun.py
Uses a scratch AR home ($UIUI_ML_ROOT/ar-dryrun) whose locked/ and code/ are symlinks to the real ones (so the real hashes.json is verified); everything else is separate."""
import json, os, shutil, signal, subprocess, sys, time
from pathlib import Path
import yaml
UML = Path(os.environ.get("UIUI_ML_ROOT") or "workspace").resolve()

REAL = UML / "ar"; DRY = UML / "ar-dryrun"; PY = sys.executable
fails = []


def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name + (f"  {extra}" if extra and not cond else "")); (None if cond else fails.append(name))


def tsv(p):
    L = Path(p).read_text().splitlines(); return [dict(zip(L[0].split("\t"), l.split("\t"))) for l in L[1:]]


def wait(cond, timeout=240, what=""):
    t = time.time()
    while time.time() - t < timeout:
        if cond(): return True
        time.sleep(0.5)
    print("TIMEOUT waiting for", what); return False


subprocess.run(["chmod", "-R", "u+w", str(DRY)], check=False); shutil.rmtree(DRY, ignore_errors=True); DRY.mkdir(parents=True)
(DRY / "code").symlink_to(REAL / "code")
# test-only locked dir: v2 sets are not built yet, so lock the superseded v1 sets together with the real (staged) tooling; production ar/locked is not touched
shutil.copytree(REAL / "locked-stage", DRY / "locked", ignore=shutil.ignore_patterns("__pycache__", "dev-*.jsonl", "vibe.jsonl", "leakage_report.json", "allowed_train.json", "hashes.json", "V2_README.md"))
for f in ("dev-sel.jsonl", "dev-hold.jsonl", "vibe.jsonl", "leakage_report.json"): shutil.copy(REAL / "locked-v1-superseded" / f, DRY / "locked" / f)
(DRY / "locked/V2_README.md").write_text("test stand-in\n")
subprocess.check_call([PY, str(DRY / "locked/lock.py"), "--ar-home", str(DRY), "--data-root", str(UML)])
for p_ in DRY.joinpath("locked").rglob("*"): p_.chmod(0o444 if p_.is_file() else 0o555)
for f in ("runner.sh", "runner_lib.py"): shutil.copy(REAL / f, DRY / f)
shutil.copytree(REAL / "tests", DRY / "tests"); (DRY / "runs").mkdir()
(DRY / "init" / "step-0000001").mkdir(parents=True); (DRY / "init/step-0000001/COMPLETE").write_text("ok\n"); (DRY / "init/step-0000001/quality.json").write_text('{"err": 0.30}')
base = {"name": "base", "mode": "qat", "data": {"sources": [{"name": "vaani", "manifest": str(UML / "data/manifests/vaani/train.jsonl"), "weight": 1.0}], "batch_size": 2},
        "optim": {"lr": 1e-5}, "train": {"total_steps": 10}, "model": {}, "eval": {"batch_size": 16}}
(DRY / "base.yaml").write_text(yaml.safe_dump(base))
env = dict(os.environ, AR_HOME=str(DRY), AR_PY=PY, AR_TRAIN_CMD=f"{PY} {DRY}/tests/stub_train.py", AR_SKIP_GPU_CHECK="1", AR_POLL_SECS="1", AR_ERR_RETRY="1",
           AR_TIMEOUT_EXTRA_MIN="0.05", UIUI_LAB_RUNS=str(DRY / "runs"), AR_DIE_AT="after-commit")


def q(name, desc="x", delta=0.0, mode="ok", budget=0.05, extra=None):
    d = {"description": desc, "base": str(DRY / "base.yaml"), "overrides": {"stub": {"delta": delta, "mode": mode}, "train": {"max_minutes": budget}}}
    if extra: d.update(extra)
    (DRY / "queue").mkdir(exist_ok=True); (DRY / "queue" / f"{name}.yaml").write_text(yaml.safe_dump(d))


def start():
    return subprocess.Popen(["bash", str(DRY / "runner.sh")], env=env, stdout=open(DRY / "runner.out", "ab"), stderr=subprocess.STDOUT, start_new_session=True)


def results(): return tsv(DRY / "results.tsv") if (DRY / "results.tsv").exists() else []


subprocess.check_call([PY, str(DRY / "runner_lib.py"), "init-best", "--config", str(DRY / "base.yaml"), "--ckpt", str(DRY / "init/step-0000001")], env=env)
EXP = [("001-improve", dict(delta=-0.10)), ("002-same", dict(delta=0.0)), ("003-worse", dict(delta=0.10)), ("004-crash", dict(mode="crash")), ("005-improve", dict(delta=-0.08)),
       ("006-deva", dict(delta=-0.10, mode="deva")), ("007-runaway", dict(delta=-0.10, mode="runaway")), ("008-hang", dict(mode="hang", budget=0.02))]
for n, kw in EXP: q(n, desc=f"exp {n}", **kw)
q("010-baddata", desc="uses a non-allowed manifest", extra={"overrides": {"stub": {}, "data": {"sources": [{"name": "legacy", "manifest": str(UML / "data/manifests/cvindia/train.jsonl"), "weight": 1.0}]}}})
(DRY / "queue" / "011-nodesc.yaml").write_text(yaml.safe_dump({"base": str(DRY / "base.yaml")}))
q("012-commitmismatch", desc="wants another commit", extra={"commit": "deadbeef"})

r = start()
ok = wait(lambda: len(results()) >= 12, 300, "12 results (baseline + 11 experiments)")
check("all queue files processed", ok)
runlog = (DRY / "runner.out").read_text()
check("runner died after committing the baseline outcome and re-applied it exactly once (reboot between commit and apply)", [x["exp_id"] for x in results()].count("baseline") == 1 and "AR_DIE" not in runlog and (DRY / "state/died-after-commit").exists())
R = {x["exp_id"]: x for x in results()}
exp_status = {"baseline": "keep", "001-improve": "keep", "002-same": "discard", "003-worse": "discard", "004-crash": "crash", "005-improve": "keep", "006-deva": "discard",
              "007-runaway": "discard", "008-hang": "crash", "010-baddata": "crash", "011-nodesc": "crash", "012-commitmismatch": "crash"}
for k, v in exp_status.items(): check(f"status {k} = {v}", R.get(k, {}).get("status") == v, str(R.get(k)))
check("results.tsv header", open(DRY / "results.tsv").readline().rstrip("\n").split("\t") == ["exp_id", "commit", "hinglish_wer", "en_wer", "d_hinglish", "ci_hi", "d_en", "runaways", "peak_gb", "minutes", "status", "description", "fw_pts", "cer"])
check("hang was a timeout crash", "timeout" in R["008-hang"]["description"], R["008-hang"]["description"])
check("bad data manifest rejected", "not in locked/allowed_train.json" in R["010-baddata"]["description"])
check("missing description rejected", "description" in R["011-nodesc"]["description"])
check("commit mismatch rejected", "commit mismatch" in R["012-commitmismatch"]["description"])
check("deva leakage -> discard by sanity rule", any("devanagari" in x for x in json.load(open(DRY / "done/006-deva.result.json"))["verdict"]["reasons"]))
check("runaway -> discard by sanity/runaway rule", any("runaway" in x for x in json.load(open(DRY / "done/007-runaway.result.json"))["verdict"]["reasons"]))
check("improving experiment has CI upper < 0", float(R["001-improve"]["ci_hi"].split(",")[1]) < 0 and float(R["001-improve"]["d_hinglish"]) < 0, R["001-improve"]["ci_hi"])
check("fw_pts and cer logged", R["001-improve"]["fw_pts"] != "" and R["001-improve"]["cer"] != "", str(R["001-improve"]))
check("peak_gb recorded", R["001-improve"]["peak_gb"] == "12.34")
wait(lambda: not list((DRY / "queue").glob("*.yaml")), 20, "queue empty")
check("queue emptied into done/", not list((DRY / "queue").glob("*.yaml")) and (DRY / "done/001-improve.yaml").exists())
b = json.load(open(DRY / "best.json")); check("best.json = 005-improve", b["exp_id"] == "005-improve" and b["init_ckpt"].endswith("ar-005-improve/step-0000010") and Path(b["rows"]).exists(), str(b.get("exp_id")))
check("no stray best.json.tmp", not list(DRY.glob("best.json.*")))
kt = {x["exp_id"]: x for x in tsv(DRY / "kept.tsv")}
check("kept.tsv rows", list(kt) == ["baseline", "001-improve", "005-improve"], str(list(kt)))
check("hold wer logged for every kept", all(kt[k]["hold_hinglish_wer"] and kt[k]["hold_en_wer"] for k in kt))
check("test sets only for kept_n % 3 == 0 (baseline)", kt["baseline"]["hiacc"] != "" and kt["001-improve"]["hiacc"] == "" and kt["005-improve"]["librispeech-clean"] == "")
check("hold improves with sel (stub is honest)", float(kt["001-improve"]["d_hold_hinglish"]) < 0)
for e in ("001-improve", "005-improve"):
    o = DRY / "out" / f"ar-{e}"; check(f"{e}: vibe.md + sanity.json + verdict.json written", all((o / f).exists() for f in ("vibe.md", "sanity.json", "verdict.json", "dev-sel.rows.jsonl", "vibe.rows.jsonl", "dev-hold.rows.jsonl")))
vm = (DRY / "out/ar-005-improve/vibe.md").read_text(); check("vibe.md flags changes", "| * |" in vm and "48 fixed clips" in vm)
steps = {p.parent.name for p in (DRY / "out").glob("*/step-*")}
check("disk: only best + last 2 discards keep checkpoints", steps == {"ar-005-improve", "ar-006-deva", "ar-007-runaway"}, str(steps))
tr = json.load(open(DRY / "runs/ar-001-improve/run.json")); check("tracker run tagged autoresearch with summary", "autoresearch" in tr["tags"] and tr["summary"]["autoresearch"]["status"] == "keep")
check("tracker marks crash failed", json.load(open(DRY / "runs/ar-004-crash/run.json"))["status"] == "failed")

# reboot mid-experiment: stub hangs on attempt 1, runner + stub are SIGKILLed, a fresh runner restarts the experiment from scratch
q("009-kill", desc="killed mid-run (simulated reboot)", delta=-0.05, mode="hang_once", budget=5)
mark = DRY / "state/stub-hung-ar-009-kill"; pidf = DRY / "out/ar-009-kill/stub.pid"
check("009 started", wait(lambda: mark.exists() and pidf.exists(), 60, "009 running"))
os.killpg(r.pid, signal.SIGKILL); os.kill(int(pidf.read_text()), signal.SIGKILL); r.wait(); time.sleep(1)
check("nothing recorded for the killed experiment", "009-kill" not in {x["exp_id"] for x in results()} and (DRY / "queue/009-kill.yaml").exists())
bj = (DRY / "best.json").read_text(); r = start()
check("009 completed after restart", wait(lambda: "009-kill" in {x["exp_id"] for x in results()}, 120, "009 result"))
R = {x["exp_id"]: x for x in results()}; check("009 kept after restart from scratch", R["009-kill"]["status"] == "keep", str(R["009-kill"]))
kt = {x["exp_id"]: x for x in tsv(DRY / "kept.tsv")}; check("3rd kept experiment gets the test sets", kt["009-kill"]["kept_n"] == "3" and kt["009-kill"]["hiacc"] != "" and kt["009-kill"]["fleurs-hi"] != "", str(kt["009-kill"]))
check("best.json moved to 009 atomically", json.load(open(DRY / "best.json"))["exp_id"] == "009-kill" and bj != (DRY / "best.json").read_text())
steps = {p.parent.name for p in (DRY / "out").glob("*/step-*")}; check("disk after 009", steps == {"ar-009-kill", "ar-006-deva", "ar-007-runaway"}, str(steps))
Path(DRY / "STOP").write_text(""); check("runner exits on STOP", wait(lambda: r.poll() is not None, 30, "runner exit"))

# tamper: a locked file that differs from hashes.json must stop the runner before any experiment
T = UML / "ar-dryrun-tamper"; subprocess.run(["chmod", "-R", "u+w", str(T)], check=False); shutil.rmtree(T, ignore_errors=True); T.mkdir(); (T / "code").symlink_to(REAL / "code"); shutil.copytree(DRY / "locked", T / "locked")
for p in (T / "locked").rglob("*"): p.chmod(0o755 if p.is_dir() else 0o644)
(T / "locked/dev-sel.jsonl").write_text((T / "locked/dev-sel.jsonl").read_text().replace("a", "b", 1))
v = subprocess.run([PY, "-I", str(DRY / "locked/verify.py"), "--ar-home", str(T)], capture_output=True, text=True)
check("verify.py rejects a tampered dev-sel", v.returncode == 2 and "dev-sel" in v.stderr, v.stderr[:200])
for f in ("runner.sh", "runner_lib.py"): shutil.copy(REAL / f, T / f)
shutil.copytree(REAL / "tests", T / "tests"); (T / "queue").mkdir(); (T / "queue/001-x.yaml").write_text("description: x\n"); shutil.copy(DRY / "best.json", T / "best.json")
p = subprocess.Popen(["bash", str(T / "runner.sh")], env=dict(env, AR_HOME=str(T)), stdout=open(T / "out.log", "w"), stderr=subprocess.STDOUT, start_new_session=True); time.sleep(6)
os.killpg(p.pid, signal.SIGKILL); txt = (T / "out.log").read_text()
check("runner refuses to run on hash mismatch", "REFUSING" in txt and not (T / "results.tsv").exists() and (T / "queue/001-x.yaml").exists(), txt[-300:])
print("\nFAILED: " + ", ".join(fails) if fails else "\nALL DRY-RUN CHECKS PASSED"); sys.exit(1 if fails else 0)
