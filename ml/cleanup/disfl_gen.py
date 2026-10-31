#!/usr/bin/env python
"""Build the synthetic disfluency (DELETE-tag) dataset from clean gold sentences. Mac-only experiment.

Each record: words (ASR-style normalized, lowercase), del (0/1), cat (None|filler|rep|repair),
punct/case labels (on KEPT words, computed from the clean gold text; -100 on deleted words / mixed-case),
kind (pos|neg_tpl|neg_mined|clean|redup), clean (gold text), mix.
Outputs under data/disfl/. Deterministic (seeded).
"""
import json, random, re, sys
from pathlib import Path

from uiui_cleanup import words_in, is_structured
from tagging import tag_text, MIXED
import disfl_templates as T

HERE = Path(__file__).parent
OUT = HERE / "data/disfl"
IGN = -100
TERMS = HERE.parent / "data/workplace/terms.tsv"

PEOPLE = ["Rahul", "Priya", "Amit", "Neha", "Sanjay", "Meera", "Karan", "Ananya", "Vikram", "Divya", "Arjun", "Pooja", "Rohan", "Sneha", "Nitin", "Isha", "Kabir", "Tanvi"]
DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
MONTHS = ["January", "February", "March", "April", "June", "July", "August", "September", "October", "November", "December"]
CITIES = ["Pune", "Mumbai", "Delhi", "Bangalore", "Chennai", "Hyderabad", "Kolkata", "Jaipur"]
OBJS = ["the deck", "the report", "the invoice", "the proposal", "the budget sheet", "the contract", "the roadmap", "the agenda", "the draft", "the slides", "the checklist"]
HOURS = list(range(1, 12))

FILLER_PLAIN = ["um", "uh", "umm", "uhh", "er", "erm", "hmm", "ah"]
NUMW = set("one two three four five six seven eight nine ten eleven twelve".split())
REDUP_OK = set("very bye step day one again kabhi dheere thoda jaldi chhote chhota bar baar kuch bahut ghar dhire haan accha acha no ha".split())
FUNC_EN = "i the we to a and is can you it in of for that this my our please are will have be on at with".split()
FUNC_HI = "main hum kal aaj ko ka ki ke se hai toh yeh woh mujhe aap tum kya nahi mera".split()
NOT_AFTER_LIKE = set("i we you they he she it would d to do don't will looks look looked feel feels sounds seem seems something anything nothing just much more not me us them be would'nt what how".split())
LIKE_BEFORE = set("the a an my our your this that these those some really very so just totally almost pretty about three four five six ten twenty a".split()) | NUMW
SUBJ = set("i we it they he she you".split())
HI_SUBJ = set("main hum woh yeh wo ye aap tum mera meri".split())


def load_terms():
    names, cities = [], []
    for l in open(TERMS):
        p = l.rstrip("\n").split("\t")
        if len(p) > 3 and p[3] in ("fname_m", "fname_f") and " " not in p[0]:
            names.append(p[0])
        if len(p) > 3 and p[3] == "city" and " " not in p[0]:
            cities.append(p[0])
    return names, cities


def fill(tpl, rng):
    d = {}
    d["P"], d["P2"] = rng.sample(PEOPLE, 2)
    d["D"], d["D2"] = rng.sample(DAYS, 2)
    h, h2 = rng.sample(HOURS, 2)
    ap = rng.choice(["am", "pm"])
    d["H"], d["H2"] = str(h), str(h2)
    d["T"], d["T2"] = f"{h} {ap}", f"{h2} {ap}"
    d["O"] = rng.choice(OBJS)
    d["C"] = rng.choice(CITIES)
    d["N"] = str(rng.choice([2, 3, 4, 5, 8, 10, 12, 15, 20]))
    s = tpl
    for k, v in d.items():
        s = s.replace("{" + k + "}", v)
    return s


# ------------------------------------------------------------------ record building
def make_record(clean, ins, kind, mix, rid, extra=None):
    """clean gold text + insertions {clean_word_index: [(word, cat), ...]} -> record."""
    ws = words_in(clean)
    tags = tag_text(clean)
    if not ws:
        return None
    W, P, C = [], [], []
    for w, (orig, p, c) in zip(ws, tags):
        W.append(w.normalized)
        P.append(p)
        C.append(IGN if c == MIXED else c)
    words, dels, cats, punct, case = [], [], [], [], []
    for i in range(len(W) + 1):
        for (w, cat) in ins.get(i, []):
            words.append(w); dels.append(1); cats.append(cat); punct.append(IGN); case.append(IGN)
        if i < len(W):
            words.append(W[i]); dels.append(0); cats.append(None); punct.append(P[i]); case.append(C[i])
    r = {"id": rid, "kind": kind, "mix": mix, "clean": clean, "words": words, "del": dels, "cat": cats,
         "punct": punct, "case": case}
    if extra:
        r.update(extra)
    return r


# ------------------------------------------------------------------ template records
MARK = re.compile(r"\[\[([fpr]):(.*?)\]\]")
CAT = {"f": "filler", "r": "rep", "p": "repair"}


def template_record(tpl, rng, kind, rid):
    s = fill(tpl, rng)
    clean, ins, pos = "", {}, 0
    plain_parts, last = [], 0
    prefix = ""
    for m in MARK.finditer(s):
        prefix += s[last:m.start()]
        idx = len(words_in(prefix))
        toks = [w.normalized for w in words_in(m.group(2))]
        if m.group(1) == "r":  # always delete the EARLIER copy (same as injected repetitions)
            before = [w.normalized for w in words_in(prefix)]
            if len(toks) <= len(before) and before[len(before) - len(toks):] == toks:
                idx -= len(toks)
        ins.setdefault(idx, []).extend((t, CAT[m.group(1)]) for t in toks)
        last = m.end()
    prefix += s[last:]
    clean = re.sub(r"\s+", " ", prefix).strip()
    clean = re.sub(r"\s+([,.?!])", r"\1", clean)
    # capitalise the first letter if the template started with a deleted token
    if clean and clean[0].islower() and s.startswith("[["):
        clean = clean[0].upper() + clean[1:]
    mix = "hinglish" if re.search(r"\b(kal|hai|ko|kya|nahi|main|hum|woh|aaj|ye|yeh|mujhe|matlab|acha|haan|toh|aap|tum|na)\b", clean.lower()) else "en"
    return make_record(clean, ins, kind, mix, rid, {"tpl": 1})


# ------------------------------------------------------------------ injectors
def pick_filler(rng, mix):
    if mix == "hinglish":
        r = rng.random()
        if r < 0.30: return rng.choice(FILLER_PLAIN)
        if r < 0.55: return "matlab"
        if r < 0.65: return "acha"
        if r < 0.75: return "haan"
        if r < 0.87: return "na"
        if r < 0.92: return "woh"
        if r < 0.96: return "like"
        return "you know"
    r = rng.random()
    if r < 0.50: return rng.choice(FILLER_PLAIN)
    if r < 0.63: return "like"
    if r < 0.73: return "you know"
    if r < 0.82: return "i mean"
    if r < 0.90: return "basically"
    if r < 0.96: return "actually"
    return "so"


def boundary_ok(f, i, W, P, mix):
    """May filler f be inserted before clean word i (i == len(W): end)? Conservative, context-based."""
    n = len(W)
    prev = W[i - 1] if i > 0 else None
    nxt = W[i] if i < n else None
    clause_start = i == 0 or P[i - 1] in (1, 2, 3, 4)
    if f in FILLER_PLAIN:
        return True
    if f == "like":
        if nxt is None or prev in NOT_AFTER_LIKE:
            return False
        return nxt in LIKE_BEFORE or nxt.isdigit() or (clause_start and i > 0)
    if f in ("you know", "i mean"):
        if prev in ("do", "did", "if", "as", "i", "we", "they", "what", "that", "let", "don't", "to", "will", "can", "would", "should"):
            return False
        if nxt is None:
            return i >= 4
        return clause_start and (nxt in SUBJ or nxt in ("the", "this", "that", "so", "but", "and") and False or nxt in HI_SUBJ) and nxt not in ("you",)
    if f in ("basically", "actually"):
        return i > 0 and prev in SUBJ and nxt not in (None, "have", "has", "had") or (clause_start and i > 0 and nxt in SUBJ)
    if f == "so":
        return False  # only used in clusters, see inject_filler
    if f == "matlab":
        if prev in ("iska", "uska", "is", "us", "ka", "koi", "kuch", "ye", "yeh", "kya"):
            return False
        if nxt in ("kya", "hai", "ki", "hota", "nikalta") and False:
            return False
        return i > 0 and i < n - 1 or (i == 0 and nxt in HI_SUBJ)
    if f == "acha":  # sentence-initial "acha" is an acknowledgement (kept); only mid-sentence hesitation is deleted
        return i > 0 and (nxt in ("toh", "to", "ki") or (nxt in HI_SUBJ and not clause_start))
    if f == "haan":
        return i > 0 and (prev in ("ki", "toh", "to", "aur", "par", "lekin") or nxt in HI_SUBJ and clause_start) and nxt is not None
    if f == "woh":
        return False  # cluster only
    if f == "na":
        return i > 0 and i < n and prev in ("main", "woh", "yeh", "hum", "mera", "meri", "kal", "aaj", "wo", "ye", "tum", "aap", "toh", "report", "client") and nxt is not None
    return False


def inject_filler(rng, W, P, ins, mix, n_try=12):
    f = pick_filler(rng, mix)
    n = len(W)
    if f == "so":
        # only inside a cluster at the very start: "so um ..." / "um so ..."
        k = rng.choice(FILLER_PLAIN)
        ins.setdefault(0, []).extend(rng.choice([[("so", "filler"), (k, "filler")], [(k, "filler"), ("so", "filler")]]))
        return True
    cands = [i for i in range(n + 1) if boundary_ok(f, i, W, P, mix)]
    if not cands:
        f = rng.choice(FILLER_PLAIN)
        cands = list(range(n + 1))
        # bias to start / early / clause boundaries
        w = [3 if (i == 0 or (i > 0 and P[i - 1] in (1, 2, 3, 4))) else 1 for i in cands]
        i = rng.choices(cands, w)[0]
    else:
        i = rng.choice(cands)
    if f in FILLER_PLAIN:
        w = [3 if (j == 0 or (j > 0 and P[j - 1] in (1, 2, 3, 4))) else (0.4 if j == n else 1) for j in cands] if False else None
    toks = f.split()
    cluster = [(t, "filler") for t in toks]
    # clusters: plain + discourse ("um like"), or woh + filler for Hinglish
    r = rng.random()
    if f not in FILLER_PLAIN and r < 0.15:
        cluster = [(rng.choice(FILLER_PLAIN), "filler")] + cluster
    elif f in FILLER_PLAIN and r < 0.12:
        cluster = cluster + [(rng.choice(FILLER_PLAIN), "filler")]
    elif mix == "hinglish" and f in FILLER_PLAIN and r < 0.25:
        cluster = [("woh", "filler")] + cluster
    ins.setdefault(i, []).extend(cluster)
    return True


def inject_rep(rng, W, P, ins, mix):
    n = len(W)
    fun = FUNC_HI if mix == "hinglish" else FUNC_EN
    idx = [i for i in range(n) if W[i] not in REDUP_OK and not W[i][0].isdigit() and (i == 0 or W[i - 1] != W[i]) and (i + 1 >= n or W[i + 1] != W[i])]
    if not idx:
        return False
    pref = [i for i in idx if W[i] in fun]
    i = rng.choice(pref) if pref and rng.random() < 0.7 else rng.choice(idx)
    k = rng.choices([1, 2, 3], [0.70, 0.22, 0.08])[0]
    k = min(k, n - i)
    span = W[i:i + k]
    if any(w[0].isdigit() for w in span) or any(P[j] != 0 for j in range(i, i + k - 1)):
        k = 1; span = W[i:i + 1]
    times = 1 + (rng.random() < 0.12)
    cl = [(w, "rep") for _ in range(times) for w in span]
    if rng.random() < 0.18:  # filler between the copies: "i um i think"
        cl = cl + [(rng.choice(FILLER_PLAIN), "filler")]
    ins.setdefault(i, []).extend(cl)
    return True


EN_CUES = [["no"], ["sorry"], ["i", "mean"], ["no", "wait"], ["actually", "no"], ["or", "rather"], ["make", "that"], ["wait", "no"]]
HI_CUES = [["nahi", "nahi"], ["nahi"], ["matlab"], ["sorry"], ["i", "mean"], ["arre"], ["ruko"]]


def inject_repair(rng, W, P, ins, mix, names, cities):
    n = len(W)
    cands = []
    for i, w in enumerate(W):
        if w in [d.lower() for d in DAYS] and True:
            cands.append((i, "day"))
        elif w in [m.lower() for m in MONTHS]:
            cands.append((i, "month"))
        elif w.isdigit() and i + 1 < n and W[i + 1] in ("am", "pm"):
            cands.append((i, "time"))
        elif w.isdigit() and len(w) <= 2:
            cands.append((i, "num"))
        elif w in NUMW:
            cands.append((i, "numw"))
        elif w.capitalize() in names_set(names) and P[i] != 0 or w.capitalize() in names_set(names):
            cands.append((i, "name"))
        elif w.capitalize() in names_set(cities):
            cands.append((i, "city"))
    if not cands:
        return False
    i, typ = rng.choice(cands)
    w = W[i]
    if typ == "day":
        alt = [d.lower() for d in DAYS if d.lower() != w]
    elif typ == "month":
        alt = [m.lower() for m in MONTHS if m.lower() != w]
    elif typ in ("time", "num"):
        alt = [str(x) for x in range(1, 13) if str(x) != w] if typ == "time" else [str(x) for x in (2, 3, 4, 5, 6, 8, 10, 12, 15, 20, 30) if str(x) != w]
    elif typ == "numw":
        alt = [x for x in NUMW if x != w]
    elif typ == "name":
        alt = [x.lower() for x in names if x.lower() != w]
    else:
        alt = [x.lower() for x in cities if x.lower() != w]
    a = rng.choice(alt)
    reparandum = [a]
    if typ == "time" and rng.random() < 0.5:
        reparandum = [a, W[i + 1]]  # "3 pm no 4 pm"
    cue = rng.choice(HI_CUES if mix == "hinglish" and rng.random() < 0.8 else EN_CUES)
    ins.setdefault(i, []).extend([(t, "repair") for t in reparandum + cue])
    return True


NAMES_CACHE = {}


def names_set(lst):
    k = id(lst)
    if k not in NAMES_CACHE:
        NAMES_CACHE[k] = set(x for x in lst)
    return NAMES_CACHE[k]


def inject(clean, mix, rng, names, cities, plan):
    """plan: list of phenomena e.g. ['filler','rep']. -> record or None."""
    ws = words_in(clean)
    if len(ws) < 3 or len(ws) > 45:
        return None
    tags = tag_text(clean)
    W = [w.normalized for w in ws]
    P = [t[1] for t in tags]
    ins = {}
    ok = False
    for ph in plan:
        if ph == "filler":
            ok |= inject_filler(rng, W, P, ins, mix)
        elif ph == "rep":
            ok |= inject_rep(rng, W, P, ins, mix)
        elif ph == "repair":
            ok |= inject_repair(rng, W, P, ins, mix, names, cities)
    if not ins:
        return None
    return ins


def sample_plan(rng):
    r = rng.random()
    if r < 0.42: return ["filler"]
    if r < 0.52: return ["filler", "filler"]
    if r < 0.70: return ["rep"]
    if r < 0.88: return ["repair"]
    return rng.choice([["filler", "rep"], ["filler", "repair"], ["rep", "repair"], ["filler", "filler", "rep"]])


TARGETS = set("like so actually basically matlab woh haan acha na mean know sorry no".split())
REDUPS = ["very very", "bye bye", "kabhi kabhi", "dheere dheere", "thoda thoda", "jaldi jaldi", "chhote chhote", "bahut bahut", "ghar ghar", "step by step"]


def redup_record(rng, rid):
    """Legit repetitions that must be kept."""
    P_, = [rng.choice(PEOPLE)]
    ex = [
        ("It was a very very long call with %s." % P_, "en"), ("The kids said bye bye to %s." % P_, "en"),
        ("Kabhi kabhi %s late aata hai." % P_, "hinglish"), ("%s dheere dheere kaam seekh raha hai." % P_, "hinglish"),
        ("Thoda thoda karke %s ne sab finish kiya." % P_, "hinglish"), ("Jaldi jaldi kaam khatam karo." , "hinglish"),
        ("Bahut bahut shukriya, %s." % P_, "hinglish"), ("We did it step by step with %s." % P_, "en"),
        ("Chhote chhote tasks pehle karo.", "hinglish"), ("%s had had enough of the delays." % P_, "en"),
    ]
    clean, mix = rng.choice(ex)
    return make_record(clean, {}, "redup", mix, rid)


# ------------------------------------------------------------------ main builds
def load_jsonl(p):
    return [json.loads(l) for l in open(p) if l.strip()]


def build_split(src_rows, rng, names, cities, n_pos_per_row, tag, neg_mined_cap, tpl_pos, tpl_neg, n_tpl_pos, n_tpl_neg, n_redup):
    recs, i = [], 0
    clean_texts = []
    for r in src_rows:
        mix = r.get("mix", "en")
        for _ in range(n_pos_per_row):
            plan = sample_plan(rng)
            ins = inject(r["text"], mix, rng, names, cities, plan)
            if ins is None:
                continue
            rec = make_record(r["text"], ins, "pos", mix, f"{tag}-pos-{i:06d}")
            i += 1
            if rec: recs.append(rec)
    # mined hard negatives: real sentences containing ambiguous words, unchanged
    mined = []
    for r in src_rows:
        ws = set(re.findall(r"[\w']+", r["text"].lower()))
        if ws & TARGETS:
            mined.append(r)
    rng.shuffle(mined)
    for j, r in enumerate(mined[:neg_mined_cap]):
        rec = make_record(r["text"], {}, "neg_mined", r.get("mix", "en"), f"{tag}-nm-{j:06d}")
        if rec: recs.append(rec)
    for j in range(n_tpl_pos):
        recs.append(template_record(rng.choice(tpl_pos), rng, "pos", f"{tag}-tp-{j:06d}"))
    for j in range(n_tpl_neg):
        t = rng.choice(tpl_neg)
        rec = template_record(t, rng, "neg_tpl", f"{tag}-tn-{j:06d}")
        recs.append(rec)
    for j in range(n_redup):
        recs.append(redup_record(rng, f"{tag}-rd-{j:06d}"))
    return recs


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    names, cities = load_terms()
    names = sorted(set(names) | set(PEOPLE))
    cities = sorted(set(cities) | set(CITIES))
    nt = load_jsonl(HERE / "data/natural/natural_train.jsonl")
    slot = [r for r in load_jsonl(HERE / "data/natural/train_nat_plus_slot.jsonl") if r["id"].startswith("ntr") is False]
    hi = load_jsonl(HERE / "data/hinglish/train_hinglish.jsonl")
    ne = load_jsonl(HERE / "data/natural/natural_eval.jsonl")
    he = load_jsonl(HERE / "data/hinglish/eval_hinglish.jsonl")
    # leakage guard: no eval sentence text in any train source
    ev_texts = {r["text"] for r in ne + he}
    assert not (ev_texts & {r["text"] for r in nt + slot + hi}), "train/eval overlap"
    rng = random.Random(20261028)
    slot_all = slot
    tr = build_split(nt + hi, rng, names, cities, 1, "dtr", 0, T.POS_TRAIN, T.NEG_TRAIN, 1400, 5200, 400)
    # extra mined hard negatives (real sentences with like/so/na/woh/know/sorry/no...) from the slot corpus
    mined = [r for r in slot_all + nt + hi if set(re.findall(r"[\w']+", r["text"].lower())) & TARGETS]
    rng.shuffle(mined)
    tr += [make_record(r["text"], {}, "neg_mined", r.get("mix", "en"), f"dnm-{j:06d}") for j, r in enumerate(mined[:1500])]
    ev_src = ne + he
    random.Random(5).shuffle(ev_src)
    ev = build_split(ev_src[:1000], random.Random(99), names, cities, 1, "dev", 0, T.POS_EVAL, T.NEG_EVAL, 200, 1100, 100)
    mined_e = [r for r in ev_src[1000:] if set(re.findall(r"[\w']+", r["text"].lower())) & TARGETS]
    ev += [make_record(r["text"], {}, "neg_mined", r.get("mix", "en"), f"dem-{j:05d}") for j, r in enumerate(mined_e)]
    clean_ev = [make_record(r["text"], {}, "clean", r.get("mix", "en"), f"dcl-{k:05d}") for k, r in enumerate(ne + he)]
    clean_ev = [c for c in clean_ev if c]

    def composed(src, tpls, n, rg, tag):
        out = []
        for j in range(n):
            t = template_record(rg.choice(tpls), rg, "neg_tpl", "x")
            r = rg.choice(src)
            a, b = (t["clean"], r["text"]) if rg.random() < 0.5 else (r["text"], t["clean"])
            rec = make_record(a + " " + b, {}, "neg_comp", "hinglish" if "hinglish" in (t["mix"], r.get("mix")) else "en", f"{tag}-{j:06d}")
            if rec and len(rec["words"]) <= 45: out.append(rec)
        return out
    tr += composed(nt + hi, T.NEG_TRAIN, 3800, rng, "dnc")
    ev += composed(ev_src, T.NEG_EVAL, 1000, random.Random(31), "dec")

    def dedupe(rows):
        seen, out = set(), []
        for r in rows:
            k = (tuple(r["words"]), tuple(r["del"]))
            if k in seen: continue
            seen.add(k); out.append(r)
        return out
    tr, ev = dedupe(tr), dedupe(ev)
    rng.shuffle(tr)
    for name, rows in (("train", tr), ("eval", ev), ("eval_clean", clean_ev)):
        with open(OUT / f"{name}.jsonl", "w") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
    import collections
    def stats(rows):
        c = collections.Counter(r["kind"] for r in rows)
        pos_tok = collections.Counter(cat for r in rows for cat in r["cat"] if cat)
        keep_tok = sum(1 for r in rows for d in r["del"] if d == 0)
        return {"rows": len(rows), "kinds": dict(c), "deleted_tokens_by_cat": dict(pos_tok), "keep_tokens": keep_tok,
                "hinglish_rows": sum(r["mix"] == "hinglish" for r in rows)}
    st = {n: stats(r) for n, r in (("train", tr), ("eval", ev), ("eval_clean", clean_ev))}
    json.dump(st, open(OUT / "stats.json", "w"), indent=1)
    print(json.dumps(st, indent=1))


if __name__ == "__main__":
    main()
