#!/usr/bin/env python3
"""Build the v2 / vb manifests with romanize_v2. Never modifies an existing manifest; writes only new dirs/files.
  python build_v2.py vb|v2|evalsets|devmix|all   [--procs 6]
(needs the audio-less manifests + the extracted verbatim text $UIUI_ML_ROOT/eval-dev/vb_<src>.jsonl)."""
import collections, json, multiprocessing as mp, os, re, sys, unicodedata
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from uiui_root import ROOT, SPEECH
M = f"{ROOT}/data/manifests"
sys.path.insert(0, f"{SPEECH}/eval/evalx")
import romanize_v2 as r2, romlib, vaani_clean as vc  # noqa: E402
from fair_wer import align  # noqa: E402

FW = set("hai hain ke ka ki ko par pe se mein main men me ne na nahi nahin kar kare tha thi the the hoon ho hua hui hue raha rahi rahe wala wali wale "
         "aur ya jo kya toh to bhi hi yeh ye woh wo is us un in ek tak liye gaya gayi gaye hum tum aap mujhe tab jab ab".split())
TAG = re.compile(r"<[^>]*>|\[[^\]]*\]|\{[^}]*\}|#{2,}|\*+")


def clean_vb(v):
    t = TAG.sub(" ", v)
    return re.sub(r"\s+", " ", t).strip()


def work(args):
    kind, row, extra = args
    old = row["reference"]
    raw = row["reference_raw"]
    out = dict(row)
    if kind == "vb":
        v = extra["verbatim"]
        out["has_unintelligible"] = "<unintelligible>" in v
        out["reference_raw_std"] = raw
        cv = clean_vb(v)
        out["reference_raw"] = cv
        new = r2.romanize_v2(cv)
        std_v2 = r2.romanize_v2(raw)
        legacy = romlib.roman(raw)
        tags = TAG.findall(v)
    elif kind == "vaani":
        t, why, _ = vc.clean(raw)
        new = r2.romanize_v2(t) if t is not None else old
        std_v2 = new
        legacy = romlib.roman(t) if t is not None else old
        tags = []
    elif kind == "vaani_eval":
        t, why, _ = vc.clean(raw)
        new = r2.romanize_v2(t, "eval") if t is not None else old
        std_v2 = new
        legacy = romlib.roman(t, "eval") if t is not None else old
        tags = []
    elif kind == "evalset":
        new = r2.romanize_v2(raw, "eval"); std_v2 = new; legacy = romlib.roman(raw, "eval"); tags = []
    else:
        new = r2.romanize_v2(raw); std_v2 = new; legacy = romlib.roman(raw); tags = []
    if new != old:
        out["reference_v1"] = old
    out["reference"] = new
    return out, dict(changed=new != old, v2only=std_v2 != old, repro=legacy == old, tags=tags, old=old, new=new)


def fwchanges(pairs):
    c = collections.Counter()
    for old, new in pairs:
        a, b = old.lower().split(), new.lower().split()
        if a == b:
            continue
        for op, x, y in align(a, b):
            if op == "sub" and (x in FW or y in FW):
                c[f"{x}>{y}"] += 1
            elif op in ("del", "ins") and (x or y) in FW:
                c[(f"{x}>-" if op == "del" else f"->{y}")] += 1
    return c


def run(kind, src, dst, procs, vbmap=None, files=("train.jsonl", "dev.jsonl")):
    os.makedirs(f"{M}/{dst}", exist_ok=True)
    summ = {}
    for fn in files:
        p = f"{M}/{src}/{fn}"
        if not os.path.exists(p):
            continue
        rows = [json.loads(l) for l in open(p) if l.strip()]
        jobs = [(kind, r, {"verbatim": vbmap[r["id"]]["verbatim"]} if vbmap else {}) for r in rows]
        with mp.Pool(procs) as pool:
            res = pool.map(work, jobs, chunksize=500)
        kept, drop, tags = [], collections.Counter(), collections.Counter()
        pairs, ch, v2only, repro = [], 0, 0, 0
        for out, st in res:
            for t in st["tags"]: tags[t] += 1
            if not out["reference"].strip() or (re.search(r"[^\x00-\x7f]", out["reference"]) and not re.search(r"[^\x00-\x7f]", st["old"])):
                drop["empty_or_non_ascii"] += 1; continue
            kept.append(out); ch += st["changed"]; v2only += st["v2only"]; repro += st["repro"]
            if st["changed"]: pairs.append((st["old"], st["new"]))
        with open(f"{M}/{dst}/{fn}", "w") as f:
            for r in kept: f.write(json.dumps(r, ensure_ascii=False) + "\n")
        n = max(len(kept), 1)
        summ[fn] = dict(rows_in=len(rows), rows_out=len(kept), dropped=dict(drop), changed_rows=ch, changed_pct=round(100 * ch / n, 2),
                        changed_by_romanizer_only_pct=round(100 * v2only / n, 2), v1_reproduced_pct=round(100 * repro / n, 2),
                        top_function_word_changes=fwchanges(pairs).most_common(25), tags_stripped=tags.most_common(15),
                        unintelligible_rows=sum(1 for r, _ in res if r.get("has_unintelligible")))
        print(dst, fn, json.dumps({k: v for k, v in summ[fn].items() if k not in ("top_function_word_changes", "tags_stripped")}), flush=True)
    json.dump(summ, open(f"{M}/{dst}/summary_v2.json", "w"), indent=1, ensure_ascii=False)


def load_vb(src):
    return {json.loads(l)["id"]: json.loads(l) for l in open(f"{ROOT}/eval-dev/vb_{src}.jsonl")}


def devmix(procs):
    rows = [json.loads(l) for l in open(f"{M}/dev-mix.jsonl")]
    base = {}
    for s in ("indicvoices", "kathbath", "mucs"):
        for l in open(f"{M}/{s}/dev.jsonl"):
            r = json.loads(l); base[(s, r["id"])] = r
    vb = load_vb("indicvoices")
    for variant in ("v2", "vb"):
        out, ch, cnt = [], 0, 0
        for r in rows:
            r = dict(r)
            if r["source"] in ("indicvoices", "kathbath", "mucs"):
                bid = r["id"].split("-", 1)[1] if r["id"].startswith(r["source"] + "-") else r["id"]
                b = base.get((r["source"], bid)) or base.get((r["source"], r["id"]))
                raw = b["reference_raw"]
                if variant == "vb" and r["source"] == "indicvoices":
                    raw = clean_vb(vb[bid]["verbatim"])
                new = r2.romanize_v2(raw)
                cnt += 1
                if new != r["reference"]:
                    r["reference_v1"] = r["reference"]; ch += 1
                r["reference"] = new
            out.append(r)
        fn = f"{M}/dev-mix_{variant}.jsonl"
        with open(fn, "w") as f:
            for r in out: f.write(json.dumps(r, ensure_ascii=False) + "\n")
        print("dev-mix", variant, "rows", len(out), "re-romanized", cnt, "changed", ch)


def evalsets(procs):
    d = f"{ROOT}/data/evalsets-lexicon-v2"
    for s in ("hiacc", "mucs-hien-test", "fleurs-hi"):
        os.makedirs(f"{d}/{s}", exist_ok=True)
        rows = [json.loads(l) for l in open(f"{ROOT}/data/evalsets-lexicon/{s}/manifest.jsonl")]
        n = ch = 0
        with open(f"{d}/{s}/manifest.jsonl", "w") as f:
            for r in rows:
                out, st = work(("evalset", r, {})) if r.get("reference_raw") else (dict(r), dict(changed=False))
                n += 1; ch += st["changed"]
                f.write(json.dumps(out, ensure_ascii=False) + "\n")
        print("evalset", s, n, "changed", ch, f"{100*ch/n:.1f}%")


if __name__ == "__main__":
    what, procs = sys.argv[1], 6
    if "--procs" in sys.argv: procs = int(sys.argv[sys.argv.index("--procs") + 1])
    if what in ("vb", "all"):
        for s in ("indicvoices", "indicvoices2"):
            run("vb", s, f"{s}_vb", procs, vbmap=load_vb(s))
    if what in ("v2", "all"):
        for s in ("mucs", "kathbath", "shrutilipi"):
            run("plain", s, f"{s}_v2", procs)
        run("vaani", "vaani", "vaani_v2", procs)
        run("vaani_eval", "vaani", "vaani_v2", procs, files=("test_eval.jsonl",))
    if what in ("full", "all"):
        run("plain", "shrutilipi_full", "shrutilipi_full_v2", procs)
    if what in ("devmix", "all"): devmix(procs)
    if what in ("evalsets", "all"): evalsets(procs)
