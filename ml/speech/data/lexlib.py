"""Word-level Devanagari -> casual Roman lexicon helpers. Uses the selected deterministic converter (romanize_hybrid.py)."""
import difflib, json, os, re, sys, unicodedata
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import romanize_hybrid as rh  # noqa: E402

# Extra canonical spellings (convention: hai hain nahi kya main mein hoon raha/rahi/rahe kyunki yeh woh toh aur kuch bahut abhi theek accha)
EXTRA_LEX = {
    "यह": "yeh", "ये": "yeh", "वह": "woh", "वो": "woh", "तो": "toh", "रहा": "raha", "रही": "rahi", "रहे": "rahe",
    "रहीं": "rahin", "हूँ": "hoon", "हूं": "hoon", "होता": "hota", "होती": "hoti", "होते": "hote",
    "है": "hai", "हैं": "hain", "था": "tha", "थी": "thi", "थे": "the", "थीं": "thin", "मैं": "main", "मै": "main",
    "में": "mein", "मे": "mein", "नहीं": "nahi", "नही": "nahi", "नहिं": "nahi", "क्या": "kya", "क्यों": "kyun",
    "क्योंकि": "kyunki", "क्यूंकि": "kyunki", "कुछ": "kuch", "बहुत": "bahut", "अभी": "abhi", "ठीक": "theek",
    "अच्छा": "accha", "अच्छी": "acchi", "अच्छे": "acche", "और": "aur", "एक": "ek", "का": "ka", "के": "ke",
    "को": "ko", "से": "se", "पर": "par", "भी": "bhi", "ही": "hi", "जो": "jo", "कि": "ki", "की": "ki",
    "ना": "na", "न": "na", "हम": "hum", "आप": "aap", "तुम": "tum", "मैंने": "maine", "मुझे": "mujhe",
    "मेरा": "mera", "मेरी": "meri", "मेरे": "mere", "हमारा": "hamara", "हमारी": "hamari", "हमारे": "hamare",
    "उसने": "usne", "उसे": "use", "उन्हें": "unhein", "उनको": "unko", "इसे": "ise", "इस": "is", "उस": "us",
    "जी": "ji", "हाँ": "haan", "हां": "haan", "बस": "bas", "सब": "sab", "सबको": "sabko", "कोई": "koi",
    "तब": "tab", "जब": "jab", "अब": "ab", "कब": "kab", "कैसे": "kaise", "कहाँ": "kahan", "कहां": "kahan",
    "यहाँ": "yahan", "यहां": "yahan", "वहाँ": "wahan", "वहां": "wahan", "बात": "baat", "लोग": "log",
    "करना": "karna", "करने": "karne", "करके": "karke", "करते": "karte", "करता": "karta", "करती": "karti",
    "कर": "kar", "करो": "karo", "करें": "karein", "करेंगे": "karenge", "गया": "gaya", "गई": "gayi", "गए": "gaye",
    "दिया": "diya", "लिया": "liya", "किया": "kiya", "आया": "aaya", "आई": "aayi", "आए": "aaye",
    "वाला": "wala", "वाली": "wali", "वाले": "wale", "सकता": "sakta", "सकती": "sakti", "सकते": "sakte",
    "चाहिए": "chahiye", "चाहता": "chahta", "चाहती": "chahti", "बोलते": "bolte", "लिए": "liye", "साथ": "saath",
    "पास": "paas", "ऐसे": "aise", "जैसे": "jaise", "वैसे": "waise", "तक": "tak", "फिर": "phir", "बाद": "baad",
    "पहले": "pehle", "लेकिन": "lekin", "मगर": "magar", "अगर": "agar", "या": "ya", "तथा": "tatha", "हो": "ho",
    "होगा": "hoga", "होगी": "hogi", "होंगे": "honge", "हुआ": "hua", "हुई": "hui", "हुए": "hue", "लगा": "laga",
    "बहुत": "bahut", "थोड़ा": "thoda", "थोड़ी": "thodi", "थोड़े": "thode", "सा": "sa", "सी": "si", "से": "se",
    "इसलिए": "isliye", "इसीलिए": "isiliye", "कितना": "kitna", "कितने": "kitne", "कितनी": "kitni", "ऐसा": "aisa",
    "ऐसी": "aisi", "जैसा": "jaisa", "वही": "wahi", "यही": "yahi", "उनका": "unka", "उनकी": "unki", "उनके": "unke",
    "इनका": "inka", "इनकी": "inki", "इनके": "inke", "तुम्हारा": "tumhara", "तेरा": "tera", "तू": "tu", "मैम": "ma'am",
    "ओके": "okay", "ओके": "okay", "हेलो": "hello", "थैंक्यू": "thank you", "सर": "sir", "भाई": "bhai", "दोस्त": "dost",
    "दोस्तों": "doston", "नमस्कार": "namaskar", "धन्यवाद": "dhanyavad", "स्वागत": "swagat", "आपका": "aapka",
    "आपकी": "aapki", "आपके": "aapke", "आपको": "aapko", "आपने": "aapne", "हमने": "humne", "हमें": "humein",
    "तुम्हें": "tumhein", "चीज": "cheez", "चीज़": "cheez", "चीजें": "cheezein", "चीज़ें": "cheezein",
}
EXTRA_LEX.update({"लिबरऑफिस": "libreoffice", "नाइन्टीन": "nineteen", "एक्चुअली": "actually", "पेसेंट": "patient", "पबजी": "pubg",
                  "पबज़ी": "pubg", "यूटूब": "youtube", "यूट्यूब": "youtube", "व्हाट्सएप": "whatsapp", "बांका": "banka"})
LEX = dict(rh.LEX)
LEX.update(EXTRA_LEX)
rh.LEX.update(LEX)

DEVA_TOK = re.compile(r"[ऀ-ॣ॰-ॿ]+")
DIGITS = {ord(c): str(i) for i, c in enumerate("०१२३४५६७८९")}


def norm_deva(w):
    w = unicodedata.normalize("NFC", w).replace("‍", "").replace("‌", "")
    return w


import inspect
_src = inspect.getsource(rh.roman_word).replace('.replace("jn", "gy")', '')   # global jn->gy mangled e.g. bijnes -> bigyes
exec(_src, rh.__dict__)  # rebinds rh.roman_word without the global jn->gy rewrite (only ज्ञ gets gy, below)


def _fix(r):
    r = re.sub(r"(?<=[a-z])ie$", "iye", r)
    r = re.sub(r"ie(?=ga$|gi$|ge$|nge$)", "iye", r)
    r = re.sub(r"(a|aa)e(?=$|nge$|ga$|gi$)", "ye", r) if False else r
    r = re.sub(r"aae(?=$|nge$|ga$|gi$|n$)", "aye", r)
    r = re.sub(r"aie$", "aiye", r)
    r = re.sub(r"(?<=[bcdfghjklmnprstvz])y$", "ya", r)
    r = re.sub(r"(tr|dr|kr|pr|ntr)$", lambda m: m.group(1) + "a", r)
    return r


def det(w):
    w = norm_deva(w).replace("ज्ञ", "ग्य")
    return _fix(rh.roman_word(w))


def cons(x):
    x = x.lower().replace("ph", "f").replace("ck", "k").replace("sh", "s").replace("ch", "c").replace("kh", "k").replace("gh", "g")
    x = re.sub(r"c(?=[ei])", "s", x).replace("c", "k").replace("q", "k").replace("z", "j").replace("w", "v").replace("x", "ks")
    x = re.sub(r"[jzs]", "s", x)
    x = re.sub(r"[aeiouyh]", "", x)
    return re.sub(r"(.)\1+", r"\1", x)


def skel(x):
    x = x.replace("aa", "a").replace("ee", "i").replace("oo", "u").replace("w", "v").replace("c", "k").replace("ph", "f").replace("ck", "k")
    x = re.sub(r"h(?=[aeiou]|$)", "", x) if False else x
    return re.sub(r"(.)\1+", r"\1", x)


def sim(a, b):
    return difflib.SequenceMatcher(None, skel(a), skel(b)).ratio()


def accept_proposal(p, d, zipf):
    """phonetic-similarity + wordfreq filter on an LLM English-spelling proposal p for deterministic spelling d."""
    if not re.fullmatch(r"[a-z]{3,20}", p):
        return False, "shape"
    z = zipf(p, "en")
    if z < 3.0 or (len(p) == 3 and z < 3.8):
        return False, "rare"
    s = max(sim(p, d), difflib.SequenceMatcher(None, cons(p), cons(d)).ratio() - 0.05)
    if s < 0.6 or len(p) > len(d) + 4:
        return False, "dissimilar"
    if z - zipf(d, "en") < 0.8:
        return False, "det_is_english_like"
    return True, "ok"


def tokens(text):
    """Split into (is_deva, piece) pieces."""
    out, pos = [], 0
    for m in DEVA_TOK.finditer(text):
        if m.start() > pos:
            out.append((False, text[pos:m.start()]))
        out.append((True, m.group()))
        pos = m.end()
    if pos < len(text):
        out.append((False, text[pos:]))
    return out
