"""English sources: run shipped Phonon over the staged clips; keep clips where Phonon agrees with the gold text
(WER < threshold) and write the reference as GOLD WORDS in Phonon's cased/punctuated surface style.
  python english_relabel.py <source> [--wer 0.15]
Output: data/stage/<source>/english.jsonl  (id, wer, reference, hyp, gold)"""
import argparse, difflib, json, re, subprocess, sys, os
sys.path.insert(0, os.path.dirname(__file__)); sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "eval", "evalx"))
from common import DATA, Run
import score

PHONON = os.environ.get("PHONON_EVAL_BIN") or str(DATA.parent / "phonon-eval/.build/release/phonon-eval")
BUNDLE = os.environ.get("PHONON_BUNDLE") or str(DATA.parent / "models/Phonon")
NUM = score.NUMBER_WORDS


def key(w):
    t = score.base_tokens(w)
    return "".join(NUM.get(x, x) for x in t)


def fix_surface(w):
    core = re.sub(r"[^A-Za-z]", "", w)
    if len(core) > 4 and core.isupper():
        w = w.lower()
    return w


def merge(gold, hyp):
    hs = [(fix_surface(w), key(w)) for w in hyp.split()]
    hs = [(s, k) for s, k in hs if k]
    gw = [(w, key(w)) for w in gold.split()]
    gw = [(w, k) for w, k in gw if k]
    sm = difflib.SequenceMatcher(None, [k for _, k in hs], [k for _, k in gw], autojunk=False)
    out = []
    P = ".,?!;:"
    for op, a0, a1, b0, b1 in sm.get_opcodes():
        if op == "equal":
            out += [s for s, _ in hs[a0:a1]]
        elif op in ("replace", "insert"):
            seg = [re.sub(r"[^\w']", "", w).lower() if not w.isupper() or len(w) <= 4 else w.lower() for w, _ in gw[b0:b1]]
            seg = [re.sub(r"[^\w']", "", w.lower()) for w, _ in gw[b0:b1]]
            if op == "replace" and hs[a1 - 1][0][-1] in P:
                seg[-1] += hs[a1 - 1][0][-1]
            out += seg
        elif op == "delete":
            if out and hs[a1 - 1][0][-1] in P and out[-1][-1] not in P:
                out[-1] += hs[a1 - 1][0][-1]
    if not out:
        return ""
    r = " ".join(out)
    r = re.sub(r"[,;:]$", ".", r)
    r = re.sub(r"\bi\b", "I", r)
    return r[0].upper() + r[1:]


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("source"); ap.add_argument("--wer", type=float, default=0.15)
    ap.add_argument("--use-gold-as-is", action="store_true", help="keep gold text verbatim (already cased/punctuated)")
    a = ap.parse_args()
    sd = DATA / "stage" / a.source
    rows = [json.loads(l) for l in open(sd / "rows.jsonl")]
    done = {}
    op = sd / "english.jsonl"
    if op.exists():
        for l in open(op):
            r = json.loads(l); done[r["id"]] = r
    todo = [r for r in rows if r["id"] not in done]
    run = Run(f"relabel-{a.source}", kind="data", total_steps=len(rows), tags=["data", a.source], notes="Phonon agreement filter")
    if todo:
        man = sd / "phonon_in.jsonl"
        with open(man, "w") as f:
            for r in todo:
                f.write(json.dumps(dict(id=r["id"], cat="en", reference=r["text"], audio=r["audio"])) + "\n")
        out = sd / "phonon_out.jsonl"
        subprocess.run([PHONON, BUNDLE, str(man), str(out)], check=True, capture_output=True)
        hyp = {}
        for l in open(out):
            r = json.loads(l); hyp[r["id"]] = r["hypothesis"]
        with open(op, "a") as f:
            for i, r in enumerate(todo):
                h = hyp.get(r["id"], "")
                g = r["text"]
                wer = score.edits(score.fair_tokens(g, False), score.fair_tokens(h, False)) / max(1, len(score.fair_tokens(g, False)))
                ref = g if a.use_gold_as_is else merge(g, h)
                f.write(json.dumps(dict(id=r["id"], wer=round(wer, 4), reference=ref, hyp=h, gold=g), ensure_ascii=False) + "\n")
    allr = [json.loads(l) for l in open(op)]
    keep = [r for r in allr if r["wer"] < a.wer and r["reference"]]
    run.log(len(allr), rows=len(keep))
    run.note(f"{a.source}: {len(keep)}/{len(allr)} rows with Phonon WER < {a.wer}; exact-match {sum(r['wer']==0 for r in allr)}")
    run.finish()
    print(a.source, len(keep), "/", len(allr))


if __name__ == "__main__":
    main()
