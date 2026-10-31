#!/usr/bin/env python3
"""ONE-TIME: write locked/hashes.json + allowed_train.json for an AR home.   python3 lock.py --ar-home $UIUI_ML_ROOT/ar [--data-root $UIUI_ML_ROOT]
Hashes (v2 = English-first Indian professionals; the v1 Hinglish files live on in locked-v1-hinglish/ and are not locked here): the three locked sets, the scorer tree locked/evalx,
select_v2.py/verify.py/build_sets_v2.py, leakage_report.json, the evaluator (ar/code/train/evaluate.py), eval/score.py, the six
report-only test-set manifests, and a stat listing (path+size) of every audio file those sets reference.  verify.py re-checks all of it before each experiment."""
import argparse, hashlib, json, time
from pathlib import Path

TEST = ["data/evalsets-lexicon/hiacc", "data/evalsets-lexicon/mucs-hien-test", "data/evalsets-lexicon/fleurs-hi", "evalsets/svarah-partial", "evalsets/monsoon-en-in", "evalsets/librispeech-clean"]
LOCKED = ["dev-sel.jsonl", "dev-hold.jsonl", "vibe.jsonl", "select_v2.py", "verify.py", "build_sets_v2.py", "leakage_report.json", "allowed_train.json"]
AR_CODE = ["code/train/evaluate.py"]
DATA = [f"{t}/manifest.jsonl" for t in TEST]


def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def audio_stat_sha(manifest):
    lines = []
    for l in Path(manifest).read_text(encoding="utf-8").splitlines():
        if l.strip():
            a = json.loads(l)["audio"]; p = Path(a)
            lines.append(f"{a} {p.stat().st_size if p.exists() else -1}")
    return hashlib.sha256("\n".join(sorted(lines)).encode()).hexdigest()


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--ar-home", required=True); ap.add_argument("--data-root", default=None); a = ap.parse_args()
    ar = Path(a.ar_home).expanduser().resolve(); data = Path(a.data_root).expanduser().resolve() if a.data_root else ar.parent
    L = ar / "locked"
    rep = json.loads((L / "leakage_report.json").read_text())
    (L / "allowed_train.json").write_text(json.dumps(rep["allowed_train_manifests"], indent=1))
    files = {f"ar:locked/{f}": sha(L / f) for f in LOCKED}
    files.update({f"ar:locked/{p.relative_to(L)}": sha(p) for p in sorted((L / "evalx").rglob("*")) if p.is_file() and "__pycache__" not in p.parts})   # scorer code: score.py, fair_wer.py, roman_variants.py, variants/
    files.update({f"ar:{f}": sha(ar / f) for f in AR_CODE}); files.update({f"data:{f}": sha(data / f) for f in DATA})
    stats = {n: audio_stat_sha(L / f"{n}.jsonl") for n in ("dev-sel", "dev-hold", "vibe")}
    stats.update({Path(t).name: audio_stat_sha(data / t / "manifest.jsonl") for t in TEST})
    (L / "hashes.json").write_text(json.dumps({"created": time.strftime("%F %T"), "files": files, "audio_stat_sha256": stats}, indent=1))
    print(f"locked {len(files)} files, {len(stats)} audio listings -> {L / 'hashes.json'}")


if __name__ == "__main__":
    main()
