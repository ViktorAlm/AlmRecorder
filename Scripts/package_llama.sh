#!/bin/bash
#
# Build the llama.cpp CLI tools from the LOCAL External/llama.cpp checkout and stage them into the
# app's Resources for bundling. Replaces the old script, which cloned the wrong repo, built with the
# deprecated `make`, and shipped `llama-completion` renamed to `llama-mtmd-cli`.
#
# Produces (ad-hoc signed) under AlmRecorder/Resources:
#   Binaries/llama-mtmd-cli   - multimodal CLI: Voxtral transcription
#   Binaries/llama-completion        - text CLI: Gemma text generation (summaries / topics / tags)
#   Binaries/llama-server     - persistent multimodal server: Gemma audio consensus
#   Binaries/llama-embedding  - embeddings (rebuilt so its ggml matches the tools above)
#   Libraries/llama/*.dylib   - the matching ggml/llama dylibs (kept SEPARATE from Whisper's libs;
#                               loading the wrong libggml-base aborts with _ggml_add_id not found)
#   Libraries/llama/*.metal   - Metal shader sources used at runtime
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LLAMA_DIR="$REPO_ROOT/External/llama.cpp"
# Always configure in a fresh temporary tree. Reusing llama.cpp/build can leave obsolete
# versioned dylibs behind after an upstream update, and a wildcard copy would then bundle two
# incompatible ABI generations in the app.
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/almrec-llama-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
BIN_OUT="$REPO_ROOT/AlmRecorder/Resources/Binaries"
LIB_OUT="$REPO_ROOT/AlmRecorder/Resources/Libraries/llama"

echo "📦 Building llama.cpp tools from $LLAMA_DIR"

if [ ! -d "$LLAMA_DIR" ]; then
    echo "❌ External/llama.cpp not found. Add it (git clone ggml-org/llama.cpp into External/)."
    exit 1
fi

mkdir -p "$BIN_OUT" "$LIB_OUT"

# Configure + build with Metal and shared libraries (so we get dylibs to bundle).
cmake -B "$BUILD_DIR" -S "$LLAMA_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_METAL=ON \
    -DLLAMA_CURL=OFF \
    -DLLAMA_OPENSSL=OFF \
    -DLLAMA_BUILD_UI=OFF \
    -DLLAMA_USE_PREBUILT_UI=OFF \
    -DBUILD_SHARED_LIBS=ON

cmake --build "$BUILD_DIR" --config Release -j"${ALMREC_LLAMA_BUILD_JOBS:-2}" \
    --target llama-mtmd-cli llama-completion llama-server llama-embedding

# Stage the binaries.
for bin in llama-mtmd-cli llama-completion llama-server llama-embedding; do
    src="$BUILD_DIR/bin/$bin"
    if [ ! -f "$src" ]; then
        echo "❌ Build did not produce $bin at $src"
        exit 1
    fi
    cp -f "$src" "$BIN_OUT/$bin"
    codesign --force --sign - "$BIN_OUT/$bin"
    echo "✅ staged $bin"
done

# Stage the matching ggml/llama dylibs + Metal shaders into the llama-specific lib dir.
rm -f "$LIB_OUT"/*.dylib "$LIB_OUT"/*.metal 2>/dev/null || true
cp -f "$BUILD_DIR/bin/"*.dylib "$LIB_OUT/" 2>/dev/null || true
cp -f "$BUILD_DIR/bin/"*.metal "$LIB_OUT/" 2>/dev/null || true
for lib in "$LIB_OUT"/*.dylib; do
    [ -f "$lib" ] && codesign --force --sign - "$lib"
done

echo ""
echo "✅ llama.cpp tools staged:"
echo "   Binaries  → $BIN_OUT"
echo "   Libraries → $LIB_OUT"
ls -lh "$BIN_OUT"/llama-mtmd-cli "$BIN_OUT"/llama-completion \
    "$BIN_OUT"/llama-server 2>/dev/null || true
