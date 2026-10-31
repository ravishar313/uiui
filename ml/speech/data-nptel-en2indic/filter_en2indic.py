#!/usr/bin/env python3
"""Stream NPTEL en2indic parquet shards and write a filtered 16 kHz mono wav corpus + manifests.

Single process, one row group in memory at a time, CPU only. Run with `nice -n 19 python -I`.
Output: <out>/wav/<course_id>/<id>.wav, <out>/train.jsonl, <out>/dev.jsonl, <out>/stats.json
Parquet inputs are untrusted data: only pyarrow/soundfile decode them, nothing is executed.
"""
import argparse
import hashlib
import io
import json
import os
import re
import sys
from collections import Counter, defaultdict
from math import gcd

PUNCT_RE = re.compile(r"[^\w\s]|_", re.UNICODE)


def normalize(s):
    """Lowercase, strip punctuation (hyphens/apostrophes become/vanish as space/none), keep digits."""
    s = (s or "").lower().replace("'", "").replace("’", "")
    s = PUNCT_RE.sub(" ", s)
    return " ".join(s.split())


def wer(ref, hyp):
    """Word error rate on already-normalized strings. Empty ref -> 0.0 if hyp empty else 1.0."""
    r, h = ref.split(), hyp.split()
    if not r:
        return 0.0 if not h else 1.0
    prev = list(range(len(h) + 1))
    for i, rw in enumerate(r, 1):
        cur = [i] + [0] * len(h)
        for j, hw in enumerate(h, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (rw != hw))
        prev = cur
    return prev[-1] / len(r)


def is_dev_course(course_id, dev_fraction=0.02, salt="nptel-dev-v1"):
    """Deterministic course-level holdout: stable across runs, shards, machines."""
    h = hashlib.sha256(f"{salt}:{course_id}".encode()).digest()
    return int.from_bytes(h[:8], "big") / 2**64 < dev_fraction


def resample_mono_16k(audio, sr):
    import numpy as np
    from scipy.signal import resample_poly
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    if sr != 16000:
        g = gcd(sr, 16000)
        audio = resample_poly(audio, 16000 // g, sr // g)
    return np.clip(audio, -1.0, 1.0).astype("float32")


def safe_name(s):
    return re.sub(r"[^A-Za-z0-9._-]", "_", str(s))[:120]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("shards", nargs="+", help="parquet shard paths, processed one at a time")
    ap.add_argument("--out", required=True)
    ap.add_argument("--min-dur", type=float, default=2.0)
    ap.add_argument("--max-dur", type=float, default=15.0)
    ap.add_argument("--max-wer", type=float, default=0.15)
    ap.add_argument("--min-align", type=float, default=None, help="alignment_score threshold (set after inspecting distribution)")
    ap.add_argument("--course-cap-hours", type=float, default=1.0)
    ap.add_argument("--video-cap-minutes", type=float, default=0.0, help="optional per-video cap (0=off) to spread a course cap across lectures")
    ap.add_argument("--dev-fraction", type=float, default=0.02)
    ap.add_argument("--course-field", default=None, help="override course id column")
    ap.add_argument("--dry-run", action="store_true", help="write stats only, no wav/manifests")
    ap.add_argument("--batch-rows", type=int, default=256)
    ap.add_argument("--examples", type=int, default=400, help="reservoir size for pass/fail examples in stats")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--exclude-texts", default=None, help="file with one normalized eval reference per line; exact-match clips are dropped (leakage)")
    ap.add_argument("--exclude-courses", default=None, help="file with one course_id per line to drop entirely")
    a = ap.parse_args()
    if a.min_align is None:
        sys.exit("--min-align is required (see README / stats for the shard distribution)")

    import random
    import pyarrow.parquet as pq
    import soundfile as sf

    rng = random.Random(a.seed)
    ex_texts = set(l.strip() for l in open(a.exclude_texts, encoding="utf-8")) if a.exclude_texts else set()
    ex_courses = set(l.strip() for l in open(a.exclude_courses, encoding="utf-8")) if a.exclude_courses else set()
    os.makedirs(a.out, exist_ok=True)
    if not a.dry_run:
        os.makedirs(os.path.join(a.out, "wav"), exist_ok=True)
        # resume-safe for per-course caps: reload prior manifests
    course_secs = defaultdict(float)
    video_secs = defaultdict(float)
    mans = {}
    if not a.dry_run:
        for split in ("train", "dev"):
            p = os.path.join(a.out, f"{split}.jsonl")
            if os.path.exists(p):
                with open(p) as f:
                    for line in f:
                        r = json.loads(line)
                        course_secs[r["course_id"]] += r["duration"]
            mans[split] = open(p, "a")

    st = Counter()
    secs = Counter()
    pass_courses = set()
    all_courses = set()
    ex_pass, ex_fail, seen_p, seen_f = [], [], 0, 0

    def reservoir(lst, seen, item):
        if len(lst) < a.examples:
            lst.append(item)
        else:
            j = rng.randint(0, seen)
            if j < a.examples:
                lst[j] = item

    for shard in a.shards:
        pf = pq.ParquetFile(shard)
        names = pf.schema_arrow.names
        cf = a.course_field or next((c for c in ("course_id", "course", "course_name", "video_id", "video", "lecture_id") if c in names), None)
        idf = next((c for c in ("id", "audio_id", "utt_id", "segment_id") if c in names), None)
        acol = next((c for c in ("audio", "chunked_audio_filepath") if c in names), None)
        # skip the ~20 translation columns: they are large and unused here
        cols = [c for c in names if not (c.endswith("_text") and c not in ("text", "pred_text")) and not c.endswith("_mining_score")]
        for batch in pf.iter_batches(batch_size=a.batch_rows, columns=cols):
            for r in batch.to_pylist():
                st["total"] += 1
                audio = r.get(acol)
                text = r.get("text") or ""
                pred = r.get("pred_text") or ""
                al = r.get("alignment_score")
                cid = str(r[cf]) if cf and r.get(cf) is not None else "unknown"
                all_courses.add(cid)
                dur = r.get("duration")
                reason = None
                # cheap checks first; decode audio only for survivors
                if dur is not None:
                    dur = float(dur)
                    if not (a.min_dur <= dur <= a.max_dur):
                        reason = "duration"
                if reason is None and (al is None or al < a.min_align):
                    reason = "alignment"
                w = None
                if reason is None:
                    w = wer(normalize(text), normalize(pred))
                    if w > a.max_wer:
                        reason = "wer"
                if reason is None and not normalize(text):
                    reason = "empty_text"
                if reason is None and (cid in ex_courses or normalize(text) in ex_texts):
                    reason = "eval_leak"
                vid = str(r.get("video_id", ""))
                if reason is None and course_secs[cid] >= a.course_cap_hours * 3600:
                    reason = "course_cap"
                if reason is None and a.video_cap_minutes and video_secs[vid] >= a.video_cap_minutes * 60:
                    reason = "video_cap"
                data = audio.get("bytes") if isinstance(audio, dict) else None
                if reason is None and (dur is None or not data):
                    # need decode for duration (no duration column)
                    try:
                        arr, sr = sf.read(io.BytesIO(data), dtype="float32", always_2d=False)
                        dur = len(arr) / sr
                    except Exception:
                        reason = "decode_error"
                    else:
                        if not (a.min_dur <= dur <= a.max_dur):
                            reason = "duration"
                        elif course_secs[cid] + dur > a.course_cap_hours * 3600 + a.max_dur:
                            reason = "course_cap"
                # the audio "path" inside the struct is a per-video index, not unique: use video_id + start_time
                if idf and r.get(idf) is not None:
                    clip_id = str(r[idf])
                else:
                    clip_id = f"{r.get('video_id', cid)}_{int(round(float(r.get('start_time') or 0) * 1000)):08d}"
                info = {"id": clip_id, "course_id": cid, "duration": dur, "text": text, "pred_text": pred, "wer": w, "alignment_score": al}
                if reason:
                    st["fail_" + reason] += 1
                    seen_f += 1
                    reservoir(ex_fail, seen_f - 1, {**info, "reason": reason})
                    continue
                split = "dev" if is_dev_course(cid, a.dev_fraction) else "train"
                st["pass"] += 1
                st["pass_" + split] += 1
                secs[split] += dur
                course_secs[cid] += dur
                video_secs[vid] += dur
                pass_courses.add(cid)
                seen_p += 1
                reservoir(ex_pass, seen_p - 1, info)
                if not a.dry_run:
                    try:
                        arr, sr = sf.read(io.BytesIO(data), dtype="float32", always_2d=False)
                        arr = resample_mono_16k(arr, sr)
                        d = os.path.join(a.out, "wav", safe_name(cid))
                        os.makedirs(d, exist_ok=True)
                        path = os.path.join(d, safe_name(clip_id) + ".wav")
                        sf.write(path, arr, 16000, subtype="PCM_16")
                    except Exception:
                        st["pass"] -= 1; st["pass_" + split] -= 1; st["fail_decode_error"] += 1
                        secs[split] -= dur; course_secs[cid] -= dur
                        continue
                    mans[split].write(json.dumps({
                        "id": clip_id, "audio_filepath": os.path.abspath(path), "duration": round(len(arr) / 16000, 3),
                        "text": text, "course_id": cid, "wer_text_pred": round(w, 4), "alignment_score": al,
                    }, ensure_ascii=False) + "\n")
            print(f"[{shard}] rows={st['total']} pass={st['pass']}", file=sys.stderr, flush=True)
        for m in mans.values():
            m.flush()

    for m in mans.values():
        m.close()
    stats = {
        "args": vars(a), "counts": dict(st), "pass_hours": {k: v / 3600 for k, v in secs.items()},
        "courses_seen": len(all_courses), "courses_passing": len(pass_courses),
        "examples_pass": ex_pass, "examples_fail": ex_fail,
    }
    with open(os.path.join(a.out, "stats.json"), "w") as f:
        json.dump(stats, f, ensure_ascii=False, indent=1)
    print(json.dumps({"counts": dict(st), "pass_hours": stats["pass_hours"], "courses": [len(all_courses), len(pass_courses)]}))


if __name__ == "__main__":
    main()
