#!/usr/bin/env python3
"""Autoresearch experiment engine (called by runner.sh).   AR home = $AR_HOME or the directory of this file ($UIUI_ML_ROOT/ar by convention).

  runner_lib.py run-one                  run (or finish) the first queue/*.yaml.  exit 0 handled one, 10 queue empty, 11 best.json not initialised
  runner_lib.py init-best --config C --ckpt STEP_DIR [--description D]    write best.json for the starting model (baseline is evaluated by run-one)
  runner_lib.py status                   print best.json and the tail of results.tsv

Crash-safety design: an experiment's outcome is first written as ONE atomic record (state/commits/<exp>.json); everything visible (best.json, results.tsv,
kept.tsv, queue -> done, tracker, pruning) is then applied idempotently from that record.  A reboot before the record exists restarts the experiment from
scratch (its out dir is deleted first); a reboot after it only re-applies.  best.json is only ever replaced by an atomic rename.
"""
import argparse, contextlib, copy, fcntl, json, os, re, shlex, shutil, signal, subprocess, sys, time
from pathlib import Path
import yaml

AR = Path(os.environ.get("AR_HOME") or Path(__file__).resolve().parent).resolve()
DATA = Path(os.environ.get("AR_DATA_ROOT") or AR.parent)
os.environ.setdefault("UIUI_ML_ROOT", str(DATA))      # configs may use ${UIUI_ML_ROOT}
CODE, LOCKED, QUEUE, DONE, OUT, STATE = AR / "code", AR / "locked", AR / "queue", AR / "done", AR / "out", AR / "state"
GPU = str(os.environ.get("AR_GPU", "0")).strip() or "0"      # this runner's GPU; every per-runner path below is keyed by it (two runners = two GPUs)
if not re.fullmatch(r"\d+", GPU): raise SystemExit(f"AR_GPU must be a GPU index, got {GPU!r}")
RUNNING = STATE / "running" / f"gpu{GPU}"                      # queue files this runner has claimed (atomic rename out of queue/)
CURRENT = STATE / f"current-gpu{GPU}.json"
PAUSE_DIR, PREEMPT_DIR = STATE / "pause", STATE / "preempted"  # written by ops/gpu_guard.py: pause accounting per run id / preempt markers per experiment
DUTY_SLEEP = ((AR / "state" / "duty_sleep").read_text().strip() if (AR / "state" / "duty_sleep").is_file() else None) or os.environ.get("AR_DUTY_SLEEP", "0.12")   # state/duty_sleep overrides (read per experiment, no restart)           # train.py sleeps this fraction of each step's time (keeps our own GPU util < 90% on average)
PY = os.environ.get("AR_PY") or sys.executable
DEFAULT_BUDGET_MIN = 25.0
TIMEOUT_EXTRA_MIN = float(os.environ.get("AR_TIMEOUT_EXTRA_MIN", 25))
MAX_ATTEMPTS = 3
KEEP_DISCARDED = 2
CATS = ("en_in", "cm", "work", "hi", "native")      # v2 sets (English-first Indian professionals); primary score S = weighted sum, see locked/select_v2.py
HINGLISH_CATS = ("hinglish", "short", "free", "cm", "hi")   # cats scored with the Roman-Hinglish variant folding (test sets keep their v1 cats hinglish/en)
RESULTS_COLS = ["exp_id", "commit", "S", "en_in_wer", "cm_wer", "work_wer", "hi_wer", "native_wer", "d_S", "ci_S", "runaways", "peak_gb", "minutes", "status", "description", "term_acc", "cm_fw_pts"]
# report-only test sets (svarah-partial and monsoon-en-in left this list: they are now part of dev-sel / dev-hold)
TEST_SETS = [("hiacc", "data/evalsets-lexicon/hiacc/manifest.jsonl", 150), ("mucs-hien-test", "data/evalsets-lexicon/mucs-hien-test/manifest.jsonl", 150),
             ("fleurs-hi", "data/evalsets-lexicon/fleurs-hi/manifest.jsonl", 100), ("librispeech-clean", "evalsets/librispeech-clean/manifest.jsonl", 100)]   # as round3_lut4_kd_v1.yaml, minus the two now in dev
KEPT_COLS = ["exp_id", "commit", "kept_n", "sel_S", "hold_S", "d_hold_S"] + [f"hold_{c}_wer" for c in CATS] + [t[0] for t in TEST_SETS] + ["description"]
TEST_EVERY_KEPT = 3


class Reject(Exception):
    """experiment cannot run (bad config etc.): recorded as a crash."""


def log(*a): print(time.strftime("[%F %T]"), "runner:", *a, flush=True)


def _fair_wer():
    """decision/reporting metric = locked/evalx/fair_wer.py twer (T-WER with attested-variant folding; NOT score.py fair WER)."""
    sys.path.insert(0, str(LOCKED / "evalx")); import fair_wer
    return fair_wer


def _select():
    """the LOCKED scorer (select_v2.py): per-cat WER table and the primary score S."""
    sys.path.insert(0, str(LOCKED)); import select_v2
    return select_v2


# ---- small io helpers ----------------------------------------------------------------------------------------------------
def atomic_write(path, text):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True); tmp = path.with_name(path.name + ".tmp")
    with open(tmp, "w") as f: f.write(text); f.flush(); os.fsync(f.fileno())
    os.replace(tmp, path)
    fd = os.open(path.parent, os.O_RDONLY)
    try: os.fsync(fd)
    finally: os.close(fd)


_LOCK = {"fd": None, "depth": 0}


@contextlib.contextmanager
def commit_lock():
    """global (all GPUs) flock state/commit.lock: decisions, records, best.json/tsv updates, hold/test eval of a keep and pruning are serialised.  Re-entrant within a process."""
    if _LOCK["depth"] == 0:
        STATE.mkdir(parents=True, exist_ok=True); fd = os.open(STATE / "commit.lock", os.O_RDWR | os.O_CREAT, 0o644); fcntl.flock(fd, fcntl.LOCK_EX); _LOCK["fd"] = fd
    _LOCK["depth"] += 1
    try: yield
    finally:
        _LOCK["depth"] -= 1
        if _LOCK["depth"] == 0: fcntl.flock(_LOCK["fd"], fcntl.LOCK_UN); os.close(_LOCK["fd"]); _LOCK["fd"] = None


def update_current(**kw):
    """state/current-gpuN.json: what this runner is doing (read by status, the guard and prune_disk)."""
    cur = read_json(CURRENT, {}) or {}; cur.update(kw); cur["gpu"] = GPU; atomic_write(CURRENT, json.dumps(cur))


def read_json(p, default=None):
    try: return json.loads(Path(p).read_text())
    except (OSError, ValueError): return default


def clean(v): return "" if v is None else str(v).replace("\t", " ").replace("\n", " ")


def tsv_rows(path):
    if not Path(path).exists(): return []
    lines = Path(path).read_text().splitlines()
    return [dict(zip(lines[0].split("\t"), l.split("\t"))) for l in lines[1:] if l.strip()]


def tsv_append_once(path, cols, row):
    """append `row` unless a row with the same exp_id exists (idempotent re-apply)."""
    path = Path(path)
    if any(r.get("exp_id") == row["exp_id"] for r in tsv_rows(path)): return False
    new = not path.exists() or not path.read_text().strip()
    with open(path, "a") as f:
        if new: f.write("\t".join(cols) + "\n")
        f.write("\t".join(clean(row.get(c)) for c in cols) + "\n"); f.flush(); os.fsync(f.fileno())
    return True


def deep_merge(a, b):
    for k, v in (b or {}).items():
        if isinstance(v, dict) and isinstance(a.get(k), dict): deep_merge(a[k], v)
        else: a[k] = copy.deepcopy(v)
    return a


def best(): return read_json(AR / "best.json")


def code_commit():
    try: return (CODE / "COMMIT").read_text().strip()
    except OSError: return "unknown"


def newest_step(d):
    c = sorted(p for p in Path(d).glob("step-*") if re.fullmatch(r"step-\d+", p.name) and (p / "COMPLETE").exists())
    return c[-1] if c else None


# ---- config preparation ------------------------------------------------------------------------------------------------------
def locked_sets():
    return {"dev-sel": {"name": "dev-sel", "manifest": str(LOCKED / "dev-sel.jsonl")}, "vibe": {"name": "vibe", "manifest": str(LOCKED / "vibe.jsonl")},
            "dev-hold": {"name": "dev-hold", "manifest": str(LOCKED / "dev-hold.jsonl")}}


def test_specs():
    return [{"name": n, "manifest": str(DATA / m), "max_clips": mc} for n, m, mc in TEST_SETS]


def enforce(cfg, exp, init_ckpt, sets, eval_only=False, rows_dir=None):
    """Overwrite everything that makes results comparable.  The agent controls the rest (model, optim, data mix, distill, qat, ...)."""
    cfg = copy.deepcopy(cfg); rid = f"ar-{exp}" + ("-eval" if eval_only else "")
    allowed = {str(Path(p).resolve()) for p in read_json(LOCKED / "allowed_train.json", [])}
    for s in (cfg.get("data") or {}).get("sources", []):
        if str(Path(s["manifest"]).resolve()) not in allowed: raise Reject(f"data source {s.get('name')} uses {s['manifest']}: not in locked/allowed_train.json")
    cfg["name"] = rid; cfg["run_id"] = rid; cfg["out_dir"] = str(OUT)
    cfg["tags"] = list(dict.fromkeys(["autoresearch"] + (["eval-only"] if eval_only else []) + [t for t in cfg.get("tags", []) if t != "autoresearch"]))
    cfg.setdefault("train", {}); cfg["train"].setdefault("max_minutes", DEFAULT_BUDGET_MIN)
    cfg.setdefault("model", {})["init_ckpt"] = str(init_ckpt)
    old = cfg.get("eval") or {}
    E = {k: old[k] for k in ("batch_size", "dtype", "use_ema") if k in old}; E.setdefault("batch_size", 16)
    E.update(at_start=False, every=10 ** 9, save_rows=True, sets=sets)
    if rows_dir: E["rows_dir"] = str(rows_dir)
    cfg["eval"] = E
    cfg["checkpoint"] = {"every": 10 ** 9, "every_minutes": 0, "keep_last": 1, "keep_optim": 1, "dtype": (cfg.get("checkpoint") or {}).get("dtype", "float32")}
    return cfg, rid


def load_queue_file(q, search_dir=None):
    raw = yaml.safe_load(os.path.expandvars(Path(q).read_text())) or {}
    meta = {k: raw.pop(k) for k in ("description", "base", "overrides", "commit", "init_ckpt") if k in raw}
    if not str(meta.get("description", "")).strip(): raise Reject("queue file has no one-line `description`")
    if meta.get("base"):
        bp = Path(meta["base"])
        for cand in ([bp] if bp.is_absolute() else [CODE / "train" / "configs" / bp, CODE / bp, Path(search_dir or Path(q).parent) / bp]):
            if cand.exists(): bp = cand; break
        else: raise Reject(f"base config {meta['base']} not found")
        cfg = deep_merge(yaml.safe_load(os.path.expandvars(bp.read_text())), raw)
    else: cfg = raw
    deep_merge(cfg, meta.get("overrides") or {})
    if "mode" not in cfg or "data" not in cfg: raise Reject("config lacks mode/data (give `base:` or a full config)")
    return cfg, meta


# ---- running train.py --------------------------------------------------------------------------------------------------------
def train_env():
    e = dict(os.environ)
    e.update(PYTORCH_CUDA_ALLOC_CONF="expandable_segments:True", CUDA_VISIBLE_DEVICES=GPU, OMP_NUM_THREADS="4", NUMBA_NUM_THREADS="8", AR_DUTY_SLEEP=DUTY_SLEEP)
    return e


def pause_total(rid):
    """seconds this run has spent SIGSTOPped by the guard (completed pauses + the one in progress), from state/pause/<rid>.json."""
    d = read_json(PAUSE_DIR / f"{rid}.json", {}) or {}
    return float(d.get("total") or 0) + (max(time.time() - float(d["since"]), 0) if d.get("since") else 0)


def run_train(cfg_path, extra, timeout_min, logfile):
    """-> (returncode, wall minutes).  rc 124 = hard timeout (process group killed).  One process on this runner's GPU.
    Paused time (guard SIGSTOP) is added to the timeout and is excluded from train.max_minutes by train.py (AR_PAUSE_FILE)."""
    rid = Path(cfg_path).stem; (PAUSE_DIR / f"{rid}.json").unlink(missing_ok=True)
    cmd = shlex.split(os.environ.get("AR_TRAIN_CMD") or f"{PY} train.py") + ["--config", str(cfg_path)] + extra
    t0 = time.time()
    with open(logfile, "ab") as lf:
        subprocess.run(["pkill", "-u", str(os.getuid()), "-f", "--", f"--config {cfg_path}"], check=False)   # leftovers of our own earlier attempt only
        p = subprocess.Popen(cmd, cwd=CODE / "train", env=dict(train_env(), AR_PAUSE_FILE=str(PAUSE_DIR / f"{rid}.json")), stdout=lf, stderr=subprocess.STDOUT, start_new_session=True)
        update_current(train_pid=p.pid, train_pgid=p.pid, cfg=str(cfg_path), train_rid=rid)
        rc = None
        while rc is None:
            try: rc = p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                if time.time() - t0 - pause_total(rid) > timeout_min * 60:
                    log(f"TIMEOUT after {timeout_min:.1f} min (+{pause_total(rid) / 60:.1f} min paused): stopping process group {p.pid}")
                    os.killpg(p.pid, signal.SIGTERM); os.killpg(p.pid, signal.SIGCONT)
                    try: p.wait(60)
                    except subprocess.TimeoutExpired: os.killpg(p.pid, signal.SIGKILL); p.wait()
                    rc = 124
        update_current(train_pid=None, train_pgid=None)
    return rc, (time.time() - t0) / 60


def eval_only(exp, base_cfg, ckpt, sets, rows_dir, logfile, timeout_min=60):
    cfg, rid = enforce(base_cfg, exp, ckpt, sets, eval_only=True, rows_dir=rows_dir)
    cp = STATE / "cfg" / f"{rid}.yaml"; atomic_write(cp, yaml.safe_dump(cfg))
    shutil.rmtree(OUT / rid, ignore_errors=True); shutil.rmtree(tracker_root() / rid, ignore_errors=True)
    Path(rows_dir).mkdir(parents=True, exist_ok=True)
    for attempt in range(int(os.environ.get("AR_EVAL_PREEMPT_RETRIES", 10)) + 1):
        rc, mins = run_train(cp, ["--eval-only"], timeout_min, logfile)
        if not preempted_marker(exp): break
        clear_preempted(exp); log(f"{exp}: eval-only run preempted by the guard (GPU busy); retrying in {PREEMPT_WAIT}s"); time.sleep(PREEMPT_WAIT)
    return rc == 0 and all((Path(rows_dir) / f"{s['name']}.rows.jsonl").exists() for s in sets), mins


PREEMPT_WAIT = int(os.environ.get("AR_PREEMPT_WAIT_SECS", 120))


def preempted_marker(exp): return (PREEMPT_DIR / exp).exists()


def clear_preempted(exp): (PREEMPT_DIR / exp).unlink(missing_ok=True)


def tracker_root():
    return Path(os.environ.get("UIUI_LAB_RUNS") or DATA / "runs")


# ---- outcome ----------------------------------------------------------------------------------------------------------------
def metrics_by_cat(rows_path):
    fw = _fair_wer()
    rows = [json.loads(l) for l in Path(rows_path).read_text().splitlines() if l.strip()]
    return fw.twer(rows, hinglish_cats=HINGLISH_CATS, use_eval_only=True)[0]


def wer_by_cat(rows_path):
    return {k: v["twer"] for k, v in metrics_by_cat(rows_path).items()}


def set_scores(rows_path):
    """{cat: WER, ..., "S": primary score} of a v2 rows file (cats absent from the set are dropped and the weights renormalised, as in select_v2)."""
    sel = _select(); t = sel.wer_table(sel.read_rows(rows_path)); S, _ = sel.score_S({c: t[c] for c in CATS if c in t})
    return {**{c: t[c]["wer"] for c in CATS if c in t}, "S": round(S, 3)}


def peak_gb(outd, final):
    if final and final.get("peak_gb") is not None: return final["peak_gb"]
    vals = []
    try:
        for l in (tracker_root() / outd.name / "metrics.jsonl").read_text().splitlines():
            r = json.loads(l); vals += [r[k] for k in r if k.endswith("_gb") and isinstance(r[k], (int, float))]
    except OSError: pass
    return round(max(vals), 2) if vals else None


def crash_record(exp, rid, commit, desc, why, minutes, queue_file, pk=None):
    row = {"exp_id": exp, "commit": commit, "minutes": round(minutes, 1), "status": "crash", "description": f"{desc} [{why}]", "peak_gb": pk}
    return {"exp": exp, "run_id": rid, "row": row, "kept_row": None, "new_best": None, "queue_file": queue_file, "why": why}


def build_kept_row(exp, commit, desc, kept_n, sel_scores, outd, prev_best, ckpt, base_cfg):
    """hold-out numbers (every kept experiment) + test-set numbers (every 3rd kept experiment, incl. the baseline).  Report-only, never used for decisions."""
    row = {"exp_id": exp, "commit": commit, "kept_n": kept_n, "sel_S": sel_scores.get("S"), "description": desc}
    do_test = kept_n % TEST_EVERY_KEPT == 0
    sets = [locked_sets()["dev-hold"]] + (test_specs() if do_test else [])
    ok, _ = eval_only(exp, base_cfg, ckpt, sets, outd, outd / "eval-only.log")
    if not ok:
        row["description"] = desc + " [hold/test eval FAILED]"; return row, None
    hold = set_scores(outd / "dev-hold.rows.jsonl")
    row.update(hold_S=hold["S"], **{f"hold_{c}_wer": hold.get(c) for c in CATS})
    ph = (prev_best or {}).get("hold") or {}
    if ph.get("S") is not None and hold.get("S") is not None: row["d_hold_S"] = round(hold["S"] - ph["S"], 2)
    if do_test:
        for n, _, _ in TEST_SETS:
            try: row[n] = wer_by_cat(outd / f"{n}.rows.jsonl").get("ALL")
            except OSError: pass
    return row, hold


def new_best_dict(exp, commit, ckpt, outd, hold, config, wers, desc):
    return {"exp_id": exp, "commit": commit, "init_ckpt": str(ckpt), "rows": str(outd / "dev-sel.rows.jsonl"), "vibe_rows": str(outd / "vibe.rows.jsonl"),
            "hold_rows": str(outd / "dev-hold.rows.jsonl") if hold else None, "hold": hold, "config": str(config),
            "sel_wer": wers, "description": desc, "updated": time.strftime("%F %T")}


# ---- apply (idempotent) ------------------------------------------------------------------------------------------------------
def apply_record(rec):
    with commit_lock():
        exp = rec["exp"]
        if rec.get("new_best"): atomic_write(AR / "best.json", json.dumps(rec["new_best"], indent=1))
        if rec.get("kept_row"): tsv_append_once(AR / "kept.tsv", KEPT_COLS, rec["kept_row"])
        tsv_append_once(AR / "results.tsv", RESULTS_COLS, rec["row"])
        tracker_mark(rec)
        qf = rec.get("queue_file")
        if qf and Path(qf).exists():                    # the claimed file (state/running/gpuN/<exp>.yaml) -> done/
            DONE.mkdir(exist_ok=True); os.replace(qf, DONE / Path(qf).name)
        atomic_write(DONE / f"{exp}.result.json", json.dumps(rec, indent=1))
        (STATE / "attempts" / exp).unlink(missing_ok=True)
        update_current(exp=None, finished=exp, t=time.time(), init_ckpt=None, out_dir=None, run_id=None, train_pid=None, train_pgid=None, cfg=None, claim_best=None, phase=None)
        prune_disk()


def tracker_mark(rec):
    """results onto the tracker run (dashboard): status + autoresearch summary.  Never raises."""
    try:
        sys.path.insert(0, str(CODE / "lab"))
        import tracker
        tracker.ROOT = tracker_root()
        rid = rec["run_id"]; row = rec["row"]; f = tracker_root() / rid / "run.json"
        if not f.exists(): tracker.Run(rid, kind="train", tags=["autoresearch"], run_id=rid, notes=row.get("description", "")).finish("failed")
        meta = json.loads(f.read_text())
        meta.setdefault("summary", {})["autoresearch"] = {k: row.get(k) for k in ("status", "S", "en_in_wer", "cm_wer", "work_wer", "hi_wer", "native_wer", "d_S", "ci_S", "runaways", "minutes")}
        meta["notes"] = meta.get("notes") or row.get("description", "")
        meta["tags"] = list(dict.fromkeys(meta.get("tags", []) + ["autoresearch", row["status"]]))
        if row["status"] == "crash" and meta.get("status") == "running": meta.update(status="failed", error=rec.get("why"), ended=time.time())
        tracker._write_json(f, meta)
    except Exception as e: log(f"tracker update skipped: {e}")


def running_experiments():
    """every runner's state/current-gpu*.json that has a live experiment: [{exp, init_ckpt, out_dir, ...}]."""
    out = []
    for f in sorted(STATE.glob("current-gpu*.json")):
        c = read_json(f)
        if c and c.get("exp"): out.append(c)
    return out


def prune_keep_set():
    """dirs under ar/out that must keep their checkpoints: best's checkpoint dir, the last KEEP_DISCARDED discarded experiments, and for EVERY running
    experiment (any GPU) its init checkpoint's dir and its own out dir."""
    b = best(); keep = set()
    if b: keep.add(str(Path(b["init_ckpt"]).resolve().parent))
    rows = tsv_rows(AR / "results.tsv")
    for e in [r["exp_id"] for r in rows if r["status"] == "discard"][-KEEP_DISCARDED:]: keep.add(str((OUT / f"ar-{e}").resolve()))
    for c in running_experiments():
        if c.get("init_ckpt"): keep.add(str(Path(c["init_ckpt"]).resolve().parent))
        if c.get("out_dir"): keep.add(str(Path(c["out_dir"]).resolve()))
    return keep


def prune_disk():
    """Everything under ar/out not in prune_keep_set() loses its step-*/best dirs (rows/logs stay).  Only experiments already in results.tsv are touched."""
    keep = prune_keep_set(); rows = tsv_rows(AR / "results.tsv"); freed = 0
    for r in rows:
        d = (OUT / f"ar-{r['exp_id']}").resolve()
        if str(d) in keep or not d.is_dir() or OUT.resolve() not in d.parents: continue
        for sub in list(d.glob("step-*")) + list(d.glob("best*")) + list(d.glob("*.tmp")):
            freed += sum(f.stat().st_size for f in sub.rglob("*") if f.is_file()); shutil.rmtree(sub, ignore_errors=True)
    if freed: log(f"pruned {freed / 1e9:.2f} GB of old checkpoints")


# ---- init / baseline ---------------------------------------------------------------------------------------------------------
def init_best(a):
    ck = Path(a.ckpt).resolve()
    if not (ck / "COMPLETE").exists(): raise SystemExit(f"{ck}: no COMPLETE marker")
    cfgp = Path(a.config).resolve(); assert cfgp.exists()
    atomic_write(AR / "best.json", json.dumps({"exp_id": None, "init_ckpt": str(ck), "rows": None, "config": str(cfgp), "description": a.description or "starting model",
                                               "updated": time.strftime("%F %T")}, indent=1))
    print("best.json written; the runner evaluates the baseline (dev-sel, vibe, dev-hold, test sets) on its first run")


def maybe_die(point):   # test hook for reboot simulation: the process dies exactly like a power cut
    if os.environ.get("AR_DIE_AT") == point and not (STATE / f"died-{point}").exists():
        (STATE / f"died-{point}").write_text("x"); os._exit(9)


def do_baseline(b):
    with commit_lock():                                      # one runner evaluates the baseline; the other waits and then finds best.json initialised
        b = best()
        if b.get("rows"): return
        _do_baseline(b)


def _do_baseline(b):
    exp, rid = "baseline", "ar-baseline"; outd = OUT / rid
    rec_path = STATE / "commits" / "baseline.json"
    if rec_path.exists(): apply_record(json.loads(rec_path.read_text())); return
    cfg = yaml.safe_load(os.path.expandvars(Path(b["config"]).read_text()))
    shutil.rmtree(outd, ignore_errors=True); outd.mkdir(parents=True)
    update_current(exp=exp, started=time.time(), init_ckpt=str(b["init_ckpt"]), out_dir=str(outd), run_id=rid)
    L = locked_sets(); sets = [L["dev-sel"], L["vibe"], L["dev-hold"]] + test_specs()
    ok, mins = eval_only(exp, cfg, b["init_ckpt"], sets, outd, outd / "baseline.log")
    commit = code_commit()
    if not ok: raise SystemExit("baseline evaluation failed; see " + str(outd / "baseline.log"))
    wers = set_scores(outd / "dev-sel.rows.jsonl"); hold = set_scores(outd / "dev-hold.rows.jsonl"); sm = metrics_by_cat(outd / "dev-sel.rows.jsonl")
    nb = new_best_dict(exp, commit, b["init_ckpt"], outd, hold, b["config"], wers, b.get("description", "starting model"))
    kept = {"exp_id": exp, "commit": commit, "kept_n": 0, "sel_S": wers["S"], "hold_S": hold["S"], **{f"hold_{c}_wer": hold.get(c) for c in CATS}, "description": "baseline (starting model)"}
    for n, _, _ in TEST_SETS: kept[n] = wer_by_cat(outd / f"{n}.rows.jsonl").get("ALL")
    row = {"exp_id": exp, "commit": commit, "S": wers["S"], **{f"{c}_wer": wers.get(c) for c in CATS}, "minutes": round(mins, 1), "status": "keep",
           "description": "baseline (starting model)", "cm_fw_pts": sm.get("cm", {}).get("fw_pts")}
    rec = {"exp": exp, "run_id": rid, "row": row, "kept_row": kept, "new_best": nb, "queue_file": None}
    atomic_write(rec_path, json.dumps(rec, indent=1)); maybe_die("after-commit")
    apply_record(rec)


# ---- one experiment --------------------------------------------------------------------------------------------------------------
def claim_next():
    """-> Path of a queue file this runner now owns (state/running/gpuN/), or None.  First anything already in our own running dir (reboot recovery),
    then the first queue file we win by os.rename (atomic: a lost race raises FileNotFoundError and we try the next file)."""
    RUNNING.mkdir(parents=True, exist_ok=True)
    mine = sorted(RUNNING.glob("*.yaml"))
    if mine: return mine[0]
    for q in sorted(QUEUE.glob("*.yaml")):
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", q.stem):
            try: os.rename(q, DONE / (q.name + ".badname"))
            except OSError: pass
            continue
        try: os.rename(q, RUNNING / q.name)
        except OSError: continue                                 # claimed by the other runner
        return RUNNING / q.name
    return None


def run_select(b, outd):
    """the LOCKED select_v2.py of the candidate's rows in outd against best b's rows -> (verdict dict | None, error text)."""
    out = subprocess.run([PY, "-I", str(LOCKED / "select_v2.py"), "--base", b["rows"], "--cand", str(outd / "dev-sel.rows.jsonl"), "--base-vibe", b["vibe_rows"],
                          "--cand-vibe", str(outd / "vibe.rows.jsonl"), "--locked-sel", str(LOCKED / "dev-sel.jsonl"), "--locked-vibe", str(LOCKED / "vibe.jsonl"),
                          "--out-dir", str(outd)], capture_output=True, text=True, env=dict(os.environ, AR_SCORE_DIR=str(CODE / "eval")))
    if out.returncode != 0: return None, f"select_v2.py failed rc={out.returncode}: {(out.stdout or out.stderr)[-300:]}"
    return json.loads(out.stdout), ""


def best_id(b): return (b or {}).get("exp_id"), (b or {}).get("rows")


def requeue(q, exp, att_f, att):
    """guard preempted this run (GPU needed by someone else): back to queue/, attempt not consumed, no crash record."""
    clear_preempted(exp)
    if att <= 1: att_f.unlink(missing_ok=True)
    else: att_f.write_text(str(att - 1))
    os.rename(q, QUEUE / Path(q).name)
    update_current(exp=None, requeued=exp, t=time.time(), init_ckpt=None, out_dir=None, run_id=None, claim_best=None)
    log(f"{exp}: PREEMPTED by the GPU guard: put back in the queue (attempt not counted); waiting for the GPU to be free")
    return 12


def run_one():
    for d in (QUEUE, DONE, OUT, STATE / "commits", STATE / "cfg", STATE / "attempts", STATE / "running", PAUSE_DIR, PREEMPT_DIR, AR / "logs"): d.mkdir(parents=True, exist_ok=True)
    b = best()
    if not b: log("best.json missing: run  runner_lib.py init-best --config C --ckpt STEP_DIR"); return 11
    if not b.get("rows"):
        log("evaluating baseline"); do_baseline(b); return 0
    q = claim_next()
    if q is None: return 10
    b = best()                                              # the best at claim time: this experiment is compared with it unless it moves before the decision
    exp = q.stem
    rid = f"ar-{exp}"; outd = OUT / rid; commit = code_commit(); desc = ""
    rec_path = STATE / "commits" / f"{exp}.json"
    if rec_path.exists():                                   # finished earlier, died before/while applying
        log(f"{exp}: re-applying recorded outcome"); apply_record(json.loads(rec_path.read_text())); return 0
    att_f = STATE / "attempts" / exp; att = (int(att_f.read_text() or 0) + 1) if att_f.exists() else 1; att_f.write_text(str(att))
    clear_preempted(exp)

    def finish_crash(why, mins=0.0, pk=None):
        log(f"{exp}: CRASH ({why})")
        rec = crash_record(exp, rid, commit, desc or exp, why, mins, str(q), pk)
        with commit_lock(): atomic_write(rec_path, json.dumps(rec, indent=1)); apply_record(rec)
        return 0
    try:
        base_cfg, meta = load_queue_file(q, QUEUE); desc = str(meta["description"]).strip().splitlines()[0]
        if att > MAX_ATTEMPTS: return finish_crash(f"started {att - 1} times without finishing (reboot loop?)")
        if meta.get("commit") and str(meta["commit"]) not in commit: return finish_crash(f"code commit mismatch: wanted {meta['commit']}, deployed {commit}")
        init = meta.get("init_ckpt") or (base_cfg.get("model") or {}).get("init_ckpt")
        if not init or init == "best": init = b["init_ckpt"]
        L = locked_sets()
        cfg, rid = enforce(base_cfg, exp, init, [L["dev-sel"], L["vibe"]])
        budget = float(cfg["train"]["max_minutes"])
    except Reject as e: return finish_crash(f"rejected: {e}")
    except Exception as e: return finish_crash(f"bad queue file: {type(e).__name__}: {e}")
    outd = OUT / rid
    timeout = budget * (1 + float(DUTY_SLEEP or 0)) + TIMEOUT_EXTRA_MIN   # train.py sleeps duty*step outside the budget, so the wall-clock limit must allow for it
    cp = STATE / "cfg" / f"{rid}.yaml"; atomic_write(cp, yaml.safe_dump(cfg))
    atomic_write(CURRENT, json.dumps({"exp": exp, "gpu": GPU, "started": time.time(), "attempt": att, "budget_min": budget, "init_ckpt": str(init), "out_dir": str(outd), "run_id": rid,
                                      "claim_best": best_id(b), "train_pid": None}))
    shutil.rmtree(outd, ignore_errors=True); shutil.rmtree(tracker_root() / rid, ignore_errors=True)    # restart from scratch
    outd.mkdir(parents=True)
    log(f"{exp}: start attempt {att}  gpu {GPU}  budget {budget} min  timeout {timeout:.1f} min  commit {commit}  init {init}  :: {desc}")
    rc, mins = run_train(cp, [], timeout, outd / "train.log")
    if preempted_marker(exp) and not (outd / "FINISHED").exists(): return requeue(q, exp, att_f, att)   # a SIGTERMed train.py never writes FINISHED
    final = read_json(outd / "final.json"); pk = peak_gb(outd, final); ck = newest_step(outd)
    if rc != 0: return finish_crash("timeout" if rc == 124 else f"exit {rc}", mins, pk)
    if ck is None or not all(p.exists() for p in (outd / "FINISHED", outd / "dev-sel.rows.jsonl", outd / "vibe.rows.jsonl")):
        return finish_crash("exit 0 but no FINISHED/rows/checkpoint", mins, pk)
    v, err = run_select(b, outd)                            # preliminary verdict against the best at claim time (outside the lock: the bootstrap is slow)
    if v is None: return finish_crash(err, mins, pk)
    with commit_lock():                                     # ---- decision, record and apply are serialised across GPUs
        b2 = best(); rescored = best_id(b2) != best_id(b)
        if rescored:
            log(f"{exp}: best moved {best_id(b)[0]} -> {best_id(b2)[0]} while this ran: RE-SCORING against the current best")
            v, err = run_select(b2, outd)
            if v is None: return finish_crash(err, mins, pk)
            b = b2
        log(f"{exp}: {v['status'].upper()} S {v['S_cand']} (best {v['S_base']}) d_S {v['d_S']} ci {v['ci_S']} runaways {v['runaways']}{' [re-scored vs ' + str(best_id(b)[0]) + ']' if rescored else ''} :: {'; '.join(v['reasons'])}")
        row = {"exp_id": exp, "commit": commit, "S": v["S_cand"], **{f"{c}_wer": v["cand"].get(f"{c}_wer") for c in CATS}, "d_S": v["d_S"], "ci_S": ",".join(map(str, v["ci_S"])),
               "runaways": v["runaways"], "peak_gb": pk, "minutes": round(mins, 1), "status": v["status"], "description": desc + (" [re-scored vs newer best]" if rescored else ""),
               "term_acc": v["terms"]["cand_acc"], "cm_fw_pts": v["cand"].get("cm_fw_pts")}
        kept_row = nb = None
        if v["status"] == "keep":
            wers = {**{c: v["cand"].get(f"{c}_wer") for c in CATS}, "S": v["S_cand"]}
            update_current(phase="hold-eval")
            kept_row, hold = build_kept_row(exp, commit, desc, len(tsv_rows(AR / "kept.tsv")), wers, outd, b, ck, base_cfg)
            nb = new_best_dict(exp, commit, ck, outd, hold, b["config"], wers, desc)
        rec = {"exp": exp, "run_id": rid, "row": row, "kept_row": kept_row, "new_best": nb, "queue_file": str(q), "verdict": v, "rescored": rescored}
        atomic_write(rec_path, json.dumps(rec, indent=1)); maybe_die("after-commit")
        apply_record(rec)
    return 0


def status():
    print(json.dumps(best(), indent=1))
    for f in sorted(STATE.glob("current-gpu*.json")):
        c = read_json(f, {}) or {}
        if c.get("exp"):
            print(f"GPU {c.get('gpu', f.stem[len('current-gpu'):])}: running {c['exp']} (attempt {c.get('attempt')}, {(time.time() - c.get('started', time.time())) / 60:.1f} min in, budget {c.get('budget_min')} min"
                  f"{', ' + c['phase'] if c.get('phase') else ''}{', paused ' + format(pause_total(c['run_id']) / 60, '.1f') + ' min' if c.get('run_id') and pause_total(c['run_id']) else ''})")
        else: print(f"GPU {c.get('gpu', f.stem[len('current-gpu'):])}: idle (last finished {c.get('finished') or c.get('requeued')})")
    r = AR / "results.tsv"
    print("\n".join(r.read_text().splitlines()[-8:]) if r.exists() else "no results yet")


def main():
    ap = argparse.ArgumentParser(); sp = ap.add_subparsers(dest="cmd", required=True)
    sp.add_parser("run-one"); sp.add_parser("status")
    i = sp.add_parser("init-best"); i.add_argument("--config", required=True); i.add_argument("--ckpt", required=True); i.add_argument("--description")
    a = ap.parse_args()
    if a.cmd == "init-best": init_best(a)
    elif a.cmd == "status": status()
    else: sys.exit(run_one())


if __name__ == "__main__":
    main()
