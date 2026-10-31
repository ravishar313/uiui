"""Build ONE word-level lexicon over all unique Devanagari words in the corpus.
  python build_lexicon.py [--no-llm] [--min-count N]
Reads data/stage/*/rows.jsonl (field text) + evalsets/*/source_references.jsonl (field source).
LLM (Qwen2.5-7B MLX, few-shot, prefix-cached) only PROPOSES English spellings; kept iff lexlib.accept_proposal passes
(phonetic similarity + wordfreq) and the word is not in lexicon/denylist.txt or protected LEX.
Writes lexicon/lexicon.tsv (reviewable), lexicon/llm_cache.jsonl (resumable proposals).
"""
import argparse, collections, copy, glob, json, os, sys, time
from uiui_root import ROOT
os.environ["HF_HOME"] = ROOT + "/hf"; os.environ["HF_HUB_OFFLINE"] = "1"
sys.path.insert(0, os.path.dirname(__file__))
from lexlib import *
from wordfreq import zipf_frequency
from common import Run, DATA

SYS = ("You decide whether a Devanagari word is an English loanword (an English word that Hindi speakers say, written in "
       "Devanagari script). Reply with ONLY the English word in lowercase Latin letters, or NO if the word is native Hindi, "
       "Urdu, Sanskrit, or a person or place name.")
SHOTS = [("क्लिक", "click"), ("ऑफिस", "office"), ("फोन", "phone"), ("मीटिंग", "meeting"), ("कर", "NO"), ("साझा", "NO"),
         ("चीन", "NO"), ("बात", "NO"), ("स्कूल", "school"), ("सरकार", "NO"), ("बस", "NO"), ("पेपर", "paper"), ("लेकिन", "NO"),
         ("टाइम", "time"), ("दिल्ली", "NO"), ("प्रोजेक्ट", "project"), ("आदमी", "NO"), ("पोस्ट", "post"), ("पैसे", "NO"),
         ("कैसे", "NO"), ("डॉक्टर", "doctor"), ("सिलेंडर", "cylinder"), ("गैस", "gas"), ("मास्टर", "master"), ("नाम", "NO"),
         ("रेल", "rail"), ("तेल", "NO"), ("बिल्ड", "build"), ("पहचान", "NO"), ("कार", "car"), ("गाँव", "NO")]
LOANMARK = set("ऑॉ")


def collect():
    c = collections.Counter()
    srcs = collections.Counter()
    for f in glob.glob(str(DATA / "stage/*/rows.jsonl")):
        for l in open(f):
            t = json.loads(l)["text"]
            for d, p in tokens(t):
                if d:
                    c[norm_deva(p)] += 1
    for f in glob.glob(ROOT + "/evalsets/*/source_references.jsonl"):
        for l in open(f):
            r = json.loads(l)
            for d, p in tokens(r.get("source", "") or ""):
                if d:
                    c[norm_deva(p)] += 1
    return c


def deny():
    p = DATA / "lexicon/denylist.txt"
    return {l.split("#")[0].strip() for l in open(p) if l.split("#")[0].strip()} if p.exists() else set()


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--no-llm", action="store_true"); ap.add_argument("--min-count", type=int, default=2)
    a = ap.parse_args()
    LD = DATA / "lexicon"; LD.mkdir(exist_ok=True)
    cache_p = LD / "llm_cache.jsonl"
    cache = {}
    if cache_p.exists():
        for l in open(cache_p):
            r = json.loads(l); cache[r["w"]] = r["p"]
    cnt = collect()
    dn = deny()
    todo = [w for w, n in cnt.most_common() if w not in cache and w not in LEX and w not in dn and
            (n >= a.min_count or any(ch in LOANMARK for ch in w)) and len(w) >= 2]
    print(f"unique words {len(cnt)}, tokens {sum(cnt.values())}, llm todo {len(todo)}", flush=True)
    if todo and not a.no_llm:
        import glob as g
        from mlx_lm import load, generate
        from mlx_lm.models.cache import make_prompt_cache
        M = g.glob(ROOT + "/hf/hub/models--mlx-community--Qwen2.5-7B-Instruct-4bit/snapshots/*")[0]
        model, tok = load(M)
        pre = [{"role": "system", "content": SYS}]
        for w, x in SHOTS:
            pre += [{"role": "user", "content": w}, {"role": "assistant", "content": x}]
        full = tok.apply_chat_template(pre + [{"role": "user", "content": "XX"}], add_generation_prompt=True, tokenize=False)
        prefix = full[: full.rindex("<|im_start|>user")]
        import mlx.core as mx
        base = make_prompt_cache(model)
        ptoks = tok.encode(prefix)
        model(mx.array(ptoks)[None], cache=base); mx.eval([c.state for c in base])
        run = Run("lexicon-llm", kind="data", total_steps=len(todo), tags=["data", "lexicon"], notes="Qwen2.5-7B proposals, prefix cached")
        t0 = time.time(); out = open(cache_p, "a")
        for i, w in enumerate(todo, 1):
            suffix = full[len(prefix):].replace("XX", w)
            try:
                o = generate(model, tok, prompt=tok.encode(suffix), max_tokens=8, verbose=False, prompt_cache=copy.deepcopy(base))
            except Exception as e:
                o = "ERR"
            o = o.strip().lower().split("\n")[0]
            out.write(json.dumps({"w": w, "p": o}, ensure_ascii=False) + "\n"); cache[w] = o
            if i % 100 == 0:
                out.flush(); run.log(i, rows_per_s=i / (time.time() - t0))
        out.close(); run.finish()
    rows = []
    for w, n in cnt.most_common():
        d = det(w)
        src, final, why = "det", d, ""
        if w in LEX:
            src, final = "lex", LEX[w]
        elif w in dn:
            src, why = "deny", "denylist"
        elif w in cache:
            p = cache[w].strip(".").strip()
            if p and p != "no":
                ok, why = accept_proposal(p, d, zipf_frequency)
                if ok and n <= 2 and (sim(p, d) < 0.7 or len(p) > len(d) + 2 or len(p) < len(d) - 3):
                    ok, why = False, "rare_strict"
                if ok:
                    src, final = "llm", p
        rows.append((w, n, d, cache.get(w, ""), final, src, why))
    with open(LD / "lexicon.tsv", "w") as f:
        f.write("deva\tcount\tdeterministic\tllm_proposal\tfinal\tsource\tnote\n")
        for r in rows:
            f.write("\t".join(map(str, r)) + "\n")
    s = collections.Counter(r[5] for r in rows)
    print("written", len(rows), dict(s), "llm-covered tokens", sum(r[1] for r in rows if r[5] == "llm"), "/", sum(r[1] for r in rows))


if __name__ == "__main__":
    main()
