"""Spelling-tolerant canonicalisation for Roman Hinglish (scorer-side only).

canon(token) maps a Roman token to the canonical spelling of its word using the attested-variant map in
eval/variants/. It never merges grammatically distinct words: every token in PROTECTED is returned unchanged
(and is never the *source* of a merge), so hai/hain, ke/ka/ki, par/pe, kar/ke, mein/main, ... stay distinct.

Data files (see variants/README.md for licenses):
  variants_permissive.tsv         Aksharantar (CC-BY / CC0) only
  variants_evalonly_dakshina.tsv  derived from Dakshina (CC BY-SA 4.0): EVAL ONLY, never a training target
  extra_variants.tsv              hand-curated additions (our own)
Set use_eval_only=False to load only the permissive + hand-curated data.
"""
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
VARIANT_DIR = os.path.join(HERE, "variants")

# Words that are distinct grammatical items (or gender/number forms) and must never be merged with a neighbour.
_PROTECTED_GROUPS = """
hai hain ho hoon hota hoti hote hoga hogi honge hua hui hue hone hona tha thi the thin
ka ke ki ko par pe se mein main ne na nahi
kar karke karte karta karti karna karne karni karo karein karenge karega karegi karoge kiya kiye
raha rahi rahe rahin gaya gayi gaye aaya aayi aaye
wala wali wale bada badi bade chota choti chote
mera meri mere tera teri tere apna apni apne hamara hamari hamare tumhara tumhari tumhare
uska uski uske unka unki unke iska iski iske inka inki inke
is us in un ise use inhe unhe
aur ya jo kya kyun kyunki hum tum tu aap mujhe tumhe ek do teen
kab kahan kaha kaun kitna kitni kitne kaise kaisa kaisi
sab sabhi koi kuch tab jab ab abhi agar lekin magar
sakta sakti sakte chahiye chahta chahti chahte liye bhi hi to toh tak bas
"""
PROTECTED = set(_PROTECTED_GROUPS.split())

# Closed-class Hindi/Hinglish function words used for the separate function-word error bucket.
FUNCTION_WORDS = set("""
hai hain ho hoon hun hota hoti hote hoga hogi honge hua hui hue tha thi the thin raha rahi rahe rahin
ka ke ki ko ne se mein main par pe tak liye saath sath bina wala wali wale
aur ya jo ki kya kyun kyunki ki toh to bhi hi na nahi nahin mat
ye yeh wo woh is us in un ise use inhe unhe yahan wahan yaha waha
mai hum tum tu aap mujhe mujh humein hume tumhe tumhein
mera meri mere tera teri tere apna apni apne hamara hamari hamare tumhara uska uski uske unka unki unke iska iski iske
kuch koi sab sabhi kab kahan kaha kaun kitna kitni kitne kaise kaisa kaisi
tab jab ab abhi phir fir agar lekin magar par isliye
sakta sakti sakte chahiye gaya gayi gaye kar karke
ek do
""".split())


def is_protected_form(tok):
    return tok in PROTECTED


def _load(path, into):
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as f:
        for l in f:
            if l.startswith("#") or not l.strip():
                continue
            p = l.rstrip("\n").split("\t")
            if len(p) >= 2 and p[0] not in PROTECTED and p[0] != p[1]:
                into[p[0]] = p[1]


class VariantMap:
    def __init__(self, use_eval_only=True, variant_dir=VARIANT_DIR):
        self.map = {}
        _load(os.path.join(variant_dir, "variants_permissive.tsv"), self.map)
        if use_eval_only:
            _load(os.path.join(variant_dir, "variants_evalonly_dakshina.tsv"), self.map)
        _load(os.path.join(variant_dir, "extra_variants.tsv"), self.map)   # loaded last: hand-curated wins
        for k in list(self.map):                                           # resolve chains a->b->c
            v, seen = self.map[k], {k}
            while v in self.map and v not in seen:
                seen.add(v)
                v = self.map[v]
            self.map[k] = v
        self.map = {k: v for k, v in self.map.items() if k != v and v not in self.map}   # drops cycles

    def canon(self, tok):
        if tok in PROTECTED:
            return tok
        c = self.map.get(tok, tok)
        return c

    def canon_tokens(self, toks):
        return [self.canon(t) for t in toks]


_default = None


def default_map(use_eval_only=True):
    global _default
    if _default is None or _default[0] != use_eval_only:
        _default = (use_eval_only, VariantMap(use_eval_only))
    return _default[1]


def canon(tok):
    return default_map().canon(tok)
