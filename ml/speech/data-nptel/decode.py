"""Decode opus -> 16 kHz mono PCM16 WAV in parallel (<=20 procs). python decode.py map.jsonl  (rows: src, dst)"""
import json, subprocess, sys, os
from concurrent.futures import ThreadPoolExecutor
rows=[json.loads(l) for l in open(sys.argv[1])]
def go(r):
    if os.path.exists(r["dst"]) and os.path.getsize(r["dst"])>44: return 0
    os.makedirs(os.path.dirname(r["dst"]),exist_ok=True)
    p=subprocess.run(["/usr/bin/ffmpeg","-nostdin","-v","error","-y","-i",r["src"],"-ac","1","-ar","16000","-c:a","pcm_s16le",r["dst"]+".tmp.wav"])
    if p.returncode: return 1
    os.replace(r["dst"]+".tmp.wav",r["dst"]); return 0
with ThreadPoolExecutor(20) as ex: bad=sum(ex.map(go,rows))
print("failed",bad,"of",len(rows))
