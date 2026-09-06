#!/bin/bash
#
# Build whisper.cpp from the recorded submodule revision in a fresh tree and stage one coherent
# native runtime into AlmRecorder/Resources. A fresh tree matters: stale ggml dylibs from an older
# checkout can load successfully and then crash as soon as Metal registers its backend.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHISPER_DIR="$ROOT/External/whisper.cpp"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/almrec-whisper-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
BIN_OUT="$ROOT/AlmRecorder/Resources/Binaries"
LIB_OUT="$ROOT/AlmRecorder/Resources/Libraries"

if [ ! -f "$WHISPER_DIR/CMakeLists.txt" ]; then
  echo "ERROR: External/whisper.cpp is missing or not initialized" >&2
  exit 1
fi

echo "Building whisper.cpp from $(git -C "$WHISPER_DIR" rev-parse --short=12 HEAD)"
cmake -B "$BUILD_DIR" -S "$WHISPER_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DGGML_CCACHE=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_SERVER=OFF \
  -DWHISPER_BUILD_EXAMPLES=ON
cmake --build "$BUILD_DIR" --config Release -j"${ALMREC_WHISPER_BUILD_JOBS:-2}" \
  --target whisper-cli

mkdir -p "$BIN_OUT" "$LIB_OUT"
cp -f "$BUILD_DIR/bin/whisper-cli" "$BIN_OUT/whisper-cli"
cp -fL "$BUILD_DIR/src/libwhisper.1.dylib" "$LIB_OUT/libwhisper.1.dylib"
cp -fL "$BUILD_DIR/ggml/src/libggml.dylib" "$LIB_OUT/libggml.dylib"
cp -fL "$BUILD_DIR/ggml/src/libggml-base.dylib" "$LIB_OUT/libggml-base.dylib"
cp -fL "$BUILD_DIR/ggml/src/libggml-cpu.dylib" "$LIB_OUT/libggml-cpu.dylib"
cp -fL "$BUILD_DIR/ggml/src/ggml-blas/libggml-blas.dylib" "$LIB_OUT/libggml-blas.dylib"
cp -fL "$BUILD_DIR/ggml/src/ggml-metal/libggml-metal.dylib" "$LIB_OUT/libggml-metal.dylib"

codesign --force --sign - "$BIN_OUT/whisper-cli"
for library in \
  "$LIB_OUT/libwhisper.1.dylib" \
  "$LIB_OUT/libggml.dylib" \
  "$LIB_OUT/libggml-base.dylib" \
  "$LIB_OUT/libggml-cpu.dylib" \
  "$LIB_OUT/libggml-blas.dylib" \
  "$LIB_OUT/libggml-metal.dylib"; do
  codesign --force --sign - "$library"
done

echo "Staged whisper-cli and matching whisper/ggml libraries"
