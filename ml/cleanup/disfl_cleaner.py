"""Cleanup pipeline with the DELETE head: same as uiui_cleanup.Cleaner, plus word deletion.
Backends: torch (9-logit HF ckpt). Deletion = sigmoid(logit8) > thr on the final piece of each word.
Safety: a segment where >max_frac of words would be deleted, or all words, is left undeleted."""
from __future__ import annotations
import numpy as np
import torch
from uiui_cleanup import (Tokenizer, words_in, chunks_for, accepted, segments_for, apply_case, finalize_punctuation,
                          PUNCT_CHARS, ORDINARY_PUNCT, URL_RE, WindowError, TorchBackend)


class DisflBackend(TorchBackend):
    def predict(self, ids):
        t = self.torch
        a = t.tensor([ids], dtype=t.long, device=self.device)
        with t.no_grad():
            return self.model(input_ids=a, attention_mask=t.ones_like(a)).logits[0].float().cpu().numpy()


class DisflCleaner:
    def __init__(self, ckpt, thr=0.5, max_frac=0.5, device="cpu"):
        self.be = DisflBackend(ckpt, device); self.tok = Tokenizer(); self.thr = thr; self.max_frac = max_frac

    def tags(self, source):
        words = words_in(source)
        if not words: return words, [], np.zeros(0)
        pieces, memo = [], {}
        for w in words:
            if w.normalized in memo: pieces.append(pieces[memo[w.normalized]])
            else:
                memo[w.normalized] = len(pieces); pieces.append(self.tok.encode(w.normalized))
        preds, dprob = [], []
        for ch in chunks_for([len(p) for p in pieces]):
            ids = [0]
            for wi in ch.context: ids.extend(pieces[wi])
            ids.append(2)
            if len(ids) > 128: raise WindowError("unsupportedLength")
            lg = self.be.predict(ids)
            cur = 0
            for wi in ch.context:
                cur += len(pieces[wi])
                if wi not in ch.emission: continue
                row = lg[cur]
                preds.append((int(np.argmax(row[:5])), int(np.argmax(row[5:8]))))
                dprob.append(float(1 / (1 + np.exp(-row[8]))))
        return words, preds, np.array(dprob)

    def delete_mask(self, dprob):
        m = dprob > self.thr
        if m.all() or m.sum() > self.max_frac * len(m): return np.zeros_like(m)
        return m

    @staticmethod
    def reconstruct(source, words, preds, dele):
        out = [source[: words[0].start]]
        urls = [(m.start(), m.end()) for m in URL_RE.finditer(source)]
        for i, w in enumerate(words):
            if dele[i]: continue
            gap_end = words[i + 1].start if i + 1 < len(words) else len(source)
            out.append(apply_case(source[w.start:w.end], preds[i][1])); out.append(PUNCT_CHARS[preds[i][0]])
            for off in range(w.end, gap_end):
                ch = source[off]
                if ch not in ORDINARY_PUNCT or any(a <= off < b for a, b in urls): out.append(ch)
        res = "".join(out)
        return res

    def clean(self, text, finalize=True, delete=True):
        parts = []
        for seg, sep in segments_for(text, 450):
            cleaned = seg
            if seg and len(seg.encode()) <= 900 and accepted(seg, seg) is not None:
                try:
                    words, preds, dp = self.tags(seg)
                    if words:
                        dele = self.delete_mask(dp) if delete else np.zeros(len(words), bool)
                        cleaned = self.reconstruct(seg, words, preds, dele).rstrip() if dele.any() else self.reconstruct(seg, words, preds, dele)
                except WindowError:
                    pass
            parts.append(cleaned + sep)
        res = "".join(parts)
        return finalize_punctuation(res) if finalize else res
