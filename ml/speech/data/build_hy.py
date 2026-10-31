#!/usr/bin/env python3
"""Hybrid IndicVoices manifests (_hy): STANDARDIZED Devanagari, with verbatim substituted only for whitelisted real spoken-form choices.
  python build_hy.py [--procs 5]   -> data/manifests/{indicvoices,indicvoices2}_hy/{train,dev}.jsonl + summary_hy.json, dev-mix_hy.jsonl
Needs $UIUI_ML_ROOT/eval-dev/vb_<src>.jsonl (see build_v2.py) and romanize_v2.py (this directory)."""
import collections, json, multiprocessing as mp, os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from uiui_root import ROOT, SPEECH
M = f"{ROOT}/data/manifests"
sys.path.insert(0, f"{SPEECH}/eval/evalx")
import romanize_v2 as r2  # noqa: E402
from fair_wer import align  # noqa: E402

TAG = re.compile(r"<[^>]*>|\[[^\]]*\]|\{[^}]*\}|#{2,}|\*+")
# (standardized token, verbatim token) pairs where the verbatim token is a real spoken-form / grammatical choice. Exact token match on both sides.
WHITELIST = {("पर", "पे"), ("कर", "के"), ("लेकर", "लेके"), ("हैं", "है"), ("है", "हैं"), ("कि", "की"), ("की", "कि"), ("नहीं", "ना")}
# NOT taken (annotator spelling noise / truncations): हे ए->है, नई नइ नही->नहीं, औ ओर->और, त->तो, बी वी->भी, बहोत बोहोत->बहुत, रा रए->रहा/रहे, ...
MAX_UNMATCHED = 0.30


def clean(s):
    return re.sub(r"\s+", " ", TAG.sub(" ", s)).strip()


def hybrid(std, vb):
    a, b = clean(std).split(), clean(vb).split()
    if not a:
        return " ".join(a), [], True
    ops = align(a, b)
    if sum(o != "ok" for o, _, _ in ops) > MAX_UNMATCHED * len(a):
        return " ".join(a), [], False
    out, rep, i = [], [], 0
    for o, x, y in ops:
        if o == "ok":
            out.append(x)
        elif o == "sub":
            if (x, y) in WHITELIST and not (x == "कर" and i == 0):   # कर->के only as a conjunctive participle (after a verb stem)
                out.append(y); rep.append(f"{x}>{y}")
            else:
                out.append(x)
        elif o == "del":
            out.append(x)
        if o != "ins":
            i += 1
    return " ".join(out), rep, True


def work(args):
    row, vb = args
    hy, rep, aligned = hybrid(row["reference_raw"], vb["verbatim"])
    new = r2.romanize_v2(hy)
    out = dict(row)
    out["reference_raw_std"] = row["reference_raw"]; out["reference_raw_vb"] = clean(vb["verbatim"]); out["reference_raw"] = hy
    out["has_unintelligible"] = "<unintelligible>" in vb["verbatim"]
    out["hy_replacements"] = len(rep)
    if new != row["reference"]:
        out["reference_v1"] = row["reference"]
    out["reference"] = new
    return out, rep, aligned, new != row["reference"]


def main(procs):
    summ = {}
    for src in ("indicvoices", "indicvoices2"):
        vbm = {json.loads(l)["id"]: json.loads(l) for l in open(f"{ROOT}/eval-dev/vb_{src}.jsonl")}
        os.makedirs(f"{M}/{src}_hy", exist_ok=True)
        for fn in ("train.jsonl", "dev.jsonl"):
            rows = [json.loads(l) for l in open(f"{M}/{src}/{fn}")]
            with mp.Pool(procs) as p:
                res = p.map(work, [(r, vbm[r["id"]]) for r in rows], chunksize=500)
            pairs = collections.Counter(); ch = nrep = skipped = 0; kept = []
            for out, rep, aligned, c in res:
                if not out["reference"].strip():
                    continue
                kept.append(out); pairs.update(rep); ch += c; nrep += bool(rep); skipped += not aligned
            with open(f"{M}/{src}_hy/{fn}", "w") as f:
                for r in kept: f.write(json.dumps(r, ensure_ascii=False) + "\n")
            n = len(kept)
            summ[f"{src}/{fn}"] = dict(rows=n, dropped=len(rows) - n, changed_vs_v1=ch, changed_pct=round(100 * ch / n, 2), rows_with_replacement=nrep,
                                       poor_alignment_kept_std=skipped, pair_counts=dict(pairs.most_common()))
            print(src, fn, {k: v for k, v in summ[f"{src}/{fn}"].items() if k != "pair_counts"}, dict(pairs.most_common()), flush=True)
    json.dump(summ, open(f"{M}/indicvoices_hy/summary_hy.json", "w"), indent=1, ensure_ascii=False)
    # dev-mix_hy
    vb = {json.loads(l)["id"]: json.loads(l) for l in open(f"{ROOT}/eval-dev/vb_indicvoices.jsonl")}
    base = {}
    for s in ("indicvoices", "kathbath", "mucs"):
        for l in open(f"{M}/{s}/dev.jsonl"):
            r = json.loads(l); base[(s, r["id"])] = r
    n = ch = 0
    with open(f"{M}/dev-mix_hy.jsonl", "w") as f:
        for l in open(f"{M}/dev-mix.jsonl"):
            r = json.loads(l)
            if r["source"] in ("indicvoices", "kathbath", "mucs"):
                bid = r["id"].split("-", 1)[1] if r["id"].startswith(r["source"] + "-") else r["id"]
                b = base[(r["source"], bid)]
                raw = b["reference_raw"]
                if r["source"] == "indicvoices":
                    raw = hybrid(raw, vb[bid]["verbatim"])[0]
                new = r2.romanize_v2(raw); n += 1
                if new != r["reference"]: r["reference_v1"] = r["reference"]; ch += 1
                r["reference"] = new
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print("dev-mix_hy re-romanized", n, "changed", ch)


if __name__ == "__main__":
    main(int(sys.argv[sys.argv.index("--procs") + 1]) if "--procs" in sys.argv else 5)
