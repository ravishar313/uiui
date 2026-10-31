"""Lexicon-lookup romanization of Devanagari / mixed text (fast, deterministic)."""
import re, sys, os
sys.path.insert(0, os.path.dirname(__file__))
from lexlib import *

from uiui_root import ROOT
LEXICON_TSV = ROOT + "/data/lexicon/lexicon.tsv"
_lex = None
OOV = set()


def lexicon():
    global _lex
    if _lex is None:
        _lex = {}
        for i, l in enumerate(open(LEXICON_TSV, encoding="utf-8")):
            if i == 0:
                continue
            p = l.rstrip("\n").split("\t")
            _lex[p[0]] = p[4]
    return _lex


def word(w):
    w = norm_deva(w)
    lx = lexicon()
    r = lx.get(w)
    if r is None:
        OOV.add(w)
        r = LEX.get(w) or det(w)
    return r


def clean_src(t):
    t = re.sub(r"<[^>]*>|\[[^\]]*\]|\{[^}]*\}", " ", t)          # tags / glosses
    t = t.replace("।", ". ").replace("॥", ". ").translate(DIGITS)
    t = re.sub(r"[“”\"()\[\]*_~`]", " ", t).replace("’", "'").replace("‘", "'")
    t = re.sub(r"\s+", " ", t).strip()
    return t


def roman(text, style="train"):
    """style=train: keep source punctuation (. , ? !) and sentence-case; style=eval: lowercase, no punctuation."""
    t = clean_src(text)
    out = []
    for d, p in tokens(t):
        out.append(word(p) if d else p)
    r = "".join(out)
    r = re.sub(r"\s+", " ", r).strip()
    if style == "eval":
        r = re.sub(r"[.,?!;:]", " ", r).replace("-", " ").replace("'", "'")
        r = re.sub(r"(?<![A-Za-z0-9])'|'(?![A-Za-z0-9])", " ", r)
        return " ".join(r.split())
    return sentence_case(r)


def sentence_case(r):
    r = re.sub(r"\s+([.,?!;:])", r"\1", r)
    r = re.sub(r"^[\s.,?!;:'-]+", "", r)
    r = re.sub(r"\bi\b(?!\.)", "I", r)
    r = re.sub(r"\bi'(m|ll|d|ve)\b", lambda m: "I'" + m.group(1), r)
    r = re.sub(r"(^|[.?!]\s+)([a-z])", lambda m: m.group(1) + m.group(2).upper(), r)
    return r
