"""Formatting quality on REAL speech-model output (eval-only audio; prints aggregates only, never transcripts).
Input: phonon-eval rows (id, cat, reference, hypothesis) from the app transcriber.  Pipelines compared:
  raw  = ASR text as emitted;  old/new = ASR text -> app cleanup port (uiui_cleanup.Cleaner, gate + finalize) with each ONNX model.
Scoring on words the ASR got right: hyp and ref word sequences (lowercased, punctuation stripped) are aligned with difflib; for every
matched word compare the trailing mark (NONE/COMMA/PERIOD/QUESTION/EXCL; ';'->COMMA, ':'->NONE) and the case class (lower/Cap/UPPER/mixed).
Punctuation only on rows whose reference has punctuation; case on rows whose reference has a capital.
Usage: cleanup_on_asr.py ROWS.jsonl OLD.onnx NEW.onnx OUT.json"""
import sys, json, re, difflib, collections
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from uiui_cleanup import Cleaner, OnnxBackend

WORD = re.compile(r"[\w'’]+(?:[.,:]\d+)*[\w'’]*", re.U)
MARK = {",": "COMMA", ";": "COMMA", ".": "PERIOD", "?": "QUESTION", "!": "EXCL"}

def toks(text):
    out = []
    for m in WORD.finditer(text):
        w = m.group(0); tail = text[m.end():m.end() + 3].lstrip(" \"')]”’")
        mark = MARK.get(tail[:1], "NONE") if tail else "NONE"
        if w.isupper() and len(w) > 1 and any(c.isalpha() for c in w): cs = "UPPER"
        elif w[:1].isupper() and (w[1:].islower() or not any(c.isalpha() for c in w[1:])): cs = "CAP"
        elif w.islower() or not any(c.isalpha() for c in w): cs = "LOWER"
        else: cs = "MIXED"
        out.append((w.lower(), mark, cs))
    return out

class Agg:
    def __init__(self): self.p = collections.Counter(); self.case = [0, 0]; self.cap_need = [0, 0]; self.acr = [0, 0]; self.overcap = [0, 0]; self.words = 0; self.ref_words = 0
    def add(self, ref, hyp, do_p, do_c):
        R, H = toks(ref), toks(hyp); self.ref_words += len(R)
        sm = difflib.SequenceMatcher(a=[x[0] for x in R], b=[x[0] for x in H], autojunk=False)
        for blk in sm.get_matching_blocks():
            for k in range(blk.size):
                r, h = R[blk.a + k], H[blk.b + k]; self.words += 1
                if do_p:
                    for cls in ("COMMA", "PERIOD", "QUESTION"):
                        self.p[(cls, "tp")] += r[1] == cls and h[1] == cls
                        self.p[(cls, "fp")] += r[1] != cls and h[1] == cls
                        self.p[(cls, "fn")] += r[1] == cls and h[1] != cls
                if do_c and r[2] != "MIXED":
                    self.case[0] += r[2] == h[2]; self.case[1] += 1
                    if r[2] == "CAP" and blk.a + k > 0 and R[blk.a + k - 1][1] == "NONE" and r[0] != "i": self.cap_need[0] += h[2] == "CAP"; self.cap_need[1] += 1
                    if r[2] == "UPPER": self.acr[0] += h[2] == "UPPER"; self.acr[1] += 1
                    if r[2] == "LOWER": self.overcap[0] += h[2] != "LOWER"; self.overcap[1] += 1
    def f1(self, classes):
        tp = sum(self.p[(c, "tp")] for c in classes); fp = sum(self.p[(c, "fp")] for c in classes); fn = sum(self.p[(c, "fn")] for c in classes)
        return round(100 * 2 * tp / max(2 * tp + fp + fn, 1), 1)
    def summary(self):
        pct = lambda a: round(100 * a[0] / max(a[1], 1), 1)
        return {"punct_f1": self.f1(("COMMA", "PERIOD", "QUESTION")), "comma_f1": self.f1(("COMMA",)), "period_f1": self.f1(("PERIOD",)),
                "question_f1": self.f1(("QUESTION",)), "question_n": self.p[("QUESTION", "tp")] + self.p[("QUESTION", "fn")],
                "case_acc": pct(self.case), "midsentence_cap": pct(self.cap_need), "midsentence_cap_n": self.cap_need[1],
                "acronym_upper": pct(self.acr), "acronym_n": self.acr[1], "wrongly_capitalised": pct(self.overcap), "matched_words": self.words, "ref_words": self.ref_words}

rows = [json.loads(l) for l in open(sys.argv[1])]
cleaners = {"old": Cleaner(OnnxBackend(sys.argv[2])), "new": Cleaner(OnnxBackend(sys.argv[3]))}
aggs = collections.defaultdict(Agg); changed = collections.Counter(); gated = 0
for r in rows:
    ref, hyp = r["reference"], r["hypothesis"]
    outs = {"raw": hyp}
    for k, c in cleaners.items():
        try: outs[k] = c.clean(hyp)
        except Exception: outs[k] = hyp
    gated += outs["new"] == hyp and outs["old"] == hyp
    do_p = bool(re.search(r"[.,?!]", ref)); do_c = bool(re.search(r"[A-Z]", ref))
    for k, o in outs.items():
        changed[k] += o != hyp
        for cat in (r["cat"], "ALL"): aggs[(k, cat)].add(ref, o, do_p, do_c)
res = {f"{k}|{cat}": a.summary() for (k, cat), a in sorted(aggs.items())}
res["_meta"] = {"rows": len(rows), "changed_by_cleanup": dict(changed), "unchanged_by_both": gated}
json.dump(res, open(sys.argv[4], "w"), indent=1)
cats = sorted({c for (_, c) in aggs})
keys = ["punct_f1", "comma_f1", "period_f1", "question_f1", "case_acc", "midsentence_cap", "acronym_upper", "wrongly_capitalised"]
print("cat      pipe " + " ".join(k[:12].rjust(12) for k in keys))
for cat in cats:
    for k in ("raw", "old", "new"):
        s = res[f"{k}|{cat}"]; print(f"{cat:8} {k:4} " + " ".join(f"{s[x]:12}" for x in keys))
print(res["_meta"]); print({c: (res[f"new|{c}"]["question_n"], res[f"new|{c}"]["midsentence_cap_n"], res[f"new|{c}"]["acronym_n"]) for c in cats}, "(question n, mid-sentence cap n, acronym n)")
