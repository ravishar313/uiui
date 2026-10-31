#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift -module-cache-path "$PWD/.build/icon-cache" scripts/generate-icon.swift "$PWD/resources"
python3 - <<'PY'
from pathlib import Path
import struct
root=Path('resources/UIUIIcon.iconset')
names={'icp4':'icon_16x16.png','icp5':'icon_32x32.png','icp6':'icon_32x32@2x.png','ic07':'icon_128x128.png','ic08':'icon_256x256.png','ic09':'icon_512x512.png','ic10':'icon_512x512@2x.png','ic11':'icon_16x16@2x.png','ic12':'icon_32x32@2x.png','ic13':'icon_128x128@2x.png','ic14':'icon_256x256@2x.png'}
chunks=[]
for tag,name in names.items():
    image=(root/name).read_bytes()
    chunks.append(tag.encode()+struct.pack('>I',len(image)+8)+image)
body=b''.join(chunks)
Path('resources/UIUIIcon.icns').write_bytes(b'icns'+struct.pack('>I',len(body)+8)+body)
PY
