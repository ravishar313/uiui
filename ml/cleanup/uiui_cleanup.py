"""Python port of the uiui MiniLM cleanup pipeline (read-only reference: the app repository).

Mirrors, function for function:
  MiniLMText.words / chunks / reconstruct / applyCase      (Sources/UIUICore/MiniLMText.swift)
  DictationCleanupText.segments / accepted                 (Sources/UIUICore/DictationCleanupText.swift)
  MiniLMFormattingRuntime.generate                         (Sources/UIUI/MiniLMCleanup.swift)
  DictationPunctuation.finalize                            (Sources/UIUICore/DictationPunctuation.swift)
  CMiniLM Tokenizer (SentencePiece id mapping)             (Sources/CMiniLM/Tokenizer.hpp)

Known approximations (see README): Swift Character = grapheme cluster, here a code point;
Swift lowercased()/folding vs Python str.lower()/casefold(); ICU vs `regex` module.
"""
from __future__ import annotations

import os
import unicodedata
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import regex as re

UIUI = Path(os.environ.get("UIUI_APP_ROOT") or Path(__file__).resolve().parents[2])  # READ-ONLY: the app repository root (default: this repo)
SP_MODEL = UIUI / "resources/MiniLM/sentencepiece.bpe.model"
ONNX_MODEL = UIUI / "resources/MiniLM/model.int8.onnx"
FP32_DIR = UIUI / "model-sources/MiniLM"

PUNCT_CHARS = ["", ",", ".", "?", "!"]
PUNCT_NAMES = ["NONE", "COMMA", "PERIOD", "QUESTION", "EXCLAMATION"]
CASE_NAMES = ["LOWER", "CAP", "UPPER"]

WORD_RE = re.compile(r"\p{L}[\p{L}\p{M}\p{N}'’\-]*|\p{N}+(?:[.,]\p{N}+)*")
URL_RE = re.compile(r"(?:https?://|www\.)\S+", re.IGNORECASE)
ORDINARY_PUNCT = set(".,!?;:")


# ---------------------------------------------------------------- tokenizer
class Tokenizer:
    """Per-word SentencePiece encode with the app's id mapping (piece 0 -> 3, else piece+1)."""

    def __init__(self, path: str | os.PathLike = SP_MODEL):
        import sentencepiece as spm
        self.sp = spm.SentencePieceProcessor(model_file=str(path))
        assert self.sp.get_piece_size() == 31998 and self.sp.unk_id() == 0 and self.sp.bos_id() == 1

    def encode(self, text: str) -> list[int]:
        return [3 if p == 0 else p + 1 for p in self.sp.encode(text)]


# ---------------------------------------------------------------- MiniLMText
@dataclass(frozen=True)
class Word:
    start: int  # code point offsets into the source
    end: int
    original: str
    normalized: str


def words_in(source: str) -> list[Word]:
    urls = [(m.start(), m.end()) for m in URL_RE.finditer(source)]
    out = []
    for m in WORD_RE.finditer(source):
        if any(a <= m.start() < b for a, b in urls):
            continue
        orig = m.group(0)
        norm = unicodedata.normalize("NFKC", orig).lower()
        out.append(Word(m.start(), m.end(), orig, norm))
    return out


@dataclass(frozen=True)
class Chunk:
    context: range
    emission: range


class WindowError(Exception):
    pass


def chunks_for(counts: list[int]) -> list[Chunk]:
    if not all(0 < c <= 126 for c in counts):
        raise WindowError("unsupportedLength")
    chunks, emit_start, n = [], 0, len(counts)
    while emit_start < n:
        start, left = emit_start, 0
        while start > 0 and emit_start - start < 24 and left + counts[start - 1] <= 25:
            start -= 1
            left += counts[start]
        end, used = start, 0
        while end < n and used + counts[end] <= 126:
            used += counts[end]
            end += 1
        if end <= emit_start:
            start, end = emit_start, emit_start + 1
        emit_end = end
        if end < n:
            right = 0
            while emit_end > emit_start + 1 and end - emit_end < 24 and right + counts[emit_end - 1] <= 25:
                emit_end -= 1
                right += counts[emit_end]
        chunks.append(Chunk(range(start, end), range(emit_start, emit_end)))
        emit_start = emit_end
    return chunks


def apply_case(word: str, casing: int) -> str:
    saw_lower = False
    for ch in word:
        if ch.islower():
            saw_lower = True
        if saw_lower and ch.isupper():
            return word  # intentional internal capitals are kept
    out, first_letter = [], True
    for ch in word:
        is_letter = unicodedata.category(ch).startswith("L")
        upper = casing == 2 or (casing == 1 and first_letter and is_letter)
        val = ch.upper() if upper else ch.lower()
        out.append(val if len(val) == 1 else ch)
        if is_letter:
            first_letter = False
    return "".join(out)


def reconstruct(source: str, words: list[Word], preds: list[tuple[int, int]]) -> str:
    if len(words) != len(preds) or words != words_in(source):
        raise WindowError("alignment")
    if not words:
        return source
    urls = [(m.start(), m.end()) for m in URL_RE.finditer(source)]
    out = [source[: words[0].start]]
    for i, w in enumerate(words):
        gap_end = words[i + 1].start if i + 1 < len(words) else len(source)
        out.append(apply_case(source[w.start:w.end], preds[i][1]))
        out.append(PUNCT_CHARS[preds[i][0]])
        for off in range(w.end, gap_end):
            ch = source[off]
            in_url = any(a <= off < b for a, b in urls)
            if ch not in ORDINARY_PUNCT or in_url:
                out.append(ch)
    return "".join(out)


# ---------------------------------------------------------------- DictationCleanupText
def segments_for(text: str, max_bytes: int = 450) -> list[tuple[str, str]]:
    """(text, separator) pairs; split only between whitespace-delimited words."""
    if not text:
        return []
    budget = max(1, max_bytes)
    result: list[tuple[str, str]] = []
    n, cur = len(text), 0
    while cur < n and text[cur].isspace():
        cur += 1
    if cur > 0:
        result.append(("", text[:cur]))
    start = body_end = cur
    body_bytes = gap_bytes = 0
    while cur < n:
        word_start, word_bytes = cur, 0
        while cur < n and not text[cur].isspace():
            word_bytes += len(text[cur].encode())
            cur += 1
        if body_bytes > 0 and (gap_bytes > budget - min(body_bytes, budget)
                               or word_bytes > budget - min(body_bytes + gap_bytes, budget)):
            result.append((text[start:body_end], text[body_end:word_start]))
            start, body_bytes, gap_bytes = word_start, 0, 0
        body_bytes += gap_bytes + word_bytes
        body_end = cur
        gap_bytes = 0
        while cur < n and text[cur].isspace():
            gap_bytes += len(text[cur].encode())
            cur += 1
    if body_bytes > 0:
        result.append((text[start:body_end], text[body_end:]))
    return result


_STRUCT_CHARS = set("/\\@`<>[]{}|=_+*$#")
_STRUCT_RE = re.compile(r"[\p{L}\p{N}][.][\p{L}\p{N}]|\d[:：]\d|[\p{L}\p{N}_][(]|(?:^|\s)--[\p{L}]")
_CODE_RE = re.compile(
    r"^(?:[-•]\s|\d+[.)]\s|(?:let|var|const|func|function|def|class|struct|enum|import|guard|throw|return|if|for|while|go|git|npm|pnpm|yarn|bun|swift|python|python3|node|cargo|cd|ls|mkdir|rm|mv|cp|chmod|sh|zsh|bash|sudo|brew|gh|curl|ssh|kubectl|docker)\s)",
    re.IGNORECASE)


def is_structured(text: str) -> bool:
    if any(c in _STRUCT_CHARS for c in text):
        return True
    for c in text:
        cat = unicodedata.category(c)
        if cat == "Cc" and not c.isspace():
            return True
        if cat == "Cf" and ord(c) != 0x200D:
            return True
    if _STRUCT_RE.search(text):
        return True
    first = text.strip()
    if _CODE_RE.match(first):
        return True
    return first.lower() in ("true", "false", "nil", "null")


def _is_lexical(c: str) -> bool:
    cat = unicodedata.category(c)
    return cat[0] in "LN" or cat in ("Mn", "Mc", "Me")


def lexical_tokens(text: str) -> list[str]:
    res, word = [], ""

    def flush():
        nonlocal word
        if word:
            w = word.replace("’", "'").casefold()
            res.append(unicodedata.normalize("NFC", w))
            word = ""

    n = len(text)
    for i, c in enumerate(text):
        prev = text[i - 1] if i > 0 else None
        nxt = text[i + 1] if i + 1 < n else None
        inside = prev is not None and nxt is not None and _is_lexical(prev) and _is_lexical(nxt)
        connector = inside and c in "'’-."
        num_comma = c == "," and prev is not None and nxt is not None and prev.isnumeric() and nxt.isnumeric()
        num_sign = c in "-−" and nxt is not None and nxt.isnumeric()
        num_suffix = c in "%‰" and prev is not None and prev.isnumeric()
        if _is_lexical(c) or connector or num_comma or num_sign or num_suffix:
            word += c
        else:
            flush()
            if not c.isspace() and not unicodedata.category(c).startswith("P"):
                res.append(c)
    flush()
    return res


def accepted(candidate: str, original: str) -> str | None:
    src_bytes = len(original.encode())
    if src_bytes == 0 or src_bytes > 16384 or len(candidate.encode()) > src_bytes * 2 + 64:
        return None
    if is_structured(original) or is_structured(candidate):
        return None
    trimmed = candidate.strip()
    if not trimmed:
        return None
    src_tokens = lexical_tokens(original)
    if not any(c.isalpha() or c.isnumeric() for c in original) or not src_tokens:
        return None
    if src_tokens != lexical_tokens(trimmed):
        return None
    return trimmed


# ---------------------------------------------------------------- DictationPunctuation.finalize
_AUX = {"am", "is", "are", "was", "were", "can", "could", "will", "would", "shall", "should", "may", "might",
        "must", "do", "does", "did", "have", "has", "had", "isn't", "aren't", "wasn't", "weren't", "can't",
        "couldn't", "won't", "wouldn't", "shouldn't", "don't", "doesn't", "didn't", "haven't", "hasn't", "hadn't"}
_SUBJ = {"i", "you", "we", "he", "she", "it", "they", "this", "that", "these", "those", "there", "anyone",
         "someone", "everybody", "anybody"}
_CODE_STARTS = {"let", "var", "const", "func", "function", "def", "return", "import", "class", "struct", "enum",
                "guard", "throw", "if", "for", "while", "git", "npm", "pnpm", "yarn", "bun", "swift", "python",
                "python3", "node", "cargo", "go", "cd", "ls", "mkdir", "rm", "mv", "cp", "chmod", "sh", "zsh",
                "bash", "sudo", "brew", "gh", "curl", "ssh", "kubectl", "docker"}


def _final_sentence(text: str) -> str:
    start = 0
    for i, c in enumerate(text):
        if c in ".?!" and i + 1 < len(text) and text[i + 1].isspace():
            start = i + 1
    tail = text[start:]
    return tail.lstrip()


def _is_plain_prose(text: str) -> bool:
    if not any(c.isalpha() for c in text):
        return False
    if any(c in "\n\r" or c in "/\\@#`<>[]{}|=_+*;$" for c in text):
        return False
    if text[0] in "-•>":
        return False
    n = len(text)
    for i, c in enumerate(text):
        if c in "\"“”«»":
            return False
        if c in "'‘’":
            inside = 0 < i < n - 1 and text[i - 1].isalpha() and text[i + 1].isalpha()
            if not inside:
                return False
        if c == "." and 0 < i < n - 1 and text[i - 1].isalnum() and text[i + 1].isalnum():
            return False
        if c in "()":
            return False
    parts = text.split()
    first = parts[0].lower() if parts else ""
    if first and first[-1] in ".)" and first[:-1] and first[:-1].isnumeric():
        return False
    return first not in _CODE_STARTS and text.lower() not in ("true", "false", "null", "nil")


def _is_direct_question(text: str) -> bool:
    if any(c in ".?!:;" for c in text):
        return False
    ws = [w for w in re.split(r"[^\p{L}'’]+", text.lower(), maxsplit=15) if w]
    if ws and ws[0] in ("okay", "ok", "well", "so", "hey"):
        ws = ws[1:]
    if len(ws) < 3:
        return False
    nw = [w.replace("’", "'") for w in ws]
    if nw[0] in _AUX:
        if nw[0] in ("do", "have") and nw[1] in ("it", "this", "that", "these", "those"):
            return False
        if nw[0] == "don't":
            return False
        if nw[0] == "may" and nw[1] not in ("i", "we"):
            return False
        if nw[1] in _SUBJ:
            return True
        return nw[0] not in ("do", "have") and len(ws) >= 4 and nw[1] in ("the", "a", "an", "my", "your", "our")
    if nw[0] not in ("what", "which", "who", "where", "when", "why", "how"):
        return False
    if nw[1] in _AUX:
        if nw[0] == "what" and nw[1] in ("is", "are", "was", "were") and any(
                w in ("is", "are", "was", "were") for w in nw[3:]):
            return False
        return True
    if nw[1] in _SUBJ:
        return False
    if nw[0] in ("what", "which"):
        nouns = {"time", "day", "date", "year", "version", "model", "branch", "build", "app", "file", "project",
                 "color", "colour", "size", "name", "number", "status", "language", "option", "one", "way"}
        return len(nw) >= 4 and nw[1] in nouns and nw[2] in _AUX
    return nw[0] == "how" and nw[1] in ("long", "much", "many", "often", "far", "soon", "old") \
        and len(nw) >= 4 and nw[2] in _AUX


def finalize_punctuation(transcript: str) -> str:
    if len(transcript) > 16384:
        return transcript
    stripped = transcript.strip()
    if not stripped:
        return transcript
    start = len(transcript) - len(transcript.lstrip())
    end = len(transcript.rstrip())
    body = transcript[start:end]
    if not _is_plain_prose(body):
        return transcript
    terminal = transcript[end - 1]
    if terminal == ".":
        before = body[:-1]
        if not before or before[-1] == "." or unicodedata.category(before[-1]).startswith("P"):
            return transcript
        if not _is_direct_question(_final_sentence(before)):
            return transcript
        return transcript[: end - 1] + "?" + transcript[end:]
    if not (terminal.isalpha() or terminal.isnumeric()):
        return transcript
    p = "?" if _is_direct_question(_final_sentence(body)) else "."
    return transcript[:end] + p + transcript[end:]


# ---------------------------------------------------------------- label mode
# Where the app port can lose a model "?": finalize_punctuation never turns a model '?' into '.', but
# (a) when the model's last tag is NONE it appends '.' unless the ENGLISH-only heuristic fires, so Hinglish
# questions the model left unpunctuated become '.', and (b) it rewrites a model '.' into '?' only for English
# patterns, so a Hinglish question the model tagged PERIOD stays '.'. Label mode never overrides a model
# QUESTION/EXCLAMATION/PERIOD; it only adds a terminal mark when the model left none.
_HI_Q_START = {"kya", "kab", "kaun", "kaise", "kyun", "kyon", "kahan", "kidhar", "kitna", "kitne", "kitni", "kisne",
               "kisko", "kiska", "kiski", "kiske", "kisse", "kaunsa", "konsa", "konsi", "kaunsi", "kis"}


def _hinglish_question(sentence: str) -> bool:
    ws = [w for w in re.split(r"[^\p{L}'’]+", sentence.lower()) if w]
    if len(ws) < 2:
        return False
    tail2, tail1 = " ".join(ws[-2:]), ws[-1]
    if tail2 in ("hai na", "ya nahi", "ya na") or tail1 in ("haina", "kya"):
        return True
    return ws[0] in _HI_Q_START and "," not in sentence[: len(sentence) // 2 or 1]


def finalize_label(transcript: str, hinglish_questions: bool = False) -> str:
    stripped = transcript.rstrip()
    if not stripped or len(transcript) > 16384:
        return transcript
    end = len(stripped)
    body = transcript[:end]
    if not _is_plain_prose(body.lstrip()):
        return transcript
    terminal = body[-1]
    tail = transcript[end:]
    if terminal in "?!":
        return transcript
    if terminal == ".":
        if hinglish_questions and _hinglish_question(_final_sentence(body[:-1])):
            return body[:-1] + "?" + tail
        return transcript
    if not (terminal.isalpha() or terminal.isnumeric()):
        return transcript
    if hinglish_questions and _hinglish_question(_final_sentence(body)):
        return body + "?" + tail
    return body + "." + tail


# ---------------------------------------------------------------- backends
class OnnxBackend:
    """Shipped int8 ONNX, same ORT session options as CMiniLM.cpp (1 thread, sequential, CPU)."""

    def __init__(self, path=ONNX_MODEL):
        import onnxruntime as ort
        o = ort.SessionOptions()
        o.intra_op_num_threads = 1
        o.inter_op_num_threads = 1
        o.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
        o.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        self.sess = ort.InferenceSession(str(path), o, providers=["CPUExecutionProvider"])
        self.names = [i.name for i in self.sess.get_inputs()]

    def predict(self, ids: list[int]) -> np.ndarray:
        a = np.asarray([ids], dtype=np.int64)
        feeds = {"input_ids": a, "attention_mask": np.ones_like(a)}
        if "token_type_ids" in self.names:
            feeds["token_type_ids"] = np.zeros_like(a)
        return self.sess.run(None, feeds)[0][0]


class TorchBackend:
    """FP32 (or fine-tuned) HF checkpoint dir; eager attention, eval mode."""

    def __init__(self, path=FP32_DIR, device="cpu"):
        import torch
        from transformers import AutoModelForTokenClassification
        self.torch = torch
        self.device = device
        self.model = AutoModelForTokenClassification.from_pretrained(
            str(path), attn_implementation="eager").to(device).eval()

    def predict(self, ids: list[int]) -> np.ndarray:
        t = self.torch
        a = t.tensor([ids], dtype=t.long, device=self.device)
        with t.no_grad():
            out = self.model(input_ids=a, attention_mask=t.ones_like(a)).logits
        return out[0].float().cpu().numpy()[:, :8]  # disfluency checkpoints carry a 9th (DELETE) logit: ignored here


# ---------------------------------------------------------------- pipeline
class Cleaner:
    def __init__(self, backend, tokenizer: Tokenizer | None = None):
        self.backend = backend
        self.tok = tokenizer or Tokenizer()

    def tags(self, source: str) -> tuple[list[Word], list[tuple[int, int]], np.ndarray | None]:
        """MiniLMFormattingRuntime.generate up to (not including) reconstruct. Also returns raw
        per-word logits (n_words x 8) at the emitting position for parity checks."""
        words = words_in(source)
        if not words:
            return words, [], None
        pieces: list[list[int]] = []
        memo: dict[str, int] = {}
        for w in words:
            if w.normalized in memo:
                pieces.append(pieces[memo[w.normalized]])
            else:
                memo[w.normalized] = len(pieces)
                pieces.append(self.tok.encode(w.normalized))
        chunks = chunks_for([len(p) for p in pieces])
        preds: list[tuple[int, int]] = []
        rows: list[np.ndarray] = []
        for ch in chunks:
            ids = [0]
            joined = []
            for wi in ch.context:
                ids.extend(pieces[wi])
                joined.append(words[wi].normalized)
            if len(ch.context) > 1 and self.tok.encode(" ".join(joined)) != ids[1:]:
                raise WindowError("alignment")
            ids.append(2)
            if len(ids) > 128:
                raise WindowError("unsupportedLength")
            logits = self.backend.predict(ids)
            if logits.shape != (len(ids), 8) or not np.isfinite(logits).all():
                raise WindowError("alignment")
            cursor = 0
            for wi in ch.context:
                cursor += len(pieces[wi])
                if wi not in ch.emission:
                    continue
                row = logits[cursor]
                preds.append((int(np.argmax(row[:5])), int(np.argmax(row[5:8]))))
                rows.append(row)
        return words, preds, np.stack(rows)

    def generate(self, source: str) -> str:
        """MiniLMFormattingRuntime.generate (fallback to source on any failure/rejection)."""
        if accepted(source, source) is None:
            return source
        try:
            words, preds, _ = self.tags(source)
            if not words:
                return source
            cand = reconstruct(source, words, preds)
        except WindowError:
            return source
        return source if accepted(cand, source) is None else cand

    def clean(self, text: str, finalize: bool = True, gate: bool = True, label_mode: bool = False,
              hinglish_questions: bool = False) -> str:
        """DictationCleanup.finish: 450-byte segments -> generate -> accepted -> finalize.
        gate=False skips the `accepted` structured-text guards (model-only diagnostics).
        label_mode=True: formatting of training LABELS, not dictation: the model's terminal punctuation is
        kept (see finalize_label). hinglish_questions additionally lets a Hinglish tail heuristic turn a
        final '.'/missing mark into '?'."""
        out = []
        for seg, sep in segments_for(text, 450):
            cleaned = seg
            if seg and len(seg.encode()) <= 900:
                if gate:
                    cand = self.generate(seg)
                    cleaned = accepted(cand, seg) or seg
                else:
                    try:
                        words, preds, _ = self.tags(seg)
                        cleaned = reconstruct(seg, words, preds) if words else seg
                    except WindowError:
                        cleaned = seg
            out.append(cleaned + sep)
        res = "".join(out)
        if label_mode:
            return finalize_label(res, hinglish_questions) if finalize else res
        return finalize_punctuation(res) if finalize else res


def make_cleaner(backend: str = "onnx", ckpt: str | None = None, device: str = "cpu") -> Cleaner:
    if backend == "onnx":
        return Cleaner(OnnxBackend(ckpt or ONNX_MODEL))
    return Cleaner(TorchBackend(ckpt or FP32_DIR, device))


if __name__ == "__main__":
    import argparse, json, sys
    ap = argparse.ArgumentParser(description="Format lowercase/unpunctuated text with the cleanup model. "
                                 "Reads one text per line (or jsonl with --field) from --input/stdin.")
    ap.add_argument("--input", default="-")
    ap.add_argument("--output", default="-")
    ap.add_argument("--field", default=None, help="jsonl field to format (rows are copied with '<field>_formatted')")
    ap.add_argument("--backend", default="torch", choices=["onnx", "torch"])
    ap.add_argument("--ckpt", default=None)
    ap.add_argument("--device", default="cpu")
    ap.add_argument("--label-mode", action="store_true",
                    help="training-label formatting: keep the model's terminal punctuation (never rewritten by the "
                         "English dictation finalize), add '.' only if the model left none")
    ap.add_argument("--hinglish-questions", action="store_true",
                    help="with --label-mode: promote a final '.'/missing mark to '?' on Hinglish question patterns")
    a = ap.parse_args()
    cl = make_cleaner(a.backend, a.ckpt, a.device)
    fi = sys.stdin if a.input == "-" else open(a.input)
    fo = sys.stdout if a.output == "-" else open(a.output, "w")
    for line in fi:
        line = line.rstrip("\n")
        if not line.strip():
            continue
        if a.field:
            r = json.loads(line)
            r[a.field + "_formatted"] = cl.clean(r[a.field], label_mode=a.label_mode, hinglish_questions=a.hinglish_questions)
            fo.write(json.dumps(r, ensure_ascii=False) + "\n")
        else:
            fo.write(cl.clean(line, label_mode=a.label_mode, hinglish_questions=a.hinglish_questions) + "\n")
