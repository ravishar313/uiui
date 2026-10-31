"""Parity: shipped int8 ONNX (onnxruntime, app session options) vs PyTorch FP32 checkpoint through the
same Python port of the app pipeline. Inputs are ASR-style (lowercase, no punctuation)."""
import argparse, json, os, random, time
import numpy as np
from uiui_cleanup import make_cleaner, words_in
from tagging import strip_input


def load(path, n, rnd):
    rows = [json.loads(l) for l in open(path)]
    rnd.shuffle(rows)
    return [r["text"] for r in rows[:n]]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workplace", default=os.path.join(os.environ.get("UIUI_ML_ROOT") or "workspace", "data/workplace/sentences_eval.jsonl"))
    ap.add_argument("--general", default="data/general/regression_eval.jsonl")
    ap.add_argument("--n-workplace", type=int, default=100)
    ap.add_argument("--n-general", type=int, default=100)
    ap.add_argument("--long", type=int, default=10, help="also N long (multi-sentence, ~60-150 word) inputs to exercise windowing")
    ap.add_argument("--device", default="cpu")
    ap.add_argument("--out", default="parity_report.json")
    a = ap.parse_args()
    rnd = random.Random(7)
    texts = load(a.workplace, a.n_workplace, rnd) + load(a.general, a.n_general, rnd)
    inputs = [strip_input(t) for t in texts]
    # long inputs: concatenate random sentences (also tests >126-piece multi-window path)
    pool = [strip_input(t) for t in load(a.workplace, 400, rnd)]
    inputs += [" ".join(rnd.sample(pool, rnd.choice([6, 10, 14]))) for _ in range(a.long)]
    onnx, torch_ = make_cleaner("onnx"), make_cleaner("torch", device=a.device)

    t0 = time.time(); res = []
    for s in inputs:
        w1, p1, l1 = onnx.tags(s); w2, p2, l2 = torch_.tags(s)
        res.append((s, p1, p2, l1, l2, onnx.clean(s), torch_.clean(s)))
    n_words = sum(len(r[1]) for r in res)
    punct_dis = sum(x[0] != y[0] for r in res for x, y in zip(r[1], r[2]))
    case_dis = sum(x[1] != y[1] for r in res for x, y in zip(r[1], r[2]))
    sent_tag_eq = sum(r[1] == r[2] for r in res)
    out_eq = sum(r[5] == r[6] for r in res)
    dl = np.concatenate([np.abs(r[3] - r[4]).reshape(-1) for r in res])
    # margin of disagreeing words
    dis = [(r[0], i) for r in res for i, (x, y) in enumerate(zip(r[1], r[2])) if x != y]
    rep = dict(sentences=len(inputs), words=n_words, punct_disagree=punct_dis, case_disagree=case_dis,
               punct_agree_pct=100 * (1 - punct_dis / n_words), case_agree_pct=100 * (1 - case_dis / n_words),
               sentences_identical_tags=sent_tag_eq, sentences_identical_output=out_eq,
               logit_abs_diff_mean=float(dl.mean()), logit_abs_diff_p99=float(np.percentile(dl, 99)),
               logit_abs_diff_max=float(dl.max()), seconds=time.time() - t0, torch_device=a.device)
    rep["disagreements"] = [{"input": s, "word": words_in(s)[i].original,
                             "onnx": [int(v) for v in next(r for r in res if r[0] == s)[1][i]],
                             "torch": [int(v) for v in next(r for r in res if r[0] == s)[2][i]]} for s, i in dis[:25]]
    json.dump(rep, open(a.out, "w"), indent=1, ensure_ascii=False)
    print(json.dumps({k: v for k, v in rep.items() if k != "disagreements"}, indent=1))
    for d in rep["disagreements"][:10]:
        print(d)

main()
