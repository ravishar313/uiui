# Phonon-2 Core ML export toolchain

Turns a (fine-tuned) Phonon-2 PyTorch checkpoint into a drop-in replacement for uiui's shipped
`resources/Phonon` bundle (`Phonon-2.mlmodelc`, `decoder.bin`, `manifest.json`).

```bash
cd speech/export  # with PYTHONPATH=<repo>/ml
# environment: torch 2.14, coremltools 9.0 (transformers not needed)
python export_bundle.py <model.fermion | state_dict.pt> <out_dir> [--requantize] [--allow-lossy] [--functions 5,10,15,35] [--jobs 4]
```

`<out_dir>` then holds `Phonon-2.mlmodelc`, `decoder.bin`, `manifest.json` (+ licence files, `export_report.json`) and loads with
`Transcriber(bundle:)` / `phonon-eval <out_dir> <manifest.jsonl> <out.jsonl>`.  ~8 min on an M-series Mac (4 functions in parallel).

| file | role |
|---|---|
| `export_bundle.py` | CLI; orchestrates the stages below, writes `manifest.json` (container_sha256 = sha256 of the checkpoint file) |
| `checkpoint.py` | reads `model.fermion` (lossless raw codes kept) or a ParakeetForTDT `.pt`/`.safetensors` state_dict (also qat.py parametrisations -> projected five-value weights) |
| `encoder_graph.py` | traceable torch encoder with the runtime inputs `mel, m1, m2, m3, kmask[, pos]`; 1/64 residual-scale, BatchNorm fold, constant relative keys |
| `convert.py` | `ct.convert` (fp16, fp32 I/O, macOS15) + prune (1-bit mask) + palettise (64-entry fp16 LUT per 16 output rows, uint6 indices) |
| `verify.py` | asserts every stored LUT/mask tensor equals fp16(PyTorch weight) bit for bit, in every function of the final package |
| `precision.py` | mixed precision: which encoder linears are 4-bit (detection / `precision.json`), the int4-g16 grid (fit, snap), HF-name -> Core ML const name |
| `fivevalue.py` | five-value detection and `--requantize` (per-row Lloyd fit of {0,+-lo,+-hi}, per-layer error report) |
| `decoder_bin.py` | `phonon2-decoder-bin-v2` writer (int6, default; byte-identical to the shipped file for the unmodified container) and `phonon2-decoder-bin-v3` (`--decoder-dtype float32|float16`: matrices and biases uncompressed, no scale arrays) |
| `accept.py` | native-evaluator A/B of two bundles (text diffs, WER, median decode_ms) |
| `ane_compile_time.py` | cold Neural Engine compile time per function |
| `tests/test_units.py`, `tests/test_int4.py` | fast unit checks (the latter incl. a toy Core ML compress round-trip; needs coremltools) |
| `smoke/smoke_bits4.py` | memory-light mixed-precision QAT smoke run (freezes all but the 4-bit layers) |

### Uncompressed decoder (`--decoder-dtype float32|float16`, format v3)
`decoder.bin` v2 stores the decoder/joint matrices as per-row int6, which costs ~4 points of WER on Hinglish clips. `--decoder-dtype float32`
writes every matrix and bias as plain little-endian float32 (exactly the checkpoint), `float16` as fp16; the app (current `DecoderBin.swift`)
reads both and decodes with its FP32 path (the int8-only compiled reference decoder is not used). Default stays `int6p` (v2) so existing
exports and the shipped bundle are unchanged. `--decoder-only` rewrites just `decoder.bin` + `manifest.json` into an out dir that already
holds a `Phonon-2.mlmodelc`. `verify.verify_decoder_bin` checks the written file bit for bit against the checkpoint tensors.

Fidelity notes: see the report that accompanied this tool (relative-key table recipe, fp16 noise floor).

## Mixed precision: 4-bit encoder linears

Some of the 264 encoder linears can be 4-bit instead of five-value (training: `qat.bits4: [module names or regexes]` in the config,
default empty = unchanged).  Scheme **int4-g16**: rows in blocks of 16, one learnable scale `s_g` per block, `w = s_g * q`, `q` integer in
[-8, 7].  A block therefore has <= 16 distinct values and is stored by the *same* Core ML mechanism as the 6-bit tensors,
`palettize_weights(custom, per_grouped_channel, group_size=16)` (a `constexpr_lut_to_dense`, macOS15 opset): one 16-entry fp16 LUT per
16 output rows, uint4 indices, **no zero mask** (the mask costs 1 bit/weight, a 4-bit index 4).  The group of 16 rows is what the existing
LUT op uses; per-row scales would need one LUT per row.  Size: `O*I/2 + O` bytes per layer (+ `O/16*32` for the LUTs), e.g. a 1024x4096
FFN linear is 2.0 MB + 8 KB.

Export finds 4-bit layers (first source wins, all re-checked: every 16-row group must hold <= 16 distinct fp16 values):
1. `precision.json` next to the weights: `{"format": "uiui-precision-v1", "bits4": ["encoder.layers.10.feed_forward1.linear1.weight", ...]}`
   (`precision.write_precision_json`; an empty list means "none, do not auto-detect");
2. `qat_scales.safetensors` next to the weights (written by train/ckpt.py in qat mode; `modes.qat_scales` adds a `<module>.bits4_scale`
   entry per 4-bit layer, so no extra trainer hook is needed);
3. the weights themselves (not five-value and <= 16 values per 16-row group); or, for a raw QAT state_dict, the `parametrizations.weight.0.scale` keys.

`--requantize` leaves 4-bit layers alone.  `verify.py` additionally requires 4-bit layers to be stored as `constexpr_lut_to_dense` with
uint4 indices (and all others as mask + 6-bit LUT), bit-exact against fp16(checkpoint weight).  With no 4-bit layers every config handed
to Core ML is unchanged and the bundle is byte-identical to before.

### lut4 grid (`qat.bits4_grid: lut4`)
Same Core ML op and group size as int4-g16, but the 16 LUT entries of each 16-row group are free (non-uniform): initialised by Lloyd-Max
(best of quantile start and the optimal uniform grid), trained straight-through (nearest entry; entries get the gradient), fp16-rounded.
Export is unchanged: detection from the weights (<= 16 values per 16-row group), the `qat_scales.safetensors` sidecar (`<module>.bits4_lut`)
or raw-state_dict `.parametrizations.weight.0.lut` keys all work, and verify checks the same bit-exact uint4 `constexpr_lut_to_dense`.
