"""Download parquet shards from HF, convert to 16k wav, stage rows. Usage: ingest_parquet.py <source>"""
import ast, os, queue, re, sys, threading
import pyarrow.parquet as pq
sys.path.insert(0, os.path.dirname(__file__))
from common import *
from huggingface_hub import hf_hub_download, HfFileSystem, HfApi

os.environ["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
RAW = DATA / "raw"
api = HfApi()


def files(repo, pre):
    return sorted(f for f in api.list_repo_files(repo, repo_type="dataset") if f.startswith(pre) and f.endswith(".parquet"))


def pick(lst, idxs):
    return [lst[i] for i in idxs if i < len(lst)]


def rows_iv(t, shard):
    for i, r in enumerate(t.to_pylist()):
        try:
            dec = ast.literal_eval(r["verification_report"]).get("decision")
        except Exception:
            dec = None
        if dec not in ("excellent", "good", None):
            continue
        yield f"{shard}-{i}", r["audio_filepath"]["bytes"], r["text"], r["speaker_id"], dict(scenario=r["scenario"], lang_meta="hi")


def rows_kb(t, shard):
    for i, r in enumerate(t.to_pylist()):
        yield f"{shard}-{i}", r["audio_filepath"]["bytes"], r["text"], r["speaker_id"], {}


def rows_sl(t, shard):
    for i, r in enumerate(t.to_pylist()):
        yield f"{shard}-{i}", r["audio_filepath"]["bytes"], r["text"], f"{shard}-c{i // 40}", {}


def rows_mucs(t, shard):
    for i, r in enumerate(t.to_pylist()):
        yield r["segment_id"], r["audio"]["bytes"], r["transcript"], r["speaker_id"], dict(recording=r["segment_id"].rsplit("_", 1)[0])


def rows_libri(t, shard):
    for i, r in enumerate(t.to_pylist()):
        yield r["id"], r["audio"]["bytes"], r["text"], r["speaker_id"], {}


def rows_cv(t, shard):
    for i, r in enumerate(t.to_pylist()):
        if (r.get("down_votes") or 0) > 0:
            continue
        yield r["path"].replace(".mp3", ""), r["audio"]["bytes"], r["sentence"], r["client_id"][:16], dict(accent=r["accents"])


def rows_nptel(t, shard):
    for i, r in enumerate(t.to_pylist()):
        yield f"{shard}-{i}", r["audio"]["bytes"], r.get("transcription") or "", r["speaker_name"], dict(norm=r.get("transcription_normalised"), fname=r.get("file_name"))


def read_cols(source):
    return dict(indicvoices=["audio_filepath", "text", "speaker_id", "verification_report", "scenario"],
                kathbath=["audio_filepath", "text", "speaker_id"], shrutilipi=["audio_filepath", "text"],
                mucs=["audio", "segment_id", "transcript", "speaker_id"], librispeech=["audio", "id", "text", "speaker_id"],
                cvindia=["audio", "path", "sentence", "client_id", "down_votes", "accents"],
                nptel=["audio", "transcription", "speaker_name", "transcription_normalised", "file_name"])[source]


def cfg(source):
    if source == "indicvoices":
        r = "ai4bharat/IndicVoices"; fl = files(r, "hindi/train"); return r, pick(fl, range(0, 82, 4)), rows_iv, 120, 5429 * 21
    if source == "kathbath":
        r = "ai4bharat/Kathbath"; fl = files(r, "hindi/train"); return r, pick(fl, range(0, 32, 6)), rows_kb, 20, 2868 * 6
    if source == "shrutilipi":
        r = "ai4bharat/Shrutilipi"; fl = files(r, "hindi/train"); return r, pick(fl, [40, 140, 90]), rows_sl, 10, 3749 * 2
    if source == "mucs":
        r = "dianavdavidson/MUCS-Hinglish"; return r, files(r, "data/train"), rows_mucs, 999, 52825
    if source == "librispeech":
        r = "openslr/librispeech_asr"; fl = files(r, "all/train.clean.100"); return r, pick(fl, range(14)), rows_libri, 62, 2039 * 8
    if source == "cvindia":
        r = "WillHeld/india_accent_cv"; fl = files(r, "data/train"); return r, pick(fl, range(0, 34)), rows_cv, 80, 2692 * 34
    if source == "nptel":
        r = "skbose/indian-english-nptel-v0"; fl = files(r, "data/train"); return r, pick(fl, range(0, 215, 4)), rows_nptel, 200, 2000 * 54
    raise SystemExit("unknown source")


def mucs_test_exclusions():
    fs = HfFileSystem(); spk, rec = set(), set()
    for k in range(2):
        with fs.open(f"datasets/dianavdavidson/MUCS-Hinglish/data/test-0000{k}-of-00002.parquet", "rb") as f:
            t = pq.read_table(f, columns=["speaker_id", "segment_id"]).to_pylist()
        for r in t:
            spk.add(r["speaker_id"]); rec.add(r["segment_id"].rsplit("_", 1)[0])
    return spk, rec


def main(source):
    repo, shards, rowfn, cap_h, total = cfg(source)
    ing = Ingest(source, total, notes=f"{repo}; {len(shards)} shards; cap {cap_h} h")
    if source == "mucs":
        spk, rec = mucs_test_exclusions()
        ing.excl_spk |= spk
        ing.run.note(f"MUCS test speakers excluded: {len(spk)}; test recordings: {len(rec)}")
        json.dump(dict(speakers=sorted(spk), recordings=sorted(rec)), open(ing.sdir / "mucs_test_ids.json", "w"))
    q = queue.Queue(maxsize=2)
    todo = [s for s in shards if s not in ing.done]

    def dl():
        for s in todo:
            q.put((s, hf_hub_download(repo, s, repo_type="dataset", local_dir=RAW / source)))
        q.put(None)
    threading.Thread(target=dl, daemon=True).start()
    cols = read_cols(source)
    while True:
        it = q.get()
        if it is None:
            break
        s, path = it
        if ing.stats["seconds"] / 3600 >= cap_h:
            os.remove(path); continue
        pf = pq.ParquetFile(path)
        tag = re.sub(r"[^0-9]", "", os.path.basename(s).split("-of-")[0]) or os.path.basename(s)
        tag = f"{tag}"
        for g in range(pf.metadata.num_row_groups):
            t = pf.read_row_group(g, columns=[c for c in cols if c in pf.schema_arrow.names])
            for uid, b, text, spk, extra in rowfn(t, f"{source}-{tag}-g{g}"):
                if source == "mucs" and extra.get("recording") in rec:
                    ing.stats["excluded"] += 1; continue
                ing.add(uid if source in ("mucs", "librispeech") else f"{source}-{uid}" if not uid.startswith(source) else uid,
                        b, text, spk, extra)
            if ing.stats["seconds"] / 3600 >= cap_h:
                break
        ing.shard_done(s)
        pf = None
        os.remove(path)
    ing.finish()


if __name__ == "__main__":
    main(sys.argv[1])
