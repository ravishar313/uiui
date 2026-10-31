"""Formatting metrics on words the ASR got right (shared by cleanup_on_asr.py and editor/eval_editor.py)."""

import sys, json, re, difflib, collections
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

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

