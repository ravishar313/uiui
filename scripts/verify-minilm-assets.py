#!/usr/bin/env python3
"""Build-time verification only; no model session or runtime dependency."""
import hashlib
import json
from pathlib import Path
import sys


def require(condition):
    if not condition:
        raise ValueError("invalid bundle")


def verify(directory):
    directory = directory.resolve()
    manifest = directory / "manifest.json"
    require(manifest.is_file() and 0 < manifest.stat().st_size <= 1_048_576)
    files = json.loads(manifest.read_text())["files"]
    require(isinstance(files, list) and len(files) == 2)
    paths = [item["path"] for item in files]
    require(all(isinstance(path, str) for path in paths) and len(set(paths)) == 2)
    require(sum(path.endswith(".onnx") for path in paths) == 1)
    require(sum(path == "sentencepiece.bpe.model" for path in paths) == 1)
    for item in files:
        relative = Path(item["path"])
        require(not relative.is_absolute() and ".." not in relative.parts)
        path = directory / relative
        require(path.is_file() and not path.is_symlink())
        require(path.resolve().parent == directory)
        require(path.stat().st_size == item["bytes"] and item["bytes"] > 0)
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1_048_576), b""):
                digest.update(block)
        require(digest.hexdigest() == item["sha256"])


if __name__ == "__main__":
    try:
        require(len(sys.argv) == 2)
        verify(Path(sys.argv[1]))
    except (KeyError, TypeError, ValueError, OSError):
        sys.exit("MiniLM bundle verification failed")
    print("MiniLM bundle hashes verified")
