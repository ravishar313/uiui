"""KenLM wrapper with the small interface tdt_decode.TDTDecoder expects: init_state(), score(state, tok) -> ln p, advance(state, tok).
Words are the BPE token ids written as decimal strings (see lm/prepare_text.py).  KenLM scores are log10; converted to natural log."""
from __future__ import annotations
import math, sys, os

LN10 = math.log(10.0)


class KenLMScorer:
    def __init__(self, path: str, bos: bool = True):
        from uiui_root import ROOT
        sys.path.insert(0, ROOT + "/dec-dev/pylib")
        import kenlm
        self.kenlm = kenlm
        self.lm = kenlm.Model(path)
        self._scratch = kenlm.State()
        self.bos = bos
        self._names = {}

    def _w(self, y: int) -> str:
        w = self._names.get(y)
        if w is None: w = self._names[y] = str(y)
        return w

    def init_state(self):
        s = self.kenlm.State()
        if self.bos: self.lm.BeginSentenceWrite(s)
        else: self.lm.NullContextWrite(s)
        return s

    def score(self, state, y: int) -> float:
        return self.lm.BaseScore(state, self._w(y), self._scratch) * LN10

    def advance(self, state, y: int):
        out = self.kenlm.State()
        self.lm.BaseScore(state, self._w(y), out)
        return out

    @property
    def order(self): return self.lm.order
