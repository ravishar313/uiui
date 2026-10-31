#!/usr/bin/env python3
"""GPU safety guard for the autoresearch runners (2x RTX 5090 with a weak PSU, shared with other users).   Stdlib only.

  gpu_guard.py run            the guard loop (tmux session ar-guard, started by ops/start_ar.sh): sample every ~5 s, pause / resume / preempt our train.py
  gpu_guard.py busy --gpu N   exit 0 + reason on stdout if runner N must not start now (used by runner.sh), exit 1 if GPU N is free for us

Guard rules, per GPU on which one of OUR train.py runs (decide() below is the pure decision function):
  PAUSE  (SIGSTOP our process group) when
    a) a foreign process (not owned by $USER) appears with > 2 GB VRAM (or grows by > 2 GB): small idle resident services that were already there when
       our run started are grandfathered (they are the baseline);
    b) the 30 s rolling mean of utilization > 90 % or of power draw > 90 % of power.limit;
    c) the 30 s rolling mean of the TOTAL power of all GPUs > 90 % of the sum of limits (the GPU drawing most of ours is paused).
  RESUME (SIGCONT) once no reason has applied for 60 s.
  PREEMPT when paused 20 min in a row: write state/preempted/<exp>, SIGTERM (+SIGCONT so it is delivered) our group; runner_lib puts the experiment back in queue/.
We only ever signal the process group recorded by our own runner in state/current-gpuN.json, after checking (via ps) that it is owned by $USER, is its own session
leader and its command line is a train.py with that run's `--config`.  No pkill, no pattern matching over other processes.
Pause accounting: state/pause/<run_id>.json {"total": s, "since": ts|null}.  train.py subtracts paused time from train.max_minutes, runner_lib extends its hard timeout.
Everything is logged to stdout (ops/start_ar.sh appends it to logs/guard.log).  Never logs anything but pids, GPU numbers and numbers.
"""
import argparse, json, os, signal, subprocess, sys, time
from pathlib import Path

AR = Path(os.environ.get("AR_HOME") or Path(__file__).resolve().parent.parent).resolve()
STATE = AR / "state"
import getpass
USER = os.environ.get("USER") or os.environ.get("LOGNAME") or getpass.getuser()
NVSMI = os.environ.get("AR_NVSMI", "nvidia-smi")
CFG = dict(period=5.0, window=30.0, util_hi=90.0, power_frac=0.9, total_power_frac=0.9, foreign_mb=2048.0, clear_secs=60.0, preempt_secs=1200.0)
BUSY = dict(foreign_mb=6000.0, util_busy=20.0, sample_secs=10.0, sample_every=2.0)


def log(*a): print(time.strftime("[%F %T]"), "guard:", *a, flush=True)


# ---- pure decision logic ---------------------------------------------------------------------------------------------------
def new_state(): return {"gpu": {}, "total_hist": []}


def _mean(h, i): return sum(x[i] for x in h) / len(h)


def _full(h, now, window): return bool(h) and now - h[0][0] >= window * 0.66      # ~20 s of samples before a rolling mean is trusted (no single-spike pause)


def decide(state, now, gpus, cfg=CFG):
    """state: mutable dict from new_state().  gpus: {idx: {"util": %, "power": W, "limit": W, "ours": None | {...}, "foreign": {pid: used_mb}}}  (foreign = processes NOT owned by $USER).
    -> list of actions [{"gpu", "act": "pause"|"resume"|"preempt", "reason": str}].  Mutates state (histories, baselines, pause timers) but does no I/O."""
    actions = []; G = state["gpu"]; w = cfg["window"]
    for g, x in gpus.items():
        s = G.setdefault(g, {"hist": [], "baseline": None, "paused_since": None, "clear_since": None, "preempted": False, "reasons": []})
        s["hist"].append((now, x["util"], x["power"])); s["hist"] = [h for h in s["hist"] if h[0] >= now - w]
    state["total_hist"].append((now, sum(x["power"] for x in gpus.values()))); state["total_hist"] = [h for h in state["total_hist"] if h[0] >= now - w]
    th = [h for h in state["total_hist"] if h[0] > state.get("c_pause_t", -1e18)]       # after pausing one GPU for (c), judge the total only on fresh samples (don't pause both)
    lim = sum(x["limit"] for x in gpus.values())
    total_hot = _full(th, now, w) and lim > 0 and _mean(th, 1) > cfg["total_power_frac"] * lim
    # (c) names the GPU with the highest current power among those running our job; a GPU that is already paused stays under (c) while it holds
    running = [g for g, x in gpus.items() if x["ours"] and G[g]["paused_since"] is None]
    target = max(running, key=lambda g: gpus[g]["power"], default=None) if total_hot else None
    for g, x in gpus.items():
        s = G[g]
        if not x["ours"]:                                   # nothing of ours here: refresh the foreign baseline, forget pause state
            s.update(baseline=dict(x["foreign"]), paused_since=None, clear_since=None, preempted=False, reasons=[]); continue
        if s["baseline"] is None: s["baseline"] = dict(x["foreign"])
        reasons = []
        for pid, mb in sorted(x["foreign"].items()):
            grown = mb - s["baseline"].get(pid, 0.0)
            if grown > cfg["foreign_mb"]: reasons.append(f"foreign pid {pid} uses {mb:.0f} MB ({'new' if pid not in s['baseline'] else 'grown'} +{grown:.0f} MB)")
        h = s["hist"]
        if _full(h, now, w):
            if _mean(h, 1) > cfg["util_hi"]: reasons.append(f"{w:.0f}s mean util {_mean(h, 1):.0f}% > {cfg['util_hi']:.0f}%")
            if x["limit"] > 0 and _mean(h, 2) > cfg["power_frac"] * x["limit"]: reasons.append(f"{w:.0f}s mean power {_mean(h, 2):.0f} W > {cfg['power_frac'] * 100:.0f}% of {x['limit']:.0f} W")
        if total_hot and (g == target or s["paused_since"] is not None):
            reasons.append(f"total power {_mean(th, 1):.0f} W > {cfg['total_power_frac'] * 100:.0f}% of summed limits")
        s["reasons"] = reasons
        if s["paused_since"] is None:
            if reasons:
                if total_hot and g == target: state["c_pause_t"] = now
                s.update(paused_since=now, clear_since=None, preempted=False); actions.append({"gpu": g, "act": "pause", "reason": "; ".join(reasons)})
        elif reasons: s["clear_since"] = None
        else:
            if s["clear_since"] is None: s["clear_since"] = now
            if now - s["clear_since"] >= cfg["clear_secs"]:
                actions.append({"gpu": g, "act": "resume", "reason": f"clear for {now - s['clear_since']:.0f}s (paused {now - s['paused_since']:.0f}s)"})
                s.update(paused_since=None, clear_since=None); continue
        if s["paused_since"] is not None and not s["preempted"] and now - s["paused_since"] >= cfg["preempt_secs"]:
            s["preempted"] = True; actions.append({"gpu": g, "act": "preempt", "reason": f"paused {now - s['paused_since']:.0f}s >= {cfg['preempt_secs']:.0f}s"})
    return actions


def busy_reason(gpu, procs, util_samples, production_job, uid_of, user, cfg=BUSY):
    """runner start gate for ONE gpu.  procs = [(pid, used_mb)] on that gpu; uid_of(pid) -> owner name | None.  -> reason string or None (free).
    busy: a production job file; any process of ours on the GPU; any foreign process > 6 GB; mean util > 20 % over the sample window while none of ours runs there."""
    if production_job: return "production job file in jobs/active"
    for pid, mb in procs:
        if uid_of(pid) == user: return f"own process {pid} on GPU {gpu}"
    for pid, mb in procs:
        if mb > cfg["foreign_mb"]: return f"foreign process {pid} uses {mb:.0f} MB on GPU {gpu}"
    if util_samples and sum(util_samples) / len(util_samples) > cfg["util_busy"]: return f"GPU {gpu} util {sum(util_samples) / len(util_samples):.0f}% > {cfg['util_busy']:.0f}% with none of our jobs there"
    return None


# ---- I/O: nvidia-smi / ps / signals ---------------------------------------------------------------------------------------
def _num(v):
    try: return float(str(v).strip())
    except ValueError: return 0.0


def _csv(args):
    r = subprocess.run([NVSMI] + args + ["--format=csv,noheader,nounits"], capture_output=True, text=True, timeout=20)
    if r.returncode != 0: raise RuntimeError(f"nvidia-smi rc={r.returncode}")
    return [[c.strip() for c in l.split(",")] for l in r.stdout.splitlines() if l.strip()]


def query_gpus():
    """-> {idx: {util, power, limit, uuid}}, [(idx, pid, used_mb)] for every compute process."""
    gpus = {}; byuuid = {}
    for idx, uuid, util, pw, lim in _csv(["--query-gpu=index,uuid,utilization.gpu,power.draw,power.limit"]):
        gpus[int(idx)] = dict(util=_num(util), power=_num(pw), limit=_num(lim), uuid=uuid); byuuid[uuid] = int(idx)
    procs = [(byuuid[u], int(pid), _num(mb)) for u, pid, mb in _csv(["--query-compute-apps=gpu_uuid,pid,used_memory"]) if u in byuuid and pid.isdigit()]
    return gpus, procs


def ps_info(pid):
    """-> (uid, pgid, stat, args) of a pid, or None."""
    r = subprocess.run(["ps", "-ww", "-o", "uid=,pgid=,stat=,args=", "-p", str(pid)], capture_output=True, text=True)
    parts = r.stdout.strip().split(None, 3)
    if r.returncode != 0 or len(parts) < 4: return None
    return int(parts[0]), int(parts[1]), parts[2], parts[3]


def owner(pid):
    r = subprocess.run(["ps", "-o", "user=", "-p", str(pid)], capture_output=True, text=True)
    return r.stdout.strip() or None


def our_job(cur, matcher="train.py"):
    """validated ours: current-gpuN.json names train_pid + cfg; confirm with ps that it is really that process.  -> {"pid","pgid","rid","exp","stopped"} | None"""
    if not cur or not cur.get("train_pid") or not cur.get("cfg"): return None
    info = ps_info(cur["train_pid"])
    if not info: return None
    uid, pgid, stat, args = info; toks = args.split()
    if uid != os.getuid() or pgid != int(cur["train_pid"]) or pgid == os.getpgrp(): return None
    if "--config" not in toks or toks[toks.index("--config") + 1:][:1] != [cur["cfg"]] or matcher not in args: return None
    rid = cur.get("train_rid") or Path(cur["cfg"]).stem; exp = rid[3:] if rid.startswith("ar-") else rid
    if exp.endswith("-eval"): exp = exp[:-5]
    return {"pid": int(cur["train_pid"]), "pgid": pgid, "rid": rid, "exp": exp, "stopped": stat.startswith("T")}


def read_json(p):
    try: return json.loads(Path(p).read_text())
    except (OSError, ValueError): return None


def write_json(p, d):
    p = Path(p); p.parent.mkdir(parents=True, exist_ok=True); t = p.with_name(p.name + ".tmp"); t.write_text(json.dumps(d)); os.replace(t, p)


def collect():
    """-> gpus dict for decide(): idx -> {util, power, limit, ours, foreign{pid: mb}}"""
    gpus, procs = query_gpus(); out = {}
    for idx, g in gpus.items():
        cur = read_json(STATE / f"current-gpu{idx}.json")
        foreign = {pid: mb for i, pid, mb in procs if i == idx and owner(pid) != USER}
        out[idx] = dict(util=g["util"], power=g["power"], limit=g["limit"], ours=our_job(cur, os.environ.get("AR_GUARD_TRAIN_MATCH", "train.py")), foreign=foreign)
    return out


class Pauses:
    """pause accounting files + signalling; the only place that signals."""
    def __init__(self): self.acc = {}          # gpu -> {"rid", "since", "total_before"}

    def _file(self, rid): return STATE / "pause" / f"{rid}.json"

    def pause(self, g, job, reason):
        f = self._file(job["rid"]); prev = (read_json(f) or {}).get("total", 0.0)
        self.acc[g] = dict(rid=job["rid"], since=time.time(), total=prev); write_json(f, {"total": prev, "since": time.time()})
        os.killpg(job["pgid"], signal.SIGSTOP); log(f"PAUSE gpu {g} exp {job['exp']} pgid {job['pgid']}: {reason}")

    def resume(self, g, job, reason):
        a = self.acc.pop(g, None)
        if a: write_json(self._file(a["rid"]), {"total": a["total"] + time.time() - a["since"], "since": None})   # accounting first, then SIGCONT
        os.killpg(job["pgid"], signal.SIGCONT); log(f"RESUME gpu {g} exp {job['exp']}: {reason}")

    def preempt(self, g, job, reason):
        write_json(STATE / "preempted" / job["exp"], {"gpu": g, "t": time.time(), "reason": reason})
        os.killpg(job["pgid"], signal.SIGTERM); os.killpg(job["pgid"], signal.SIGCONT)         # a stopped process only sees SIGTERM once continued
        log(f"PREEMPT gpu {g} exp {job['exp']}: {reason}; SIGTERM sent, runner will re-queue it"); a = self.acc.pop(g, None)
        if a: write_json(self._file(a["rid"]), {"total": a["total"] + time.time() - a["since"], "since": None})


def adopt(state, now, gpus, pauses):
    """after a guard restart: a train.py of ours that is already stopped counts as paused (since now) so it is resumed/pre-empted by the normal rules."""
    for g, x in gpus.items():
        s = state["gpu"].get(g)
        if x["ours"] and x["ours"]["stopped"] and g not in pauses.acc and (s is None or s["paused_since"] is None):
            f = pauses._file(x["ours"]["rid"]); d = read_json(f) or {}
            pauses.acc[g] = dict(rid=x["ours"]["rid"], since=float(d.get("since") or now), total=float(d.get("total") or 0))
            st = state["gpu"].setdefault(g, {"hist": [], "baseline": None, "paused_since": None, "clear_since": None, "preempted": False, "reasons": []})
            st["paused_since"] = pauses.acc[g]["since"]; st["baseline"] = st["baseline"] if st["baseline"] is not None else dict(x["foreign"]); log(f"adopted already-stopped job on gpu {g} (exp {x['ours']['exp']})")


def run_loop():
    state = new_state(); pauses = Pauses(); fails = 0; log(f"up (AR_HOME={AR}, user {USER}, period {CFG['period']}s)")
    while True:
        t0 = time.time()
        try:
            gpus = collect(); fails = 0
            adopt(state, t0, gpus, pauses)
            for a in decide(state, t0, gpus):
                job = gpus[a["gpu"]]["ours"]
                try: getattr(pauses, a["act"])(a["gpu"], job, a["reason"])
                except ProcessLookupError: log(f"{a['act']} gpu {a['gpu']}: process already gone")
        except Exception as e:
            fails += 1
            if fails in (1, 12, 120): log(f"sampling failed ({fails}x): {type(e).__name__}: {e}")
        if (AR / "STOP").exists() and not any(our_job(read_json(f), os.environ.get("AR_GUARD_TRAIN_MATCH", "train.py")) for f in STATE.glob("current-gpu*.json")):
            log("STOP file present and no job of ours running: exiting"); return 0
        time.sleep(max(CFG["period"] - (time.time() - t0), 0.5))


def busy_cmd(gpu):
    if any(Path(os.environ.get("UIUI_ML_ROOT") or "workspace").resolve().joinpath("jobs/active").glob("*.job")): print(busy_reason(gpu, [], [], True, owner, USER)); return 0
    try: gpus, procs = query_gpus()
    except Exception as e: print(f"cannot query nvidia-smi ({e}): treating GPU {gpu} as busy"); return 0
    mine = [(pid, mb) for i, pid, mb in procs if i == gpu]
    r = busy_reason(gpu, mine, [], False, owner, USER)
    if r is None:                                              # nothing of ours / no big foreign process: is somebody working on it (util)?
        samples = []; n = max(int(BUSY["sample_secs"] / BUSY["sample_every"]), 1)
        for k in range(n):
            if k: time.sleep(float(os.environ.get("AR_BUSY_EVERY", BUSY["sample_every"])))
            try: samples.append(query_gpus()[0][gpu]["util"])
            except Exception: pass
        r = busy_reason(gpu, mine, samples, False, owner, USER)
    if r: print(r); return 0
    return 1


def main():
    ap = argparse.ArgumentParser(); sp = ap.add_subparsers(dest="cmd", required=True); sp.add_parser("run")
    b = sp.add_parser("busy"); b.add_argument("--gpu", type=int, required=True); a = ap.parse_args()
    sys.exit(run_loop() if a.cmd == "run" else busy_cmd(a.gpu))


if __name__ == "__main__":
    main()
