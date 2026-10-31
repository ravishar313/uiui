"""Greedy TDT decoding in PyTorch on eval manifests -> eval/score.py compute()."""
from __future__ import annotations
import sys, time, json
from pathlib import Path
from collections import defaultdict
import torch
import tdt_decode
from torch.nn.utils import parametrize

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "eval" / "evalx"))
from score import compute  # noqa: E402  (import only; owned by another worker)
from data import load_manifest, read_wave  # noqa: E402


def pick(items, max_clips):
    """Cap to max_clips, round-robin over categories so the cap keeps the category mix."""
    if not max_clips or len(items) <= max_clips: return items
    by = defaultdict(list)
    for it in items: by[it["cat"]].append(it)
    out, cats = [], list(by)
    while len(out) < max_clips and any(by.values()):
        for c in cats:
            if by[c] and len(out) < max_clips: out.append(by[c].pop(0))
    return out


def load_eval_sets(specs, log=print):
    sets = {}
    for s in specs:
        items, _ = load_manifest(s["manifest"], s.get("max_secs"), None, log, s["name"])
        for it in items: it["cat"] = it["cat"] or s.get("default_cat", "en")
        sets[s["name"]] = pick(items, s.get("max_clips"))
    return sets


@torch.no_grad()
def transcribe(model, proc, items, device="cuda", batch_size=8, dtype=None, max_new_tokens=None):
    was_training = model.training
    model.eval()
    order = sorted(range(len(items)), key=lambda i: items[i]["dur"])
    hyps = [None] * len(items)
    t0 = time.perf_counter()
    for s in range(0, len(order), batch_size):
        ids = order[s:s + batch_size]
        inp = proc.feature_extractor([read_wave(items[i]["audio"]) for i in ids], sampling_rate=16000, return_tensors="pt",
                                     padding=True, return_attention_mask=True)
        with parametrize.cached(), torch.autocast(torch.device(device).type, dtype=dtype, enabled=dtype is not None):
            # Decode exactly like the app (PilotTDT: greedy TDT, max 10 symbols per frame).  transformers' generate has no
            # per-frame cap, so a rare duration-0 cycle ran to max_length there; the shipped decoder cannot do that.
            out = model.get_audio_features(input_features=inp["input_features"].to(device), attention_mask=inp["attention_mask"].to(device),
                                           output_attention_mask=True)
            enc = out.pooler_output
            lens = out.attention_mask.sum(-1) if out.attention_mask is not None else torch.full((len(ids),), enc.shape[1], device=enc.device)
            res = tdt_decode.TDTDecoder(model, device).decode(enc.float(), lens, tdt_decode.DecodeConfig(max_symbols=10))
        for i, h in zip(ids, tdt_decode.ids_to_text(proc, res)): hyps[i] = h
    ms = 1000 * (time.perf_counter() - t0) / max(len(items), 1)
    if was_training: getattr(model, "restore_train_mode", model.train)()
    return hyps, ms


def evaluate(model, proc, items, device="cuda", batch_size=8, dtype=None):
    hyps, ms = transcribe(model, proc, items, device, batch_size, dtype)
    rows = [{"id": it["id"], "cat": it["cat"], "reference": it["text"], "hypothesis": h, "speaker": it["speaker"]}
            for it, h in zip(items, hyps)]
    metrics, samples = compute(rows)
    return metrics, samples, ms, rows
