#!/bin/zsh
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
source_database="${ALMREC_PRIVATE_LIBRARY_DB:-$HOME/Library/Application Support/AlmRecorder/transcriptions_grdb.db}"
scratch_directory="$(mktemp -d "${TMPDIR:-/tmp}/almrecorder-speaker-benchmark.XXXXXX")"
snapshot_database="$scratch_directory/library-snapshot.db"

cleanup() {
    rm -rf "$scratch_directory"
}
trap cleanup EXIT

if [[ ! -f "$source_database" ]]; then
    print -u2 "Private AlmRecorder database not found: $source_database"
    exit 2
fi

/usr/bin/sqlite3 "$source_database" ".backup '$snapshot_database'"

gold_audio_paths=("${(@f)$(/usr/bin/sqlite3 "$snapshot_database" \
    "SELECT DISTINCT COALESCE(file_path, '') FROM recordings WHERE speaker_review_status = 'gold'")}")
for gold_audio_path in "${gold_audio_paths[@]}"; do
    [[ -z "$gold_audio_path" || -r "$gold_audio_path" ]] && continue
    print -u2 "The command-line benchmark cannot read protected gold audio: $gold_audio_path"
    print -u2 "Run Settings → Evaluation → Compare presets inside AlmRecorder instead,"
    print -u2 "or grant the terminal Full Disk Access / use imported audio outside Voice Memos."
    exit 3
done

cd "$repository_root"
swift_arguments=()
if [[ -n "${ALMREC_SWIFT_SCRATCH_PATH:-}" ]]; then
    swift_arguments+=(--scratch-path "$ALMREC_SWIFT_SCRATCH_PATH")
fi
ALMREC_PRIVATE_SPEAKER_BENCHMARK=1 \
ALMREC_GLOBAL_SHADOW_DB="$snapshot_database" \
swift test "${swift_arguments[@]}" \
    --filter SpeakerPipelineLiveEval/test_currentProductionOnPrivateSnapshot
