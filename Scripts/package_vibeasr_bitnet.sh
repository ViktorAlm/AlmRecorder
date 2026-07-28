#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$REPO_ROOT/External/VibeASR.cpp"
BUILD_DIR="${ALMREC_VIBEASR_BUILD_DIR:-$SOURCE_DIR/build}"
OUTPUT_DIR="$REPO_ROOT/AlmRecorder/Resources/Binaries"
JOBS="${ALMREC_VIBEASR_BUILD_JOBS:-4}"
EXPECTED_COMMIT="4af6a72174b775af0ef108a8ddcb881c72ea9995"

if [ ! -f "$SOURCE_DIR/CMakeLists.txt" ]; then
    echo "VibeASR.cpp is missing. Run: git submodule update --init --recursive External/VibeASR.cpp"
    exit 1
fi

ACTUAL_COMMIT="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
if [ "$ACTUAL_COMMIT" != "$EXPECTED_COMMIT" ]; then
    echo "VibeASR.cpp is at $ACTUAL_COMMIT; expected pinned commit $EXPECTED_COMMIT"
    exit 1
fi

echo "Building the pinned VibeASR.cpp realtime server…"
cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF
cmake --build "$BUILD_DIR" --target asr_stream_server --parallel "$JOBS"

mkdir -p "$OUTPUT_DIR"
cp "$BUILD_DIR/bin/asr_stream_server" "$OUTPUT_DIR/vibeasr-stream-server"
chmod +x "$OUTPUT_DIR/vibeasr-stream-server"

echo "Packaged $OUTPUT_DIR/vibeasr-stream-server"
