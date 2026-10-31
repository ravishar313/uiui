#!/usr/bin/env python3
"""LOCKED scorer and keep/discard rule (v2: English-first Indian professionals) for autoresearch.  The agent must not edit this file (the runner verifies its sha256 before every experiment).

    select_v2.py --base base.rows.jsonl --cand cand.rows.jsonl [--base-vibe b.jsonl --cand-vibe c.jsonl] [--locked-sel dev-sel.jsonl --locked-vibe vibe.jsonl]
                 [--out-dir DIR] [--resamples 1000] [--seed 0]       -> JSON verdict on stdout (and DIR/verdict.json, DIR/sanity.json, DIR/vibe.md)

Rows: id, cat, reference|ref, hypothesis|hyp [, speaker, terms].  cat in en_in | cm | work | hi | native.
Per-cat WER (fair_wer.twer, eval-only variant map): T-WER (attested Roman-Hindi spelling variants folded; hai/hain, ke/ka, par/pe, kar/ke, mein/main stay errors) for cm and hi,
raw-token WER (lowercase, punctuation stripped, exact match) for en_in, native and work.
Primary score  S = 0.40 en_in + 0.25 cm + 0.15 work + 0.10 hi + 0.10 native   (a cat absent from the rows is dropped and the weights are renormalised; recorded in the verdict).
Paired bootstrap stratified by cat: clips are resampled with replacement WITHIN each cat (same indices for baseline and candidate), the per-cat deltas (cand - base, absolute WER points)
are combined with the weights -> delta S with a 95% CI.
KEEP if  delta-S CI upper < 0
     AND per-cat guards (point delta, absolute points): en_in <= +0.2, native <= +0.3, cm <= +0.3, work <= +0.5, hi <= +2.0 (Hindi is a secondary robustness slice; raised from +1.0 on 2026-10-27 after exp 001)
     AND workplace term accuracy (share of the reference `terms` reproduced exactly: case-insensitive, punctuation-stripped, multi-word aware) drops by <= 1.0 point.
Sanity rules (on dev-sel + vibe hyps) then force DISCARD: empty hyps > baseline + 2; any new runaway clip (in cand, not in base); Devanagari characters in more than 0.5% of hyps.
Runaway = hyp words / ref words > 3.   Terms come from the rows or, when the rows lack them (evaluate.py does not carry them), from the --locked-sel manifest.
"""
import argparse, json, os, random, re, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def _load_evalx():
    """scorer code is the LOCKED copy in locked/evalx (score.py, fair_wer.py, roman_variants.py, variants/), hashed by lock.py; AR_EVALX_DIR is for tests only."""
    d = Path(os.environ.get("AR_EVALX_DIR") or HERE / "evalx")
    sys.path.insert(0, str(d))
    import score, fair_wer
    return score, fair_wer


score, fair_wer = _load_evalx()

CATS = ("en_in", "cm", "work", "hi", "native")
WEIGHTS = {"en_in": 0.40, "cm": 0.25, "work": 0.15, "hi": 0.10, "native": 0.10}
TWER_CATS = ("cm", "hi")                                   # Roman-Hinglish variant folding; the others use raw tokens
GUARDS = {"en_in": 0.2, "native": 0.3, "cm": 0.3, "work": 0.5, "hi": 2.0}       # max allowed per-cat delta WER (absolute points, cand - base)
TERM_DROP_MAX = 1.0                                        # max allowed drop of workplace term accuracy (absolute points)
RUNAWAY_RATIO = 3.0
RUNAWAY_MIN_EXTRA = 8   # and at least this many extra words: a spelled-out number ("1210" -> "one thousand two hundred and ten") is not a runaway
DEVA = re.compile("[\u0900-\u097F]")
DEVA_MAX_FRAC = 0.005
EMPTY_SLACK = 2


def read_rows(path):
    out = {}
    for l in Path(path).read_text(encoding="utf-8").splitlines():
        if not l.strip(): continue
        r = json.loads(l)
        row = {"id": r["id"], "cat": r["cat"], "reference": r.get("reference", r.get("ref", "")), "hypothesis": r.get("hypothesis", r.get("hyp", "")) or "",
               "speaker": r.get("speaker"), "terms": r.get("terms")}
        if row["id"] in out: raise ValueError(f"{path}: duplicate id {row['id']}")
        out[row["id"]] = row
    return out


def read_terms(locked_path):
    """id -> terms list from a locked manifest."""
    out = {}
    for l in Path(locked_path).read_text(encoding="utf-8").splitlines():
        if l.strip():
            r = json.loads(l)
            if r.get("terms"): out[r["id"]] = r["terms"]
    return out


def nwords(t): return len(score.base_tokens(t))


def is_runaway(r):
    h, ref = nwords(r["hypothesis"]), nwords(r["reference"])
    return h / max(ref, 1) > RUNAWAY_RATIO and h - ref >= RUNAWAY_MIN_EXTRA


def per_clip(rows):
    """id -> (errors, words); T-WER tokenisation for cm/hi, raw tokens elsewhere."""
    _, samples = fair_wer.twer(list(rows.values()), hinglish_cats=TWER_CATS, use_eval_only=True)
    return {s["id"]: (s["twer_errors"], s["words"]) for s in samples}


def wer_table(rows):
    m, _ = fair_wer.twer(list(rows.values()), hinglish_cats=TWER_CATS, use_eval_only=True)
    return {k: {"wer": v["twer"], "raw_wer": v["raw_wer"], "cer": v["cer"], "fw_pts": v["fw_pts"], "words": v["words"]} for k, v in m.items()}


def weights_for(present):
    """renormalised weights over the cats that are present."""
    tot = sum(WEIGHTS[c] for c in present)
    return {c: WEIGHTS[c] / tot for c in present}


def score_S(table, present=None):
    """weighted primary score of one wer_table (cats missing from the table are dropped, weights renormalised)."""
    present = [c for c in CATS if c in table] if present is None else present
    w = weights_for(present)
    return sum(w[c] * table[c]["wer"] for c in present), w


def _norm_phrase(t): return score.base_tokens(t)


def term_hits(terms, hypothesis):
    """(hit, total) of the reference terms found in the hypothesis: case-insensitive, punctuation-stripped, contiguous word sequence (multi-word aware)."""
    hyp = score.base_tokens(hypothesis); hit = total = 0
    for term in terms or []:
        t = _norm_phrase(term)
        if not t: continue
        total += 1
        n = len(t)
        if any(hyp[i:i + n] == t for i in range(len(hyp) - n + 1)): hit += 1
    return hit, total


def term_accuracy(rows):
    """share (percent) of work-row reference terms reproduced exactly; None when there are no terms."""
    hit = total = 0
    for r in rows.values():
        if r["cat"] != "work" or not r.get("terms"): continue
        h, t = term_hits(r["terms"], r["hypothesis"]); hit += h; total += t
    return (100.0 * hit / total, hit, total) if total else None


def bootstrap_S(per_cat, w, B, rng):
    """per_cat: cat -> (eb, ec, words) lists; paired bootstrap stratified by cat.  -> {'S': (point, lo, hi), cat: (point, lo, hi)} in absolute WER points (cand - base)."""
    data = {c: ([e2 - e1 for e1, e2 in zip(eb, ec)], wd) for c, (eb, ec, wd) in per_cat.items()}

    def delta(c, idx):
        d, wd = data[c]
        return 100 * sum(d[i] for i in idx) / max(sum(wd[i] for i in idx), 1)
    point = {c: delta(c, range(len(data[c][1]))) for c in data}
    pS = sum(w[c] * point[c] for c in data)
    samples = {c: [] for c in data}; sS = []
    for _ in range(B):
        tot = 0.0
        for c in data:
            n = len(data[c][1]); x = delta(c, rng.choices(range(n), k=n)); samples[c].append(x); tot += w[c] * x
        sS.append(tot)
    def q(xs): xs = sorted(xs); return xs[int(0.025 * B)], xs[int(0.975 * B) - 1]
    res = {"S": (pS,) + q(sS)}
    for c in data: res[c] = (point[c],) + q(samples[c])
    return res


def sanity(rows):
    """collapse / leakage indicators on one set of rows."""
    rs = list(rows.values()); n = len(rs)
    if not n: return {"clips": 0}
    ratios = [nwords(r["hypothesis"]) / max(nwords(r["reference"]), 1) for r in rs]
    hyp_tok = [t for r in rs for t in score.base_tokens(r["hypothesis"])]
    ref_tok = [t for r in rs for t in score.base_tokens(r["reference"])]
    ttr = lambda t: len(set(t)) / len(t) if t else None
    th, tr = ttr(hyp_tok), ttr(ref_tok)
    loan = None
    ev = getattr(score, "ENGLISH_VOCAB", None)
    if ev:
        known = set(score.HINGLISH_VARIANTS) | set(score.HINGLISH_VARIANTS.values()) | score.CANON_KNOWN
        tot = kept = 0
        for r in rs:
            if r["cat"] not in TWER_CATS: continue
            hs = set(score.base_tokens(r["hypothesis"]))
            for t in set(score.base_tokens(r["reference"])):
                if t.isascii() and t.isalpha() and len(t) > 3 and t in ev and t not in known:
                    tot += 1; kept += t in hs
        loan = {"english_tokens_in_cm_hi_refs": tot, "kept_as_english": kept, "share": round(kept / tot, 4) if tot else None}
    return {"clips": n, "mean_len_ratio": round(sum(ratios) / n, 4), "pooled_len_ratio": round(len(hyp_tok) / max(len(ref_tok), 1), 4),
            "empty_hyps": sum(1 for r in rs if not nwords(r["hypothesis"])), "runaways": sum(1 for r in rs if is_runaway(r)),
            "devanagari_hyps": sum(1 for r in rs if DEVA.search(r["hypothesis"])), "devanagari_frac": round(sum(1 for r in rs if DEVA.search(r["hypothesis"])) / n, 5),
            "ttr_hyp": round(th, 4) if th else None, "ttr_ref": round(tr, 4) if tr else None,
            "ttr_ratio": round(th / tr, 4) if th and tr else None, "loanword_kept_as_english": loan}


def check_locked(rows, locked_path, label):
    """candidate/baseline rows must cover exactly the locked ids, with byte-identical references."""
    lk = {}
    for l in Path(locked_path).read_text(encoding="utf-8").splitlines():
        if l.strip(): r = json.loads(l); lk[r["id"]] = r["reference"]
    if set(rows) != set(lk): return f"{label}: id set differs from {locked_path} (missing {len(set(lk) - set(rows))}, extra {len(set(rows) - set(lk))})"
    bad = [i for i in rows if rows[i]["reference"] != lk[i]]
    return f"{label}: {len(bad)} references differ from the locked copy, e.g. {bad[:3]}" if bad else None


def decide(boot, term_delta):
    """(keep?, reasons, guards) from the bootstrap result and the term-accuracy delta (cand - base, points; None = no terms)."""
    why, guards, ok = [], {}, True
    S = boot["S"]
    sig = S[2] < 0
    if not sig: why.append(f"delta S CI upper {S[2]:.3f} >= 0 (no significant gain in the weighted score)")
    for c, lim in GUARDS.items():
        if c not in boot: continue
        passed = boot[c][0] <= lim
        guards[c] = {"delta": round(boot[c][0], 3), "limit": lim, "ok": passed}
        if not passed: ok = False; why.append(f"guard {c}: delta {boot[c][0]:.3f} > +{lim}")
    if term_delta is not None:
        passed = term_delta >= -TERM_DROP_MAX
        guards["terms"] = {"delta": round(term_delta, 3), "limit": -TERM_DROP_MAX, "ok": passed}
        if not passed: ok = False; why.append(f"guard terms: term accuracy {term_delta:.3f} < -{TERM_DROP_MAX}")
    if sig and ok: why.append("delta S CI upper < 0 and every guard holds")
    return sig and ok, why, guards


def vibe_md(base, cand, bvibe, cvibe, locked_vibe=None):
    order = {}
    if locked_vibe:
        for l in Path(locked_vibe).read_text(encoding="utf-8").splitlines():
            if l.strip(): r = json.loads(l); order[r["id"]] = (r.get("vibe_source") or r.get("source") or "", r.get("seconds"))
    ids = sorted(cvibe, key=lambda i: (cvibe[i]["cat"], order.get(i, ("",))[0], i))
    esc = lambda t: (t or "").replace("|", "\\|").replace("\n", " ")
    changed = sum(1 for i in ids if i in bvibe and bvibe[i]["hypothesis"] != cvibe[i]["hypothesis"])
    L = [f"# vibe check: {len(ids)} fixed clips, {changed} changed vs previous best", "", "`*` = hypothesis changed.  err = word errors previous best -> new.", "",
         "| | cat | source | id | ref | previous best | new | err |", "|---|---|---|---|---|---|---|---|"]
    ec = per_clip(cvibe); eb = per_clip(bvibe) if bvibe else {}
    for i in ids:
        b = bvibe.get(i, {}).get("hypothesis", "") if bvibe else ""
        c = cvibe[i]["hypothesis"]
        L.append(f"| {'*' if b != c else ''} | {cvibe[i]['cat']} | {order.get(i, ('',))[0]} | {i} | {esc(cvibe[i]['reference'])} | {esc(b)} | {esc(c)} | {eb.get(i, ('?',))[0]} -> {ec[i][0]} |")
    return "\n".join(L) + "\n"


def run(base, cand, bvibe=None, cvibe=None, resamples=1000, seed=0, terms=None):
    ids = sorted(set(base) & set(cand))
    if set(base) != set(cand): raise ValueError(f"baseline and candidate cover different clips ({len(base)} vs {len(cand)}; common {len(ids)})")
    b = {i: dict(base[i]) for i in ids}; c = {i: dict(cand[i]) for i in ids}
    for i in ids:
        if b[i]["reference"] != c[i]["reference"] or b[i]["cat"] != c[i]["cat"]: raise ValueError(f"reference/cat differ between baseline and candidate for {i}")
        bad = b[i]["cat"] not in CATS
        if bad: raise ValueError(f"unknown cat {b[i]['cat']!r} for {i} (expected one of {CATS})")
        t = (terms or {}).get(i) or b[i].get("terms") or c[i].get("terms")
        b[i]["terms"] = c[i]["terms"] = t
    present = [k for k in CATS if any(b[i]["cat"] == k for i in ids)]
    if not present: raise ValueError("no clips")
    w = weights_for(present)
    eb, ec = per_clip(b), per_clip(c)
    per_cat = {}
    for cat in present:
        cid = [i for i in ids if b[i]["cat"] == cat]
        per_cat[cat] = ([eb[i][0] for i in cid], [ec[i][0] for i in cid], [eb[i][1] for i in cid])
    boot = bootstrap_S(per_cat, w, resamples, random.Random(seed))
    ta_b, ta_c = term_accuracy(b), term_accuracy(c)
    term_delta = (ta_c[0] - ta_b[0]) if ta_b and ta_c else None
    run_b = [i for i in ids if is_runaway(b[i])]; run_c = [i for i in ids if is_runaway(c[i])]
    wt_b, wt_c = wer_table(b), wer_table(c)
    keep, why, guards = decide(boot, term_delta)
    sb, sc = dict(b), dict(c)
    new_run = [i for i in run_c if i not in set(run_b)]
    if bvibe is not None and cvibe is not None:
        sb.update({"vibe::" + k: v for k, v in bvibe.items()}); sc.update({"vibe::" + k: v for k, v in cvibe.items()})
        new_run += ["vibe::" + k for k, v in cvibe.items() if is_runaway(v) and not is_runaway(bvibe.get(k, v))]
    san_b, san_c = sanity(sb), sanity(sc)
    forced = []
    if san_c["empty_hyps"] > san_b["empty_hyps"] + EMPTY_SLACK: forced.append(f"empty hyps {san_c['empty_hyps']} > baseline {san_b['empty_hyps']} + {EMPTY_SLACK}")
    if new_run: forced.append(f"new runaway clips: {new_run[:5]}")
    if san_c["devanagari_frac"] > DEVA_MAX_FRAC: forced.append(f"devanagari in {san_c['devanagari_frac'] * 100:.2f}% of hyps (> {DEVA_MAX_FRAC * 100}%)")
    status = "keep" if keep and not forced else "discard"
    r3 = lambda x: None if x is None else round(x, 3)
    ci = lambda r: [round(r[1], 3), round(r[2], 3)]
    S_b, _ = score_S(wt_b, present); S_c, _ = score_S(wt_c, present)
    per_cat_tbl = {cat: {"clips": len(per_cat[cat][2]), "words": wt_b[cat]["words"], "metric": "T-WER" if cat in TWER_CATS else "raw WER", "weight": round(w[cat], 4),
                         "base_wer": wt_b[cat]["wer"], "cand_wer": wt_c[cat]["wer"], "delta": r3(boot[cat][0]), "ci": ci(boot[cat]), "guard": GUARDS[cat], "guard_ok": guards[cat]["ok"],
                         "cand_cer": wt_c[cat]["cer"], "cand_fw_pts": wt_c[cat]["fw_pts"]} for cat in present}
    verdict = {"status": status, "reasons": why + [f"sanity: {f}" for f in forced], "clips": len(ids),
               "weights_used": {k: round(v, 4) for k, v in w.items()}, "cats_present": present, "cats_missing": [k for k in CATS if k not in present],
               "S_base": r3(S_b), "S_cand": r3(S_c), "d_S": r3(boot["S"][0]), "ci_S": ci(boot["S"]), "per_cat": per_cat_tbl, "guards": guards,
               "terms": {"base_acc": r3(ta_b[0]) if ta_b else None, "cand_acc": r3(ta_c[0]) if ta_c else None, "delta": r3(term_delta), "n_terms": ta_b[2] if ta_b else 0,
                         "limit": -TERM_DROP_MAX},
               "base": {"runaways": len(run_b), **{f"{k}_wer": wt_b[k]["wer"] for k in present}, "all_wer": wt_b.get("ALL", {}).get("wer")},
               "cand": {"runaways": len(run_c), **{f"{k}_wer": wt_c[k]["wer"] for k in present}, "all_wer": wt_c.get("ALL", {}).get("wer"),
                        "cm_fw_pts": wt_c.get("cm", {}).get("fw_pts"), "cm_cer": wt_c.get("cm", {}).get("cer")},
               "runaways": len(run_c), "resamples": resamples, "seed": seed, "wer_table_cand": wt_c, "wer_table_base": wt_b}
    return verdict, {"baseline": san_b, "candidate": san_c, "rules": {"empty_slack": EMPTY_SLACK, "devanagari_max_frac": DEVA_MAX_FRAC, "runaway_ratio": RUNAWAY_RATIO, "forced_discard": forced}}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True); ap.add_argument("--cand", required=True)
    ap.add_argument("--base-vibe"); ap.add_argument("--cand-vibe")
    ap.add_argument("--locked-sel"); ap.add_argument("--locked-vibe")
    ap.add_argument("--out-dir"); ap.add_argument("--resamples", type=int, default=1000); ap.add_argument("--seed", type=int, default=0)
    a = ap.parse_args()
    base, cand = read_rows(a.base), read_rows(a.cand)
    bv = read_rows(a.base_vibe) if a.base_vibe else None; cv = read_rows(a.cand_vibe) if a.cand_vibe else None
    problems = []
    if a.locked_sel:
        problems += [p for p in (check_locked(base, a.locked_sel, "baseline rows"), check_locked(cand, a.locked_sel, "candidate rows")) if p]
    if a.locked_vibe and cv is not None:
        problems += [p for p in (check_locked(cv, a.locked_vibe, "candidate vibe rows"), check_locked(bv, a.locked_vibe, "baseline vibe rows") if bv else None) if p]
    if problems:
        print(json.dumps({"status": "invalid", "reasons": problems})); sys.exit(3)
    verdict, san = run(base, cand, bv, cv, a.resamples, a.seed, terms=read_terms(a.locked_sel) if a.locked_sel else None)
    if a.out_dir:
        d = Path(a.out_dir); d.mkdir(parents=True, exist_ok=True)
        (d / "verdict.json").write_text(json.dumps(verdict, indent=1)); (d / "sanity.json").write_text(json.dumps(san, indent=1))
        if cv is not None: (d / "vibe.md").write_text(vibe_md(base, cand, bv or {}, cv, a.locked_vibe))
    print(json.dumps(verdict))


if __name__ == "__main__":
    main()
