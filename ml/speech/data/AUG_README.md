# Augmentation corpora for train/augment.py (built 2026-10-27 IST)
We redistribute trained model weights, so only commercially usable data is kept. Lists are JSONL {path, seconds}, all 16 kHz mono (no conversion was needed).

| list | source | license | kept |
|---|---|---|---|
| noise.jsonl | MUSAN noise/free-sound (openslr.org/17, README: no content that forbids commercial use) | Public Domain (Freesound, per its LICENSE) | 5.91 h |
| noise.jsonl | MUSAN noise/sound-bible | per-file CC BY 3.0 ("Attribution 3.0") or Public Domain (LICENSE file) - attribution: raw/musan_meta/musan/noise/sound-bible/LICENSE | 0.31 h |
| babble.jsonl | MUSAN speech/librivox | Public Domain | 20.38 h |
| babble.jsonl | MUSAN speech/us-gov | US Public Domain | 40.07 h |
| rir.jsonl | RIRS_NOISES simulated_rirs smallroom + mediumroom (openslr.org/26, 28; Apache 2.0) | Apache 2.0 | 40000 RIRs, 8.33 h (small 2.78 h, medium 5.56 h) |

Totals: noise 913 files / 6.23 h (17 files < 0.5 s dropped); babble 426 files / 60.45 h; rir 40000 files.

## Excluded
- MUSAN music (all five sources): per-track licenses are mixed (CC BY-SA 1.0/2.5/3.0 DE, CC BY-ND, CC BY, PD; see raw/musan_meta/musan/music/*/LICENSE); share-alike / no-derivatives terms are not clear for our use, and music is not needed. Not extracted.
- RIRS_NOISES real_rirs_isotropic_noises (RWCP: "Research and development use only" (SLR13); AIR: "Not stated" (SLR20); REVERB 2014: unclear): deleted.
- RIRS_NOISES pointsource_noises (duplicate of MUSAN free-sound, Public Domain): deleted. simulated largeroom (Apache 2.0, 30-50 m halls) is on disk but unlisted: not representative of offices/homes/cafes.
- MUSAN tarball and RIRS zip deleted after extraction. License files of every MUSAN subset are kept in raw/musan_meta/.

Paths: raw/musan/musan/{noise,speech}, raw/rirs/RIRS_NOISES/simulated_rirs. Lists built by autoresearch/ops/prep_aug_lists.py. samples/ holds 5 augmented wavs (+ _ORIGINAL). smoke.log has the CPU cost and throughput run.
