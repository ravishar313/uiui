"""Stage rows -> data/manifests/<source>/{train,dev}.jsonl  (romanize via lexicon, eval-exclusion, speaker-disjoint 2% dev).
  python finalize.py <source> [<source> ...]"""
import glob, json, os, re, sys, collections
sys.path.insert(0, os.path.dirname(__file__))
from common import DATA, spk_is_dev
import romlib

EV = DATA.parent / "evalsets"
HINGLISH = {"indicvoices", "kathbath", "shrutilipi", "mucs", "vaani"}
ENGLISH = {"librispeech", "cvindia", "nptel"}


def nk(t):
    return " ".join(re.sub(r"[^\w' ]+", " ", t.lower()).split())


def eval_keys():
    ids, spk, texts = set(), set(), set()
    for m in glob.glob(str(EV / "*/manifest.jsonl")):
        for l in open(m):
            r = json.loads(l)
            ids.add(r["id"]); texts.add(nk(r["reference"]))
            if r.get("speaker") and r["speaker"] != "unknown":
                spk.add(str(r["speaker"]))
    for m in glob.glob(str(EV / "*/source_references.jsonl")):
        for l in open(m):
            texts.add(nk(json.loads(l).get("source", "")))
    p = DATA / "stage/mucs/mucs_test_texts.json"
    if p.exists():
        texts |= {nk(t) for t in json.load(open(p))}
    texts.discard("")
    return ids, spk, texts


def build(source, ekeys):
    ids, spk, texts = ekeys
    sd = DATA / "stage" / source
    rows = [json.loads(l) for l in open(sd / "rows.jsonl")]
    eng = {}
    if source in ENGLISH:
        for l in open(sd / "english.jsonl"):
            r = json.loads(l); eng[r["id"]] = r
    maxwer = {"cvindia": 0.5}.get(source, 0.15)
    out = {"train": [], "dev": []}
    drop = collections.Counter()
    seen = set()
    for r in rows:
        if r["id"] in seen:
            drop["duplicate_id"] += 1; continue
        seen.add(r["id"])
        if r["id"] in ids or r["speaker"] in spk:
            drop["eval_id_or_speaker"] += 1; continue
        raw = r["text"].strip()
        if source in HINGLISH:
            ref = romlib.roman(raw)
            lang = "hinglish"
            if not re.search(r"[A-Za-z0-9]", ref):
                drop["empty"] += 1; continue
            if len(ref.split()) < 1:
                drop["empty"] += 1; continue
            if re.search(r"[ऀ-ॿ]", ref):
                drop["residual_devanagari"] += 1; continue
        else:
            e = eng.get(r["id"])
            if e is None or e["wer"] >= maxwer or not e["reference"]:
                drop["phonon_disagrees"] += 1; continue
            ref, lang = e["reference"], "en"
        if nk(raw) in texts or nk(ref) in texts:
            drop["eval_text"] += 1; continue
        row = dict(id=r["id"], audio=r["audio"], reference=ref, reference_raw=raw, speaker=r["speaker"], source=source,
                   lang=lang, seconds=r["seconds"])
        if source in ENGLISH and source in ("nptel", "cvindia"):
            row["phonon_wer"] = eng[r["id"]]["wer"]
        out["train"].append(row)
    # speaker-disjoint 2% dev: take speakers in hash order until >= 2% of rows
    import hashlib
    bysp = collections.defaultdict(list)
    for r in out["train"]:
        bysp[r["speaker"]].append(r)
    order = sorted(bysp, key=lambda s: hashlib.md5(f"{source}|{s}".encode()).hexdigest())
    total, n, dev = len(out["train"]), 0, []
    for s_ in order:
        if n >= 0.02 * total:
            break
        if len(bysp[s_]) > 0.05 * total and n > 0:
            continue
        dev += bysp[s_]; n += len(bysp[s_])
    devids = {r["id"] for r in dev}
    out = {"train": [r for r in out["train"] if r["id"] not in devids], "dev": dev}
    md = DATA / "manifests" / source
    md.mkdir(parents=True, exist_ok=True)
    summ = {}
    for sp, rs in out.items():
        with open(md / f"{sp}.jsonl", "w") as f:
            for r in rs:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
        summ[sp] = dict(rows=len(rs), hours=round(sum(r["seconds"] for r in rs) / 3600, 2), speakers=len({r["speaker"] for r in rs}))
    summ["dropped"] = dict(drop)
    json.dump(summ, open(md / "summary.json", "w"), indent=1)
    print(source, summ)


if __name__ == "__main__":
    ek = eval_keys()
    for s in sys.argv[1:]:
        build(s, ek)
