# Native MiniLM dependencies and bridge

The application uses C++17 SentencePiece and ONNX Runtime directly. There is no
Python, JavaScript, web view, model server, network client, or subprocess runtime
in the bridge. This bundle targets **arm64 macOS 14+**. `Sources/CMiniLM` owns
the synchronous C boundary; Swift owns normalization, source ranges, model
windowing, cancellation checks, and serialized lifecycle calls.

## Pinned inputs

* SentencePiece **0.2.1**, official Google commit
  [`31646a467d2051eb904e0b45de3a73e91fe1c1e3`](https://github.com/google/sentencepiece/tree/31646a467d2051eb904e0b45de3a73e91fe1c1e3).
  `source/` retains the exact official archive, SHA256
  `b4eb17e6bea5c9380ddd79d04d01d6aa5e280be8f3e3cef1f745a80e6d9451ce`.
  It was copied from this repository's existing fullstop benchmark and verified
  before extraction. The owned `lib/libsentencepiece.a` is rebuilt from this
  archive, with protobuf-lite and the internal Abseil implementation included.
  No separate protobuf or Abseil library is needed. Tests/trainer/tools are not
  linked into the application. The complete source archive preserves upstream
  and bundled dependency notices; distributable notices are also in `licenses/`.
* ONNX Runtime **1.23.2** arm64, `lib/libonnxruntime.1.23.2.dylib`, SHA256
  `480790a978a48ad3e06ce86b6025e037bd70221637f5c104a8dde19617364cf4`.
  This is the existing Moonshine Voice 0.1.5 wheel's native library, whose hash
  matches the upstream Moonshine Git LFS object used by the native core probe.
  The original pointer was under the now-removed experimental tree
  `build/small-asr-benchmark/moonshine/upstream/core/third-party/onnxruntime/lib/macos/arm64/`.
  Headers are exact official Microsoft
  [v1.23.2 session API headers](https://github.com/microsoft/onnxruntime/tree/v1.23.2/include/onnxruntime/core/session),
  downloaded separately to avoid retaining Moonshine formatting changes.
  The MIT license and official v1.23.2 ThirdPartyNotices are in `licenses/`.
* `provenance.json` records actual shipped dependency/header/license hashes.
  `upstream-SHA256SUMS` verifies immutable upstream inputs. No model weights or
  tokenizer model are included here; application asset ownership stays in Swift.

## Build and check

From the repository root:

```sh
./scripts/build-minilm-native.sh
./scripts/build-minilm-native.sh --check-tokenizer \
  resources/MiniLM/sentencepiece.bpe.model
```

The script verifies the pinned archive and runtime, extracts into ignored
`Vendor/MiniLM/build/`, uses local CMake to build `sentencepiece-static`, and
compiles the bridge and an opt-in session checker. It never runs a model.
`CMAKE=/absolute/path/to/cmake` selects a build tool; otherwise CMake must be
on PATH. Experiment environments are not retained as hidden build dependencies.
Ordinary `swift build` and app packaging use the pinned libraries already in
`Vendor/MiniLM/lib` and do not require CMake. CMake's installation location does
not become an application dependency. The rebuild uses Release, arm64, macOS deployment target 14.0, shared
libraries off, tcmalloc off, and four compiler jobs. No global installation or
network download occurs in the build script.

`--check-tokenizer` loads only SentencePiece, checks 33 frozen Hugging Face
tokenizer fixtures, literal special strings, malformed UTF-8, unknown mapping,
no truncation, and C boundary error handling. Its fixtures contain only authored
public synthetic text. Fixture generation is optional build-time tooling using
the existing isolated Python tokenizer environment; it never imports the model
or ONNX Runtime. The app does not use that tooling.

The session checker is **built but never run automatically**. The following is
a historical benchmark invocation: its base checkpoint and temporary fixtures
were removed during experiment cleanup. Its results and provenance are preserved
in [the experiment archive](../../docs/experiments/README.md). A new numerical
comparison must supply a matched model and its own reference fixtures; the tuned
production model must not be compared with the old base-checkpoint logits.
Serialize any model execution with other model processes.

```sh
Vendor/MiniLM/build/session-contract \
  build/cleanup-frontier-20261024/minilm/assets/model_quantized.onnx \
  build/cleanup-frontier-20261024/minilm/assets/sentencepiece.bpe.model \
  build/cleanup-frontier-20261024/minilm/native/fixtures
```

It creates one owned context, checks buffer and input guards, runs the short and
long public core fixtures once each, and compares logits and argmax hashes
against the previously frozen Python/native core comparison. This is numerical
and C-boundary validation; it does not prove whole-app RAM, UI responsiveness,
cancellation, or cleanup quality.

## SwiftPM and app packaging

Create a C-family `CMiniLM` target from `Sources/CMiniLM`, public headers
`include`, C++ standard 17, and C++ header search path `Vendor/MiniLM/include`.
Link the full `Vendor/MiniLM/lib/libsentencepiece.a` path, `-L` the vendor library
directory, `-lonnxruntime.1.23.2`, and `-lc++`. The public C header imports into
Swift with an `OpaquePointer` context and `Int` for `size_t` capacities/counts.
Return values use C `int` (`Int32` in Swift).

For command-line development, add an rpath to the absolute vendor `lib` directory.
For the app, copy only `libonnxruntime.1.23.2.dylib` into
`Contents/Frameworks` and use `@executable_path/../Frameworks` as rpath. The dylib
already has install name `@rpath/libonnxruntime.1.23.2.dylib`; no install-name
rewrite is required. It depends only on macOS system libraries/frameworks.
SentencePiece is statically linked; do not copy its archive or the source/build
directories into the app. Copy every `licenses/` notice to application resources.
Sign the nested runtime before signing the app. Code signing changes binary
bytes, so the documented runtime SHA is for the original vendored input, before
application signing.

## C boundary and tokenizer contract

`uiui_minilm_create` owns one tokenizer, ORT environment and CPU session. ORT uses
one intra-op thread, one inter-op thread, sequential execution, all graph
optimizations, and default CPU arena/prepacking. No optional provider is added.
ORT logging is discarded, and returned diagnostics are fixed codes containing
neither caller text nor file paths. `destroy` releases all owned resources; it
does not promise that the OS returns every allocator page immediately.

`encode` accepts a literal UTF-8 string, without added-token parsing. Swift must
reject embedded NULs and apply the publisher's NFKC/lowercase normalization.
SentencePiece's own model normalizer remains active. SP unknown ID 0 maps to HF
3; normal SP IDs 3...31997 map to ID+1. SP control/unused IDs are rejected. Swift
adds CLS=0 and SEP=2. Literal `<s>`, `</s>`, `<pad>`, `<unk>` and `<mask>` are
encoded as ordinary characters rather than invoking HF added-token behavior.
The expected SP vocabulary is 31,998 entries with unknown=0, BOS=1, EOS=2 and no
pad. Model vocabulary is 32,000. Encoding never truncates; NULL output/capacity 0
queries its full required size. A short output buffer fails without partial IDs.

`predict` accepts one 1...128-token window, supplies all-one attention and
all-zero token types, validates supported input/output shapes, checks every
logit is finite, and copies exactly `count*8` logits only after validation.
Invalid calls leave output untouched. The context is intentionally serialized
by its Swift owner; destroy and inference must never overlap. A synchronous
window cannot be interrupted halfway; Swift checks cancellation around calls.
