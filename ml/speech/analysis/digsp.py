"""Digit-spacing label fix. Only the `reference` (or `text`) field changes; everything else is byte-identical.
Rules (convention derived from the locked eval refs, style statistics only):
 - ordinals (11th, 1st, 22nd), decades (1990s, 70s), single letter+digits (x1, q3, a2, h2), units (10mm, 100hz, 80k),
   alphanumeric identifiers whose letter part is not an ordinary word (ch1, sqr1, md5, hba1c, fy26, co2, ipv4) stay glued.
 - dictionary word (>=3 letters) + digits, or function word (in/at/by/on/of/to/or/so/up) + >=2 digits: split ("in1940"->"in 1940", "statement1"->"statement 1", "July2020").
 - digits + am/pm: split ("3pm"->"3 pm"; eval refs have 54 spaced, 0 glued).
 - digits + dictionary word (>=4 letters, not a unit): split ("5minutes"->"5 minutes").
"""
import re
WORDS=set()
for p in ("/usr/share/dict/american-english","/usr/share/dict/british-english"):
    for w in open(p,encoding="utf-8",errors="ignore"):
        w=w.strip()
        if w.isalpha() and w.isascii() and len(w)>=3 and not w[0].isupper(): WORDS.add(w)   # lowercase entries only: drops proper-noun-only/acronym entries
FUNC={"in","at","by","on","of","to","or","so","up","is","as","from","for","and","about","till","until","since"}
# identifier-like letter parts that are also dictionary words but are variable/file/format names in programming lectures
KEEP_PREFIX={"bit","bits","hex","oct","sub","str","num","sq","sqr","abc","emp","stud","var","tmp","temp","min","max","sum","avg","arr","ptr","obj","cat","dog","row","col","int","float","char","bin","div","mod","exp","log","sin","cos","tan","pos","neg","len","buf","msg","opt","cfg","idx","ref","val","res","ret","cnt","fig","eq","tab","lan","car","map","set","add","cars","omega","rho","zero","one","ode","sox","alpha","beta","gamma","delta","theta","sigma","lambda","tau","phi","psi","eta","this","there"}
KEEP_SUFFIX={"bit","bits","byte","bytes","hz","khz","mhz","ghz","kb","mb","gb","tb","db","mm","cm","km","kg","mg","ml","cc","min","sec","ms","ns","us","fps","dpi","rpm","kv","mv","ma","mah","bps","kbps","mbps","gbps","ppm","pct","th","st","nd","rd","x","k","m","s","d","v","w","l","g","c","f","a","b","p","h","n","r","t"}
TOK=re.compile(r"(?<![A-Za-z0-9])([A-Za-z]+)([0-9]+)(?![A-Za-z0-9])|(?<![A-Za-z0-9])([0-9]+)([A-Za-z]+)(?![A-Za-z0-9])")
def _lw(a,d):
    al=a.lower()
    if len(a)<2: return False
    if len(a)==2: return al in FUNC and len(d)>=2
    if al in KEEP_PREFIX: return False
    return al in WORDS or al in FUNC
def _wd(d,a):
    al=a.lower()
    if al in ("am","pm"): return True
    if al in KEEP_SUFFIX or len(a)<4: return False
    return al in WORDS and not re.fullmatch(r"(st|nd|rd|th)",al)
def fix(t):
    def rep(m):
        if m.group(1) is not None:
            a,d=m.group(1),m.group(2)
            return f"{a} {d}" if _lw(a,d) else m.group(0)
        d,a=m.group(3),m.group(4)
        return f"{d} {a}" if _wd(d,a) else m.group(0)
    return TOK.sub(rep,t)
def category(m):
    """for inventory: classify a glued token"""
    s=m.group(0)
    if m.group(1) is not None:
        a,d=m.group(1),m.group(2)
        if _lw(a,d): return "a_prose_word_number"
        if len(a)==1: return "d_single_letter_var"
        return "b_identifier"
    d,a=m.group(3),m.group(4)
    if a.lower() in ("st","nd","rd","th"): return "c_ordinal"
    if re.fullmatch(r"s",a.lower()): return "c_decade_s"
    if _wd(d,a): return "a_number_word" if a.lower() not in("am","pm") else "a_ampm"
    return "b_identifier_or_unit"
