"""Unit tests for autoresearch/locked/select_v2.py on synthetic rows.   python3 -m unittest tests/test_select_v2.py   (pure stdlib)"""
import json, math, random, subprocess, sys, tempfile, unittest
from pathlib import Path

LOCKED = Path(__file__).resolve().parent.parent / "locked"
sys.path.insert(0, str(LOCKED))
import select_v2 as sel  # noqa: E402

WORDS = "aap kaise hain main theek hoon kal market jaunga phone number bhejna please send meeting tomorrow office ghar jaldi bataiye kuch paisa train ticket book karo".split()
N = {"en_in": 200, "cm": 150, "work": 100, "hi": 100, "native": 100}


def make(n=N, seed=1, terms=True):
    """truth rows (hypothesis == reference).  work rows: 10 words, 2 of them are workplace terms."""
    rng = random.Random(seed); rows = {}
    for cat, k in n.items():
        for j in range(k):
            ref = " ".join(rng.choice(WORDS) for _ in range(rng.randint(6, 12)))
            r = {"id": f"{cat}{j}", "cat": cat, "reference": ref, "hypothesis": ref, "speaker": f"s{j % 20}"}
            if cat == "work":
                r["reference"] = r["hypothesis"] = "please send the kubernetes deployment report to the office tomorrow morning"
                if terms: r["terms"] = ["kubernetes", "deployment"]
            rows[r["id"]] = r
    return rows


def damage(rows, cat, k, seed=0):
    """copy of rows where the first k clips of `cat` (shuffled with seed, restricted to still-correct clips) get exactly one wrong word."""
    out = {i: dict(r) for i, r in rows.items()}
    ids = [i for i, r in out.items() if r["cat"] == cat and r["hypothesis"] == r["reference"]]
    random.Random(seed).shuffle(ids)
    for i in ids[:k]:
        w = out[i]["hypothesis"].split(); w[0] = "zzz"; out[i]["hypothesis"] = " ".join(w)
    return out


def fix(rows, truth, cat):
    out = {i: dict(r) for i, r in rows.items()}
    for i, r in out.items():
        if r["cat"] == cat: r["hypothesis"] = truth[i]["reference"]
    return out


def words(rows, cat): return sum(len(sel.score.base_tokens(r["reference"])) for r in rows.values() if r["cat"] == cat)


class Base(unittest.TestCase):
    def setUp(self):
        self.truth = make()
        b = self.truth
        for cat, frac in (("en_in", 0.4), ("cm", 0.4), ("work", 0.2), ("hi", 0.4), ("native", 0.2)):
            b = damage(b, cat, int(N[cat] * frac), seed=3)
        self.base = b

    def v(self, cand, base=None, **kw):
        return sel.run(base or self.base, cand, resamples=300, **kw)[0]

    def fixed_all(self, cats=("en_in", "cm", "work", "hi", "native")):
        c = self.base
        for cat in cats: c = fix(c, self.truth, cat)
        return c


class Weighting(Base):
    def test_weights_are_the_spec(self):
        self.assertEqual(sel.WEIGHTS, {"en_in": 0.40, "cm": 0.25, "work": 0.15, "hi": 0.10, "native": 0.10})
        self.assertAlmostEqual(sum(sel.WEIGHTS.values()), 1.0)

    def test_S_is_weighted_sum_of_cat_wers(self):
        v = self.v(self.fixed_all(("cm",)))
        for tag in ("base", "cand"):
            want = sum(sel.WEIGHTS[c] * v["per_cat"][c][f"{tag}_wer"] for c in sel.CATS)
            self.assertAlmostEqual(v[f"S_{tag}"], want, delta=0.01)
        # fixing all cm errors moves S by exactly 0.25 * cm base WER
        self.assertAlmostEqual(v["d_S"], -0.25 * v["per_cat"]["cm"]["base_wer"], delta=0.02)
        self.assertEqual(v["weights_used"], {"en_in": 0.4, "cm": 0.25, "work": 0.15, "hi": 0.1, "native": 0.1})
        self.assertEqual(v["cats_missing"], [])

    def test_d_S_combines_cat_deltas_with_weights(self):
        cand = self.fixed_all(("en_in", "native"))
        cand = damage(cand, "hi", 5, seed=9)
        v = self.v(cand)
        self.assertAlmostEqual(v["d_S"], sum(v["weights_used"][c] * v["per_cat"][c]["delta"] for c in v["cats_present"]), delta=0.01)

    def test_per_cat_metric_labels(self):
        v = self.v(self.base)
        self.assertEqual({c: v["per_cat"][c]["metric"] for c in sel.CATS}, {"en_in": "raw WER", "cm": "T-WER", "work": "raw WER", "hi": "T-WER", "native": "raw WER"})

    def test_renormalised_when_a_cat_is_absent(self):
        keep = lambda rows: {i: r for i, r in rows.items() if r["cat"] != "work"}
        v = self.v(keep(self.fixed_all(("en_in",))), base=keep(self.base))
        self.assertEqual(v["cats_missing"], ["work"]); self.assertNotIn("work", v["per_cat"])
        self.assertAlmostEqual(sum(v["weights_used"].values()), 1.0, places=3)
        self.assertAlmostEqual(v["weights_used"]["en_in"], 0.40 / 0.85, places=3); self.assertAlmostEqual(v["weights_used"]["cm"], 0.25 / 0.85, places=3)
        self.assertAlmostEqual(v["d_S"], -v["weights_used"]["en_in"] * v["per_cat"]["en_in"]["base_wer"], delta=0.02)
        self.assertEqual(v["terms"]["n_terms"], 0); self.assertIsNone(v["terms"]["delta"])

    def test_two_cats_only(self):
        keep = lambda rows: {i: r for i, r in rows.items() if r["cat"] in ("cm", "native")}
        v = self.v(keep(self.fixed_all(("cm",))), base=keep(self.base))
        self.assertEqual(v["cats_present"], ["cm", "native"]); self.assertAlmostEqual(v["weights_used"]["cm"], 0.25 / 0.35, places=3)

    def test_unknown_cat_rejected(self):
        bad = {i: dict(r) for i, r in self.base.items()}; k = next(iter(bad)); bad[k]["cat"] = "hinglish"
        with self.assertRaises(ValueError): sel.run(bad, {i: dict(r) for i, r in bad.items()}, resamples=10)

    def test_bootstrap_degenerate_has_zero_width(self):
        res = sel.bootstrap_S({"a": ([1, 1, 1], [1, 1, 1], [5, 5, 5])}, {"a": 1.0}, 50, random.Random(0))
        self.assertEqual(res["S"], (0.0, 0.0, 0.0))

    def test_bootstrap_is_stratified(self):
        # cat a: constant improvement on every clip; cat b: nothing.  Every resample has delta_a == -20 exactly, so stratification pins S to 0.5 * -20 = -10 with zero width.
        a = ([1] * 10, [0] * 10, [5] * 10); b = ([0] * 7, [0] * 7, [5] * 7)
        res = sel.bootstrap_S({"a": a, "b": b}, {"a": 0.5, "b": 0.5}, 100, random.Random(1))
        self.assertAlmostEqual(res["S"][0], -10.0); self.assertAlmostEqual(res["S"][1], -10.0); self.assertAlmostEqual(res["S"][2], -10.0)


class Decision(Base):
    def test_clear_gain_is_kept(self):
        v = self.v(self.fixed_all()); self.assertEqual(v["status"], "keep", v["reasons"]); self.assertLess(v["ci_S"][1], 0)
        self.assertTrue(all(g["ok"] for g in v["guards"].values()))

    def test_identical_is_discarded(self):
        v = self.v({i: dict(r) for i, r in self.base.items()}); self.assertEqual(v["status"], "discard"); self.assertEqual(v["d_S"], 0)

    def test_noise_level_change_is_discarded(self):
        cand = {i: dict(r) for i, r in self.base.items()}
        k = next(i for i, r in cand.items() if r["cat"] == "en_in" and r["hypothesis"] != self.truth[i]["reference"]); cand[k]["hypothesis"] = self.truth[k]["reference"]
        v = self.v(cand); self.assertEqual(v["status"], "discard"); self.assertGreaterEqual(v["ci_S"][1], 0)

    def test_guards_en_in_native_cm_work_hi(self):
        """every other cat is fixed (big, significant S gain); `cat` is perfect in the baseline and regresses by just inside / just outside its guard."""
        for cat, limit in sel.GUARDS.items():
            others = tuple(c for c in sel.CATS if c != cat)
            k_ok = math.floor(limit * words(self.truth, cat) / 100 - 1e-9)          # most extra word errors that still satisfy delta <= limit
            base = {i: (dict(self.truth[i]) if r["cat"] == cat else dict(r)) for i, r in self.base.items()}
            cand0 = fix(self.fixed_all(others), self.truth, cat)
            v_ok = self.v(damage(cand0, cat, k_ok, seed=21), base=base)
            v_bad = self.v(damage(cand0, cat, k_ok + 1, seed=21), base=base)
            self.assertLessEqual(v_ok["per_cat"][cat]["delta"], limit, (cat, v_ok["per_cat"][cat])); self.assertEqual(v_ok["status"], "keep", (cat, v_ok["reasons"]))
            self.assertGreater(v_bad["per_cat"][cat]["delta"], limit, (cat, v_bad["per_cat"][cat])); self.assertEqual(v_bad["status"], "discard", cat)
            self.assertTrue(any(f"guard {cat}" in r for r in v_bad["reasons"]), v_bad["reasons"]); self.assertFalse(v_bad["guards"][cat]["ok"])
            self.assertLess(v_bad["ci_S"][1], 0, "S alone would have been kept: only the guard blocks it")

    def test_guard_limits_are_the_spec(self):
        self.assertEqual(sel.GUARDS, {"en_in": 0.2, "native": 0.3, "cm": 0.3, "work": 0.5, "hi": 2.0}); self.assertEqual(sel.TERM_DROP_MAX, 1.0)

    def test_hi_regression_inside_its_wide_guard_is_tolerated(self):
        W = words(self.truth, "hi"); k = int(0.9 * W / 100)
        base = {i: (dict(self.truth[i]) if r["cat"] == "hi" else dict(r)) for i, r in self.base.items()}
        cand = damage(fix(self.fixed_all(("en_in", "cm", "work", "native")), self.truth, "hi"), "hi", k, seed=5)
        v = self.v(cand, base=base); self.assertEqual(v["status"], "keep", v["reasons"]); self.assertGreater(v["per_cat"]["hi"]["delta"], 0.3)


class TermMetric(Base):
    def test_term_hits_rules(self):
        h = sel.term_hits
        self.assertEqual(h(["Kubernetes"], "Please deploy KUBERNETES now."), (1, 1))                      # case-insensitive, punctuation-stripped
        self.assertEqual(h(["stand-up meeting"], "we had a stand up meeting today"), (1, 1))             # punctuation inside a term, multi-word
        self.assertEqual(h(["pull request"], "open a pull request"), (1, 1))
        self.assertEqual(h(["pull request"], "request a pull"), (0, 1))                                  # order matters
        self.assertEqual(h(["pull request"], "pull the request"), (0, 1))                                # must be contiguous
        self.assertEqual(h(["pytorch"], "py torch"), (0, 1))                                              # exact reproduction
        self.assertEqual(h(["pytorch"], "pytorches"), (0, 1))                                             # no substring credit
        self.assertEqual(h(["Q3 OKRs", "roadmap"], "the q3 okrs and the roadmap"), (2, 2))
        self.assertEqual(h(["a", "a"], "a"), (2, 2))                                                      # each listed term counts
        self.assertEqual(h([], "anything"), (0, 0)); self.assertEqual(h(None, "anything"), (0, 0)); self.assertEqual(h([""], "x"), (0, 0))

    def test_term_accuracy_only_over_work_rows_with_terms(self):
        rows = {"w1": {"id": "w1", "cat": "work", "reference": "a b", "hypothesis": "a", "terms": ["a", "b"]},
                "w2": {"id": "w2", "cat": "work", "reference": "c", "hypothesis": "c", "terms": ["c"]},
                "w3": {"id": "w3", "cat": "work", "reference": "d", "hypothesis": "x", "terms": None},
                "e1": {"id": "e1", "cat": "en_in", "reference": "d", "hypothesis": "x", "terms": ["d"]}}
        acc, hit, tot = sel.term_accuracy(rows); self.assertEqual((hit, tot), (2, 3)); self.assertAlmostEqual(acc, 200 / 3)
        self.assertIsNone(sel.term_accuracy({"e": rows["e1"]}))

    def damage_terms(self, rows, n):
        out = {i: dict(r) for i, r in rows.items()}
        ids = sorted(i for i, r in out.items() if r["cat"] == "work" and "kubernetes" in r["hypothesis"])[:n]
        for i in ids: out[i]["hypothesis"] = out[i]["hypothesis"].replace("kubernetes", "kubernetez")
        return out

    def test_term_accuracy_reported_in_verdict(self):
        base = {i: (dict(self.truth[i]) if r["cat"] == "work" else dict(r)) for i, r in self.base.items()}
        cand = self.damage_terms(self.fixed_all(), 1)
        v = self.v(cand, base=base)
        self.assertEqual(v["terms"]["n_terms"], 200); self.assertAlmostEqual(v["terms"]["base_acc"], 100.0); self.assertAlmostEqual(v["terms"]["cand_acc"], 99.5)
        self.assertAlmostEqual(v["terms"]["delta"], -0.5); self.assertTrue(v["guards"]["terms"]["ok"]); self.assertEqual(v["status"], "keep", v["reasons"])

    def test_term_accuracy_drop_over_one_point_discards(self):
        base = {i: (dict(self.truth[i]) if r["cat"] == "work" else dict(r)) for i, r in self.base.items()}
        cand = self.damage_terms(self.fixed_all(), 3)      # 3 of 200 terms: -1.5 points; work WER only +0.27, under its guard
        v = self.v(cand, base=base)
        self.assertLess(v["per_cat"]["work"]["delta"], sel.GUARDS["work"]); self.assertTrue(v["guards"]["work"]["ok"])
        self.assertAlmostEqual(v["terms"]["delta"], -1.5); self.assertFalse(v["guards"]["terms"]["ok"])
        self.assertEqual(v["status"], "discard"); self.assertTrue(any("guard terms" in r for r in v["reasons"]), v["reasons"])

    def test_exactly_one_point_drop_is_allowed(self):
        base = {i: (dict(self.truth[i]) if r["cat"] == "work" else dict(r)) for i, r in self.base.items()}
        cand = self.damage_terms(self.fixed_all(), 2)      # -1.0 exactly
        v = self.v(cand, base=base); self.assertAlmostEqual(v["terms"]["delta"], -1.0); self.assertTrue(v["guards"]["terms"]["ok"])

    def test_terms_loaded_from_locked_manifest_when_rows_lack_them(self):
        no_terms = make(terms=False)
        base = no_terms; cand = self.damage_terms(no_terms, 2)
        lk = {i: ["kubernetes", "deployment"] for i, r in no_terms.items() if r["cat"] == "work"}
        v = sel.run(base, cand, resamples=50, terms=lk)[0]
        self.assertEqual(v["terms"]["n_terms"], 200); self.assertAlmostEqual(v["terms"]["delta"], -1.0)
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "sel.jsonl"; p.write_text("".join(json.dumps({"id": i, "reference": r["reference"], "terms": ["kubernetes"]}) + "\n" for i, r in make().items() if r["cat"] == "work"))
            self.assertEqual(len(sel.read_terms(str(p))), N["work"])


class Sanity(Base):
    def test_empty_hyp_slack(self):
        def with_empty(n):
            c = self.fixed_all(); ks = [i for i, r in c.items() if r["cat"] == "cm"][:n]
            for k in ks: c[k]["hypothesis"] = ""
            return c
        base = self.base
        self.assertEqual(self.v(with_empty(2))["status"], "keep")
        v = self.v(with_empty(3)); self.assertEqual(v["status"], "discard"); self.assertTrue(any("empty" in r for r in v["reasons"]))

    def test_new_runaway_forces_discard(self):
        c = self.fixed_all(); k = next(i for i, r in c.items() if r["cat"] == "en_in"); c[k]["hypothesis"] = (c[k]["hypothesis"] + " ") * 5
        v = self.v(c); self.assertEqual(v["status"], "discard"); self.assertEqual(v["runaways"], 1); self.assertTrue(any("runaway" in r for r in v["reasons"]))

    def test_existing_runaway_in_baseline_is_not_new(self):
        base = {i: dict(r) for i, r in self.base.items()}; k = next(i for i, r in base.items() if r["cat"] == "en_in")
        base[k]["hypothesis"] = (base[k]["reference"] + " ") * 5
        c = fix(self.fixed_all(), self.truth, "en_in"); c[k]["hypothesis"] = (c[k]["reference"] + " ") * 5       # still a runaway, not new
        v = self.v(c, base=base); self.assertEqual(v["status"], "keep", v["reasons"])

    def test_devanagari_forces_discard(self):
        total = sum(N.values())      # 650 clips: 0.5% = 3.25
        c = self.fixed_all(); ks = [i for i, r in c.items() if r["cat"] == "native"][:4]
        for k in ks: c[k]["hypothesis"] += " नमस्ते"
        v = self.v(c); self.assertEqual(v["status"], "discard"); self.assertTrue(any("devanagari" in r for r in v["reasons"]))
        c = self.fixed_all(); c[ks[0]]["hypothesis"] += " नमस्ते"
        self.assertEqual(self.v(c)["status"], "keep")

    def test_vibe_runaway_counts(self):
        bv = {f"v{i}": {"id": f"v{i}", "cat": "cm", "reference": "a b c d", "hypothesis": "a b c d"} for i in range(4)}
        cv = {k: dict(v) for k, v in bv.items()}; cv["v1"]["hypothesis"] = "a b c d " * 4
        v = sel.run(self.base, self.fixed_all(), bv, cv, resamples=50)[0]; self.assertEqual(v["status"], "discard")

    def test_sanity_numbers(self):
        rows = {"a": {"id": "a", "cat": "en_in", "reference": "one two three four", "hypothesis": "one two three four five six seven eight nine ten eleven twelve thirteen"},
                "b": {"id": "b", "cat": "cm", "reference": "alpha beta", "hypothesis": ""}}
        s = sel.sanity(rows); self.assertEqual(s["empty_hyps"], 1); self.assertEqual(s["runaways"], 1); self.assertEqual(s["devanagari_hyps"], 0)


class Scoring(unittest.TestCase):
    def test_variant_folding_only_in_cm_hi(self):
        for cat, folded in (("cm", True), ("hi", True), ("en_in", False), ("native", False), ("work", False)):
            rows = {"a": {"id": "a", "cat": cat, "reference": "yeh nahi hai", "hypothesis": "yeh nahin hai"}}
            self.assertEqual(sel.wer_table(rows)[cat]["wer"] == 0, folded, cat)

    def test_hain_for_hai_is_an_error_in_cm(self):
        rows = {"a": {"id": "a", "cat": "cm", "reference": "yeh sahi hai", "hypothesis": "yeh sahi hain"}}
        self.assertGreater(sel.wer_table(rows)["cm"]["wer"], 0); self.assertEqual(sel.score.compute([dict(rows["a"], cat="hinglish")])[0]["hinglish"]["wer"], 0.0)

    def test_raw_wer_cases_match_pooled_formula(self):
        rows = {"a": {"id": "a", "cat": "en_in", "reference": "one two three four", "hypothesis": "one two x four"},
                "b": {"id": "b", "cat": "en_in", "reference": "alpha beta", "hypothesis": "alpha"}}
        self.assertEqual(sel.wer_table(rows)["en_in"]["wer"], round(100 * 2 / 6, 2))

    def test_deterministic_and_ci_contains_point(self):
        t = make(); base = damage(t, "cm", 40, 2); cand = fix(base, t, "cm")
        a = sel.run(base, cand, resamples=200)[0]; b = sel.run(base, cand, resamples=200)[0]
        self.assertEqual(a["ci_S"], b["ci_S"]); lo, hi = a["ci_S"]; self.assertLessEqual(lo, a["d_S"]); self.assertGreaterEqual(hi, a["d_S"])
        c = sel.run(base, cand, resamples=200, seed=5)[0]; self.assertNotEqual(a["ci_S"], c["ci_S"])

    def test_baseline_and_candidate_must_match(self):
        t = make(); c = {i: dict(r) for i, r in t.items()}; k = next(iter(c)); c[k]["reference"] = "other"
        with self.assertRaises(ValueError): sel.run(t, c, resamples=10)
        with self.assertRaises(ValueError): sel.run(t, dict(list(t.items())[:-1]), resamples=10)


class Cli(unittest.TestCase):
    def test_files_aliases_and_invalid_reference(self):
        t = make(); base = damage(t, "cm", 40, 2); cand = fix(base, t, "cm")
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            def w(name, rows, alias=False):
                with open(d / name, "w") as f:
                    for r in rows.values(): f.write(json.dumps({"id": r["id"], "cat": r["cat"], "ref": r["reference"], "hyp": r["hypothesis"]} if alias else r) + "\n")
                return str(d / name)
            lp = d / "lock.jsonl"; lp.write_text("".join(json.dumps({"id": i, "reference": r["reference"], "terms": r.get("terms")}) + "\n" for i, r in t.items()))
            b, c = w("b.jsonl", base, alias=True), w("c.jsonl", cand, alias=True)
            self.assertIsNone(sel.check_locked(sel.read_rows(b), str(lp), "b"))
            bad = {i: dict(r) for i, r in cand.items()}; bad[next(iter(bad))]["reference"] = "something else"
            self.assertIn("references differ", sel.check_locked(sel.read_rows(w("t.jsonl", bad)), str(lp), "t"))
            self.assertIn("id set differs", sel.check_locked(sel.read_rows(w("s.jsonl", dict(list(cand.items())[:-1]))), str(lp), "s"))
            out = subprocess.run([sys.executable, "-I", str(LOCKED / "select_v2.py"), "--base", b, "--cand", c, "--locked-sel", str(lp), "--out-dir", str(d / "o"), "--resamples", "100"],
                                 capture_output=True, text=True)
            self.assertEqual(out.returncode, 0, out.stderr); v = json.loads(out.stdout)
            self.assertEqual(v["status"], json.loads((d / "o/verdict.json").read_text())["status"]); self.assertTrue((d / "o/sanity.json").exists())
            self.assertEqual(v["terms"]["n_terms"], 200)          # terms came from the locked manifest
            bad_run = subprocess.run([sys.executable, "-I", str(LOCKED / "select_v2.py"), "--base", w("t2.jsonl", bad), "--cand", c, "--locked-sel", str(lp)], capture_output=True, text=True)
            self.assertEqual(bad_run.returncode, 3); self.assertEqual(json.loads(bad_run.stdout)["status"], "invalid")

    def test_vibe_md_flags_changes(self):
        bv = {f"v{i}": {"id": f"v{i}", "cat": "native", "reference": "a b c d", "hypothesis": "a b c d"} for i in range(4)}
        cv = {k: dict(v) for k, v in bv.items()}; cv["v2"]["hypothesis"] = "a b x d"
        md = sel.vibe_md(None, None, bv, cv)
        self.assertEqual([l.startswith("| * |") for l in md.splitlines() if l.startswith("| ") and "| v" in l].count(True), 1); self.assertIn("1 changed", md)


if __name__ == "__main__":
    unittest.main()
