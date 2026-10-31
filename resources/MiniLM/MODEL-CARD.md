---
library_name: transformers
pipeline_tag: token-classification
tags:
- transformers
- onnx
- bert
- punctuation-restoration
- multilingual
license: mit
---

# uiui P1

uiui P1 is the current name of this adapted model; current revision `ft3`. The notes below include its earlier history.

# punctuator-multilingual-minilm-v2

Non-generative multilingual punctuation and casing restoration model.

- Backbone: 12-layer, 384-wide multilingual MiniLM
- Vocabulary: 32,000-piece vocabulary pruned from the original XLM-R SentencePiece model
- Parameters: 33.78M
- Languages trained: en, de, fr, es, it, nl, pl, cs, sk, sl, ro, pt-BR, bg
- Training mode for this revision: balanced
- Data: ordered VoxPopuli speeches, reviewed OASST2 messages, FLEURS text, and capped creator-corrected YouTube caption spans

The model returns eight logits per token:

- indices 0–4: NONE, COMMA, PERIOD, QUESTION, EXCLAMATION
- indices 5–7: LOWER, CAP, UPPER

Select both predictions independently at the final subword of each input word.
The model only changes casing and appends punctuation; it does not generate words.

Data licenses: VoxPopuli CC0; OASST2 Apache-2.0; FLEURS CC BY 4.0; YouTube Caption Corrections dataset card MIT. The latter contains public captions collected from YouTube, so review the underlying caption/platform rights before redistributing a resulting model.

See `training_metrics.json`, `per_language_metrics.json`, and `per_source_metrics.json`. Language inclusion does not establish production quality; evaluate against real output from the target ASR system.
