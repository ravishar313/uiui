#!/bin/bash
# Build-time tooling only. Does not download, install globally, load a model,
# create an ORT session, or run inference.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
VENDOR="$ROOT/Vendor/MiniLM"
REVISION=31646a467d2051eb904e0b45de3a73e91fe1c1e3
ARCHIVE="$VENDOR/source/sentencepiece-$REVISION.tar.gz"
BUILD="$VENDOR/build"
SOURCE="$BUILD/source/sentencepiece-$REVISION"
check_hash() {
  local actual
  actual="$(shasum -a 256 "$1" | cut -d ' ' -f 1)"
  [[ "$actual" == "$2" ]] || { echo "MiniLM dependency hash mismatch: ${1##*/}" >&2; exit 1; }
}
check_hash "$ARCHIVE" b4eb17e6bea5c9380ddd79d04d01d6aa5e280be8f3e3cef1f745a80e6d9451ce
check_hash "$VENDOR/lib/libonnxruntime.1.23.2.dylib" 480790a978a48ad3e06ce86b6025e037bd70221637f5c104a8dde19617364cf4
(cd "$VENDOR" && shasum -a 256 --check upstream-SHA256SUMS >/dev/null)
[[ "$(uname -m)" == arm64 ]] || { echo "The pinned MiniLM runtime supports arm64 macOS only." >&2; exit 1; }
mkdir -p "$BUILD/source" "$VENDOR/lib"
if [[ ! -d "$SOURCE" ]]; then tar -xzf "$ARCHIVE" -C "$BUILD/source"; fi
# CMake is a development tool, never an app dependency. CMAKE may name any local
# CMake executable. Experimental environments are not build dependencies.
CMAKE_BIN="${CMAKE:-}"
if [[ -z "$CMAKE_BIN" ]]; then CMAKE_BIN="$(command -v cmake || true)"; fi
[[ -x "$CMAKE_BIN" ]] || { echo "Install CMake as a build tool or set CMAKE to its executable." >&2; exit 1; }
"$CMAKE_BIN" -S "$SOURCE" -B "$BUILD/sentencepiece" \
  -DSPM_ENABLE_SHARED=OFF -DSPM_ENABLE_TCMALLOC=OFF -DSPM_BUILD_TEST=OFF \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_POLICY_VERSION_MINIMUM=3.5
"$CMAKE_BIN" --build "$BUILD/sentencepiece" --target sentencepiece-static --parallel 4
install -m 644 "$BUILD/sentencepiece/src/libsentencepiece.a" "$VENDOR/lib/libsentencepiece.a"
# Refresh only the public header from the same immutable source used to build.
cmp "$SOURCE/src/sentencepiece_processor.h" "$VENDOR/include/sentencepiece_processor.h"
xcrun clang++ -std=c++17 -O3 -DNDEBUG -arch arm64 -mmacosx-version-min=14.0 \
  -Wall -Wextra -Werror -I "$VENDOR/include" -I "$ROOT/Sources/CMiniLM/include" \
  -c "$ROOT/Sources/CMiniLM/CMiniLM.cpp" -o "$BUILD/CMiniLM.o"
echo "Built owned SentencePiece library and compiled CMiniLM (no model execution)."
# Build, but never execute, the opt-in session/parity checker.
xcrun clang++ -std=c++17 -O2 -arch arm64 -mmacosx-version-min=14.0 \
  -Wall -Wextra -Werror "$VENDOR/tests/session-contract.cpp" "$BUILD/CMiniLM.o" \
  "$VENDOR/lib/libsentencepiece.a" "$VENDOR/lib/libonnxruntime.1.23.2.dylib" \
  -Wl,-rpath,@executable_path/../lib -o "$BUILD/session-contract"
if [[ "${1:-}" == "--check-tokenizer" ]]; then
  [[ -n "${2:-}" ]] || { echo "Pass the pinned sentencepiece.bpe.model path after --check-tokenizer." >&2; exit 1; }
  check_hash "$2" c450dfa5221ee4bf8c2a84193b2dcaea888f3a30b26cd234e66e7a76c4eaa575
  xcrun clang++ -std=c++17 -O2 -arch arm64 -mmacosx-version-min=14.0 \
    -Wall -Wextra -Werror -I "$VENDOR/include" \
    "$VENDOR/tests/tokenizer-contract.cpp" "$BUILD/CMiniLM.o" \
    "$VENDOR/lib/libsentencepiece.a" "$VENDOR/lib/libonnxruntime.1.23.2.dylib" \
    -Wl,-rpath,@executable_path/../lib -o "$BUILD/tokenizer-contract"
  "$BUILD/tokenizer-contract" "$2" "$VENDOR/tests/tokenizer-fixtures.tsv"
elif [[ $# != 0 ]]; then
  echo "Usage: $0 [--check-tokenizer /path/to/sentencepiece.bpe.model]" >&2
  exit 1
fi
