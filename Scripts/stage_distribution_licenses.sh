#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <destination-directory>" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="$1"
mkdir -p "$DESTINATION"

copy_notice() {
    local source="$1"
    local component="$2"
    local output_name="${3:-$(basename "$source")}"
    if [[ ! -f "$source" ]]; then
        echo "ERROR: required license file is missing: $source" >&2
        exit 1
    fi
    mkdir -p "$DESTINATION/$component"
    cp "$source" "$DESTINATION/$component/$output_name"
}

# Product-level notices belong in the installed app, not only beside its source code.
cp "$ROOT/LICENSE" "$DESTINATION/AlmRecorder-LICENSE.txt"
cp "$ROOT/NOTICE" "$DESTINATION/AlmRecorder-NOTICE.txt"
cp "$ROOT/THIRD-PARTY-NOTICES.md" "$DESTINATION/THIRD-PARTY-NOTICES.md"

copy_notice "$ROOT/GRDBCustom/GRDB-LICENSE.txt" "GRDB" "LICENSE.txt"
copy_notice "$ROOT/External/whisper.cpp/LICENSE" "whisper.cpp" "LICENSE.txt"
copy_notice "$ROOT/External/llama.cpp/LICENSE" "llama.cpp" "LICENSE.txt"
copy_notice "$ROOT/External/VibeASR.cpp/LICENSE" "VibeASR.cpp" "LICENSE.txt"
copy_notice "$ROOT/.build/checkouts/FluidAudio/LICENSE" "FluidAudio" "LICENSE.txt"
copy_notice "$ROOT/.build/checkouts/DBSCAN/LICENSE.md" "DBSCAN" "LICENSE.md"
copy_notice "$ROOT/.build/checkouts/swift-sdk/LICENSE" "swift-sdk" "LICENSE.txt"
copy_notice "$ROOT/.build/checkouts/swift-nio/LICENSE.txt" "swift-nio" "LICENSE.txt"
copy_notice "$ROOT/.build/checkouts/swift-nio/NOTICE.txt" "swift-nio" "NOTICE.txt"
copy_notice "$ROOT/.build/checkouts/swift-log/LICENSE.txt" "swift-log" "LICENSE.txt"
copy_notice "$ROOT/.build/checkouts/swift-log/NOTICE.txt" "swift-log" "NOTICE.txt"
copy_notice "$ROOT/.build/checkouts/swift-collections/LICENSE.txt" "swift-collections" "LICENSE.txt"
copy_notice "$ROOT/.build/checkouts/swift-atomics/LICENSE.txt" "swift-atomics" "LICENSE.txt"
copy_notice "$ROOT/.build/checkouts/swift-system/LICENSE.txt" "swift-system" "LICENSE.txt"
copy_notice "$ROOT/.build/checkouts/eventsource/LICENSE.md" "EventSource" "LICENSE.md"

# Both bundled SQLite vector extensions permit Apache-2.0 distribution. Keep a readable license
# beside each binary and preserve component-specific attribution in THIRD-PARTY-NOTICES.md.
copy_notice "$ROOT/LICENSE" "vectorlite" "LICENSE-APACHE.txt"
copy_notice "$ROOT/LICENSE" "sqlite-vec" "LICENSE-APACHE.txt"
