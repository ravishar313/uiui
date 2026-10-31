"""Build general-English regression + replay sets from permissively licensed public text.

Sources (same families the original model trained on; see resources/MiniLM data cards):
  FLEURS en_us transcripts  (CC BY 4.0)    data/general/fleurs_en_{train,dev,test}.tsv  (col 3 = raw cased text)
  OASST2 English messages   (Apache-2.0)   data/general/oasst2_ready.trees.jsonl.gz
Outputs (jsonl {id,text,source}):
  data/general/regression_eval.jsonl   FLEURS dev + hash-held-out OASST2 sentences  (never trained on)
  data/general/replay_train.jsonl      FLEURS train + remaining OASST2 sentences    (replay pool)
Download commands are in README.md.
"""
import argparse, gzip, hashlib, json, random
from pathlib import Path
import regex as re

BAD = re.compile(r"[/\\@`<>\[\]{}|=_*#$~^]|https?:|www\.|\d\.\d|\n|:\d")
SENT = re.compile(r"(?<=[.?!])\s+(?=[\"“(]?[A-Z])")


def ok(s):
    n = len(s.split())
    return 5 <= n <= 40 and not BAD.search(s) and s[-1] in ".?!" and s[0].isupper() and s.count('"') % 2 == 0 \
        and sum(c.isascii() for c in s) == len(s)


def h(s):
    return int(hashlib.sha1(s.encode()).hexdigest(), 16)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=str(Path(__file__).parent / "data/general"))
    ap.add_argument("--oasst-eval", type=int, default=400)
    ap.add_argument("--oasst-replay", type=int, default=6000)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    d = Path(a.dir)
    ev, tr = [], []
    for split, bucket in (("dev", ev), ("train", tr)):
        for line in (d / f"fleurs_en_{split}.tsv").read_text().splitlines():
            t = line.split("\t")[2].strip()
            if ok(t) and t not in {x["text"] for x in bucket}:
                bucket.append({"text": t, "source": f"fleurs-{split}"})
    oe, ot, seen = [], [], set()
    def walk(node):
        if node.get("lang") == "en" and not node.get("deleted") and node.get("review_result") is not False:
            for s in SENT.split(node["text"].replace("\r", "")):
                s = " ".join(s.split())
                if ok(s) and s not in seen:
                    seen.add(s)
                    # whole-thread-ish grouping: hash on the message id so one message never straddles splits
                    (oe if h(node["message_id"]) % 20 == 0 else ot).append({"text": s, "source": "oasst2"})
        for r in node.get("replies", []):
            walk(r)
    with gzip.open(d / "oasst2_ready.trees.jsonl.gz", "rt") as f:
        for line in f:
            walk(json.loads(line)["prompt"])
    rnd = random.Random(a.seed)
    rnd.shuffle(oe); rnd.shuffle(ot)
    ev += oe[: a.oasst_eval]
    tr += ot[: a.oasst_replay]
    ev_texts = {x["text"] for x in ev}
    tr = [x for x in tr if x["text"] not in ev_texts]
    for name, rows, pre in (("regression_eval", ev, "gen-ev"), ("replay_train", tr, "gen-tr")):
        with open(d / f"{name}.jsonl", "w") as f:
            for i, r in enumerate(rows):
                f.write(json.dumps({"id": f"{pre}-{i:05d}", "text": r["text"], "mix": "en", "source": r["source"]}, ensure_ascii=False) + "\n")
        print(name, len(rows))

main()
