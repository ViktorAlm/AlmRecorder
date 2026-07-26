#!/usr/bin/env bash

set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"
cd "$repository_root"

scan_history=false
if [[ "${1:-}" == "--history" ]]; then
    scan_history=true
elif [[ $# -ne 0 ]]; then
    echo "usage: $0 [--history]" >&2
    exit 2
fi

failure_count=0

report_failure() {
    echo "privacy check failed: $1" >&2
    failure_count=$((failure_count + 1))
}

path_is_forbidden() {
    local path="$1"
    local lowercase_path
    lowercase_path="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"

    case "$lowercase_path" in
        tests/*|*/tests/*|test/*|*/test/*|fixtures/*|*/fixtures/*|\
        .local-eval/*|*/.local-eval/*|eval-data/*|*/eval-data/*|\
        evaluation-data/*|*/evaluation-data/*|test-data/*|*/test-data/*|\
        gold-data/*|*/gold-data/*|gold-set/*|*/gold-set/*|\
        comparisons/*|*/comparisons/*|benchmarks/*|*/benchmarks/*)
            return 0
            ;;
    esac

    case "$lowercase_path" in
        *tests.swift|*test.swift|*fixture*.swift)
            return 0
            ;;
    esac

    case "$lowercase_path" in
        *.wav|*.mp3|*.m4a|*.flac|*.aac|*.aiff|*.caf|*.m4v|*.mkv|*.mov|\
        *.mp4|*.ogg|*.opus|*.webm|*.wma|*.db|*.db-shm|*.db-wal|*.sqlite|\
        *.sqlite-shm|*.sqlite-wal|*.sqlite3|*.sqlite3-shm|*.sqlite3-wal|\
        *.jsonl|*.csv|*.tsv|*.rttm|*.srt|*.vtt|*.textgrid)
            return 0
            ;;
    esac

    case "$lowercase_path" in
        *transcript*.json|*transcript*.txt|*transcription*.json|\
        *transcription*.txt|*utterance*.json|*utterance*.txt|\
        *recording*.json|*recording*.txt|*speaker*gold*.json|\
        *speaker*benchmark*.json|*speaker*comparison*.json|\
        *evaluation*.json|*eval*.json|*gold*.json|*benchmark*.json|\
        *comparison*.json)
            return 0
            ;;
    esac

    return 1
}

scan_paths_from_index() {
    local path
    while IFS= read -r -d '' path; do
        if path_is_forbidden "$path"; then
            report_failure "forbidden tracked path: $path"
        fi
    done < <(git ls-files -z)
}

scan_paths_from_commit() {
    local commit="$1"
    local path
    while IFS= read -r -d '' path; do
        if path_is_forbidden "$path"; then
            report_failure "forbidden path in commit $commit: $path"
        fi
    done < <(git ls-tree -r -z --name-only "$commit")
}

scan_machine_paths() {
    local revision_args=("$@")
    local matches
    matches="$(git grep "${revision_args[@]}" -I -n -E '/Users/[A-Za-z0-9._-]+' -- \
        . ':!Scripts/check_repository_privacy.sh' 2>/dev/null || true)"
    if [[ -n "$matches" ]]; then
        report_failure "tracked text contains a machine-specific home path"
    fi
}

scan_email_literals() {
    local revision_args=("$@")
    local email
    while IFS= read -r email; do
        [[ -z "$email" ]] && continue
        report_failure "tracked text contains an email literal"
    done < <(git grep "${revision_args[@]}" -I -h -o -E \
        '[[:alnum:]._%+-]+@[[:alpha:]][[:alnum:].-]*\.[[:alpha:]]{2,}' -- \
        . ':!Scripts/check_repository_privacy.sh' 2>/dev/null || true)
}

scan_local_blocklist() {
    local revision_args=("$@")
    local blocklist_path="${ALMREC_PRIVACY_BLOCKLIST:-$repository_root/.privacy-blocklist}"
    [[ -f "$blocklist_path" ]] || return 0

    local literal
    while IFS= read -r literal || [[ -n "$literal" ]]; do
        [[ -z "$literal" ]] && continue
        [[ "$literal" == \#* ]] && continue
        if git grep "${revision_args[@]}" -I -F -q -- "$literal" -- . 2>/dev/null; then
            report_failure "tracked text matches a private local fingerprint"
        fi
    done < "$blocklist_path"
}

scan_test_constructs() {
    local revision_args=("$@")
    local matches
    matches="$(git grep "${revision_args[@]}" -I -n -E \
        '(^|[^A-Za-z])(XCTest|PreviewProvider)([^A-Za-z]|$)|#Preview' -- \
        '*.swift' 2>/dev/null || true)"
    if [[ -n "$matches" ]]; then
        report_failure "tracked Swift source contains test or preview constructs"
    fi
}

scan_hardcoded_data_literals() {
    local revision_args=("$@")
    local matches
    matches="$(git grep "${revision_args[@]}" -I -n -E \
        '(^|[^A-Za-z])(transcript|utteranceText|recordingTitle|speakerName|attendeeName)[[:space:]]*[:=][[:space:]]*"[^"\\]+"|PromptTestConfig[[:space:]]*\(' -- \
        '*.swift' 2>/dev/null || true)"
    if [[ -n "$matches" ]]; then
        report_failure "tracked Swift source contains a hardcoded evaluation/data literal"
    fi
}

scan_index_content() {
    scan_machine_paths --cached
    scan_email_literals --cached
    scan_local_blocklist --cached
    scan_test_constructs --cached
    scan_hardcoded_data_literals --cached
}

scan_paths_from_index
scan_index_content

if $scan_history; then
    while IFS= read -r commit; do
        scan_paths_from_commit "$commit"
        scan_machine_paths "$commit"
        scan_email_literals "$commit"
        scan_local_blocklist "$commit"
        scan_test_constructs "$commit"
        scan_hardcoded_data_literals "$commit"
    done < <(git rev-list --all)
fi

if (( failure_count > 0 )); then
    echo "privacy check found $failure_count violation(s)" >&2
    exit 1
fi

echo "privacy check passed"
