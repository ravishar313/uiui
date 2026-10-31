"""Fixtures copied from the app's Swift tests (read-only repo) to pin the Python port to the Swift logic.
Run: python -m pytest tests -q   (or python tests/test_port.py)"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from uiui_cleanup import *  # noqa

P = lambda p, c: (p, c)  # (punct idx, case idx)  NONE,COMMA,PERIOD,QUESTION,EXCL / LOWER,CAP,UPPER


def restore(src, preds):
    return reconstruct(src, words_in(src), preds)


def test_gaps_urls_symbols():
    s = "  hello\tworld\nhttps://example.com/a?q=1,  `x` @ £₹👩🏽‍💻"
    assert [w.original for w in words_in(s)] == ["hello", "world", "x"]
    assert restore(s, [P(1, 1), P(2, 0), P(0, 2)]) == "  Hello,\tworld.\nhttps://example.com/a?q=1,  `X` @ £₹👩🏽‍💻"
    assert restore("", []) == ""


def test_clusters():
    assert restore('"hello?!..."  \nworld!', [P(1, 1), P(2, 0)]) == '"Hello,"  \nworld.'
    q = '"hello." HTTPS://example.com/a?q=1, \n🙂'
    assert restore(q, [P(2, 1)]) == '"Hello." HTTPS://example.com/a?q=1, \n🙂'


def test_numbers():
    s = "don't  don't keep -5% −7‰ 1,000 3.14 twenty-one items"
    ws = words_in(s)
    assert [w.original for w in ws] == ["don't", "don't", "keep", "5", "7", "1,000", "3.14", "twenty-one", "items"]
    p = [P(0, 0)] * len(ws)
    p[0], p[-1] = P(1, 1), P(2, 0)
    c = reconstruct(s, ws, p)
    assert c == "Don't,  don't keep -5% −7‰ 1,000 3.14 twenty-one items."
    assert accepted(c, s) is None  # decimal => structured => bypassed
    assert restore("we we are ready", [P(1, 1), P(0, 0), P(0, 0), P(2, 0)]) == "We, we are ready."


def test_unicode_case():
    s = "ＣＡＦÉ café straße İ iPhone OpenAI macOS"
    ws = words_in(s)
    assert [w.normalized for w in ws] == ["café", "café", "straße", "i̇", "iphone", "openai", "macos"]
    assert restore(s, [P(0, 2)] * len(ws)) == "ＣＡＦÉ CAFÉ STRAßE İ iPhone OpenAI macOS"
    assert restore("ÉLÈVE", [P(2, 1)]) == "Élève."
    assert restore("İ", [P(0, 0)]) == "İ"


def test_windows():
    for counts in ([1] * 600, [20] * 50, [126], [90, 80, 1], [25, 126, 25], []):
        ch = chunks_for(counts)
        assert [i for c in ch for i in c.emission] == list(range(len(counts)))
        for c in ch:
            assert sum(counts[i] for i in c.context) <= 126 and len(c.emission) > 0
            assert c.emission.start - c.context.start <= 24
    ch = chunks_for([1] * 300)
    assert (ch[0].context, ch[0].emission) == (range(0, 126), range(0, 102))
    assert (ch[1].context, ch[1].emission) == (range(78, 204), range(102, 180))


def test_finalize():
    assert finalize_punctuation("Okay, have we built everything") == "Okay, have we built everything?"
    for q in ["can you check the build", "is this ready", "what time is the meeting", "how does it work",
              "why did this fail", "how long does it take", "Can’t you see the preview",
              "what model are we using", "which branch is ready", "may I check the build"]:
        assert finalize_punctuation(q) == q + "?", q
    for t in ["The build is ready", "okay", "ship it", "Have a look", "Do it now", "Don’t you worry",
              "May you have a wonderful day", "I wonder why this failed", "what we need is more time",
              "how to build this", "What is important is preserving the original words"]:
        assert finalize_punctuation(t) == t + ".", t
    assert finalize_punctuation("  the BUILD has  42 items, and 3 remain\t ") == "  the BUILD has  42 items, and 3 remain.\t "
    assert finalize_punctuation("Can you check the build? We are waiting") == "Can you check the build? We are waiting."
    assert finalize_punctuation("Okay, have we built everything.") == "Okay, have we built everything?"


def test_segments_lossless():
    t = "  " + " ".join(["word%d" % i for i in range(200)]) + "  \n"
    segs = segments_for(t, 450)
    assert "".join(a + b for a, b in segs) == t and all(len(a.encode()) <= 450 for a, _ in segs)


if __name__ == "__main__":
    for k, v in list(globals().items()):
        if k.startswith("test_"):
            v(); print("ok", k)
