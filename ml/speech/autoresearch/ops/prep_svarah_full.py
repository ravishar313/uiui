#!/usr/bin/env python3
"""Convert the full AI4Bharat Svarah test parquet (downloaded from the Hugging Face hub) into 16 kHz mono PCM16 wavs + manifest.jsonl.
CPU only:   python3 prep_svarah_full.py [--root $UIUI_ML_ROOT/evalsets/svarah-full]
Speaker id: the fNNNN / mNNNN token of the file name is a per-RECORDING id (3,232 of them), not a speaker; the metadata profile (gender, age group, mother tongue, state, district,
qualification, job, domain) has 115 distinct values for the ~117 speakers and is constant per file id, so a hash of it is the speaker proxy used to split dev-sel / dev-hold speaker-disjoint."""
import argparse, glob, hashlib, io, json, os, re
import numpy as np, soundfile as sf
import pyarrow.parquet as pq
from scipy.signal import resample_poly

ap = argparse.ArgumentParser(); ap.add_argument("--root", default=os.path.join(os.environ.get("UIUI_ML_ROOT") or "workspace", "evalsets/svarah-full")); a = ap.parse_args()
root = a.root; os.makedirs(root + "/audio", exist_ok=True)
PROFILE = ["gender", "age-group", "primary_language", "native_place_state", "native_place_district", "highest_qualification", "job_category", "occupation_domain"]
n = bad = 0
with open(root + "/manifest.jsonl", "w", encoding="utf-8") as out:
    for f in sorted(glob.glob(root + "/raw/data/*.parquet")):
        for r in pq.read_table(f, columns=["audio_filepath", "duration", "text", "gender", "age-group", "primary_language", "native_place_state", "native_place_district", "highest_qualification", "job_category", "occupation_domain"]).to_pylist():
            name = r["audio_filepath"]["path"]; stem = os.path.splitext(os.path.basename(name))[0]
            m = re.search(r"_([fm]\d+)_", stem)
            if not m or not (r["text"] or "").strip(): bad += 1; continue
            x, sr = sf.read(io.BytesIO(r["audio_filepath"]["bytes"]), dtype="float32", always_2d=True); x = x.mean(1)
            if sr != 16000: g = np.gcd(sr, 16000); x = resample_poly(x, 16000 // g, sr // g).astype("float32")
            p = f"{root}/audio/svarahf-{stem}.wav"; sf.write(p, x, 16000, subtype="PCM_16")
            out.write(json.dumps({"id": f"svarahf-{stem}", "cat": "en", "speaker": "p" + hashlib.sha1("|".join(str(r[c]) for c in PROFILE).encode()).hexdigest()[:8], "recording": m.group(1), "reference": re.sub(r"\s+", " ", r["text"]).strip(), "audio": p, "seconds": round(len(x) / 16000, 3),
                                  "gender": r["gender"], "age_group": r["age-group"], "mother_tongue": r["primary_language"], "state": r["native_place_state"]}, ensure_ascii=False) + "\n"); n += 1
print("clips", n, "skipped", bad)
