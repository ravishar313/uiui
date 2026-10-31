#!/usr/bin/env python
"""Score every hyp/*.jsonl with the locked scorer; romanize Devanagari with romanize_v2 (style=eval); write results.json/md."""
import sys, json, os, re, glob, collections
from uiui_root import ROOT, SPEECH
sys.path.insert(0, SPEECH + "/eval/evalx")
sys.path.insert(0, SPEECH + "/data")
from fair_wer import twer
from romanize_v2 import romanize_v2
import soundfile as sf
B = ROOT + "/bench"
SETS = ["svarah-partial", "monsoon-en-in", "librispeech-clean", "fleurs-en", "mucs-hien-test", "hiacc", "fleurs-hi"]
EN = SETS[:4]; HI = SETS[4:]
DEVA = re.compile(r"[ऀ-ॿ]")
# run key -> (display, params string, size, license, on-device note)
META = {
 "phonon2-shipped": ("Ours: Phonon-2 Core ML (shipped, ANE)", "~0.6B (5-value/6-bit palettised)", None, "CC-BY-4.0 weights", "Yes - it is the app model"),
 "parakeet-auto": ("nvidia/parakeet-tdt-0.6b-v3 (base, HF transformers fp32)", "627M", "2.5 GB fp32 (0.71 GB q8 gguf)", "CC-BY-4.0", "Yes (Core ML/ANE port exists = our Phonon base)"),
 "w3-auto": ("whisper-large-v3 (auto lang)", "1.54B", "3.1 GB fp16", "Apache-2.0", "Heavy: fits in RAM, ~real-time-ish on GPU, no ANE"),
 "w3-en": ("whisper-large-v3 (forced en)", "1.54B", "3.1 GB fp16", "Apache-2.0", "same"),
 "w3turbo-auto": ("whisper-large-v3-turbo (auto lang)", "809M", "1.6 GB fp16", "MIT", "Feasible (GPU), ~0.8 GB if 4-bit"),
 "w3turbo-en": ("whisper-large-v3-turbo (forced en)", "809M", "1.6 GB fp16", "MIT", "same"),
 "prime-en": ("Oriserve Whisper-Hindi2Hinglish-Prime (forced en)", "1.54B", "3.1 GB fp16", "Apache-2.0", "Heavy (large-v3 size)"),
 "prime-auto": ("Oriserve Whisper-Hindi2Hinglish-Prime (auto)", "1.54B", "3.1 GB fp16", "Apache-2.0", "Heavy"),
 "swift-en": ("Oriserve Whisper-Hindi2Hinglish-Swift (forced en)", "73M", "0.29 GB fp16", "Apache-2.0", "Yes, tiny"),
 "swift-auto": ("Oriserve Whisper-Hindi2Hinglish-Swift (auto)", "73M", "0.29 GB fp16", "Apache-2.0", "Yes, tiny"),
 "qwen06-auto": ("Qwen3-ASR-0.6B (auto lang)", "0.94B (0.6B LLM + audio enc)", "1.9 GB bf16", "Apache-2.0", "Feasible (GPU)"),
 "qwen06-en": ("Qwen3-ASR-0.6B (forced English)", "0.94B", "1.9 GB bf16", "Apache-2.0", "Feasible (GPU)"),
 "qwen17-auto": ("Qwen3-ASR-1.7B (auto lang)", "2.35B (1.7B LLM + audio enc)", "4.7 GB bf16", "Apache-2.0", "Heavy but feasible on 48 GB"),
 "qwen17-en": ("Qwen3-ASR-1.7B (forced English)", "2.35B", "4.7 GB bf16", "Apache-2.0", "same"),
}
def load(path):
    return [json.loads(l) for l in open(path) if l.strip()]
results = {}; hyps_out = {}
runs = sorted({os.path.basename(p).split(".")[0] for p in glob.glob(f"{B}/hyp/*.*.jsonl") if "timing" not in p})
for run in runs:
    results[run] = {}; deva_frac = {}
    for s in SETS:
        p = f"{B}/hyp/{run}.{s}.jsonl"
        if not os.path.exists(p): continue
        rows = load(p)
        raw_rows, rom_rows, outl = [], [], []
        nd = 0
        for r in rows:
            h = r.get("hypothesis_raw", r.get("hypothesis", "")) or ""
            has = bool(DEVA.search(h)); nd += has
            hr = romanize_v2(h, style="eval") if has else h
            base = {"id": r["id"], "cat": r["cat"], "reference": r["reference"]}
            raw_rows.append({**base, "hypothesis": h}); rom_rows.append({**base, "hypothesis": hr})
            outl.append({**r, "hypothesis_raw": h, "hypothesis_roman": hr})
        mr, _ = twer(raw_rows); mm, _ = twer(rom_rows)
        key = "ALL"
        wer_field = "raw_wer" if s in EN else "twer"
        results[run][s] = {"wer_raw_script": mr[key][wer_field], "cer_raw_script": mr[key]["cer"],
                           "wer": mm[key][wer_field], "cer": mm[key]["cer"], "raw_wer_strict": mm[key]["raw_wer"],
                           "n": len(rows), "words": mm[key]["words"], "deva_clips": nd}
        hyps_out[(run, s)] = outl
    # write per-model combined jsonl
    with open(f"{B}/hyp_all/{run}.jsonl", "w") if os.path.isdir(f"{B}/hyp_all") else open(os.devnull, "w") as f:
        for s in SETS:
            for o in hyps_out.get((run, s), []): f.write(json.dumps({"set": s, **o}, ensure_ascii=False) + "\n")
# timing
timing = collections.defaultdict(dict)
for l in open(f"{B}/hyp/timing.jsonl") if os.path.exists(f"{B}/hyp/timing.jsonl") else []:
    t = json.loads(l); timing[f"{t['model']}-{t['mode']}"][t["set"]] = t
phon = {}
for s in SETS:
    p = f"{B}/hyp/phonon2-shipped.{s}.jsonl"
    if os.path.exists(p):
        rows = load(p)
        aud = sum(sf.info(r["audio"]).duration for r in rows); dec = sum(r["decode_ms"] for r in rows) / 1000
        phon[s] = {"audio_s": round(aud, 1), "decode_s": round(dec, 2)}
for s, v in phon.items(): timing["phonon2-shipped"][s] = v
def rtfx(run):
    t = timing.get(run, {})
    a = sum(v["audio_s"] for v in t.values()); d = sum(v["decode_s"] for v in t.values())
    return a / d if d else None
probe = json.load(open(f"{B}/rtf_probe.json")) if os.path.exists(f"{B}/rtf_probe.json") else {}
out = {"results": results, "timing": timing, "rtf_probe_batch1": probe, "meta": {k: list(v) for k, v in META.items()}}
json.dump(out, open(f"{B}/results.json", "w"), indent=1, ensure_ascii=False)
def f(x): return "-" if x is None else f"{x:.1f}"
order = [r for r in ["phonon2-shipped", "parakeet-auto", "w3-auto", "w3-en", "w3turbo-auto", "w3turbo-en", "qwen06-auto", "qwen06-en", "qwen17-auto", "qwen17-en", "swift-auto", "swift-en", "prime-auto", "prime-en"] if r in results]
L = []
for title, fld, cfld in (("WER % (English sets: raw-token WER; Hinglish sets: T-WER) - Devanagari output romanized with romanize_v2", "wer", "cer"),):
    hdr = "| model | " + " | ".join(SETS) + " | EN avg | HI avg |"
    L += [f"### {title}", "", hdr, "|" + "---|" * (len(SETS) + 3)]
    for r in order:
        v = results[r]
        vals = [v.get(s, {}).get("wer") for s in SETS]
        ea = sum(x for x in vals[:4] if x is not None) / 4 if all(x is not None for x in vals[:4]) else None
        ha = sum(x for x in vals[4:] if x is not None) / 3 if all(x is not None for x in vals[4:]) else None
        L.append(f"| {META.get(r, (r,))[0]} | " + " | ".join(f(x) for x in vals) + f" | {f(ea)} | {f(ha)} |")
    L += ["", "### CER % (same text as above)", "", hdr, "|" + "---|" * (len(SETS) + 3)]
    for r in order:
        v = results[r]
        vals = [v.get(s, {}).get("cer") for s in SETS]
        ea = sum(x for x in vals[:4] if x is not None) / 4 if all(x is not None for x in vals[:4]) else None
        ha = sum(x for x in vals[4:] if x is not None) / 3 if all(x is not None for x in vals[4:]) else None
        L.append(f"| {META.get(r, (r,))[0]} | " + " | ".join(f(x) for x in vals) + f" | {f(ea)} | {f(ha)} |")
    L += ["", "### WER % on the as-emitted text (before romanization; shows the Devanagari penalty) - only rows where it differs", "", hdr, "|" + "---|" * (len(SETS) + 3)]
    for r in order:
        v = results[r]
        if not any(v.get(s, {}).get("deva_clips") for s in SETS): continue
        vals = [v.get(s, {}).get("wer_raw_script") for s in SETS]
        L.append(f"| {META.get(r, (r,))[0]} | " + " | ".join(f(x) for x in vals) + " | | |")
    L += ["", "Clips whose output contained Devanagari (of 150): " + "; ".join(f"{META.get(r,(r,))[0]}: " + ",".join(f"{s.split('-')[0]}={results[r][s]['deva_clips']}" for s in SETS if s in results[r] and results[r][s]['deva_clips']) for r in order if any(results[r].get(s, {}).get('deva_clips') for s in SETS)), ""]
L += ["### Size / license / speed", "", "| model | params | disk | license | on-device Mac? | throughput x realtime (this Mac, all 7 sets) | batch-1 x realtime (probe) |", "|---|---|---|---|---|---|---|"]
for r in order:
    m = META.get(r)
    if not m: continue
    rt = rtfx(r); pr = probe.get(r)
    L.append(f"| {m[0]} | {m[1]} | {m[2] or 'see resources/Phonon'} | {m[3]} | {m[4]} | {f(rt)} | {f(pr)} |")
L += ["", "### Per-set decode speed (x realtime = audio s / decode s)", "", "| model | " + " | ".join(SETS) + " |", "|" + "---|" * (len(SETS) + 1)]
for r in order:
    t = timing.get(r, {})
    L.append(f"| {META.get(r,(r,))[0]} | " + " | ".join(f(t[s]["audio_s"] / t[s]["decode_s"]) if s in t else "-" for s in SETS) + " |")
open(f"{B}/results_tables.md", "w").write("\n".join(L) + "\n")
print("\n".join(L))
