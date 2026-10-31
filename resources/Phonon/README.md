---
license: cc-by-sa-4.0
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

# uiui S1

Speech recognition for Indian English and Roman-script Hinglish, tuned for workplace dictation and running on the Apple Neural Engine. It outputs Latin script only, with punctuation and casing.

Revision `full-1029-s16000-f16`: FastConformer encoder with 4-bit lookup-table weights, TDT decoder in 16-bit floating point, greedy decoding, no language model. Derived from [NVIDIA Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) (CC-BY-4.0) through Fermion Research's [Phonon-2](https://huggingface.co/FermionResearch/Phonon-2) and [Phonon-2 Core ML](https://huggingface.co/FermionResearch/Phonon-2-CoreML) (CC-BY-4.0). Weights CC-BY-SA-4.0.

Results, training data, limits and licence questions are in `docs/technical-report.md` in the uiui source. Attribution is in `NOTICE`.
