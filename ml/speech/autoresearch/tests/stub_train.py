#!/usr/bin/env python3
"""Stand-in for train.py in the runner dry-run (no torch, no GPU).  Same CLI (--config, --eval-only) and same output files as train.py: the model is a number
(`err` in quality.json) and a hypothesis is the reference with that fraction of words replaced, so a better model corrects a subset of a worse model's errors.
cfg.stub: {delta: -0.1, mode: ok|crash|hang|hang_once|deva|runaway}."""
import argparse, hashlib, json, os, signal, sys, time
from pathlib import Path
import yaml

ap = argparse.ArgumentParser(); ap.add_argument("--config", required=True); ap.add_argument("--eval-only", action="store_true"); ap.add_argument("--resume"); a = ap.parse_args()
cfg = yaml.safe_load(open(a.config)); stub = cfg.get("stub", {}); mode = stub.get("mode", "ok")
rid = cfg["run_id"]; out = Path(cfg["out_dir"]) / rid; out.mkdir(parents=True, exist_ok=True)
Path(out / "stub.pid").write_text(str(os.getpid()))
sys.path.insert(0, str(Path(os.environ["AR_HOME"]) / "code" / "lab")); import tracker  # noqa: E402
run = tracker.Run(rid, kind="train", config=cfg, tags=cfg["tags"], run_id=rid); run.note(f"stub start mode={mode} eval_only={a.eval_only}")
q0 = json.load(open(Path(cfg["model"]["init_ckpt"]) / "quality.json"))["err"]
mark = Path(os.environ["AR_HOME"]) / "state" / f"stub-hung-{rid}"
if mode == "crash": run.fail("stub crash"); sys.exit(3)
if mode == "hang" or (mode == "hang_once" and not mark.exists() and not a.eval_only):
    mark.write_text("x"); time.sleep(10 ** 6)
if mode == "run" and not a.eval_only:        # long-running stand-in (stub.secs): SIGTERM -> exit 0 without FINISHED, exactly like train.py's "SIGTERM: saving and stopping"
    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
    (out / "started").write_text("x")
    t_end = time.time() + float(stub.get("secs", 5))
    while time.time() < t_end: time.sleep(0.1)
q = q0 if a.eval_only else max(q0 + stub.get("delta", 0.0), 0.0)
rows_dir = Path(cfg["eval"].get("rows_dir") or out)


def hyp(r, cat):
    w = r["reference"].split()
    for j in range(len(w)):
        if int(hashlib.sha1(f"{r['id']}:{j}".encode()).hexdigest()[:8], 16) / 2 ** 32 < q: w[j] = "zzz"
    return " ".join(w)


for s in cfg["eval"]["sets"]:
    rows = [json.loads(l) for l in open(s["manifest"]) if l.strip()]
    if s.get("max_clips"): rows = rows[: s["max_clips"]]
    res = []
    for i, r in enumerate(rows):
        r["reference"] = r.get("reference", r.get("text", "")); cat = r.get("cat") or "en"; h = hyp(r, cat)
        if not a.eval_only and s["name"] == "dev-sel":
            if mode == "deva" and i % 40 == 0: h += " नमस्ते"          # 2.5% of clips
            if mode == "runaway" and i == 3: h = (h + " ") * 5
        res.append({"id": r["id"], "cat": cat, "reference": r["reference"], "hypothesis": h, "speaker": r.get("speaker")})
    rows_dir.mkdir(parents=True, exist_ok=True)
    (rows_dir / f"{s['name']}.rows.jsonl").write_text("".join(json.dumps(x, ensure_ascii=False) + "\n" for x in res))
if not a.eval_only:
    d = out / "step-0000010"; d.mkdir(); (d / "quality.json").write_text(json.dumps({"err": q})); (d / "optim.pt").write_bytes(b"\0" * 2_000_000)
    (d / "model.safetensors").write_bytes(b"\0" * 1000); (d / "COMPLETE").write_text("ok\n")
    (out / "final.json").write_text(json.dumps({"step": 10, "budget_hit": True, "train_minutes": 0.01, "peak_gb": 12.34})); (out / "FINISHED").write_text("10\n")
run.finish()
