"""Add training manifests to locked/allowed_train.json, refresh its hash in hashes.json, log the amendment, then run verify.py
(incl. the eval-leak check).  On verify failure both files are restored.   python3 ops/amend_allowed.py "<note>" MANIFEST [MANIFEST ...]"""
import hashlib, json, os, subprocess, sys, time
from pathlib import Path
L = Path(os.environ.get("AMEND_LOCKED_DIR") or Path(os.environ.get("UIUI_ML_ROOT") or "workspace").resolve() / "ar/locked"); A, H = L / "allowed_train.json", L / "hashes.json"   # AMEND_LOCKED_DIR: dry runs on a temp copy
note, paths = sys.argv[1], [str(Path(p).expanduser().resolve()) for p in sys.argv[2:]]
if not paths: sys.exit("usage: amend_allowed.py NOTE MANIFEST...")
for p in paths:
    with open(p, encoding="utf-8") as f: r = json.loads(f.readline())
    assert {"id", "audio"} <= set(r) and ({"text", "reference"} & set(r)), f"{p}: first row lacks id/audio/text"
old_a, old_h = A.read_text(), H.read_text()
modes = {p: p.stat().st_mode for p in (A, H)}
for p in modes: os.chmod(p, modes[p] | 0o200)   # files are kept read-only; writable only during the amendment
allowed, h = json.loads(old_a), json.loads(old_h)
new = [p for p in paths if p not in allowed]
if not new: sys.exit("nothing to add (all already allowed)")
A.write_text(json.dumps(allowed + new, indent=1))
h["files"]["ar:locked/allowed_train.json"] = hashlib.sha256(A.read_bytes()).hexdigest()
h["amended"].append(f"{time.strftime('%F')} {note}"); H.write_text(json.dumps(h, indent=1))
for p in modes: os.chmod(p, modes[p])
rc = subprocess.run([sys.executable, "-I", str(L / "verify.py"), "--ar-home", str(L.parent)]).returncode
if rc:
    for p in modes: os.chmod(p, modes[p] | 0o200)
    A.write_text(old_a); H.write_text(old_h)
    for p in modes: os.chmod(p, modes[p])
    sys.exit(f"verify failed: restored both files, nothing changed")
print("added:", *new, sep="\n  ")
