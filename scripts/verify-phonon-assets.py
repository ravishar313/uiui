#!/usr/bin/env python3
"""Verify pinned precompiled speech assets; never creates a model session."""
import hashlib
import json
from pathlib import Path
import sys


def require(value):
    if not value:
        raise ValueError("invalid assets")


def verify(directory):
    directory = directory.resolve()
    manifest = directory / 'assets.json'
    require(manifest.is_file() and 0 < manifest.stat().st_size <= 1048576)
    assets = json.loads(manifest.read_text())
    require(assets['repository'] == 'uiui/S1')
    require(assets['revision'] == 'full-1029-s16000-f16')
    require(assets['container_sha256'] == '1ebefdb308a1b4f4b3fd8df86b1340cb6934b4c935f4c97386ba7119c07ff249')
    files = assets['files']
    require(isinstance(files, list) and 5 <= len(files) <= 32)
    paths = [item['path'] for item in files]
    require(len(set(paths)) == len(paths))
    require({'manifest.json','decoder.bin','Phonon-2.mlmodelc/coremldata.bin','Phonon-2.mlmodelc/model.mil','Phonon-2.mlmodelc/weights/weight.bin','SpeechActivity.mlmodelc/coremldata.bin','SpeechActivity.mlmodelc/model.mil','SpeechActivity.mlmodelc/weights/weight.bin'} <= set(paths))
    for item in files:
        relative = Path(item['path'])
        require(not relative.is_absolute() and '..' not in relative.parts and '.' not in relative.parts)
        path = directory / relative
        require(path.is_file() and not path.is_symlink() and path.resolve().is_relative_to(directory))
        require(path.stat().st_size == item['bytes'] and item['bytes'] > 0)
        digest = hashlib.sha256()
        with path.open('rb') as stream:
            for block in iter(lambda: stream.read(1048576), b''):
                digest.update(block)
        require(digest.hexdigest() == item['sha256'])


if __name__ == '__main__':
    try:
        require(len(sys.argv) == 2)
        verify(Path(sys.argv[1]))
    except (OSError, KeyError, TypeError, ValueError):
        sys.exit('Phonon bundle verification failed')
    print('Phonon compiled bundle hashes verified')
