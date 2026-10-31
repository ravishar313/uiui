"""Gold text -> ASR-style input and per-word (punct, case) labels, using the app's word regex."""
from __future__ import annotations

import regex as re

from uiui_cleanup import words_in

# Class of the *shape* of a gold word. Only LOWER/CAP/UPPER are representable by the model;
# MIXED (iPhone, GitHub, McKinsey) cannot be produced by the app (applyCase keeps only internal
# capitals already present in the lowercased ASR text, i.e. never).
LOWER, CAP, UPPER, MIXED = 0, 1, 2, 3

_DASH = re.compile(r"[—–]")


def strip_input(text: str) -> str:
    """Simulate Phonon-style ASR output: lowercase, no punctuation (matches evalsets/*: 'lowercase, no
    punctuation'). Keeps punctuation that is lexical: . , : between two alphanumerics (5.5, 3,00,000,
    1:1, v2.1), apostrophes/hyphens inside words, and symbols (₹ % & #)."""
    t = text.replace("’", "'")
    t = _DASH.sub(" ", t)
    t = re.sub(r"[\"“”«»()\[\]]", "", t)

    def repl(m):
        s, e = m.span()
        if e - s == 1 and s > 0 and e < len(t) and t[s - 1].isalnum() and t[e].isalnum():
            return m.group(0)
        return " "

    t = re.sub(r"[.,;:!?]+", repl, t)
    return re.sub(r"\s+", " ", t).strip().lower()


def case_class(word: str) -> int:
    letters = [c for c in word if c.isalpha()]
    if not letters or all(c.islower() for c in letters):
        return LOWER
    if all(c.isupper() for c in letters):
        return UPPER if (len(letters) >= 2 or len(word) > len(letters)) else CAP  # Q3 -> UPPER, I -> CAP
    if letters[0].isupper() and all(c.islower() for c in letters[1:]):
        return CAP
    return MIXED


def punct_class(gap: str) -> int:
    """Label for the gap after a word: first sentence-ish mark wins (? and ! over . over ,). ';' counts
    as COMMA (the app removes it; closest representable); ':' as NONE."""
    best = 0
    rank = {0: 0, 1: 1, 2: 2, 3: 3, 4: 3}
    for ch in gap:
        c = {",": 1, ";": 1, ".": 2, "?": 3, "!": 4}.get(ch, 0)
        if c and (best == 0 or rank[c] > rank[best]):
            best = c
    return best


def tag_text(text: str):
    """-> list of (word_original, punct_class, case_class) for each app-word of `text`."""
    ws = words_in(text)
    out = []
    for i, w in enumerate(ws):
        gap_end = ws[i + 1].start if i + 1 < len(ws) else len(text)
        gap = text[w.end:gap_end]
        # a ':' or '.' that is lexical inside "1:1" never reaches here (it is between words only when
        # the regex split on it); treat as NONE.
        out.append((w.original, punct_class(gap), case_class(w.original)))
    return out
