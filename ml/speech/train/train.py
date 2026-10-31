#!/usr/bin/env python3
"""Fine-tune Phonon-2 (ParakeetForTDT) on CUDA or MPS.   python train.py --config configs/x.yaml [--resume auto|<run out dir>] [--set a.b=c ...]

Multi-GPU: torchrun --nproc_per_node=N train.py ... (DDP; rank 0 logs, evaluates and checkpoints).
Modes (config `mode`): full | qat | lora | decoder. See README.md and configs/."""
from __future__ import annotations
import argparse, contextlib, json, math, os, random, re, signal, sys, time
from pathlib import Path
import numpy as np
import torch
import yaml
from uiui_root import load_yaml

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE.parent / "lab"))
from tracker import Run, _slug                      # noqa: E402
from torch.nn.utils import parametrize       # noqa: E402
import modes, ckpt, evaluate, devutil        # noqa: E402
from data import TrainData                   # noqa: E402
from fast_tdt import tdt_loss_lean           # noqa: E402  (trainability/scripts via modes.py)

BASE = modes.tp.BASE


def deep_set(cfg, dotted, val):
    ks = dotted.split("."); d = cfg
    for k in ks[:-1]: d = d.setdefault(k, {})
    v = yaml.safe_load(val)
    if isinstance(v, str):
        try: v = float(v)
        except ValueError: pass
    d[ks[-1]] = v


def lr_at(step, total, o, frac=None):
    """frac (0..1, share of the wall-clock budget used) replaces the step-based progress when train.time_schedule is on."""
    lr, mn, wu = o["lr"], o.get("min_lr", 0.0), o.get("warmup_steps", 0)
    if step < wu: return lr * (step + 1) / wu
    p = (step - wu) / max(total - wu, 1) if frac is None else frac
    return mn + (lr - mn) * 0.5 * (1 + math.cos(math.pi * min(p, 1.0)))


def make_batch(b, blank, device):
    ids = b["ids"]; B = len(ids); U = max(len(x) for x in ids)
    labels = torch.full((B, U), blank, dtype=torch.long)
    for i, x in enumerate(ids): labels[i, :len(x)] = torch.tensor(x)
    lab_len = torch.tensor([len(x) for x in ids])
    dec_in = torch.cat([torch.full((B, 1), blank, dtype=torch.long), labels], 1)
    return (b["feats"].to(device), b["mask"].to(device), labels.to(device), lab_len.to(device), dec_in.to(device))


class LossStep(torch.nn.Module):
    """Forward + TDT loss as one module's forward, so DDP can wrap it (hooks fire, grad all-reduce overlaps backward)."""
    def __init__(self, model, encoder_frozen, vocab, durs, sigma, chunk, kd=None):
        super().__init__(); self.model, self.frozen, self.vocab, self.durs, self.sigma, self.chunk = model, encoder_frozen, vocab, durs, sigma, chunk
        self.kd, self.kd_stats = kd, {}   # kd: plain object (teacher inside is not a submodule => DDP ignores it)

    def forward(self, feats, am, labels, lab_len, dec_in):
        m = self.model
        if self.frozen:
            with torch.no_grad(): enc = m.get_audio_features(input_features=feats, attention_mask=am)
        else: enc = m.get_audio_features(input_features=feats, attention_mask=am)
        dh = m.decoder(dec_in)
        if self.kd is not None:
            total, self.kd_stats = self.kd.loss(m, enc, dh, feats, am, dec_in, labels, enc.attention_mask.sum(-1), lab_len, self.vocab, self.durs, self.sigma, self.chunk)
            return total
        return tdt_loss_lean(enc.pooler_output, dh, labels, enc.attention_mask.sum(-1), lab_len, m.joint.head, self.vocab, self.durs,
                             sigma=self.sigma, chunk=self.chunk)


class NullRun:
    """Tracker stand-in for ranks > 0."""
    id = ""
    def __init__(self, *a, **k): pass
    def keepalive(self): return contextlib.nullcontext()
    def __enter__(self): return self
    def __exit__(self, *a): return False
    def __getattr__(self, _): return lambda *a, **k: None


def _paused_total(path):
    """seconds this run was SIGSTOPped by the autoresearch GPU guard (ar/ops/gpu_guard.py keeps the file); 0 when absent."""
    try: return float(json.loads(Path(path).read_text()).get("total") or 0)
    except (OSError, ValueError): return 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--resume", default=None, help="'auto' (newest run dir with this name) or a run output dir")
    ap.add_argument("--eval-only", action="store_true", help="autoresearch: build the model (incl. model.init_ckpt), evaluate eval.sets once, write rows, exit")
    ap.add_argument("--set", action="append", default=[], help="override, e.g. --set train.total_steps=50")
    a = ap.parse_args()
    cfg = load_yaml(a.config)
    for s in a.set: deep_set(cfg, *s.split("=", 1))
    mode = cfg["mode"]
    rank, world, local = int(os.environ.get("RANK", 0)), int(os.environ.get("WORLD_SIZE", 1)), int(os.environ.get("LOCAL_RANK", 0))
    dev = devutil.pick_device(local)
    if world > 1:
        import datetime, torch.distributed as dist
        torch.cuda.set_device(dev); dist.init_process_group("nccl", timeout=datetime.timedelta(hours=2))
    T, O, D, E = cfg["train"], cfg["optim"], cfg["data"], cfg.get("eval", {})
    seed = T.get("seed", 0) + 1000 * rank; random.seed(seed); np.random.seed(seed); torch.manual_seed(seed)
    total, accum = T["total_steps"], O.get("accum", 1)
    out_root = Path(cfg.get("out_dir", HERE / "out"))

    resume_dir, run_id, start_step, interrupted = None, None, 0, False
    if a.resume:
        if a.resume == "auto":   # newest run dir of this name: finished -> exit 0; else continue it (newest COMPLETE checkpoint, or from scratch)
            pat = re.compile(r"^\d{4}-\d{6}-" + re.escape(_slug(cfg["name"])) + "$")
            cands = sorted(p for p in out_root.glob("*") if pat.match(p.name)) if out_root.exists() else []
            rd = cands[-1] if cands else None
            if rd is not None and (rd / "FINISHED").exists(): print(f"{rd.name}: already finished"); return
        else: rd = Path(a.resume)
        if rd is None and a.resume != "auto": raise SystemExit("nothing to resume")
        if rd is not None:
            if rank == 0: ckpt.cleanup(rd)
            run_id = rd.name; interrupted = True; resume_dir = ckpt.latest(rd)
            if resume_dir is not None: start_step = int(resume_dir.name.split("-")[1])

    tags = list(dict.fromkeys([mode] + list(cfg.get("tags", []))))
    run = (Run if rank == 0 else NullRun)(cfg["name"], kind="train", config=cfg, total_steps=total, tags=tags,
              parent=cfg.get("parent", "Phonon-2 (shipping)"), notes=cfg.get("notes", ""), run_id=run_id or cfg.get("run_id"))
    with run:
        log = run.note
        out = out_root / run.id
        if rank == 0: out.mkdir(parents=True, exist_ok=True); (out / "config.yaml").write_text(yaml.safe_dump(cfg))
        if interrupted: log(f"resumed from step {start_step} after interruption" if resume_dir else "restarting from step 0 after interruption (no complete checkpoint)")
        log(f"run {run.id}  mode={mode}  steps={total}  accum={accum}  out={out}" + (f"  RESUME from {resume_dir}" if resume_dir else ""))

        data = None if a.eval_only else TrainData(D, BASE, seed, start_batch=start_step * accum, log=log)
        it = iter(data) if data is not None else None; pending = []
        sg = cfg.get("surgery") or {}
        calib = None
        if sg.get("add_blocks") and not resume_dir and it is not None:
            calib = next(it); pending.append(calib)
        model, proc, info = modes.build_model(cfg, calib, dev, log)
        log("model: " + json.dumps(info))
        mcfg = cfg.get("model", {})
        if mcfg.get("init_ckpt") and not resume_dir:   # autoresearch: start from a finished experiment's model; optimiser/schedule/step stay fresh
            log(f"init_ckpt {mcfg['init_ckpt']}: " + json.dumps(ckpt.load_init(model, Path(mcfg["init_ckpt"]), mode, dev, mcfg.get("init_from", "ema"))))
        if mcfg.get("overlay_dir") and not resume_dir:   # decoder-int6 evals: take decoder.*/joint.* from this checkpoint dir on top of init_ckpt (encoder from init_ckpt)
            from safetensors.torch import load_file
            ov = Path(mcfg["overlay_dir"]); sdv = load_file(ov / ("model_ema.safetensors" if mcfg.get("overlay_from", "ema") == "ema" else "model.safetensors"))
            named_ = dict(model.named_parameters()); sub_ = {k: v for k, v in sdv.items() if k.startswith(("decoder.", "joint."))}
            with torch.no_grad():
                for k_, v_ in sub_.items(): named_[k_].copy_(v_.to(named_[k_].device, named_[k_].dtype))
            log(f"overlay {ov}: {len(sub_)} decoder/joint tensors")
        blank, vocab, durs = model.config.blank_token_id, model.config.vocab_size, list(model.config.durations)
        qc_ = cfg.get("qat") or {}
        if qc_.get("decoder_int6"):          # opt-in: fake-quant decoder/joint exactly as export/decoder_bin.py (see int6_dec.py); default off
            import int6_dec; int6_dec.apply_decoder_int6(model, log)
        if qc_.get("freeze_encoder"):        # opt-in: train only decoder.* / joint.*; optim.pt of checkpoints then holds decoder-only trainable/ema
            for n_, p_ in model.named_parameters():
                if not n_.startswith(("decoder.", "joint.")): p_.requires_grad_(False)
            info["encoder_frozen"] = True; log("freeze_encoder: only decoder.* and joint.* are trainable")

        params = [p for p in model.parameters() if p.requires_grad]
        named = [(n, p) for n, p in model.named_parameters() if p.requires_grad]
        decay = [p for n, p in named if p.ndim >= 2 and not n.endswith((".lo", ".hi"))]
        nodecay = [p for n, p in named if not (p.ndim >= 2 and not n.endswith((".lo", ".hi")))]
        opt = torch.optim.AdamW([{"params": decay, "weight_decay": O.get("weight_decay", 1e-3)}, {"params": nodecay, "weight_decay": 0.0}],
                                lr=O["lr"], betas=tuple(O.get("betas", (0.9, 0.98))))
        ema = ckpt.EMA(model, cfg["ema"]["decay"]) if cfg.get("ema", {}).get("enabled") else None

        state = {"best": None, "audio_secs": 0.0}
        if resume_dir:
            blob = ckpt.load_into(model, resume_dir, mode, dev)
            opt.load_state_dict(blob["opt"]); state.update(best=blob.get("best"), audio_secs=blob.get("audio_secs", 0.0))
            if ema is not None and "ema" in blob: ema.shadow = {n: t.to(dev) for n, t in blob["ema"].items()}
            if rank == 0 and blob.get("rng"): ckpt.set_rng(blob["rng"])   # other ranks keep their own seed stream
            else: ckpt.reseed(seed + start_step)
            log(f"resumed step {start_step}, best {state['best']}")
        if ema is not None: ema.shadow = {n: t.to(dev) for n, t in ema.shadow.items()}

        eval_sets = evaluate.load_eval_sets(E.get("sets", []), log) if E.get("sets") and rank == 0 else {}   # rank 0 evaluates and saves alone
        bm = E.get("best_metric", {}); use_ema_eval = ema is not None and E.get("use_ema", True)
        save_dtype = cfg.get("checkpoint", {}).get("dtype", "float32")
        ck = cfg.get("checkpoint", {})

        rows_dir = Path(E["rows_dir"]) if E.get("rows_dir") else out

        def run_eval(step, final=False):
            nonlocal state
            def go():
                res = {}
                for name, items in eval_sets.items():
                    metrics, samples, ms, rows = evaluate.evaluate(model, proc, items, dev, E.get("batch_size", 8), E.get("dtype") and getattr(torch, E["dtype"]))
                    run.log_eval(step, name, metrics, samples, decode_ms=ms)
                    run.note(f"eval step {step} {name} ({len(items)} clips, {ms:.0f} ms/clip): " + ", ".join(f"{k} {v['wer']}%" for k, v in sorted(metrics.items())))
                    res[name] = metrics
                    if final and rank == 0 and (E.get("save_rows", False) or a.eval_only):   # per-clip rows for autoresearch/locked/select.py (id, cat, reference, hypothesis, speaker)
                        rows_dir.mkdir(parents=True, exist_ok=True); tmp = rows_dir / f"{name}.rows.jsonl.tmp"
                        tmp.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows)); tmp.replace(rows_dir / f"{name}.rows.jsonl")
                return res
            with run.keepalive():
                if use_ema_eval:
                    with ema.swapped(model): res = go()
                else: res = go()
            if bm and bm.get("set") in res and step > 0:
                val = res[bm["set"]].get(bm.get("category", "ALL"), {}).get(bm.get("key", "wer"))
                if val is not None and (state["best"] is None or val < state["best"]["value"]):
                    state["best"] = {"value": val, "step": step, **bm}
                    ckpt.save_best(out, model, use_ema_eval, ema, cfg, state["best"], save_dtype)
                    log(f"new best {bm} = {val} at step {step} -> {out / 'best'}")
            return res

        def save(step):
            # data position = (seed, batches consumed per rank): resume re-creates the sampler and skips exactly that many batches
            extra = {"rng": ckpt.get_rng(), "data": {"seed": seed, "batches": step * accum, "rank": rank, "world": world}}
            with run.keepalive():
                d = ckpt.save_step(out, step, model, opt, ema, state, cfg, mode, save_dtype, extra)
                ckpt.prune(out, ck.get("keep_last", 2), ck.get("keep_optim", 2))
            log(f"checkpoint {d}")

        if a.eval_only:
            run_eval(0, final=True); run.set(summary_note="eval-only"); log("eval-only done"); return
        if eval_sets and E.get("at_start", True) and start_step == 0: run_eval(0)

        encoder_frozen = info["encoder_frozen"]
        modes.attach_train_mode(model, encoder_frozen, cfg.get("model", {}).get("bn_eval", True))()
        bf16 = cfg.get("precision", "bf16") == "bf16"
        kd = None
        if cfg.get("distill"):   # teacher is rebuilt from the config on every (re)start; it is never checkpointed
            import distill
            kd = distill.Distiller(cfg["distill"], dev, log); kd.attach_student(model)
        item_kd = None   # distill.only_kd_sources: KD only on clips from sources marked `kd: true` (e.g. native English from the base model)
        if kd is not None and data is not None and cfg["distill"].get("only_kd_sources"):
            item_kd = torch.zeros(len(data.items), dtype=torch.bool)
            for s, (a0, a1) in zip(D["sources"], data.ranges):
                if s.get("kd"): item_kd[a0:a1] = True
            assert item_kd.any(), "distill.only_kd_sources is on but no data source has kd: true"
            log(f"distill only on sources {[s.get('name') for s in D['sources'] if s.get('kd')]} ({int(item_kd.sum())} clips)")
        fwd =LossStep(model, encoder_frozen, vocab, durs, T.get("tdt_sigma", 0.02), T.get("joint_chunk", 32), kd)
        inner = fwd
        if world > 1:
            from torch.nn.parallel import DistributedDataParallel as DDP
            fwd = DDP(fwd, device_ids=[local], gradient_as_bucket_view=True)
            if T.get("ddp_grad_bf16", False):   # halves all-reduce traffic on PCIe-only boxes (no NVLink)
                from torch.distributed.algorithms.ddp_comm_hooks import default_hooks
                fwd.register_comm_hook(None, default_hooks.bf16_compress_hook)
        log_every = T.get("log_every", 10); acc_loss = 0.0; acc_n = 0; t_mark = time.perf_counter(); skipped_nonfinite = 0
        acc_kd = {}
        stop = {"flag": False}
        every_min = ck.get("every_minutes", 12); last_save = time.monotonic()   # time-based checkpoints on top of the step-based ones
        signal.signal(signal.SIGTERM, lambda *_: stop.update(flag=True))
        step = n = start_step
        max_min = T.get("max_minutes"); spent = 0.0; budget_hit = False   # wall-clock training budget: evals, checkpoint saves and loading do not count
        time_sched = bool(max_min) and bool(T.get("time_schedule", False))
        duty = float(os.environ.get("AR_DUTY_SLEEP") or 0.0); pause_file = os.environ.get("AR_PAUSE_FILE"); pause_seen = 0.0
        for step in range(start_step, total):
            t_seg = time.perf_counter()
            lr = lr_at(step, total, O, frac=min(spent / (max_min * 60), 1.0) if time_sched else None)
            for g in opt.param_groups: g["lr"] = lr
            ok = True
            for k in range(accum):
                b = pending.pop() if pending else next(it)
                feats, am, labels, lab_len, dec_in = make_batch(b, blank, dev)
                if item_kd is not None: kd.mask = item_kd[b["idxs"]].to(dev)
                with torch.autocast(dev.type, dtype=torch.bfloat16, enabled=bf16), parametrize.cached():
                    loss = fwd(feats, am, labels, lab_len, dec_in)
                lv = loss.item()
                if not math.isfinite(lv) and world == 1: ok = False; break   # DDP: every rank must backward; the grad-norm check below skips the update
                with (fwd.no_sync() if world > 1 and k < accum - 1 else contextlib.nullcontext()): (loss / accum).backward()
                for kk, vv in inner.kd_stats.items(): acc_kd[kk] = acc_kd.get(kk, 0.0) + float(vv)
                acc_loss += lv; acc_n += 1; state["audio_secs"] += b["secs"] * world
            gn = torch.nn.utils.clip_grad_norm_(params, O.get("grad_clip", 1.0)) if ok else torch.tensor(float("nan"))
            if not ok or not math.isfinite(float(gn)):
                skipped_nonfinite += 1; opt.zero_grad(set_to_none=True); log(f"step {step + 1}: non-finite loss/grad, update skipped ({skipped_nonfinite} so far)")
            else:
                opt.step(); opt.zero_grad(set_to_none=True)
                if ema is not None: ema.update(model, step)
            n = step + 1
            ece = T.get("empty_cache_every", 1 if dev.type == "mps" else 0)   # MPS: variable T/U shapes otherwise grow the cache until swap
            if ece and n % ece == 0: devutil.empty_cache(dev)
            if n % log_every == 0 or n == total:
                devutil.synchronize(dev); now = time.perf_counter()
                run.log(n, loss=acc_loss / max(acc_n, 1), lr=lr, grad_norm=float(gn), s_per_step=(now - t_mark) / log_every if n % log_every == 0 else (now - t_mark),
                        audio_hours=state["audio_secs"] / 3600, **{k: v / max(acc_n, 1) for k, v in acc_kd.items()}, **{f"{dev.type}_gb": devutil.mem_gb(dev)}, skipped_nonfinite=skipped_nonfinite)
                log(f"step {n}/{total} loss {acc_loss / max(acc_n, 1):.4f} lr {lr:.2e} gn {float(gn):.2f} {(now - t_mark) / log_every:.2f}s/step "
                    f"audio {state['audio_secs'] / 3600:.2f}h {dev.type} {devutil.mem_gb(dev):.1f}GB"
                    + "".join(f" {k} {v / max(acc_n, 1):.4f}" for k, v in acc_kd.items()))
                acc_kd = {}; acc_loss = 0.0; acc_n = 0; t_mark = time.perf_counter()
            seg = time.perf_counter() - t_seg
            if pause_file:   # time the GPU guard held us SIGSTOPped inside this step is not training time
                pt = _paused_total(pause_file)
                seg -= min(max(pt - pause_seen, 0.0), seg); pause_seen = pt
            spent += seg
            if duty > 0:                          # wait for queued GPU work first, else the GPU keeps computing through the sleep
                if torch.cuda.is_available(): torch.cuda.synchronize()
                time.sleep(duty * seg)   # AR_DUTY_SLEEP: idle a fraction of every step so the average GPU util stays under 90%; not counted in the budget, so steps per run are unchanged
            if eval_sets and n % E.get("every", 500) == 0 and n != total: run_eval(n)
            due = rank == 0 and every_min and time.monotonic() - last_save > every_min * 60
            if world > 1:   # all ranks must stop on the same step
                fl = torch.tensor([float(stop["flag"])], device=dev); dist.all_reduce(fl, op=dist.ReduceOp.MAX); stop["flag"] = bool(fl.item())
            if rank == 0 and n != total and (due or n % ck.get("every", 500) == 0):
                save(n); last_save = time.monotonic()
            if stop["flag"]:
                log("SIGTERM: saving and stopping")
                if rank == 0: save(n)
                run.finish("stopped"); return
            if max_min:
                hit = torch.tensor([float(spent >= max_min * 60)], device=dev)
                if world > 1: dist.all_reduce(hit, op=dist.ReduceOp.MAX)
                if hit.item() > 0.5 and n != total:
                    budget_hit = True; log(f"train.max_minutes {max_min} reached after {spent / 60:.1f} train-min at step {n}/{total}: final eval, save, exit"); break
        final_step = n if budget_hit else total
        if eval_sets: run_eval(final_step, final=True)
        if rank == 0:
            save(final_step); (out / "final.json").write_text(json.dumps({"step": final_step, "total_steps": total, "budget_hit": budget_hit, "train_minutes": round(spent / 60, 2),
                                                                          "peak_gb": round(devutil.mem_gb(dev), 2)}))
            (out / "FINISHED").write_text(f"{final_step}\n")
        run.set(summary_note=f"best {state['best']}")
        log("done")
        if world > 1: dist.barrier(); dist.destroy_process_group()


if __name__ == "__main__":
    main()
