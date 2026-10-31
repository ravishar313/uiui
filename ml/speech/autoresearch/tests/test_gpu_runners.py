#!/usr/bin/env python3
"""Two-GPU runners + GPU guard.  No GPU, no ssh, runs on the Mac:   python3 -m unittest tests.test_gpu_runners   (needs pyyaml + numpy; ~2-3 min: it runs the real locked select_v2.py)
Fake GPUs: runner_lib is driven with AR_GPU=0/1 and the stub trainer (tests/stub_train.py); the guard's nvidia-smi is a shell script (AR_NVSMI) reading a json file."""
import importlib.util, json, os, shutil, signal, subprocess, sys, tempfile, threading, time, unittest
from pathlib import Path
import yaml

HERE = Path(__file__).resolve().parent; AR_SRC = HERE.parent; ML = AR_SRC.parent; PY = sys.executable


def load(path, name, **env):
    old = {k: os.environ.get(k) for k in env}
    os.environ.update({k: str(v) for k, v in env.items()})
    try:
        spec = importlib.util.spec_from_file_location(name, path); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
    finally:
        for k, v in old.items():
            if v is None: os.environ.pop(k, None)
            else: os.environ[k] = v


class Home:
    """scratch AR home with the real locked/ (symlink), the stub trainer and tiny test-set manifests."""
    def __init__(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="ar-gpu-test-")); self.ar = self.tmp / "ar"; ar = self.ar
        for d in ("queue", "state", "code/train", "tests"): (ar / d).mkdir(parents=True)
        (ar / "locked").symlink_to(AR_SRC / "locked")
        (ar / "code/lab").symlink_to(ML / "lab"); (ar / "code/eval").symlink_to(ML / "eval")
        shutil.copy(AR_SRC / "runner_lib.py", ar); shutil.copy(HERE / "stub_train.py", ar / "tests/stub_train.py"); (self.tmp / "runs").mkdir()
        data = self.tmp / "data"
        for rel in ("data/evalsets-lexicon/hiacc", "data/evalsets-lexicon/mucs-hien-test", "data/evalsets-lexicon/fleurs-hi", "evalsets/librispeech-clean"):
            d = data / rel; d.mkdir(parents=True)
            (d / "manifest.jsonl").write_text("".join(json.dumps({"id": f"{d.name}{i}", "reference": "hello world this is a test", "cat": "en"}) + "\n" for i in range(8)))
        self.data = data
        (ar / "init/step-0000001").mkdir(parents=True); (ar / "init/step-0000001/COMPLETE").write_text("ok\n"); (ar / "init/step-0000001/quality.json").write_text('{"err": 0.30}')
        allowed = json.loads((AR_SRC / "locked/allowed_train.json").read_text())
        base = {"name": "base", "mode": "qat", "data": {"sources": [{"name": "a", "manifest": allowed[0], "weight": 1.0}], "batch_size": 2}, "optim": {"lr": 1e-5},
                "train": {"total_steps": 10}, "model": {}, "eval": {"batch_size": 16}}
        (ar / "base.yaml").write_text(yaml.safe_dump(base))
        self.env = dict(os.environ, AR_HOME=str(ar), AR_PY=PY, AR_TRAIN_CMD=f"{PY} {ar}/tests/stub_train.py", UIUI_LAB_RUNS=str(self.tmp / "runs"), AR_DATA_ROOT=str(data),
                        AR_TIMEOUT_EXTRA_MIN="2", AR_DUTY_SLEEP="0")
        subprocess.check_call([PY, str(ar / "runner_lib.py"), "init-best", "--config", str(ar / "base.yaml"), "--ckpt", str(ar / "init/step-0000001")], env=self.env, stdout=subprocess.DEVNULL)

    def q(self, name, delta=0.0, mode="ok", secs=None, desc=None):
        stub = {"delta": delta, "mode": mode}
        if secs is not None: stub["secs"] = secs
        (self.ar / "queue" / f"{name}.yaml").write_text(yaml.safe_dump({"description": desc or f"exp {name}", "base": str(self.ar / "base.yaml"), "overrides": {"stub": stub, "train": {"max_minutes": 2}}}))

    def rl(self, gpu, *args, wait=True, **env):
        e = dict(self.env, AR_GPU=str(gpu), **{k: str(v) for k, v in env.items()})
        p = subprocess.Popen([PY, str(self.ar / "runner_lib.py"), *args], env=e, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
        if not wait: return p
        out = p.communicate()[0]; return p.returncode, out

    def mod(self, gpu): return load(self.ar / "runner_lib.py", f"rl{gpu}_{id(self)}", AR_HOME=self.ar, AR_GPU=gpu, AR_DATA_ROOT=self.data)

    def results(self):
        f = self.ar / "results.tsv"
        if not f.exists(): return {}
        L = f.read_text().splitlines(); return {r[0]: dict(zip(L[0].split("\t"), r)) for r in (l.split("\t") for l in L[1:])}

    def close(self): shutil.rmtree(self.tmp, ignore_errors=True)


class Base(unittest.TestCase):
    def setUp(self): self.h = Home(); self.addCleanup(self.h.close)


class TestClaim(Base):
    def test_claim_race_one_winner(self):
        for i in range(40): (self.h.ar / "queue" / f"{i:03d}-x.yaml").write_text("description: x\n")
        a, b = self.h.mod(0), self.h.mod(1); got = {0: [], 1: []}; bar = threading.Barrier(2)

        def go(m, k):
            bar.wait()
            while (q := m.claim_next()) is not None:
                got[k].append(q.name); m.RUNNING.joinpath(q.name).rename(m.DONE / q.name) if m.DONE.exists() else q.unlink()   # finish it so the next claim moves on
        ts = [threading.Thread(target=go, args=(a, 0)), threading.Thread(target=go, args=(b, 1))]; [t.start() for t in ts]; [t.join() for t in ts]
        allf = got[0] + got[1]
        self.assertEqual(len(allf), 40); self.assertEqual(len(set(allf)), 40, "a file was claimed twice")
        self.assertTrue(got[0] and got[1], f"one runner starved: {len(got[0])}/{len(got[1])}")

    def test_resume_own_running_dir_first(self):
        m = self.h.mod(1); m.RUNNING.mkdir(parents=True, exist_ok=True)
        (m.RUNNING / "050-old.yaml").write_text("description: x\n"); (self.h.ar / "queue/001-new.yaml").write_text("description: x\n")
        self.assertEqual(m.claim_next(), m.RUNNING / "050-old.yaml")
        self.assertTrue((self.h.ar / "queue/001-new.yaml").exists(), "must not take new work while it has an unfinished claim")
        self.assertEqual(self.h.mod(0).claim_next().resolve(), (self.h.ar / "state/running/gpu0/001-new.yaml").resolve())    # the other GPU does not touch gpu1's running dir

    def test_bad_name_goes_to_done(self):
        (self.h.ar / "queue/.bad name.yaml").write_text("x"); (self.h.ar / "done").mkdir(exist_ok=True)
        self.assertIsNone(self.h.mod(0).claim_next()); self.assertTrue((self.h.ar / "done/.bad name.yaml.badname").exists())


class TestEndToEnd(Base):
    def test_reboot_resume_from_running_dir(self):
        h = self.h; rc, out = h.rl(0, "run-one"); self.assertEqual(rc, 0, out)            # baseline
        h.q("001-a", delta=-0.10)
        m = h.mod(1); run = h.ar / "state/running/gpu1"; run.mkdir(parents=True, exist_ok=True)
        os.rename(h.ar / "queue/001-a.yaml", run / "001-a.yaml"); (h.ar / "state/attempts").mkdir(exist_ok=True); (h.ar / "state/attempts/001-a").write_text("1")   # died mid-run on attempt 1
        rc, out = h.rl(1, "run-one"); self.assertEqual(rc, 0, out)
        self.assertEqual(h.results()["001-a"]["status"], "keep"); self.assertTrue((h.ar / "done/001-a.yaml").exists()); self.assertFalse(list(run.glob("*.yaml")))
        self.assertIn("attempt 2", out)

    def test_two_runners_share_queue_and_rescore_when_best_moved(self):
        h = self.h; self.assertEqual(h.rl(0, "run-one")[0], 0)                            # baseline S
        h.q("001-slowgood", delta=-0.05, mode="run", secs=14)                             # gpu0 claims first (sorted), finishes LAST
        h.q("002-fastbest", delta=-0.12, mode="run", secs=1)                              # gpu1 claims the second, finishes first, becomes best
        p0 = h.rl(0, "run-one", wait=False); time.sleep(1.0); p1 = h.rl(1, "run-one", wait=False)
        o0, o1 = p0.communicate()[0], p1.communicate()[0]
        self.assertEqual((p0.returncode, p1.returncode), (0, 0), o0 + o1)
        self.assertIn("gpu 0", o0); self.assertIn("gpu 1", o1); self.assertIn("001-slowgood: start", o0); self.assertIn("002-fastbest: start", o1)
        R = h.results(); self.assertEqual(R["002-fastbest"]["status"], "keep")
        self.assertIn("RE-SCORING", o0, o0)                                                # 001 was a keep against the baseline, but the best moved under it
        self.assertEqual(R["001-slowgood"]["status"], "discard", R["001-slowgood"]); self.assertIn("re-scored", R["001-slowgood"]["description"])
        self.assertEqual(json.loads((h.ar / "best.json").read_text())["exp_id"], "002-fastbest")
        self.assertEqual(sorted(p.name for p in (h.ar / "done").glob("*.yaml")), ["001-slowgood.yaml", "002-fastbest.yaml"])
        self.assertEqual(len(R), 3); cur = [json.loads(f.read_text()) for f in sorted((h.ar / "state").glob("current-gpu*.json"))]; self.assertTrue(all(c["exp"] is None for c in cur))

    def test_preempted_run_is_requeued_not_recorded(self):
        h = self.h; self.assertEqual(h.rl(0, "run-one")[0], 0)
        h.q("001-pre", delta=-0.1, mode="run", secs=60); p = h.rl(0, "run-one", wait=False); cur = h.ar / "state/current-gpu0.json"
        t = time.time()
        while time.time() - t < 30:
            c = json.loads(cur.read_text()) if cur.exists() else {}
            if c.get("train_pid") and (h.ar / "out/ar-001-pre/started").exists(): break
            time.sleep(0.2)
        else: self.fail("train did not start")
        os.makedirs(h.ar / "state/preempted", exist_ok=True); (h.ar / "state/preempted/001-pre").write_text("{}"); os.killpg(c["train_pid"], signal.SIGTERM)   # what the guard does
        out = p.communicate(timeout=60)[0]
        self.assertEqual(p.returncode, 12, out); self.assertTrue((h.ar / "queue/001-pre.yaml").exists(), "not back in the queue"); self.assertNotIn("001-pre", h.results())
        self.assertFalse((h.ar / "state/attempts/001-pre").exists(), "attempt was consumed"); self.assertFalse((h.ar / "state/preempted/001-pre").exists())
        self.assertFalse((h.ar / "done/001-pre.yaml").exists()); self.assertFalse(list((h.ar / "state/running/gpu0").glob("*.yaml")))
        rc, out = h.rl(1, "run-one", ); self.assertEqual(rc, 0, out)                       # the other GPU can take it right away
        h.q("002-x"); rc, out = h.rl(0, "status"); self.assertIn("GPU 0", out); self.assertIn("GPU 1", out)

    def test_status_shows_both_gpus(self):
        h = self.h
        for g, e in ((0, "aaa"), (1, "bbb")): (h.ar / f"state/current-gpu{g}.json").write_text(json.dumps({"exp": e, "gpu": str(g), "started": time.time(), "attempt": 1, "budget_min": 25, "run_id": f"ar-{e}"}))
        rc, out = h.rl(0, "status"); self.assertIn("GPU 0: running aaa", out); self.assertIn("GPU 1: running bbb", out)


class TestPrune(Base):
    def test_keep_set_with_two_running_experiments(self):
        h = self.h; m = h.mod(0); out = h.ar / "out"
        def mk(name):
            d = out / name; (d / "step-0000010").mkdir(parents=True); (d / "step-0000010/model.bin").write_bytes(b"x" * 100); (d / "step-0000010/COMPLETE").write_text("ok"); return d
        best, run0_init, run1_init, run0_out, run1_out, stale, d1, d2, d3 = (mk(n) for n in ("ar-best", "ar-init0", "ar-init1", "ar-run0", "ar-run1", "ar-stale", "ar-d1", "ar-d2", "ar-d3"))
        (h.ar / "best.json").write_text(json.dumps({"exp_id": "best", "init_ckpt": str(best / "step-0000010"), "rows": "r", "vibe_rows": "v"}))
        cols = m.RESULTS_COLS
        (h.ar / "results.tsv").write_text("\t".join(cols) + "\n" + "".join("\t".join(e if c == "exp_id" else (s if c == "status" else "") for c in cols) + "\n"
                                                                            for e, s in (("best", "keep"), ("init0", "keep"), ("init1", "keep"), ("stale", "discard"), ("d1", "discard"), ("d2", "discard"), ("d3", "discard"))))
        for g, (init, o) in enumerate(((run0_init, run0_out), (run1_init, run1_out))):
            (h.ar / f"state/current-gpu{g}.json").write_text(json.dumps({"exp": f"run{g}", "init_ckpt": str(init / "step-0000010"), "out_dir": str(o)}))
        m.prune_disk()
        alive = lambda d: bool(list(d.glob("step-*")))
        for d in (best, run0_init, run1_init, run0_out, run1_out, d2, d3): self.assertTrue(alive(d), f"{d.name} pruned but must be kept")
        for d in (stale, d1): self.assertFalse(alive(d), f"{d.name} should have been pruned")


class TestPauseAccounting(Base):
    def test_pause_total_includes_running_pause(self):
        m = self.h.mod(0); (m.PAUSE_DIR).mkdir(parents=True, exist_ok=True)
        (m.PAUSE_DIR / "ar-x.json").write_text(json.dumps({"total": 100.0, "since": time.time() - 30}))
        self.assertAlmostEqual(m.pause_total("ar-x"), 130.0, delta=2); self.assertEqual(m.pause_total("nope"), 0.0)


# ---- guard ---------------------------------------------------------------------------------------------------------------------
G = load(AR_SRC / "ops/gpu_guard.py", "gpu_guard_t", AR_HOME=tempfile.mkdtemp(prefix="ar-guard-home-"))


def gpu(util=50.0, power=150.0, limit=400.0, ours=True, foreign=None):
    return {"util": util, "power": power, "limit": limit, "ours": {"pid": 1, "pgid": 1, "rid": "ar-x", "exp": "x", "stopped": False} if ours else None, "foreign": foreign or {}}


def feed(state, t0, secs, mk, step=5.0):
    """feed samples every `step` s from t0 for `secs`; mk(t) -> {idx: gpu}.  returns (all actions [(t, action)], end time)."""
    acts = []; t = t0
    while t <= t0 + secs:
        acts += [(t, a) for a in G.decide(state, t, mk(t))]; t += step
    return acts, t


class TestGuard(unittest.TestCase):
    def test_quiet_never_pauses(self):
        st = G.new_state(); acts, _ = feed(st, 0, 600, lambda t: {0: gpu(util=80, power=145), 1: gpu(util=85, power=140)}); self.assertEqual(acts, [])

    def test_foreign_process_appears_pauses_then_resumes_after_60s_clear(self):
        st = G.new_state(); resident = {111: 900.0}
        _, t = feed(st, 0, 60, lambda t: {0: gpu(foreign=resident)})                                     # small resident service: grandfathered
        self.assertEqual(st["gpu"][0]["paused_since"], None)
        acts, t = feed(st, t, 10, lambda t: {0: gpu(foreign={**resident, 222: 3500.0})}); self.assertEqual([a["act"] for _, a in acts], ["pause"]); self.assertIn("222", acts[0][1]["reason"])
        self.assertEqual(acts[0][0], 65)                                                                 # first sample with the process
        acts, t = feed(st, t, 300, lambda t: {0: gpu(util=0, power=60, foreign={**resident, 222: 3500.0})}); self.assertEqual(acts, [], "must stay paused while the foreign job runs")
        acts, t2 = feed(st, t, 120, lambda t: {0: gpu(util=0, power=60, foreign=resident)})
        self.assertEqual([a["act"] for _, a in acts], ["resume"]); self.assertGreaterEqual(acts[0][0] - t, 60); self.assertLess(acts[0][0] - t, 70)

    def test_small_foreign_and_grown_resident(self):
        st = G.new_state(); feed(st, 0, 20, lambda t: {0: gpu(foreign={5: 1000.0})})
        acts, _ = feed(st, 25, 10, lambda t: {0: gpu(foreign={5: 1000.0, 6: 1500.0})}); self.assertEqual(acts, [], "1.5 GB foreign newcomer is below the 2 GB threshold")
        acts, _ = feed(st, 40, 10, lambda t: {0: gpu(foreign={5: 3500.0})}); self.assertEqual([a["act"] for _, a in acts], ["pause"], "resident service grew by > 2 GB")

    def test_util_over_90_rolling_mean_not_single_spike(self):
        st = G.new_state(); acts, _ = feed(st, 0, 100, lambda t: {0: gpu(util=100 if t == 50 else 70)}); self.assertEqual(acts, [])
        st = G.new_state(); acts, _ = feed(st, 0, 100, lambda t: {0: gpu(util=95)}); self.assertEqual([a["act"] for _, a in acts], ["pause"]); self.assertIn("util", acts[0][1]["reason"])
        self.assertGreaterEqual(acts[0][0], 20)                                                          # needs ~20 s of history first

    def test_power_over_90_percent_of_limit(self):
        st = G.new_state(); acts, _ = feed(st, 0, 100, lambda t: {0: gpu(power=370)}); self.assertEqual([a["act"] for _, a in acts], ["pause"]); self.assertIn("power", acts[0][1]["reason"])

    def test_total_power_pauses_only_the_hotter_gpu(self):
        mk = lambda t: {0: gpu(util=80, power=330, limit=400), 1: gpu(util=80, power=330, limit=400)}      # 330 < 360 each, sum 660 < 720: quiet
        st = G.new_state(); acts, _ = feed(st, 0, 100, mk); self.assertEqual(acts, [])
        cfg = dict(G.CFG, power_frac=1.5)                                                                  # per-GPU power rule off: isolates rule (c)
        mk = lambda t: {0: gpu(util=80, power=380, limit=400), 1: gpu(util=80, power=350, limit=400)}      # sum 730 > 720
        st = G.new_state(); acts = []
        for i in range(30):
            gs = mk(i * 5.0)
            if st["gpu"].get(0, {}).get("paused_since") is not None: gs[0].update(util=0, power=60)       # a paused GPU stops drawing power
            acts += [(i * 5, a) for a in G.decide(st, i * 5.0, gs, cfg)]
        self.assertEqual([(a["gpu"], a["act"]) for t, a in acts if t < 80], [(0, "pause")], acts)      # later: resumes after 60 s clear, duty-cycles if still hot
        self.assertIn("total power", acts[0][1]["reason"])

    def test_paused_20_min_preempts_once(self):
        st = G.new_state(); feed(st, -10, 0, lambda t: {0: gpu()})
        acts, _ = feed(st, 0, 1500, lambda t: {0: gpu(util=0, power=60, foreign={9: 5000.0})})
        kinds = [(t, a["act"]) for t, a in acts]; self.assertEqual([k for _, k in kinds], ["pause", "preempt"], kinds)
        self.assertEqual(kinds[1][0] - kinds[0][0], 1200)

    def test_flapping_condition_resets_clear_timer(self):
        st = G.new_state(); feed(st, 0, 20, lambda t: {0: gpu()})
        _, t = feed(st, 25, 5, lambda t: {0: gpu(foreign={9: 5000.0})})                                   # pause
        _, t = feed(st, t, 40, lambda t: {0: gpu(util=0, power=60)})                                      # clear 40 s ...
        acts, t = feed(st, t, 10, lambda t: {0: gpu(util=0, power=60, foreign={9: 5000.0})}); self.assertEqual(acts, [])   # ... foreign back: timer resets
        acts, t = feed(st, t, 50, lambda t: {0: gpu(util=0, power=60)}); self.assertEqual(acts, [], "only 50 s clear")
        acts, t = feed(st, t, 20, lambda t: {0: gpu(util=0, power=60)}); self.assertEqual([a["act"] for _, a in acts], ["resume"])

    def test_gpus_are_independent(self):
        st = G.new_state(); feed(st, 0, 20, lambda t: {0: gpu(), 1: gpu()})
        acts, _ = feed(st, 25, 10, lambda t: {0: gpu(), 1: gpu(foreign={9: 5000.0})}); self.assertEqual([(a["gpu"], a["act"]) for _, a in acts], [(1, "pause")])

    def test_not_ours_no_action(self):
        st = G.new_state(); acts, _ = feed(st, 0, 100, lambda t: {0: gpu(ours=False, util=100, power=400, foreign={9: 9000.0})}); self.assertEqual(acts, [])

    def test_busy_gate(self):
        me = lambda pid: "me" if pid == 1 else "other"
        b = lambda procs, util=(), job=False: G.busy_reason(0, procs, list(util), job, me, "me")
        self.assertIsNone(b([(7, 900.0), (8, 3000.0)], [0, 0, 0]), "small resident services must not block")
        self.assertIn("own process", b([(1, 27000.0)])); self.assertIn("foreign", b([(7, 7000.0)])); self.assertIn("production", b([], job=True))
        self.assertIn("util", b([(7, 900.0)], [60, 70, 80])); self.assertIsNone(b([], [10, 25, 15]))


class TestGuardIO(unittest.TestCase):
    """real processes: signal safety, fake nvidia-smi, pause accounting files, preempt marker."""
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="ar-guard-io-")); self.addCleanup(shutil.rmtree, self.tmp, True)
        (self.tmp / "state").mkdir(); self.g = load(AR_SRC / "ops/gpu_guard.py", f"gg{id(self)}", AR_HOME=self.tmp, AR_GUARD_TRAIN_MATCH="fake_train.py")
        (self.tmp / "fake_train.py").write_text("import time\nwhile True: time.sleep(0.2)\n")
        self.cfg = self.tmp / "state/cfg/ar-x.yaml"; self.cfg.parent.mkdir(); self.cfg.write_text("x")
        self.procs = []; self.addCleanup(lambda: [os.killpg(p.pid, signal.SIGKILL) for p in self.procs if p.poll() is None])

    def spawn(self, cfg):
        p = subprocess.Popen([PY, str(self.tmp / "fake_train.py"), "--config", str(cfg)], start_new_session=True); self.procs.append(p); time.sleep(0.3); return p

    def stat(self, p): return subprocess.run(["ps", "-o", "stat=", "-p", str(p.pid)], capture_output=True, text=True).stdout.strip()

    def test_signal_safety_and_accounting(self):
        g = self.g; p = self.spawn(self.cfg); bystander = subprocess.Popen(["sleep", "300"]); self.addCleanup(bystander.kill)
        cur = {"exp": "x", "train_pid": p.pid, "cfg": str(self.cfg), "train_rid": "ar-x"}
        job = g.our_job(cur, "fake_train.py"); self.assertEqual((job["pid"], job["exp"], job["stopped"]), (p.pid, "x", False))
        self.assertIsNone(g.our_job(dict(cur, cfg=str(self.cfg) + "2"), "fake_train.py"), "different --config must not match")
        self.assertIsNone(g.our_job(dict(cur, train_pid=bystander.pid), "fake_train.py"), "foreign command line must not match")
        self.assertIsNone(g.our_job(dict(cur, train_pid=os.getpid()), "fake_train.py"), "never our own process / group")
        pa = g.Pauses(); pa.pause(0, job, "test"); time.sleep(0.4)
        self.assertTrue(self.stat(p).startswith("T"), self.stat(p)); self.assertTrue(g.our_job(cur, "fake_train.py")["stopped"]); self.assertEqual(bystander.poll(), None)
        time.sleep(1.2); pa.resume(0, job, "test"); time.sleep(0.3)
        self.assertFalse(self.stat(p).startswith("T")); d = json.loads((self.tmp / "state/pause/ar-x.json").read_text()); self.assertIsNone(d["since"]); self.assertGreaterEqual(d["total"], 1.2)
        pa.pause(0, job, "again"); time.sleep(0.2); pa.resume(0, job, "again"); self.assertGreaterEqual(json.loads((self.tmp / "state/pause/ar-x.json").read_text())["total"], d["total"])

    def test_preempt_writes_marker_and_terminates_stopped_group(self):
        g = self.g; p = self.spawn(self.cfg); job = g.our_job({"exp": "x", "train_pid": p.pid, "cfg": str(self.cfg), "train_rid": "ar-x-eval"}, "fake_train.py")
        self.assertEqual(job["exp"], "x"); pa = g.Pauses(); pa.pause(0, job, "t"); time.sleep(0.3); pa.preempt(0, job, "paused 1200s")
        self.assertEqual(p.wait(timeout=10), -signal.SIGTERM); m = json.loads((self.tmp / "state/preempted/x").read_text()); self.assertEqual(m["gpu"], 0)

    def test_collect_with_fake_nvidia_smi(self):
        fake = self.tmp / "fake-smi"; data = self.tmp / "smi.json"
        fake.write_text(f"""#!{PY}
import json, sys
d = json.load(open({str(data)!r}))
if any(a.startswith('--query-gpu') for a in sys.argv): [print(f"{{i}}, GPU-{{i}}, {{g['util']}}, {{g['power']}}, {{g['limit']}}") for i, g in enumerate(d['gpus'])]
else: [print(f"GPU-{{u}}, {{pid}}, {{mb}}") for u, pid, mb in d['apps']]
"""); fake.chmod(0o755)
        data.write_text(json.dumps({"gpus": [{"util": 87, "power": 140.5, "limit": 400.0}, {"util": 3, "power": 60, "limit": 400.0}], "apps": [[0, os.getpid(), 27000], [1, 1, 2500]]}))
        g = load(AR_SRC / "ops/gpu_guard.py", f"gf{id(self)}", AR_HOME=self.tmp, AR_NVSMI=fake, AR_GUARD_TRAIN_MATCH="fake_train.py")
        p = self.spawn(self.cfg); (self.tmp / "state/current-gpu0.json").write_text(json.dumps({"exp": "x", "train_pid": p.pid, "cfg": str(self.cfg), "train_rid": "ar-x"}))
        c = g.collect(); self.assertEqual(c[0]["util"], 87); self.assertEqual(c[0]["ours"]["pid"], p.pid); self.assertIsNone(c[1]["ours"])
        self.assertEqual(c[0]["foreign"], {}, "this test process is owned by us"); self.assertEqual(c[1]["foreign"], {1: 2500.0}, "pid 1 (root) on GPU 1 is foreign")
        self.assertEqual(g.busy_cmd(0), 0)           # own process on GPU 0 -> busy
        os.environ["AR_BUSY_EVERY"] = "0.01"
        data.write_text(json.dumps({"gpus": [{"util": 3, "power": 60, "limit": 400.0}, {"util": 3, "power": 60, "limit": 400.0}], "apps": [[1, 1, 2500]]})); self.assertEqual(g.busy_cmd(1), 1, "small resident root service on GPU 1 must not block")


if __name__ == "__main__":
    unittest.main()
