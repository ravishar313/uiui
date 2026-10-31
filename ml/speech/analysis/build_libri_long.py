"""LibriSpeech train manifest (clips <= 15 s) -> 15-25 s clips by joining ADJACENT utterances of one chapter
(utterance numbers i, i+1, ...; a gap in numbering = an utterance we do not have, so the run is cut there).
0.25 s silence between pieces. Output: data-clean/librispeech_long.jsonl + wavs in data-clean/audio/librispeech_long/."""
import json, collections, os, sys
from uiui_root import ROOT
import numpy as np, soundfile as sf
SRC = ROOT + "/data/manifests/librispeech/train.jsonl"
OUT = ROOT + "/data-clean/librispeech_long.jsonl"
AUD = ROOT + "/data-clean/audio/librispeech_long"
LO, HI, GAP = 15.0, 25.0, 0.25
os.makedirs(AUD, exist_ok=True)
ch = collections.defaultdict(list)
for l in open(SRC):
    r = json.loads(l); s, c, u = r["id"].split("-"); ch[(s, c)].append((int(u), r))
n = secs = 0
with open(OUT + ".tmp", "w") as f:
    for (s, c), items in sorted(ch.items()):
        items.sort(key=lambda x: x[0])
        run = []
        def flush(run):
            global n, secs
            if len(run) < 2: return
            d = sum(r["seconds"] for _, r in run) + GAP * (len(run) - 1)
            if not (LO <= d <= HI): return
            sil = np.zeros(int(16000 * GAP), np.int16)
            parts = []
            for i, (_, r) in enumerate(run):
                w, sr = sf.read(r["audio"], dtype="int16"); assert sr == 16000
                if i: parts.append(sil)
                parts.append(w)
            cid = f"{s}-{c}-{run[0][0]:04d}to{run[-1][0]:04d}"
            p = f"{AUD}/{cid}.wav"; sf.write(p, np.concatenate(parts), 16000, subtype="PCM_16")
            f.write(json.dumps({"id": cid, "audio": p, "reference": " ".join(r["reference"] for _, r in run),
                                "speaker": s, "source": "librispeech_long", "lang": "en", "seconds": round(d, 2)}, ensure_ascii=False) + "\n")
            n += 1; secs += d
        for u, r in items:
            cand = run + [(u, r)]
            d = sum(x["seconds"] for _, x in cand) + GAP * (len(cand) - 1)
            if run and (u != run[-1][0] + 1 or d > HI):
                flush(run); run = [(u, r)]
            else:
                run = cand
            # close a run as soon as it is long enough, so clips stay near 15-25 s
            d = sum(x["seconds"] for _, x in run) + GAP * (len(run) - 1)
            if d >= LO and len(run) >= 2: flush(run); run = []
        flush(run)
os.replace(OUT + ".tmp", OUT)
print(f"{n} clips, {secs/3600:.2f} h")
