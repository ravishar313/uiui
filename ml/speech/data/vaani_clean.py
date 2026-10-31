"""Vaani transcript cleaning -> Roman reference. Conventions handled (from inspecting the data; the dataset card documents none):
  <noise>..</noise>, <static noise>, <horn>, <music>, <bird_sound>... wrap speech over background noise: tag removed, words kept.
  <pause>/<PAUSE>: removed.  [breathing] [inhaling] [lip smacking] [cough] [click] ...: non-speech events removed.
  [unintelligible] [inaudible] [intangible] [intelligible] [faltering]: clip dropped.  tags/events about other people talking/yelling/crying: clip dropped
  (background voices may be inside the span).  '--' attached to a word = cut-off word: clip dropped; standalone '--' removed.
  {english}: gloss after a Devanagari-written English word.  Used (as the English spelling) only if it is a known English word and phonetically close to
  the Devanagari word; else dropped and the Devanagari word is romanized.  {देवनागरी}: spelling correction, dropped (spoken form kept).
  T_V {T_V}: underscored acronym -> TV.  '|' = danda.  hyphens and underscores -> spaces."""
import re, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import romlib, lexlib

DEVA = re.compile(r"[ऀ-ॿ]")
UNINTEL = re.compile(r"\[(unintelligible|inaudible|intangible|intelligible|faltering|unclear|unk|unknown)[^\]]*\]|<(unintelligible|inaudible|unclear|unk)[^>]*>", re.I)
AMBIG = re.compile(r"[<\[/](?:[a-z_ ]*(?:talk|yell|cry|shout|scream|sing|song|whisper|speak|conversation|voice)[a-z_ ]*)[>\]]", re.I)
PAUSE = re.compile(r"</?pause>", re.I)
TAG = re.compile(r"</?[A-Za-z][A-Za-z_ ]{0,40}>")
EVENT = re.compile(r"\[([^\]]{0,40})\]")
BREATH = re.compile(r"breath|inhal|exhal|lip|smack|throat|sniff|click|pause|cough|sneez|yawn|nose", re.I)
_vocab = None


def vocab():
    global _vocab
    if _vocab is None:
        _vocab = set()
        for p in (os.path.join(os.environ.get("UIUI_ML_ROOT") or "workspace", "data/stage/english_vocab.txt"),):
            if os.path.exists(p):
                _vocab = set(open(p).read().split())
    return _vocab


def rom_candidate(d):
    d = lexlib.norm_deva(d)
    return romlib.lexicon().get(d) or lexlib.LEX.get(d) or lexlib.det(d)


def gloss_ok(g, d):
    return g in vocab() and len(g) >= 3 and lexlib.sim(g, rom_candidate(d)) >= 0.5


def clean(raw):
    """-> (text_for_romlib or None, reason or None, stats dict)"""
    t = raw.replace("‍", "").replace("‌", "")
    if UNINTEL.search(t):
        return None, "unintelligible", {}
    if AMBIG.search(t):
        return None, "other_voices_tag", {}
    if re.search(r"[^\s\-]--", t) or re.search(r"(?:^|\s)[क-ह]\s+--", t):
        return None, "cutoff_word", {}
    t = PAUSE.sub(" ", t)
    ev = [e for e in EVENT.findall(t)]
    nonbreath = [e for e in ev if not BREATH.search(e)]
    t = EVENT.sub(" ", t)
    t = TAG.sub(" ", t)
    if "<" in t or ">" in t:
        return None, "unknown_tag", {}
    t = t.replace("|", ". ").replace("--", " ")
    t = re.sub(r"\s*\{", " {", t)
    t = re.sub(r"\}\s*", "} ", t)
    toks = t.split()
    out = []                       # (text, protected)
    for tok in toks:
        m = re.fullmatch(r"\{([^{}]*)\}", tok) if tok.startswith("{") and tok.endswith("}") else None
        if not tok.startswith("{") and "{" in tok:
            return None, "bad_brace", {}
        if tok.startswith("{") and not m:
            # multiword brace spanning tokens: collect until closing
            out.append((tok, False)); continue
        if not m:
            out.append((tok, False)); continue
        c = m.group(1).strip()
        if not c or DEVA.search(c):
            continue
        if re.fullmatch(r"[A-Za-z](?:_[A-Za-z])+", c) and out and DEVA.search(out[-1][0]) and not out[-1][1]:
            out[-1] = (c.replace("_", "").upper(), True); continue
        g = [w for w in re.split(r"[\s_]+", c.lower()) if w]
        k = len(g)
        if k and k <= 3 and len(out) >= k and all(DEVA.search(o[0]) and not o[1] for o in out[-k:]):
            prev = [re.sub(r"[^ऀ-ॿ]", "", o[0]) for o in out[-k:]]
            if all(re.fullmatch(r"[a-z']+", w) and gloss_ok(w, d) for w, d in zip(g, prev)):
                trail = "".join(re.findall(r"[.,?!।॥]+$", out[-1][0]))
                out[-k:] = [(w, True) for w in g]
                if trail:
                    out[-1] = (out[-1][0] + trail, True)
    # multiword brace leftovers
    txt = " ".join(o[0] for o in out)
    txt = re.sub(r"\{[^{}]*\}", " ", txt)
    if "{" in txt or "}" in txt:
        return None, "bad_brace", {}
    txt = txt.replace("_", " ")
    txt = re.sub(r"(?<=\S)-(?=\S)|\s-\s|^-|-$", " ", txt)
    txt = re.sub(r"[“”\"()*~`<>]", " ", txt)
    txt = re.sub(r"\s+", " ", txt).strip()
    nwords = len(re.findall(r"[\w']+", txt))
    st = dict(words=nwords, events=len(nonbreath))
    if nwords < 2:
        return None, "too_few_words", st
    if len(nonbreath) * 2 > nwords:
        return None, "mostly_noise", st
    return txt, None, st


def roman(raw):
    t, why, st = clean(raw)
    if t is None:
        return None, why
    return romlib.roman(t), None
