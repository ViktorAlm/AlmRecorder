#!/bin/zsh
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
source_database="${ALMREC_PRIVATE_LIBRARY_DB:-$HOME/Library/Application Support/AlmRecorder/transcriptions_grdb.db}"
scratch_directory="$(mktemp -d "${TMPDIR:-/tmp}/almrecorder-speaker-shadow.XXXXXX")"
snapshot_database="$scratch_directory/library-snapshot.db"

cleanup() {
    rm -rf "$scratch_directory"
}
trap cleanup EXIT

if [[ ! -f "$source_database" ]]; then
    print -u2 "Private AlmRecorder database not found: $source_database"
    exit 2
fi

# SQLite's online backup command produces a consistent point-in-time copy even when the app uses
# WAL. All migrations and evaluation queries run against this disposable snapshot, never live data.
/usr/bin/sqlite3 "$source_database" ".backup '$snapshot_database'"

cd "$repository_root"
swift_arguments=()
if [[ -n "${ALMREC_SWIFT_SCRATCH_PATH:-}" ]]; then
    swift_arguments+=(--scratch-path "$ALMREC_SWIFT_SCRATCH_PATH")
fi
ALMREC_GLOBAL_SHADOW_EVAL=1 \
ALMREC_GLOBAL_SHADOW_DB="$snapshot_database" \
swift test "${swift_arguments[@]}" \
    --filter GlobalSpeakerReconcilerTests/testLiveLibraryShadowWhenEnabled
