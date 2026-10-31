#!/usr/bin/env python3
"""ONE-TIME builder (v2) for the locked evaluation sets, re-targeted to English-first Indian professionals who sometimes mix Roman Hindi and use workplace vocabulary.
CPU only, stdlib:      python3 build_sets_v2.py --out <dir>        (data root $UIUI_ML_ROOT, seed 20261027; AR_DATA_ROOT overrides)
Never rerun after the sets are locked (lock.py hashes them; the runner refuses to start on a mismatch).  Before locking it may be re-run any time (e.g. when the
nptel2020 dev split or the workplace TTS eval set appears: both are picked up automatically if present).

Outputs in --out:  dev-sel.jsonl (decisions)  dev-hold.jsonl (never used for decisions)  vibe.jsonl (~60 fixed clips, 12 per cat)  leakage_report.json (incl. allowed_train_manifests)
Row fields: id, audio, reference, cat, speaker (if known), source, seconds [, terms (work), vibe_source (vibe)].   cat in en_in | cm | work | hi | native.
  en_in   Indian English        svarah (full if present, else svarah-partial), monsoon-en-in, cvindia_full dev, NPTEL pure (human-verified gold) [+ nptel2020 dev]
  cm      English-heavy mixing  mucs_v2 dev + indicvoices_hy / indicvoices2_hy dev clips whose reference is >= 25% English words
  work    workplace dictation   synthetic TTS eval set tts/out/eval/manifest.jsonl (id, audio, reference, speaker, terms[]) -- skipped (TODO) while it does not exist
  hi      Hindi robustness      kathbath_v2 / vaani_v2 / indicvoices_hy / indicvoices2_hy dev clips with <= 10% English words
  native  native English        librispeech dev + fleurs-en
dev-sel and dev-hold use the same recipe (same per-component quotas), disjoint clips and disjoint speakers wherever speaker ids exist (NPTEL pure has none: split by clip).
Nothing that is in any train manifest is eligible: id, audio path/basename, normalised reference + duration, or (>= 4 words) normalised reference text, plus speaker overlap
with the allowed train manifests of the same source.  Exact-text duplicates are collapsed inside every source pool (one clip per sentence).
"""
import argparse, hashlib, json, os, random, sys, wave
from collections import defaultdict, Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = Path(os.environ.get("AR_DATA_ROOT") or os.environ.get("UIUI_ML_ROOT") or "workspace").resolve()
SEED = 20261027
sys.path.insert(0, str(Path(os.environ.get("AR_EVALX_DIR") or HERE / "evalx")))
import score, roman_variants  # noqa: E402   (the LOCKED scorer copy: base_tokens, ENGLISH_VOCAB, Hindi word lists)
base_tokens = score.base_tokens

M = ROOT / "data/manifests"
TARGET = {"en_in": 900, "cm": 600, "work": 400, "hi": 250, "native": 250}      # clips per split
VIBE_PER_CAT = 12
CM_MIN_EN, HI_MAX_EN = 0.25, 0.10                                             # English-word share of the reference (>= 4 reference words)
DUR = (0.8, 20.0)
# quota preferences per split; shortfalls are made up by FILL (components in that order, up to each one's availability).
QUOTA = {"en_in": [("svarah", 250), ("monsoon", 95), ("nptel_pure", 200), ("nptel2020", 100), ("cvindia_full", 255)],
         "cm": [("indicvoices", 75), ("indicvoices2", 75), ("mucs", 450)],
         "work": [("work", 400)],
         "hi": [("kathbath", 40), ("vaani", 100), ("indicvoices", 55), ("indicvoices2", 55)],      # kathbath dev has only 2 speakers: kept small
         "native": [("librispeech", 150), ("fleurs_en", 100)]}
FILL = {"en_in": ["nptel_pure", "nptel2020", "cvindia_full", "svarah"], "cm": ["mucs", "indicvoices2", "indicvoices"], "work": ["work"], "hi": ["vaani", "indicvoices", "indicvoices2", "kathbath"],
        "native": ["librispeech", "fleurs_en"]}
# dev manifest dir per source; train manifests of the same source are checked for speaker overlap
DEVDIR = {"indicvoices": "indicvoices_hy", "indicvoices2": "indicvoices2_hy", "vaani": "vaani_v2", "mucs": "mucs_v2", "kathbath": "kathbath_v2",
          "shrutilipi": "shrutilipi_full_v2", "cvindia_full": "cvindia_full", "librispeech": "librispeech"}
EXTRA_TRAIN = {"shrutilipi": ["shrutilipi", "shrutilipi_v2", "shrutilipi_full"]}
SHORT = {v: k for k, v in DEVDIR.items()}
SHORT.update({d: src for src, ds in EXTRA_TRAIN.items() for d in ds})
SHORT.update({"indicvoices_vb": "indicvoices", "indicvoices2_vb": "indicvoices2", "indicvoices": "indicvoices", "indicvoices2": "indicvoices2"})

# Hindi/Hinglish words that are ALSO in /usr/share/dict/words (a plain dictionary lookup would call them English): never counted as English.
HINDI_COLLISIONS = set("""aa ab ant ba bah baal bane bani beech bees bi bola bole das di din divas em es evan hal hare hod hon jan jodi jut kara kama kendra lade le len li lo log logon loge
loot lu ma maine mar mara marne mel mil milne mo nam pa paar pad pal pare pars pita pol pun rang ru saki sate si sake tat tel ti tod toot tees va veer yam dun leta are or
patna yogi gupta patel jain guru devi assam nepal hindi hindu nehru indra akbar abdul ahmad abbas brahma dharma bata""".split())
HINDI_SET = set(score.CANON_KNOWN) | set(score.HINGLISH_VARIANTS) | set(score.HINGLISH_VARIANTS.values()) | roman_variants.PROTECTED | roman_variants.FUNCTION_WORDS | HINDI_COLLISIONS


def jl(p):
    return [json.loads(l) for l in open(p, encoding="utf-8") if l.strip()]


def ntext(t):
    return " ".join(base_tokens(t))


def wav_secs(p):
    try:
        with wave.open(p) as w: return w.getnframes() / w.getframerate()
    except Exception: return None


def is_english_word(t):
    ev = score.ENGLISH_VOCAB
    return ev is not None and t.isascii() and t.isalpha() and len(t) >= 3 and t in ev and t not in HINDI_SET


def en_share(ref):
    toks = base_tokens(ref)
    return (sum(is_english_word(t) for t in toks) / len(toks), len(toks)) if toks else (0.0, 0)


def rr_sample(rows, n, rng):
    """round-robin over speakers (shuffled), random clip from each in turn: spreads speakers instead of letting one dominate."""
    by = defaultdict(list)
    for r in rows: by[r.get("speaker") or r["id"]].append(r)
    for v in by.values(): rng.shuffle(v)
    spk = sorted(by); rng.shuffle(spk)
    out = []
    while len(out) < n and any(by.values()):
        for s in spk:
            if by[s] and len(out) < n: out.append(by[s].pop())
    return out


def split_speakers(rows):
    """balanced two-way split by speaker (greedy, largest speaker first): (side_a, side_b), no speaker on both sides; clips without a speaker count as their own speaker."""
    by = defaultdict(list)
    for r in rows: by[r.get("speaker") or r["id"]].append(r)
    a, b = [], []
    for s in sorted(by, key=lambda s: (-len(by[s]), s)):
        (a if len(a) <= len(b) else b).extend(by[s])
    return a, b


def allocate(prefs, caps, total, fill):
    """per-split quota per component: its preference (capped by availability), then the shortfall to `total` handed to the `fill` components in order up to each cap."""
    q = {n: min(p, caps.get(n, 0)) for n, p in prefs}
    left = total - sum(q.values())
    for n in fill:
        if n not in q: continue
        add = min(left, caps.get(n, 0) - q[n])
        if add > 0: q[n] += add; left -= add
    return q


class TrainIndex:
    """everything an experiment could train on: ids, audio paths/basenames, (text, duration), text, and per-source speakers of the ALLOWED manifests."""
    def __init__(self, nptel_root):
        self.ids, self.audio, self.base, self.textdur, self.text = set(), set(), set(), set(), set()
        self.spk = defaultdict(set); self.nptel_root = nptel_root; self.rows = 0

    def add(self, r, src=None):
        a = r.get("audio") or ""
        if a and not os.path.isabs(a): a = str(Path(self.nptel_root) / a)
        self.ids.add(r["id"]); self.audio.add(a); self.base.add(os.path.basename(a)); self.rows += 1
        t = ntext(r.get("reference", r.get("text", "")))
        if r.get("seconds"): self.textdur.add((t, round(float(r["seconds"]), 1)))
        if len(t.split()) >= 4: self.text.add(t)
        if src and r.get("speaker") is not None: self.spk[src].add(str(r["speaker"]))

    def finish(self): self.all_spk = set().union(*self.spk.values()) if self.spk else set()

    def why_excluded(self, r, src):
        t = ntext(r["reference"])
        if r["id"] in self.ids: return "id_in_train"
        if r["audio"] in self.audio or os.path.basename(r["audio"]) in self.base: return "audio_in_train"
        if r.get("seconds") and (t, round(float(r["seconds"]), 1)) in self.textdur: return "text_duration_in_train"
        if len(t.split()) >= 4 and t in self.text: return "text_in_train"
        s = r.get("speaker")
        if s is not None and (str(s) in self.spk.get(src, ()) or (len(str(s)) >= 6 and str(s) in self.all_spk)): return "speaker_in_train"
        return None


def load_component(name, rows_in, tix, drop_log, rng, text_key="reference"):
    """normalise rows of one source, apply duration / emptiness / leakage / duplicate filters.  Returns the eligible rows."""
    rows = []
    for r in rows_in:
        ref = r.get(text_key) or r.get("reference") or r.get("text") or ""
        row = {"id": r["id"], "audio": r["audio"], "reference": ref.strip(), "source": name, "seconds": r.get("seconds"),
               "speaker": str(r["speaker"]) if r.get("speaker") not in (None, "", "unknown") else None}
        if "terms" in r: row["terms"] = r["terms"]
        rows.append(row)
    drop, ok = Counter(), []
    for r in rows:
        if not r["seconds"]: r["seconds"] = wav_secs(r["audio"]) if os.path.exists(r["audio"]) else None
        if not (r["seconds"] and DUR[0] <= r["seconds"] <= DUR[1]): drop["duration"] += 1; continue
        if not base_tokens(r["reference"]): drop["empty_ref"] += 1; continue
        if any(c in r["reference"] for c in "[]<>{}*"): drop["markup_in_ref"] += 1; continue
        if not os.path.exists(r["audio"]): drop["missing_audio"] += 1; continue
        why = tix.why_excluded(r, name)
        if why: drop[why] += 1; continue
        ok.append(r)
    rng.shuffle(ok); out, seen = [], set()
    for r in ok:             # one clip per sentence (>= 4 words) inside a pool: no cross-speaker copies of the same text between sel and hold
        t = ntext(r["reference"])
        if len(t.split()) >= 4:
            if t in seen: drop["duplicate_text_in_pool"] += 1; continue
            seen.add(t)
        out.append(r)
    drop_log[name] = {"manifest_rows": len(rows), "eligible": len(out), "dropped": dict(drop)}
    return out


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--out", required=True)
    ap.add_argument("--require-work", action="store_true", help="fail instead of skipping the workplace component when tts/out/eval/manifest.jsonl is missing")
    ap.add_argument("--work-manifest", default=str(ROOT / "tts/out/eval/manifest.jsonl")); ap.add_argument("--work-train", default=str(ROOT / "tts/out/train/manifest.jsonl"))
    ap.add_argument("--nptel2020-dev", default=str(M / "nptel2020/dev.jsonl")); ap.add_argument("--nptel2020-train", default=str(M / "nptel2020/train.jsonl"))
    a = ap.parse_args()
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    if score.ENGLISH_VOCAB is None: sys.exit("no /usr/share/dict/words: English-share filter cannot run")
    rng = random.Random(SEED)
    nptel = ROOT / "data-nptel"
    # ---- train side ------------------------------------------------------------------------------------------------------------------
    allowed = []
    for src in ("indicvoices", "indicvoices2", "vaani", "mucs", "kathbath", "shrutilipi", "cvindia_full", "librispeech"):      # same allowed set as v1 ...
        for d in dict.fromkeys([src, DEVDIR[src]] + EXTRA_TRAIN.get(src, [])):
            allowed += [p for p in sorted((M / d).glob("train*.jsonl")) if p.is_file() and p not in allowed]
    hooks = {"nptel2020_train": Path(a.nptel2020_train), "work_synthetic_train": Path(a.work_train)}      # ... plus hooks, added once they exist
    todo = []
    for k, p in hooks.items():
        if p.is_file() and p.stat().st_size: allowed.append(p)
        else: todo.append(f"TODO: {k} ({p}) does not exist yet: not in allowed_train.json; re-run the builder (before locking) once it exists")
    train_files = sorted(set(p for p in M.glob("*/train*") if p.is_file()) | set(allowed))       # every train manifest is checked, only `allowed` ones may be trained on
    tix = TrainIndex(nptel)
    for p in train_files:
        src = SHORT.get(p.parent.name, p.parent.name) if p in allowed else None
        for r in jl(p): tix.add(r, src)
    pass_n = 0
    nptel_dev_ids = {r["id"] for r in jl(Path(a.nptel2020_dev))} if Path(a.nptel2020_dev).is_file() else set()
    for r in jl(nptel / "pass.jsonl"):                                                              # NPTEL pass set (train pool for nptel2020), relative audio paths;
        if r["id"] in nptel_dev_ids: continue                                                       # its speaker-clustered dev split is carved out of it (dev speakers are not in nptel2020/train)
        tix.add(r); pass_n += 1
    tix.finish()
    print(f"train index: {len(train_files)} manifests + nptel pass ({pass_n}), {len(tix.ids)} ids, {len(allowed)} allowed manifests", flush=True)

    # ---- pools -------------------------------------------------------------------------------------------------------------------------
    D, pools = {}, {}
    svf = ROOT / "evalsets/svarah-full/manifest.jsonl"
    sv_path = svf if svf.is_file() else ROOT / "evalsets/svarah-partial/manifest.jsonl"
    pools["svarah"] = load_component("svarah", jl(sv_path), tix, D, rng); D["svarah"]["manifest"] = str(sv_path)
    pools["monsoon"] = load_component("monsoon", jl(ROOT / "evalsets/monsoon-en-in/manifest.jsonl"), tix, D, rng)
    pools["cvindia_full"] = load_component("cvindia_full", jl(M / "cvindia_full/dev.jsonl"), tix, D, rng)
    pure = [{"id": r["id"], "audio": r["audio"], "reference": r["text"], "seconds": r.get("seconds")} for r in jl(nptel / "pure_cand.jsonl")]       # gold words (UPPERCASE; casing is irrelevant)
    pools["nptel_pure"] = load_component("nptel_pure", pure, tix, D, rng)
    n20 = Path(a.nptel2020_dev)
    if n20.is_file() and n20.stat().st_size:
        pools["nptel2020"] = load_component("nptel2020", jl(n20), tix, D, rng, text_key="text")
        have_ids = {r["id"] for r in pools["nptel_pure"]}; have_audio = {r["audio"] for r in pools["nptel_pure"]}
        pools["nptel2020"] = [r for r in pools["nptel2020"] if r["id"] not in have_ids and r["audio"] not in have_audio]      # a clip that is in both is kept once
    else:
        todo.append(f"TODO: {n20} not found: en_in uses NPTEL pure only; re-run before locking once the speaker-clustered nptel2020 dev split exists")
    for s in ("mucs", "indicvoices", "indicvoices2", "kathbath", "vaani", "librispeech"):
        pools[s] = load_component(s, jl(M / DEVDIR[s] / "dev.jsonl"), tix, D, rng)
    pools["fleurs_en"] = load_component("fleurs_en", jl(ROOT / "evalsets/fleurs-en/manifest.jsonl"), tix, D, rng)
    wm = Path(a.work_manifest)
    if wm.is_file() and wm.stat().st_size: pools["work"] = load_component("work", jl(wm), tix, D, rng)
    elif a.require_work: sys.exit(f"{wm} missing")
    else: todo.append(f"TODO: {wm} not found: cat 'work' (workplace dictation) skipped; re-run before locking once the synthetic eval set exists")
    # ---- categories ----------------------------------------------------------------------------------------------------------------------
    CAT = {"svarah": "en_in", "monsoon": "en_in", "cvindia_full": "en_in", "nptel_pure": "en_in", "nptel2020": "en_in", "work": "work", "librispeech": "native", "fleurs_en": "native", "mucs": "cm"}
    for s, rows in pools.items():
        for r in rows: r["cat"] = CAT.get(s)
    qualify = {}
    for s in ("indicvoices", "indicvoices2", "kathbath", "vaani"):
        cm_n = hi_n = mid_n = short_n = 0
        for r in pools[s]:
            sh, n = en_share(r["reference"])
            if n < 4: r["cat"] = None; short_n += 1
            elif sh >= CM_MIN_EN and s in ("indicvoices", "indicvoices2"): r["cat"] = "cm"; cm_n += 1
            elif sh <= HI_MAX_EN: r["cat"] = "hi"; hi_n += 1
            else: r["cat"] = None; mid_n += 1
        qualify[s] = {"eligible_pool": len(pools[s]), "cm_ge25pct_en": cm_n, "hi_le10pct_en": hi_n, "between_thresholds": mid_n, "under_4_words": short_n}
    raw = {}      # the raw "how many dev clips are English-heavy" answer, before any leakage / duplicate filter
    for s in ("indicvoices", "indicvoices2", "vaani", "kathbath", "mucs"):
        sh = [en_share(r.get("reference", "")) for r in jl(M / DEVDIR[s] / "dev.jsonl")]
        raw[s] = {"dev_clips": len(sh), "ge25pct_en": sum(1 for x, n in sh if n >= 4 and x >= CM_MIN_EN), "ge40pct_en": sum(1 for x, n in sh if n >= 4 and x >= 0.4),
                  "le10pct_en": sum(1 for x, n in sh if n >= 4 and x <= HI_MAX_EN)}
    for s in pools: pools[s] = [r for r in pools[s] if r["cat"]]
    # ---- vibe: carved first so it stays disjoint from sel / hold ------------------------------------------------------------------------------
    vibe = []
    for cat in ("en_in", "cm", "work", "hi", "native"):
        comps = sorted(s for s in pools if any(r["cat"] == cat for r in pools[s]))
        if not comps: continue
        per, extra = divmod(VIBE_PER_CAT, len(comps)); picked = []
        for i, s in enumerate(comps):
            cand = [r for r in pools[s] if r["cat"] == cat]
            picked += rr_sample([r for r in cand if 3 <= r["seconds"] <= 12] or cand, per + (1 if i < extra else 0), rng)
        for r in picked: r["vibe_source"] = r["source"]
        ids = {r["id"] for r in picked}
        for s in comps: pools[s] = [r for r in pools[s] if r["id"] not in ids]
        vibe += picked
    # ---- split by speaker per source, then draw the same quotas on both sides ------------------------------------------------------------------------
    sides = {s: split_speakers(rows) for s, rows in pools.items()}
    sel, hold, quotas = [], [], {}
    for cat, prefs in QUOTA.items():
        prefs = [(n, p) for n, p in prefs if n in pools]
        if not prefs: continue
        caps = {n: min(sum(r["cat"] == cat for r in sides[n][0]), sum(r["cat"] == cat for r in sides[n][1])) for n, _ in prefs}
        quotas[cat] = allocate(prefs, caps, TARGET[cat], FILL[cat])
        for n, q in quotas[cat].items():
            if q:
                sel += rr_sample([r for r in sides[n][0] if r["cat"] == cat], q, rng); hold += rr_sample([r for r in sides[n][1] if r["cat"] == cat], q, rng)
    ids = [r["id"] for r in sel + hold + vibe]; assert len(ids) == len(set(ids)), "sets overlap by id"
    assert len({r["audio"] for r in sel + hold + vibe}) == len(ids), "sets overlap by audio"

    def dump(name, rows):
        with open(out / name, "w", encoding="utf-8") as f:
            for r in sorted(rows, key=lambda r: r["id"]): f.write(json.dumps({k: v for k, v in r.items() if v is not None}, ensure_ascii=False) + "\n")
    dump("dev-sel.jsonl", sel); dump("dev-hold.jsonl", hold); dump("vibe.jsonl", vibe)

    # ---- report ------------------------------------------------------------------------------------------------------------------------------------
    def comp(rows):
        c = defaultdict(lambda: {"clips": 0, "words": 0, "hours": 0.0, "speakers": set()})
        for r in rows:
            for k in (r["source"], "cat:" + r["cat"], "ALL"):
                c[k]["clips"] += 1; c[k]["words"] += len(base_tokens(r["reference"])); c[k]["hours"] += (r.get("seconds") or 0) / 3600
                c[k]["speakers"].add(r.get("speaker") or ("clip:" + r["id"]))
        return {k: {**v, "hours": round(v["hours"], 3), "speakers": len(v["speakers"]), "speakers_known": sum(1 for x in v["speakers"] if not x.startswith("clip:"))} for k, v in sorted(c.items())}

    def leak(rows):
        nt = lambda r: ntext(r["reference"])
        return {"clips": len(rows), "id_in_any_train": sum(r["id"] in tix.ids for r in rows),
                "audio_path_or_basename_in_any_train": sum(r["audio"] in tix.audio or os.path.basename(r["audio"]) in tix.base for r in rows),
                "text_plus_duration_in_any_train": sum((nt(r), round(float(r["seconds"]), 1)) in tix.textdur for r in rows),
                "text_ge4_words_in_any_train": sum(len(nt(r).split()) >= 4 and nt(r) in tix.text for r in rows),
                "speaker_in_allowed_train_same_source": sum(r.get("speaker") is not None and str(r["speaker"]) in tix.spk.get(r["source"], set()) for r in rows)}
    k = lambda rows, f: {f(r) for r in rows}
    spk = lambda rows: {(r["source"], r["speaker"]) for r in rows if r.get("speaker")}
    t4 = lambda rows: {ntext(r["reference"]) for r in rows if len(ntext(r["reference"]).split()) >= 4}
    rep = {"seed": SEED, "targets_per_split": TARGET, "quotas_per_split": quotas, "components_present": sorted(pools), "todo": todo, "svarah_source": str(sv_path),
           "english_share_thresholds": {"cm_min": CM_MIN_EN, "hi_max": HI_MAX_EN}, "english_heavy_counts_raw_dev": raw, "english_share_after_filters": qualify,
           "allowed_train_manifests": [str(p) for p in allowed], "train_manifests_checked": [str(p) for p in train_files] + [str(nptel / "pass.jsonl")],
           "dev_manifest_sha256": {s: hashlib.sha256((M / DEVDIR[s] / "dev.jsonl").read_bytes()).hexdigest() for s in ("indicvoices", "indicvoices2", "vaani", "mucs", "kathbath", "librispeech", "cvindia_full")},
           "pools": D, "composition": {"dev-sel": comp(sel), "dev-hold": comp(hold), "vibe": comp(vibe)},
           "leakage": {"dev-sel": leak(sel), "dev-hold": leak(hold), "vibe": leak(vibe)},
           "disjoint": {"sel_hold_ids": len(k(sel, lambda r: r["id"]) & k(hold, lambda r: r["id"])), "sel_hold_audio": len(k(sel, lambda r: r["audio"]) & k(hold, lambda r: r["audio"])),
                        "sel_hold_text_ge4_words": len(t4(sel) & t4(hold)), "sel_hold_shared_speakers": len(spk(sel) & spk(hold)),
                        "vibe_vs_sel_hold_ids": len(k(vibe, lambda r: r["id"]) & k(sel + hold, lambda r: r["id"])),
                        "vibe_vs_sel_hold_shared_speakers (info only)": len(spk(vibe) & (spk(sel) | spk(hold)))}}
    (out / "leakage_report.json").write_text(json.dumps(rep, indent=1, ensure_ascii=False))
    print(json.dumps({k_: rep[k_] for k_ in ("quotas_per_split", "english_heavy_counts_raw_dev", "english_share_after_filters", "leakage", "disjoint", "todo")}, indent=1, ensure_ascii=False))
    for n in ("dev-sel", "dev-hold", "vibe"):
        print(n, {c: v for c, v in rep["composition"][n].items() if c.startswith("cat:") or c == "ALL"})


if __name__ == "__main__":
    main()
