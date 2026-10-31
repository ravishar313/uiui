---
license: cc-by-4.0
base_model: FermionResearch/Phonon-2
language:
- en
- hi
library_name: coreml
pipeline_tag: automatic-speech-recognition
tags:
- coreml
- neural-engine
- apple-silicon
- on-device
- hinglish
- indian-english
---

# Phonon-2-HL Core ML

Speech recognition for Indian English and Roman-script Hinglish, tuned for workplace dictation and running on the Apple Neural Engine. It outputs Latin script only, with punctuation and casing.

Revision `full-1029-s16000-f16`: FastConformer encoder with 4-bit lookup-table weights, TDT decoder in 16-bit floating point, greedy decoding, no language model. Derived from NVIDIA Parakeet TDT 0.6B v3 through Fermion Research's Phonon-2.

Results, training data, limits and licence questions are in `docs/technical-report.md` in the uiui source. Attribution is in `NOTICE`.
