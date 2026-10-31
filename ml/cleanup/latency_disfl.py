import json, sys, time, torch
torch.set_num_threads(1)
from uiui_cleanup import make_cleaner
from disfl_cleaner import DisflCleaner
from tagging import strip_input
rows = [json.loads(l)["text"] for l in open("data/natural/natural_eval.jsonl")][:300]
inp = [strip_input(t) for t in rows]
ft3 = make_cleaner("torch", "runs/ft3/best"); d = DisflCleaner(sys.argv[1])
def bench(f):
    for x in inp[:20]: f(x)
    t = []
    for x in inp:
        a = time.perf_counter(); f(x); t.append(time.perf_counter() - a)
    t.sort(); return {"mean_ms": 1000 * sum(t) / len(t), "p50_ms": 1000 * t[len(t) // 2], "p95_ms": 1000 * t[int(len(t) * .95)]}
r = {"ft3": bench(ft3.clean), "disfl": bench(d.clean), "n": len(inp), "threads": 1, "device": "cpu torch fp32"}
print(json.dumps(r, indent=1))
json.dump(r, open(sys.argv[2], "w"), indent=1)
