"""Dictation EDITOR: the cleanup model conditioned on the speech model's own formatting (Stage 1, 29 Oct 2026).

The 24 Oct cleanup model (and ft3/disfl3) sees bare lowercase words and re-derives every mark, so it can only
lose the speech model's punctuation/casing. The editor keeps that information in its input and edits it:

  per word  [CASE marker if the ASR wrote it Cap/UPPER/MiXed] + pieces(lowercase word) + [MARK marker if the ASR put , . ? ! after it]
  outputs   9 logits at the word's last piece: punct after (NONE COMMA PERIOD QUESTION EXCL), case (LOWER CAP UPPER), DELETE

Unformatted input (lowercase, no marks) has no markers at all, so the same model also serves ASRs that do not format.
Marker ids are NEW embedding rows (32000..32006); the ONNX inputs stay input_ids/attention_mask.
Labels from (ASR hypothesis, reference) pairs: hyp/ref words aligned with difflib; matched words take the reference mark and
case; filler words (um/uh/...) the ASR wrote but the reference lacks are DELETE; other mismatches are masked.
Never logs or prints text."""
from __future__ import annotations
import difflib, re, sys, unicodedata
from pathlib import Path
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from uiui_cleanup import (Tokenizer, Word, words_in, chunks_for, apply_case, segments_for, is_structured,  # noqa: E402
                          finalize_punctuation, URL_RE, ORDINARY_PUNCT, PUNCT_CHARS)

IGN = -100
NONE, COMMA, PERIOD, QUESTION, EXCL = range(5)
LOWER, CAP, UPPER, MIXED = 0, 1, 2, 3
MARK_ID = {COMMA: 32000, PERIOD: 32001, QUESTION: 32002, EXCL: 32003}
CASE_ID = {CAP: 32004, UPPER: 32005, MIXED: 32006}
VOCAB = 32007
MARK_OF = {",": COMMA, ";": COMMA, ".": PERIOD, "?": QUESTION, "!": EXCL}
FILLERS = {"um", "umm", "uh", "uhh", "uhm", "hmm", "hm", "er", "erm", "ah", "aah", "mm", "mmm", "eh"}


def case_of(word: str) -> int:
    letters = [c for c in word if unicodedata.category(c).startswith("L")]
    if not letters: return LOWER
    if len(letters) > 1 and all(c.isupper() for c in letters): return UPPER
    if letters[0].isupper() and all(not c.isupper() for c in letters[1:]): return CAP
    if any(c.isupper() for c in letters): return MIXED
    return LOWER


def marks_of(source: str, words: list[Word]) -> list[int]:
    """The mark the text puts right after each word (first of , . ? ! ; in the gap; ':' and others -> NONE)."""
    out = []
    for i, w in enumerate(words):
        gap = source[w.end: words[i + 1].start if i + 1 < len(words) else len(source)]
        m = NONE
        for ch in gap:
            if ch in MARK_OF: m = MARK_OF[ch]; break
            if ch == ":" or ch.isspace(): continue
        out.append(m)
    return out


def is_formatted(text: str) -> bool:
    """Same rule as the app (DictationCleanupText.isFormatted)."""
    return any(c.isupper() for c in text) and any(c in ".,?!" for c in text)


def word_ids(words: list[Word], cases: list[int], marks: list[int], tok: Tokenizer, formatted: bool):
    """-> per-word id lists and the offset of the word's last piece inside its list (where its logits are read)."""
    out, emit, memo = [], [], {}
    for w, c, m in zip(words, cases, marks):
        if w.normalized not in memo: memo[w.normalized] = tok.encode(w.normalized)
        pcs = memo[w.normalized]
        pre = [CASE_ID[c]] if formatted and c in CASE_ID else []
        post = [MARK_ID[m]] if formatted and m in MARK_ID else []
        out.append(pre + pcs + post); emit.append(len(pre) + len(pcs) - 1)
    return out, emit


# ------------------------------------------------------------------ training labels
def pair_example(hyp: str, ref: str, tok: Tokenizer):
    """(ASR hypothesis, reference) -> (ids, punct, case, del) with labels on each word's last piece, or None."""
    hw, rw = words_in(hyp), words_in(ref)
    if not hw or not rw: return None
    hc, hm = [case_of(w.original) for w in hw], marks_of(hyp, hw)
    rc, rm = [case_of(w.original) for w in rw], marks_of(ref, rw)
    fmt = is_formatted(hyp)
    P, C, D = [IGN] * len(hw), [IGN] * len(hw), [IGN] * len(hw)
    sm = difflib.SequenceMatcher(a=[w.normalized for w in hw], b=[w.normalized for w in rw], autojunk=False)
    for op, a0, a1, b0, b1 in sm.get_opcodes():
        if op == "equal" or (op == "replace" and a1 - a0 == b1 - b0):
            for k in range(a1 - a0):
                i, j = a0 + k, b0 + k
                P[i] = rm[j]; C[i] = rc[j] if rc[j] != MIXED else IGN
                D[i] = IGN if hw[i].normalized in FILLERS else 0
        elif op == "insert":
            continue
        else:   # hyp-only words (delete) or unequal replace
            for i in range(a0, a1):
                if hw[i].normalized in FILLERS and op == "delete": D[i] = 1
                elif hw[i].normalized not in FILLERS: D[i] = 0
    return assemble(hw, hc, hm, P, C, D, tok, fmt)


def assemble(words, cases, marks, P, C, D, tok, formatted):
    per, emit = word_ids(words, cases, marks, tok, formatted)
    ids, pl, cl, dl = [0], [IGN], [IGN], [IGN]
    for wi, e, p, c, d in zip(per, emit, P, C, D):
        if not wi: return None
        n = len(wi); lab = [IGN] * n
        ids += wi
        pl += [p if k == e else IGN for k in range(n)]
        cl += [c if k == e else IGN for k in range(n)]
        dl += [d if k == e else IGN for k in range(n)]
    ids.append(2); pl.append(IGN); cl.append(IGN); dl.append(IGN)
    return ids, pl, cl, dl


def disfl_example(r: dict, tok: Tokenizer, rnd):
    """Synthetic disfluency record (words/del/punct/case of the clean target) -> formatted editor input:
    kept words carry the target case and (90%) the target mark, as a formatting ASR would write them;
    deleted words are lowercase, fillers followed by a comma half the time."""
    words = [Word(0, 0, w, unicodedata.normalize("NFKC", w).lower()) for w in r["words"]]
    cases, marks, P, C, D = [], [], [], [], []
    for w, d, p, c in zip(r["words"], r["del"], r["punct"], r["case"]):
        if d:
            cases.append(LOWER); marks.append(COMMA if w in FILLERS and rnd.random() < 0.5 else NONE)
            P.append(IGN); C.append(IGN); D.append(1)
        else:
            cc = c if c in (LOWER, CAP, UPPER) else LOWER
            cases.append(cc); marks.append(p if rnd.random() < 0.9 else NONE)
            P.append(p); C.append(c if c in (LOWER, CAP, UPPER) else IGN); D.append(0)
    return assemble(words, cases, marks, P, C, D, tok, True)


def text_example(text: str, tok: Tokenizer, tag_text):
    """Gold formatted text -> UNFORMATTED editor input (no markers) with its punct/case labels (the old cleanup task)."""
    ws = words_in(text)
    tags = tag_text(text)
    if not ws or len(tags) != len(ws): return None
    P = [t[1] for t in tags]; C = [t[2] if t[2] in (LOWER, CAP, UPPER) else IGN for t in tags]
    return assemble(ws, [LOWER] * len(ws), [NONE] * len(ws), P, C, [0] * len(ws), tok, False)


# ------------------------------------------------------------------ inference (mirrors what the app port will do)
class Editor:
    def __init__(self, predict, tok: Tokenizer | None = None, del_thr=0.5, max_del_frac=0.5):
        """predict(ids) -> logits [len(ids), 9]."""
        self.predict, self.tok, self.del_thr, self.max_del_frac = predict, tok or Tokenizer(), del_thr, max_del_frac

    def tags(self, source: str):
        words = words_in(source)
        if not words: return words, [], [], [], []
        cases, marks = [case_of(w.original) for w in words], marks_of(source, words)
        per, emit = word_ids(words, cases, marks, self.tok, is_formatted(source))
        preds = [None] * len(words)
        for ch in chunks_for([len(p) for p in per]):
            ids, pos = [0], {}
            for wi in ch.context:
                pos[wi] = len(ids) + emit[wi]; ids += per[wi]
            ids.append(2)
            if len(ids) > 128: raise ValueError("unsupportedLength")
            lg = self.predict(ids)
            for wi in ch.emission:
                row = lg[pos[wi]]
                preds[wi] = (int(np.argmax(row[:5])), int(np.argmax(row[5:8])), float(1 / (1 + np.exp(-row[8]))))
        return words, cases, marks, preds

    def edit(self, source: str) -> str:
        if not source.strip() or is_structured(source): return source
        try: words, cases, marks, preds = self.tags(source)
        except ValueError: return source
        if not words: return source
        dels = [p[2] > self.del_thr for p in preds]
        if sum(dels) > self.max_del_frac * len(words) or all(dels): dels = [False] * len(words)
        urls = [(m.start(), m.end()) for m in URL_RE.finditer(source)]
        out = [source[: words[0].start]]
        for i, w in enumerate(words):
            gap_end = words[i + 1].start if i + 1 < len(words) else len(source)
            if dels[i]:
                continue   # drop the word, its mark and its gap; the previous word's gap already holds the space
            p, c, _ = preds[i]
            raw = source[w.start:w.end]
            out.append(raw if cases[i] == MIXED else apply_case(raw, c))
            out.append(PUNCT_CHARS[p])
            for off in range(w.end, gap_end):
                ch = source[off]
                if ch not in ORDINARY_PUNCT or any(a <= off < b for a, b in urls): out.append(ch)
        res = "".join(out)
        res = re.sub(r"[ \t]{2,}", " ", res).strip() if res.strip() else source
        # a deleted first word leaves the new first word lowercase: the sentence start follows the model's case for it
        return res

    def clean(self, text: str, finalize=True) -> str:
        out = []
        for seg, sep in segments_for(text, 450):
            out.append((self.edit(seg) if seg and len(seg.encode()) <= 900 else seg) + sep)
        res = "".join(out)
        return finalize_punctuation(res) if finalize else res
