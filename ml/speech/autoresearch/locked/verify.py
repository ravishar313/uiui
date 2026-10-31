#!/usr/bin/env python3
"""Runner pre-flight: refuse to run if any locked file / evaluator / test manifest / audio listing differs from hashes.json, or if any locked-set clip id,
audio path or speaker now appears in an allowed train manifest.   python3 -I verify.py --ar-home DIR [--data-root DIR] [--no-leak]   exit 0 ok, 2 mismatch."""
import argparse, hashlib, json, re, sys
from pathlib import Path


def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def audio_stat_sha(manifest):
    lines = []
    for l in Path(manifest).read_text(encoding="utf-8").splitlines():
        if l.strip():
            a = json.loads(l)["audio"]; p = Path(a)
            lines.append(f"{a} {p.stat().st_size if p.exists() else -1}")
    return hashlib.sha256("\n".join(sorted(lines)).encode()).hexdigest()


def verify(ar, data, leak=True):
    ar, data = Path(ar), Path(data); L = ar / "locked"; bad = []
    try: H = json.loads((L / "hashes.json").read_text())
    except Exception as e: return [f"cannot read hashes.json: {e}"]
    for k, want in H["files"].items():
        root, rel = k.split(":", 1); p = (ar if root == "ar" else data) / rel
        try:
            if sha(p) != want: bad.append(f"hash mismatch: {k}")
        except OSError as e: bad.append(f"missing: {k} ({e})")
    ex = {str(p.relative_to(ar)) for p in (L / "evalx").rglob("*") if p.is_file() and "__pycache__" not in p.parts and p.suffix != ".pyc"}
    listed = {k.split(":", 1)[1] for k in H["files"] if k.startswith("ar:locked/evalx/")}
    for extra in sorted(ex - listed): bad.append(f"unlisted file in locked/evalx: {extra}")
    TEST = {"hiacc": "data/evalsets-lexicon/hiacc", "mucs-hien-test": "data/evalsets-lexicon/mucs-hien-test", "fleurs-hi": "data/evalsets-lexicon/fleurs-hi",
            "svarah-partial": "evalsets/svarah-partial", "monsoon-en-in": "evalsets/monsoon-en-in", "librispeech-clean": "evalsets/librispeech-clean"}
    for n, want in H["audio_stat_sha256"].items():
        m = L / f"{n}.jsonl" if n in ("dev-sel", "dev-hold", "vibe") else data / TEST[n] / "manifest.jsonl"
        try:
            if audio_stat_sha(m) != want: bad.append(f"audio files changed for {n}")
        except OSError as e: bad.append(f"audio listing {n}: {e}")
    if leak and not bad:
        ids, audio, spk = set(), set(), {}
        for n in ("dev-sel", "dev-hold", "vibe"):
            for l in (L / f"{n}.jsonl").read_text(encoding="utf-8").splitlines():
                r = json.loads(l); ids.add(r["id"]); audio.add(r["audio"])
                if r.get("speaker") is not None and r.get("source"):
                    spk.setdefault(r["source"], set()).add(str(r["speaker"]))
        for t in json.loads((L / "allowed_train.json").read_text()):
            src = re.sub(r"_(v2|vb|hy)$", "", Path(t).parent.name); n_id = n_au = n_sp = 0     # indicvoices_hy / vaani_v2 / mucs_v2 ... -> the dev-set source name
            for l in open(t, encoding="utf-8"):
                r = json.loads(l); n_id += r["id"] in ids; n_au += r["audio"] in audio; n_sp += str(r.get("speaker")) in spk.get(src, ())
            if n_id or n_au or n_sp: bad.append(f"LEAK: {t}: {n_id} ids, {n_au} audio paths, {n_sp} speaker rows also in locked sets")
    return bad


if __name__ == "__main__":
    ap = argparse.ArgumentParser(); ap.add_argument("--ar-home", required=True); ap.add_argument("--data-root"); ap.add_argument("--no-leak", action="store_true"); a = ap.parse_args()
    ar = Path(a.ar_home).expanduser().resolve(); bad = verify(ar, a.data_root or ar.parent, not a.no_leak)
    for b in bad: print("VERIFY FAIL:", b, file=sys.stderr)
    print("verify ok" if not bad else f"verify FAILED ({len(bad)})"); sys.exit(2 if bad else 0)
