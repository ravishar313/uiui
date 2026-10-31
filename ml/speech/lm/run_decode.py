"""Encode once, decode many.  Runs on CPU (CUDA_VISIBLE_DEVICES= , <=12 threads).

  encode : python lm/run_decode.py encode --ckpt <model.safetensors> --sets name=manifest[,..] --out cache/ [--max N]
  parity : python lm/run_decode.py parity --ckpt .. --set dev-mix=<manifest> --n 120   (decoder vs model.generate, same batches)
  eval   : python lm/run_decode.py eval --cache cache/ --sets a,b --lm lms/o6.trie.bin --lam 0.2 --guard ... --out res.json
"""
from __future__ import annotations
import argparse, json, os, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "train")); sys.path.insert(0, str(HERE))
from uiui_root import ROOT as _R, SPEECH
ROOT = Path(_R)
sys.path.insert(0, str(Path(SPEECH) / "eval" / "evalx"))
import torch
from tdt_decode import (TDTDecoder, DecodeConfig, GuardConfig, load_model, encode_batch, ids_to_text)


def read_items(manifest, limit=None):
    import soundfile as sf
    items = []
    for l in open(manifest):
        if not l.strip(): continue
        r = json.loads(l)
        ref = r.get("reference", r.get("text", ""))
        if not ref.strip(): continue
        try: info = sf.info(r["audio"])
        except Exception: continue
        if info.samplerate != 16000: continue
        items.append({"id": r["id"], "audio": r["audio"], "ref": ref, "cat": r.get("cat") or r.get("category") or "en",
                      "speaker": r.get("speaker"), "secs": float(info.duration)})
    return items[:limit] if limit else items


def read_wave(path):
    import soundfile as sf
    w, _ = sf.read(path, dtype="float32", always_2d=False)
    return w.mean(-1) if w.ndim > 1 else w


def parse_sets(s):
    out = {}
    for part in s.split(","):
        n, p = part.split("=", 1); out[n] = os.path.expanduser(p)
    return out


def cmd_encode(a):
    torch.set_num_threads(a.threads)
    model, proc = load_model(a.ckpt); Path(a.out).mkdir(parents=True, exist_ok=True)
    for name, mf in parse_sets(a.sets).items():
        dst = Path(a.out) / f"{name}.pt"
        if dst.exists() and not a.force: print("skip", name); continue
        items = read_items(mf, a.max)
        order = sorted(range(len(items)), key=lambda i: items[i]["secs"])
        enc = [None] * len(items); t0 = time.time()
        for s in range(0, len(order), a.bs):
            ids = order[s:s + a.bs]
            po, lens = encode_batch(model, proc, [read_wave(items[i]["audio"]) for i in ids])
            for j, i in enumerate(ids): enc[i] = po[j, :int(lens[j])].clone()
            if (s // a.bs) % 10 == 0: print(f"{name} {s}/{len(items)} {time.time() - t0:.0f}s", flush=True)
        torch.save({"items": items, "enc": enc}, dst)
        print(f"{name}: {len(items)} clips, {sum(i['secs'] for i in items) / 3600:.2f} h, {time.time() - t0:.0f}s", flush=True)


def pad(encs):
    T = max(e.shape[0] for e in encs)
    x = torch.zeros(len(encs), T, encs[0].shape[1])
    for i, e in enumerate(encs): x[i, :e.shape[0]] = e
    return x, torch.tensor([e.shape[0] for e in encs])


def cmd_parity(a):
    """transformers generate vs TDTDecoder on identical batches (encoder recomputed by generate; ours reuses its own encode_batch)."""
    torch.set_num_threads(a.threads)
    model, proc = load_model(a.ckpt)
    n, mf = list(parse_sets(a.set).items())[0]
    items = read_items(mf)
    # spread over the manifest, sorted by duration, batches of bs (as train/evaluate.py)
    step = max(1, len(items) // a.n); items = items[::step][:a.n]
    order = sorted(range(len(items)), key=lambda i: items[i]["secs"])
    dec = TDTDecoder(model)
    modes = {"pilot(max_sym=10)": DecodeConfig(max_symbols=10), "hf(no cap)": DecodeConfig(max_symbols=None, stop_on_eos=True)}
    res = {k: {"mismatch": [], "n": 0} for k in modes}; res["generate_vs_cap"] = []
    t_gen = t_dec = 0.0
    for s in range(0, len(order), a.bs):
        ids = order[s:s + a.bs]
        inp = proc.feature_extractor([read_wave(items[i]["audio"]) for i in ids], sampling_rate=16000, return_tensors="pt",
                                     padding=True, return_attention_mask=True)
        t0 = time.time()
        with torch.no_grad():
            out = model.generate(input_features=inp["input_features"], attention_mask=inp["attention_mask"])
        t_gen += time.time() - t0
        seq = getattr(out, "sequences", out)
        ref = [x.strip() for x in proc.batch_decode(seq, skip_special_tokens=True)]
        # token-level reference: generate's sequences without blank/pad (pad=2 only after finish)
        ref_tok = []
        for row in seq.tolist():
            row = row[1:]                                  # decoder_start_token
            ref_tok.append([x for x in row if x not in (8192, 2)])     # blanks; pad (2) fills rows that finished early
        po, lens = encode_batch(model, proc, [read_wave(items[i]["audio"]) for i in ids])
        # encoder inside generate saw the same padded batch -> same encoder output
        for name, cfg in modes.items():
            t0 = time.time(); hy = dec.decode(po, lens, cfg); t_dec += time.time() - t0
            txt = ids_to_text(proc, hy)
            for j, i in enumerate(ids):
                res[name]["n"] += 1
                res[name].setdefault("token_mismatch", 0)
                if [x for x in hy[j].tokens if x != 2] != ref_tok[j]: res[name]["token_mismatch"] += 1
                if txt[j] != ref[j]:
                    res[name]["mismatch"].append({"id": items[i]["id"], "hf": ref[j], "ours": txt[j]})
    res["secs_generate"] = t_gen; res["secs_decoder_two_modes"] = t_dec
    print(json.dumps({k: (v if not isinstance(v, dict) else {"n": v["n"], "text_mismatches": len(v["mismatch"]), "token_mismatches": v.get("token_mismatch"), "examples": v["mismatch"][:3]})
                      for k, v in res.items()}, indent=1, ensure_ascii=False))
    if a.out: Path(a.out).write_text(json.dumps(res, ensure_ascii=False, indent=1))


def build_cfg(a):
    g = GuardConfig(enabled=a.guard, ngram_min=a.g_nmin, ngram_max=a.g_nmax, max_repeats=a.g_k, action=a.g_action,
                    max_tps=a.g_tps, rate_slack=a.g_slack, zero_dur_repeat=a.g_zero)
    return DecodeConfig(max_symbols=None if a.max_symbols < 0 else a.max_symbols, lm_weight=a.lam, length_bonus=a.beta, topk=a.topk,
                        fusion=a.fusion, blank_bonus=a.blank_bonus, guard=g)


def decode_set(dec, proc, blob, cfg, lm, bs=16, threads_note=None):
    items, enc = blob["items"], blob["enc"]
    order = sorted(range(len(items)), key=lambda i: enc[i].shape[0])
    hyps = [None] * len(items); st = {"lm_lookups": 0, "lm_secs": 0.0, "lm_steps": 0, "rep": 0, "rate": 0, "zero": 0}
    t0 = time.time()
    for s in range(0, len(order), bs):
        ids = order[s:s + bs]
        x, lens = pad([enc[i] for i in ids])
        hy = dec.decode(x, lens, cfg, lm=lm, secs=[items[i]["secs"] for i in ids])
        txt = ids_to_text(proc, hy)
        for j, i in enumerate(ids):
            hyps[i] = (txt[j], hy[j])
            for k in ("rep", "rate", "zero"): st[k] += hy[j].stats.get(k, 0)
        st["lm_lookups"] += hy[0].stats.get("_lm_lookups", 0); st["lm_secs"] += hy[0].stats.get("_lm_secs", 0.0)
        st["lm_steps"] += hy[0].stats.get("_lm_steps", 0)
    st["decode_secs"] = time.time() - t0
    return hyps, st


def cmd_eval(a):
    torch.set_num_threads(a.threads)
    from score import compute
    model, proc = load_model(a.ckpt)
    dec = TDTDecoder(model)
    lm = None
    if a.lm:
        from ngram_lm import KenLMScorer
        lm = KenLMScorer(a.lm)
    out = {}
    import copy
    sweep = [(float(l), float(be)) for l in str(a.lam).split(",") for be in str(a.beta).split(",")]
    blobs = {name: torch.load(Path(a.cache) / f"{name}.pt") for name in a.sets.split(",")}
    for lam, beta in sweep:
        a2 = copy.copy(a); a2.lam, a2.beta = lam, beta
        cfg = build_cfg(a2)
        for name, blob in blobs.items():
            hyps, st = decode_set(dec, proc, blob, cfg, lm, a.bs)
            rows = [{"id": it["id"], "cat": it["cat"], "reference": it["ref"], "hypothesis": h[0], "speaker": it["speaker"]}
                    for it, h in zip(blob["items"], hyps)]
            metrics, samples = compute(rows)
            key = f"{name}|lam={lam}|beta={beta}"
            out[key] = {"metrics": metrics, "stats": st, "ntok": sum(len(h[1].tokens) for h in hyps)}
            if a.dump:
                d = Path(a.dump) / (f"lam{lam}_b{beta}" if len(sweep) > 1 else ".")
                d.mkdir(parents=True, exist_ok=True)
                (d / f"{name}.jsonl").write_text("\n".join(json.dumps({**r, "tokens": h[1].tokens}, ensure_ascii=False) for r, h in zip(rows, hyps)))
            m = metrics["ALL"]
            lk = st["lm_lookups"]
            print(f"{name:18} lam {lam:<5} beta {beta:<5} wer {m['wer']:6.2f} strict {m['strict_wer']:6.2f} cer {m['cer']:6.2f}  words {m['words']}  "
                  f"tok {out[key]['ntok']}  {st['decode_secs']:.0f}s  {json.dumps({k: st[k] for k in ('rep', 'rate', 'zero')})}"
                  + (f"  lm {1e6 * st['lm_secs'] / max(st['lm_steps'], 1):.0f}us/step {1e6 * st['lm_secs'] / max(lk, 1):.2f}us/lookup" if lk else ""), flush=True)
    if a.out: Path(a.out).write_text(json.dumps({"args": vars(a), "results": out}, indent=1, ensure_ascii=False))


def main():
    ap = argparse.ArgumentParser(); sub = ap.add_subparsers(dest="cmd", required=True)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--ckpt", default=str(ROOT / "train/out/1027-044123-teacher-dense-r2/best/model.safetensors"))
    common.add_argument("--threads", type=int, default=12)
    e = sub.add_parser("encode", parents=[common]); e.add_argument("--sets", required=True); e.add_argument("--out", required=True)
    e.add_argument("--max", type=int); e.add_argument("--bs", type=int, default=8); e.add_argument("--force", action="store_true")
    p = sub.add_parser("parity", parents=[common]); p.add_argument("--set", required=True); p.add_argument("--n", type=int, default=120)
    p.add_argument("--bs", type=int, default=8); p.add_argument("--out")
    v = sub.add_parser("eval", parents=[common]); v.add_argument("--cache", required=True); v.add_argument("--sets", required=True)
    v.add_argument("--lm"); v.add_argument("--lam", default="0.0", help="comma list = sweep"); v.add_argument("--beta", default="0.0", help="comma list = sweep")
    v.add_argument("--topk", type=int, default=16); v.add_argument("--fusion", default="two_stage"); v.add_argument("--blank-bonus", type=float, default=0.0, dest="blank_bonus")
    v.add_argument("--max-symbols", type=int, default=10, dest="max_symbols")
    v.add_argument("--guard", action="store_true"); v.add_argument("--g-nmin", type=int, default=3); v.add_argument("--g-nmax", type=int, default=6)
    v.add_argument("--g-k", type=int, default=3); v.add_argument("--g-action", default="ban"); v.add_argument("--g-tps", type=float, default=0.0)
    v.add_argument("--g-slack", type=float, default=8.0); v.add_argument("--g-zero", type=int, default=0)
    v.add_argument("--bs", type=int, default=16); v.add_argument("--out"); v.add_argument("--dump")
    a = ap.parse_args()
    {"encode": cmd_encode, "parity": cmd_parity, "eval": cmd_eval}[a.cmd](a)


if __name__ == "__main__":
    main()
