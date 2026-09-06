#!/usr/bin/env bash

set -euo pipefail
shopt -s nocasematch

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
privacy_text_pathspecs=(
    '*.swift' '*.md' '*.txt' '*.sh' '*.py' '*.plist' '*.xcprivacy'
    '*.json' '*.toml' '*.yml' '*.yaml' 'Package.swift'
)

report_failure() {
    echo "privacy check failed: $1" >&2
    failure_count=$((failure_count + 1))
}

path_is_forbidden() {
    local path="$1"
    local lowercase_path="$path"

    # Reviewed, synthetic regression tests are intentionally public. They remain subject to every
    # content scanner below; only the blanket path/test-source bans are waived for this directory.
    case "$lowercase_path" in
        developertests/*)
            return 1
            ;;
    esac

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

scan_paths_from_worktree() {
    local path
    while IFS= read -r -d '' path; do
        if path_is_forbidden "$path"; then
            report_failure "forbidden working-tree path: $path"
        fi
    done < <(git ls-files -co --exclude-standard -z)
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
    if (( ${#revision_args[@]} > 0 )); then
        matches="$(git grep "${revision_args[@]}" -I -n -E '/Users/[A-Za-z0-9._-]+' -- \
            "${privacy_text_pathspecs[@]}" ':!Scripts/check_repository_privacy.sh' 2>/dev/null || true)"
    else
        matches="$(git grep -I -n -E '/Users/[A-Za-z0-9._-]+' -- \
            "${privacy_text_pathspecs[@]}" ':!Scripts/check_repository_privacy.sh' 2>/dev/null || true)"
    fi
    if [[ -n "$matches" ]]; then
        report_failure "tracked text contains a machine-specific home path"
    fi
}

scan_email_literals() {
    local revision_args=("$@")
    local email
    local matches
    if (( ${#revision_args[@]} > 0 )); then
        matches="$(git grep "${revision_args[@]}" -I -h -o -E \
            '[[:alnum:]._%+-]+@[[:alpha:]][[:alnum:].-]*\.[[:alpha:]]{2,}' -- \
            "${privacy_text_pathspecs[@]}" ':!Scripts/check_repository_privacy.sh' 2>/dev/null || true)"
    else
        matches="$(git grep -I -h -o -E \
            '[[:alnum:]._%+-]+@[[:alpha:]][[:alnum:].-]*\.[[:alpha:]]{2,}' -- \
            "${privacy_text_pathspecs[@]}" ':!Scripts/check_repository_privacy.sh' 2>/dev/null || true)"
    fi
    while IFS= read -r email; do
        [[ -z "$email" ]] && continue
        report_failure "tracked text contains an email literal"
    done <<< "$matches"
}

scan_local_blocklist() {
    local revision_args=("$@")
    local blocklist_path="${ALMREC_PRIVACY_BLOCKLIST:-$repository_root/.privacy-blocklist}"
    [[ -f "$blocklist_path" ]] || return 0

    local literal
    while IFS= read -r literal || [[ -n "$literal" ]]; do
        [[ -z "$literal" ]] && continue
        [[ "$literal" == \#* ]] && continue
        if (( ${#revision_args[@]} > 0 )); then
            if git grep "${revision_args[@]}" -I -F -q -- "$literal" -- \
                "${privacy_text_pathspecs[@]}" 2>/dev/null; then
                matched=0
            else
                matched=$?
            fi
        else
            if git grep -I -F -q -- "$literal" -- "${privacy_text_pathspecs[@]}" 2>/dev/null; then
                matched=0
            else
                matched=$?
            fi
        fi
        if (( matched == 0 )); then
            report_failure "tracked text matches a private local fingerprint"
        fi
    done < "$blocklist_path"
}

scan_test_constructs() {
    local revision_args=("$@")
    local matches
    if (( ${#revision_args[@]} > 0 )); then
        matches="$(git grep "${revision_args[@]}" -I -n -E \
            '(^|[^A-Za-z])(XCTest|PreviewProvider)([^A-Za-z]|$)|#Preview' -- \
            '*.swift' ':!DeveloperTests/**' 2>/dev/null || true)"
    else
        matches="$(git grep -I -n -E \
            '(^|[^A-Za-z])(XCTest|PreviewProvider)([^A-Za-z]|$)|#Preview' -- \
            '*.swift' ':!DeveloperTests/**' 2>/dev/null || true)"
    fi
    if [[ -n "$matches" ]]; then
        report_failure "tracked Swift source contains test or preview constructs"
    fi
}

scan_hardcoded_data_literals() {
    local revision_args=("$@")
    local matches
    if (( ${#revision_args[@]} > 0 )); then
        matches="$(git grep "${revision_args[@]}" -I -n -E \
            '(^|[^A-Za-z])(transcript|utteranceText|recordingTitle|speakerName|attendeeName)[[:space:]]*[:=][[:space:]]*"[^"\\]+"|PromptTestConfig[[:space:]]*\(' -- \
            '*.swift' 2>/dev/null | grep -v 'privacy:allow-synthetic' || true)"
    else
        matches="$(git grep -I -n -E \
            '(^|[^A-Za-z])(transcript|utteranceText|recordingTitle|speakerName|attendeeName)[[:space:]]*[:=][[:space:]]*"[^"\\]+"|PromptTestConfig[[:space:]]*\(' -- \
            '*.swift' 2>/dev/null | grep -v 'privacy:allow-synthetic' || true)"
    fi
    if [[ -n "$matches" ]]; then
        report_failure "tracked Swift source contains a hardcoded evaluation/data literal"
    fi
}

scan_untracked_content() {
    local path
    local blocklist_path="${ALMREC_PRIVACY_BLOCKLIST:-$repository_root/.privacy-blocklist}"
    while IFS= read -r -d '' path; do
        # Skip native artifacts and other binary files. `grep -Iq` returns success only for text.
        grep -Iq . "$path" 2>/dev/null || continue

        grep -Eq '/Users/[A-Za-z0-9._-]+' "$path" \
            && report_failure "untracked text contains a machine-specific home path: $path"
        grep -Eq '[[:alnum:]._%+-]+@[[:alpha:]][[:alnum:].-]*\.[[:alpha:]]{2,}' "$path" \
            && report_failure "untracked text contains an email literal: $path"
        if [[ "$path" == *.swift && "$path" != DeveloperTests/* ]]; then
            grep -Eq '(^|[^A-Za-z])(XCTest|PreviewProvider)([^A-Za-z]|$)|#Preview' "$path" \
                && report_failure "untracked Swift source contains test or preview constructs: $path"
        fi
        if [[ "$path" == *.swift ]]; then
            grep -E '(^|[^A-Za-z])(transcript|utteranceText|recordingTitle|speakerName|attendeeName)[[:space:]]*[:=][[:space:]]*"[^"\\]+"|PromptTestConfig[[:space:]]*\(' "$path" \
                | grep -qv 'privacy:allow-synthetic' \
                && report_failure "untracked Swift source contains a hardcoded evaluation/data literal: $path"
        fi
        if [[ -f "$blocklist_path" ]]; then
            while IFS= read -r literal || [[ -n "$literal" ]]; do
                [[ -z "$literal" || "$literal" == \#* ]] && continue
                grep -Fq -- "$literal" "$path" \
                    && report_failure "untracked text matches a private local fingerprint: $path"
            done < "$blocklist_path"
        fi
    done < <(git ls-files --others --exclude-standard -z)
}

scan_worktree_content() {
    scan_machine_paths
    scan_email_literals
    scan_local_blocklist
    scan_test_constructs
    scan_hardcoded_data_literals
    scan_untracked_content
}

scan_paths_from_worktree
scan_worktree_content

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
