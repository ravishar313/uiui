"""Hybrid Devanagari -> casual Roman Hinglish romanizer.

Stage 1 (deterministic, word-preserving): akshara parser with Hindi schwa deletion
          and chat-style vowel/nasal mapping + canonical function-word lexicon.
Stage 2 (optional, LLM): word-ALIGNED pass. The LLM gets a numbered token list and
          must return a JSON list of the same length. Used only to (a) recover English
          spellings of Devanagari loanwords (क्लिक -> click) and (b) fix casual spellings.
          Guard: an LLM token is accepted only if the list length matches, the source
          word is not a protected lexicon word, the LLM token is an English dictionary
          word, AND it is phonetically close to the stage-1 token. I.e. the LLM only
          does loanword recovery; Hindi spellings come from stage 1 (an earlier, looser
          guard let it flip rahi->tha, bhej->bheda). Otherwise stage-1 output is kept. So the LLM can never add,
          drop or reorder words (the failure seen with free-form prompting).

Usage: python romanize_hybrid.py <in.json> <out.json> [mlx_model_dir]
"""
import difflib
import json
import re
import sys

V_INDEP = {"अ": "a", "आ": "aa", "इ": "i", "ई": "ee", "उ": "u", "ऊ": "oo", "ऋ": "ri",
           "ए": "e", "ऐ": "ai", "ओ": "o", "औ": "au", "ऑ": "o", "ऍ": "e"}
V_SIGN = {"ा": "aa", "ि": "i", "ी": "ee", "ु": "u", "ू": "oo", "ृ": "ri", "े": "e",
          "ै": "ai", "ो": "o", "ौ": "au", "ॉ": "o", "ॅ": "e"}
CONS = {"क": "k", "ख": "kh", "ग": "g", "घ": "gh", "ङ": "n", "च": "ch", "छ": "chh",
        "ज": "j", "झ": "jh", "ञ": "n", "ट": "t", "ठ": "th", "ड": "d", "ढ": "dh",
        "ण": "n", "त": "t", "थ": "th", "द": "d", "ध": "dh", "न": "n", "प": "p",
        "फ": "ph", "ब": "b", "भ": "bh", "म": "m", "य": "y", "र": "r", "ल": "l",
        "व": "v", "श": "sh", "ष": "sh", "स": "s", "ह": "h", "ळ": "l"}
NUKTA = {"क": "k", "ख": "kh", "ग": "g", "ज": "z", "फ": "f", "ड": "d", "ढ": "rh"}
HALANT, NUK, ANUS, CANDRA, VISARGA = "्", "़", "ं", "ँ", "ः"

LEX = {  # canonical chat spellings for frequent words (Devanagari -> Roman)
    "है": "hai", "हैं": "hain", "नहीं": "nahi", "नही": "nahi", "क्या": "kya", "मैं": "main",
    "में": "mein", "हूँ": "hoon", "हूं": "hoon", "क्यों": "kyon", "क्योंकि": "kyunki",
    "यह": "yeh", "वह": "woh", "वो": "woh", "ये": "ye", "कि": "ki", "की": "ki", "भी": "bhi",
    "ही": "hi", "तो": "toh", "और": "aur", "कुछ": "kuch", "बहुत": "bahut", "अभी": "abhi",
    "ठीक": "theek", "अच्छा": "accha", "यहाँ": "yahan", "वहाँ": "wahan", "हमें": "humein",
    "तुम्हें": "tumhein", "उन्हें": "unhein", "हम": "hum", "तुम": "tum", "आप": "aap",
    "पाँच": "paanch", "जाऊँगा": "jaunga", "कृपया": "kripya", "इसलिए": "isliye",
    "लिए": "liye", "गए": "gaye", "हुए": "hue", "वैसे": "waise", "ज्ञान": "gyan",
}


PRECOMP = {"\u0958": "क\u093c", "\u0959": "ख\u093c", "\u095a": "ग\u093c", "\u095b": "ज\u093c",
           "\u095c": "ड\u093c", "\u095d": "ढ\u093c", "\u095e": "फ\u093c", "\u095f": "य\u093c"}


def aksharas(word):
    """Split into (consonant_cluster, vowel, nasal) units; vowel None = inherent a."""
    for k, v in PRECOMP.items():
        word = word.replace(k, v)
    out, i, n = [], 0, len(word)
    while i < n:
        ch = word[i]
        if ch in V_INDEP:
            v, i = V_INDEP[ch], i + 1
            nas = ""
            if i < n and word[i] in (ANUS, CANDRA):
                nas, i = "n", i + 1
            out.append(("", v, nas, 0))
            continue
        if ch in CONS:
            cl = []
            while i < n and word[i] in CONS:
                c = word[i]
                i += 1
                if i < n and word[i] == NUK:
                    cl.append(NUKTA.get(c, CONS[c]))
                    i += 1
                else:
                    cl.append(CONS[c])
                if i < n and word[i] == HALANT:
                    i += 1
                    continue
                break
            v = None
            if i < n and word[i] in V_SIGN:
                v, i = V_SIGN[word[i]], i + 1
            nas = ""
            if i < n and word[i] in (ANUS, CANDRA):
                nas, i = "n", i + 1
            if i < n and word[i] == VISARGA:
                i += 1
            out.append(("".join(cl), v, nas, len(cl)))
            continue
        i += 1  # skip unknown marks
    return out


def roman_word(word):
    if word in LEX:
        return LEX[word]
    ak = aksharas(word)
    if not ak:
        return word
    vowels = [a[1] for a in ak]
    # schwa deletion: final inherent a dropped (unless single akshara), then
    # medial V C [a] C V right-to-left (Choudhury-style heuristic).
    keep = [True] * len(ak)
    if len(ak) > 1 and vowels[-1] is None and not ak[-1][2]:
        keep[-1] = False
    j = len(ak) - 2
    while j >= 1:
        nxt_has_vowel = vowels[j + 1] is not None or keep[j + 1]
        if vowels[j] is None and not ak[j][2] and ak[j][0] and ak[j + 1][3] == 1 and nxt_has_vowel:
            keep[j] = False  # V C a C V -> V C C V   (karane -> karne, usakaa -> uska)
            j -= 2           # never delete two adjacent schwas
        else:
            j -= 1
    s = []
    for j, (c, v, nas, _) in enumerate(ak):
        last = j == len(ak) - 1
        if v is None:
            v = "a" if keep[j] else ""
        if v == "aa" and (last or j > 0):
            v = "a" if (last and c) else ("aa" if j == 0 or not c else "a")
        if v == "ee" and last:
            v = "i"
        if v == "oo" and last:
            v = "u"
        if nas:
            v = {"e": "ein", "ai": "ain", "o": "on", "ee": "in", "i": "in", "aa": "an",
                 "a": "an", "oo": "un", "u": "un"}.get(v, v + "n") if last else v + "n"
        s.append(c + v)
    r = "".join(s)
    r = r.replace("jn", "gy").replace("nb", "mb").replace("np", "mp").replace("nbh", "mbh")
    return r


DEVA = re.compile(r"[ऀ-ॿ]+")


def stage1(text):
    t = text.replace("।", " ").replace("॥", " ")
    t = DEVA.sub(lambda m: roman_word(m.group(0)), t)
    t = re.sub(r"[()\"“”]", " ", t)
    return " ".join(t.split())


# ---------------- stage 2 ----------------
PROMPT = """You fix a word-by-word romanization of a Hindi sentence into casual WhatsApp-style Hinglish.
You get the original sentence and a JSON list of tokens (a rough romanization, one per original word).
Return ONLY a JSON list of EXACTLY the same length, same order, one output token per input token.
For each token:
- If the original word is an English word written in Devanagari (e.g. क्लिक, ऑफिस, मीटिंग, फ़ाइल, डिवाइस), output the normal English spelling (click, office, meeting, file, device).
- Otherwise output the common casual Roman spelling of the Hindi word (karne, uska, tha, raha, kholein, karein, sochein, vichar, yatra).
- Latin-script tokens: copy unchanged. Never merge, split, translate, add or drop tokens."""


def is_english(o, a):
    """LLM token counts as an English loanword only if it is a reasonably frequent
    English word (wordfreq zipf >= 3) and clearly more English than the stage-1
    token. /usr/share/dict was too permissive (accepted 'tha', 'bae')."""
    from wordfreq import zipf_frequency as z
    return len(o) >= 4 and z(o, "en") >= 3.0 and z(o, "en") - z(a, "en") >= 1.0


WORD_PROMPT = ("Is the Devanagari word '{w}' an English word written in Devanagari "
               "(like क्लिक=click, ऑफिस=office)? If yes reply with only the English spelling. "
               "If it is a Hindi/Urdu/Sanskrit word reply only NO.")


def close(a, b, thr=0.6):
    sk = lambda x: re.sub(r"(.)\1+", r"\1", x.replace("aa", "a").replace("ee", "i").replace("oo", "u").replace("w", "v")
                         .replace("c", "k").replace("ph", "f").replace("ck", "k"))
    return difflib.SequenceMatcher(None, sk(a), sk(b)).ratio() >= thr


def stage2(rows, model_dir):
    from mlx_lm import generate, load
    m, tok = load(model_dir)
    for r in rows:
        src = r["text"].replace("।", " ")
        src_toks = re.sub(r"[()\"“”,.?!]", " ", src).split()
        s1 = [stage1(w) for w in src_toks]
        msgs = [{"role": "system", "content": PROMPT},
                {"role": "user", "content": f"Original: {src}\nTokens: {json.dumps(s1, ensure_ascii=False)}"}]
        kw = {"enable_thinking": False} if "qwen3" in model_dir.lower() else {}
        p = tok.apply_chat_template(msgs, add_generation_prompt=True, tokenize=False, **kw)
        raw = generate(m, tok, prompt=p, max_tokens=400, verbose=False)
        raw = raw.split("</think>")[-1]
        try:
            out = json.loads(raw[raw.index("["): raw.rindex("]") + 1])
        except Exception:
            out = None
        final, accepted = [], 0
        if isinstance(out, list) and len(out) == len(s1):
            for o, a, w in zip(out, s1, src_toks):
                o = str(o).strip().lower()
                if not DEVA.search(w):
                    final.append(w)  # Latin source token: always verbatim
                elif w in LEX:
                    final.append(a)  # protected canonical function word
                elif o and o != a and is_english(o, a) and close(o, a, 0.5):
                    final.append(o)
                    accepted += o != a
                else:
                    final.append(a)
            r["hybrid_status"] = f"aligned, {accepted} tokens changed by LLM"
        else:  # fallback: context-free per-word loanword check
            for a, w in zip(s1, src_toks):
                if not DEVA.search(w) or w in LEX:
                    final.append(a if DEVA.search(w) else w)
                    continue
                msgs = [{"role": "user", "content": WORD_PROMPT.format(w=w)}]
                p = tok.apply_chat_template(msgs, add_generation_prompt=True, tokenize=False, **kw)
                o = generate(m, tok, prompt=p, max_tokens=12, verbose=False).split("</think>")[-1].strip().lower()
                o = re.sub(r"[^a-z]", "", o.split()[0]) if o.split() else ""
                if o and o != "no" and is_english(o, a) and close(o, a, 0.5):
                    final.append(o)
                    accepted += 1
                else:
                    final.append(a)
            r["hybrid_status"] = f"length mismatch -> per-word fallback, {accepted} loanwords"
        r["hybrid"] = " ".join(final)


def main(src, dst, model_dir=None):
    rows = json.load(open(src))
    for r in rows:
        r["stage1"] = stage1(r["text"])
    if model_dir:
        stage2(rows, model_dir)
    json.dump(rows, open(dst, "w"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main(*sys.argv[1:4])
