"""Tiny file-based experiment tracker for the uiui ASR lab.

Every run is a folder under $UIUI_ML_ROOT/runs/<run_id>/:
  run.json       metadata, status, config, summary (rewritten atomically)
  metrics.jsonl  one row per logged step: {"step", "t", ...values}
  evals.jsonl    one row per evaluation: {"step", "t", "set", "metrics": {cat: {...}}, "samples": [...]}
  log.txt        free-form log lines

Usage:
    from tracker import Run
    run = Run("lora-r32-hinglish", kind="train", config={...}, total_steps=5000,
              tags=["hinglish"], parent="baseline-phonon2")
    run.log(step, loss=..., lr=...)
    run.log_eval(step, "dev", metrics_by_cat, samples)
    run.finish()            # or run.fail("message")
"""
import json
import os
import re
import socket
import threading
import time
import traceback
from datetime import datetime, timezone, timedelta
from pathlib import Path

from uiui_root import ROOT as _ML_ROOT
ROOT = Path(os.environ.get("UIUI_LAB_RUNS", Path(_ML_ROOT) / "runs"))
IST = timezone(timedelta(hours=5, minutes=30))


def _now():
    return time.time()


def _slug(name):
    return re.sub(r"[^a-z0-9._-]+", "-", name.lower()).strip("-")[:60]


def _write_json(path, data):
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=1, ensure_ascii=False))
    os.replace(tmp, path)


class Run:
    def __init__(self, name, kind="train", config=None, total_steps=None, tags=(),
                 parent=None, notes="", run_id=None):
        stamp = datetime.now(IST).strftime("%m%d-%H%M%S")
        self.id = run_id or f"{stamp}-{_slug(name)}"
        self.dir = ROOT / self.id
        self.dir.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        prev = None
        if run_id and (self.dir / "run.json").exists():      # reopen after an interruption: keep started/summary, same folder
            try: prev = json.loads((self.dir / "run.json").read_text())
            except ValueError: prev = None
        self.meta = {
            "id": self.id, "name": name, "kind": kind, "status": "running",
            "tags": list(tags), "parent": parent, "notes": notes,
            "config": config or {}, "total_steps": total_steps,
            "started": _now(), "heartbeat": _now(), "ended": None,
            "pid": os.getpid(), "host": socket.gethostname(),
            "step": 0, "summary": {}, "error": None,
        }
        if prev:
            self.meta.update(started=prev.get("started", self.meta["started"]), summary=prev.get("summary", {}),
                             step=prev.get("step", 0), resumes=prev.get("resumes", 0) + 1)
        self._save()
        self._last_beat = 0.0

    def keepalive(self, every=20.0):
        """Context manager: heartbeat from a background thread (long evals / checkpoint saves)."""
        run = self
        class _K:
            def __enter__(s):
                s.stop = threading.Event()
                def loop():
                    while not s.stop.wait(every): run._beat(force=True)
                s.t = threading.Thread(target=loop, daemon=True); s.t.start(); return run
            def __exit__(s, *a): s.stop.set(); s.t.join(1)
        return _K()

    # -- public API -------------------------------------------------------
    def log(self, step, **values):
        row = {"step": step, "t": _now(), **{k: _num(v) for k, v in values.items()}}
        with open(self.dir / "metrics.jsonl", "a") as f:
            f.write(json.dumps(row) + "\n")
        self.meta["step"] = step
        self._beat()

    def log_eval(self, step, eval_set, metrics, samples=(), decode_ms=None):
        """metrics: {category: {"wer": .., "strict_wer": .., "cer": .., "words": ..}}"""
        row = {"step": step, "t": _now(), "set": eval_set, "metrics": metrics,
               "samples": list(samples)[:200], "decode_ms": decode_ms}
        with open(self.dir / "evals.jsonl", "a") as f:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
        self.meta["summary"][eval_set] = {"step": step, "metrics": metrics, "decode_ms": decode_ms}
        self._beat(force=True)

    def note(self, text):
        line = f"[{datetime.now(IST).strftime('%H:%M:%S')}] {text}"
        with open(self.dir / "log.txt", "a") as f:
            f.write(line + "\n")
        print(line, flush=True)

    def set(self, **fields):
        self.meta.update(fields)
        self._save()

    def finish(self, status="done"):
        self.meta.update(status=status, ended=_now(), heartbeat=_now())
        self._save()

    def fail(self, message=None):
        self.meta["error"] = message or traceback.format_exc()[-2000:]
        self.finish("failed")

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        if exc_type is KeyboardInterrupt:
            self.finish("stopped")
        elif exc_type:
            self.fail()
        elif self.meta["status"] == "running":
            self.finish()
        return False

    # -- internals ---------------------------------------------------------
    def _beat(self, force=False):
        t = _now()
        if force or t - self._last_beat > 5:
            self.meta["heartbeat"] = t
            self._save()
            self._last_beat = t

    def _save(self):
        with self._lock:
            _write_json(self.dir / "run.json", self.meta)


def _num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return v
