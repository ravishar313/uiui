#!/usr/bin/env python3
"""Report-only formatting scorer (NOT part of the locked harness; never gates anything).

Input: rows jsonl with id, cat, reference, hypothesis[, terms]. Per cat (and ALL) it reports:
  term_exact   case-sensitive exact rate of `terms` (cat=work) as whole words/phrases in the hypothesis.
               `terms` comes from the row, or from --locked (default $UIUI_ML_ROOT/ar/locked/dev-sel.jsonl) joined on id.
               Also term_exact_cased: only terms that contain an uppercase letter (the ones casing can break).
  acronym      reference tokens that are all-caps with >=2 chars (EOD, Q3, KPI): exact string match in the
               aligned hypothesis position.
  propnoun     reference tokens that are Capitalised, not sentence-initial, not "I": exact match likewise.
  punct        word-end period / comma / question P/R/F1 + micro F1 over the three marks.
Alignment is the same idea as cleanup/eval_cleanup.py (word-by-word on lowercased words), but ASR hypotheses
differ from the reference, so words are aligned with difflib on lowercased tokens and the acronym / propnoun /
punct rates are computed over the ALIGNED ('equal') words only, which isolates formatting from word errors.
`n` is the number of reference items, `aligned` how many of them found an identical word in the hypothesis.
Usage: format_report.py ROWS.jsonl [--locked dev-sel.jsonl] [--json out.json]
"""
import argparse, json, os, re, sys
from collections import defaultdict
from difflib import SequenceMatcher

WORD = re.compile(r"[^\W_](?:[\w'’\-]*[^\W_])?|[^\W_]")
MARK = {".": 2, ",": 1, "?": 3, "!": 2, ";": 1}
NAMES = {1: "comma", 2: "period", 3: "question"}


def toks(text):
    """-> [(word, mark_after, sentence_initial)] ; mark = strongest of ?, ., , in the gap after the word."""
    ms = list(WORD.finditer(text))
    out, start = [], True
    for i, m in enumerate(ms):
        end = ms[i + 1].start() if i + 1 < len(ms) else len(text)
        best = 0
        for ch in text[m.end():end]:
            c = MARK.get(ch, 0)
            if c == 3 or (c and (best == 0 or c > best)):
                best = 3 if c == 3 else max(best, c)
        out.append((m.group(0), best, start))
        start = best in (2, 3)
    return out


def align(r, h):
    sm = SequenceMatcher(None, [w[0].lower() for w in r], [w[0].lower() for w in h], autojunk=False)
    pairs = []
    for tag, a, b, c, d in sm.get_opcodes():
        if tag == "equal":
            pairs += [(a + k, c + k) for k in range(b - a)]
    return dict(pairs)


class Agg:
    def __init__(self):
        self.n = defaultdict(int)
        self.cm = defaultdict(int)  # (gold, pred) counts for punct

    def add(self, ref, hyp, terms):
        r, h = toks(ref), toks(hyp)
        amap = align(r, h)
        n = self.n
        n["rows"] += 1
        up = sum(1 for w, _, _ in r if len(w) >= 2 and w.isupper())
        allcaps = len(r) >= 4 and up > 0.6 * len(r)  # ALL-CAPS reference line: acronym/propnoun not meaningful
        n["allcaps_ref_rows"] += allcaps
        for i, (w, mark, init) in enumerate(r):
            if allcaps:
                if i in amap:
                    self.cm[(mark, h[amap[i]][1])] += 1
                continue
            letters = [c for c in w if c.isalpha()]
            aligned = i in amap
            if len(w) >= 2 and letters and all(c.isupper() for c in letters):
                n["acr"] += 1
                if aligned:
                    n["acr_al"] += 1
                    n["acr_ok"] += h[amap[i]][0] == w
            if letters and w[0].isupper() and not init and w != "I" and not w.startswith("I'") \
                    and any(c.islower() for c in letters) and letters[1:] == [c.lower() for c in letters[1:]]:
                n["pn"] += 1
                if aligned:
                    n["pn_al"] += 1
                    n["pn_ok"] += h[amap[i]][0] == w
            if aligned:
                self.cm[(mark, h[amap[i]][1])] += 1
        for t in terms or []:
            cased = any(c.isupper() for c in t)
            pat = re.compile(r"(?<![\w])" + re.escape(t) + r"(?![\w])")
            ok = bool(pat.search(hyp))
            n["term"] += 1
            n["term_ok"] += ok
            if cased:
                n["termc"] += 1
                n["termc_ok"] += ok

    def report(self):
        n = self.n
        rate = lambda a, b: (round(n[a] / n[b], 4) if n[b] else None)
        out = {"rows": n["rows"], "allcaps_ref_rows_skipped_for_acr_pn": n["allcaps_ref_rows"],
               "term_exact": {"rate": rate("term_ok", "term"), "n": n["term"]},
               "term_exact_cased": {"rate": rate("termc_ok", "termc"), "n": n["termc"]},
               "acronym_exact": {"rate": rate("acr_ok", "acr_al"), "n": n["acr"], "aligned": n["acr_al"]},
               "propnoun_cap": {"rate": rate("pn_ok", "pn_al"), "n": n["pn"], "aligned": n["pn_al"]}}
        tp = fp = fn = 0
        pc = {}
        for k, nm in NAMES.items():
            t = self.cm[(k, k)]
            f_p = sum(v for (g, p), v in self.cm.items() if p == k) - t
            f_n = sum(v for (g, p), v in self.cm.items() if g == k) - t
            pr = t / (t + f_p) if t + f_p else 0.0
            rc = t / (t + f_n) if t + f_n else 0.0
            pc[nm] = {"f1": round(2 * pr * rc / (pr + rc), 4) if pr + rc else 0.0, "p": round(pr, 4),
                      "r": round(rc, 4), "support": t + f_n}
            tp, fp, fn = tp + t, fp + f_p, fn + f_n
        pr = tp / (tp + fp) if tp + fp else 0.0
        rc = tp / (tp + fn) if tp + fn else 0.0
        pc["micro_f1"] = round(2 * pr * rc / (pr + rc), 4) if pr + rc else 0.0
        out["punct"] = pc
        return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("rows")
    ap.add_argument("--locked", default=os.path.join(os.environ.get("UIUI_ML_ROOT") or "workspace", "ar/locked/dev-sel.jsonl"))
    ap.add_argument("--json", default=None)
    a = ap.parse_args()
    rows = [json.loads(l) for l in open(a.rows) if l.strip()]
    lt = {}
    if os.path.exists(a.locked):
        for l in open(a.locked):
            r = json.loads(l)
            if r.get("terms"):
                lt[r["id"]] = r["terms"]
    aggs = defaultdict(Agg)
    for r in rows:
        terms = r.get("terms") or (lt.get(r["id"]) if r.get("cat") == "work" else None)
        for k in (r.get("cat", "?"), "ALL"):
            aggs[k].add(r["reference"], r["hypothesis"], terms if r.get("cat") == "work" else None)
    rep = {k: v.report() for k, v in sorted(aggs.items(), key=lambda kv: (kv[0] == "ALL", kv[0]))}
    f = lambda x: "   -  " if x is None else f"{100 * x:6.1f}"
    print(f"{'cat':8}{'rows':>6}{'term':>8}{'(n)':>5}{'termCased':>10}{'(n)':>5}{'acro':>7}{'(n/al)':>10}{'propN':>7}{'(n/al)':>10}"
          f"{'perF1':>7}{'comF1':>7}{'queF1':>7}{'microF1':>8}")
    for k, v in rep.items():
        p = v["punct"]
        print(f"{k:8}{v['rows']:6}{f(v['term_exact']['rate']):>8}{v['term_exact']['n']:5}{f(v['term_exact_cased']['rate']):>10}"
              f"{v['term_exact_cased']['n']:5}{f(v['acronym_exact']['rate']):>7}{str(v['acronym_exact']['n']) + '/' + str(v['acronym_exact']['aligned']):>10}"
              f"{f(v['propnoun_cap']['rate']):>7}{str(v['propnoun_cap']['n']) + '/' + str(v['propnoun_cap']['aligned']):>10}"
              f"{f(p['period']['f1']):>7}{f(p['comma']['f1']):>7}{f(p['question']['f1']):>7}{f(p['micro_f1']):>8}")
    if a.json:
        json.dump(rep, open(a.json, "w"), indent=1, ensure_ascii=False)


if __name__ == "__main__":
    main()
