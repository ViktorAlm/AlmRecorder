#!/usr/bin/env bash

# Static release gate. This does not replace tests or (for the Developer ID channel) notarization;
# it catches reproducibility, metadata, native-runtime, attribution, signing-channel, and bundle-
# assembly mistakes before a DMG is uploaded.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_PATH="${1:-}"
RELEASE_CHANNEL="${ALMREC_RELEASE_CHANNEL:-developer-id}"
failures=0

pass() { echo "  ✓ $1"; }
warn() { echo "  ! $1"; }
fail() { echo "  ✗ $1" >&2; failures=$((failures + 1)); }

require_file() {
    if [[ -f "$1" ]]; then pass "$2"; else fail "$2 missing: $1"; fi
}

case "$RELEASE_CHANNEL" in
    community|developer-id|local) ;;
    *)
        echo "ERROR: unsupported ALMREC_RELEASE_CHANNEL '$RELEASE_CHANNEL'" >&2
        exit 1
        ;;
esac

echo "==> Release channel: $RELEASE_CHANNEL"

echo "==> Source metadata"
if [[ -z "$(git status --porcelain --untracked-files=all)" ]]; then
    pass "source checkout is clean"
else
    fail "source checkout has tracked or untracked changes; publish only from a committed revision"
fi

required_public_sources=(
    "AlmRecorder/PrivacyInfo.xcprivacy"
    "DeveloperTests/AlmRecorderQualitySafetyTests/PrivacyManifestSafetyTests.swift"
    "DeveloperTests/AlmRecorderQualitySafetyTests/ProductionThreeStageLiveTests.swift"
    "Scripts/check_release_readiness.sh"
    "Scripts/package_dmg.sh"
    "Scripts/package_llama.sh"
    "Scripts/package_whisper.sh"
    "docs/COMMUNITY_BUILD_INSTALL.txt"
    "docs/RELEASE_CHECKLIST.md"
)
for path in "${required_public_sources[@]}"; do
    if [[ ! -f "$path" ]]; then
        fail "required release source missing: $path"
    elif git ls-files --error-unmatch "$path" >/dev/null 2>&1; then
        pass "release source tracked: $path"
    else
        fail "required release source is not tracked: $path"
    fi
done

if plutil -lint AlmRecorder/Info.plist AlmRecorder/PrivacyInfo.xcprivacy \
    Package/Info.plist.template >/dev/null; then
    pass "property lists are valid"
else
    fail "one or more property lists are invalid"
fi
actual_info="$(plutil -convert json -o - AlmRecorder/Info.plist)"
template_info="$(plutil -convert json -o - Package/Info.plist.template)"
if [[ "$actual_info" == "$template_info" ]]; then
    pass "canonical and template app metadata match"
else
    fail "AlmRecorder/Info.plist and Package/Info.plist.template have drifted"
fi
privacy_manifest="$(plutil -p AlmRecorder/PrivacyInfo.xcprivacy)"
if grep -q 'NSPrivacyAccessedAPICategoryUserDefaults' <<< "$privacy_manifest" \
    && grep -q 'CA92.1' <<< "$privacy_manifest"; then
    pass "UserDefaults required-reason use declared"
else
    fail "UserDefaults required-reason declaration missing"
fi
if grep -q 'NSPrivacyAccessedAPICategoryFileTimestamp' <<< "$privacy_manifest" \
    && grep -q 'C617.1' <<< "$privacy_manifest" \
    && grep -q '3B52.1' <<< "$privacy_manifest"; then
    pass "container and user-selected file timestamp reasons declared"
else
    fail "file timestamp required-reason declarations missing"
fi

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' AlmRecorder/Info.plist)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' AlmRecorder/Info.plist)"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' AlmRecorder/Info.plist)"
[[ "$bundle_id" == "com.alm.AlmRecorder" ]] && pass "bundle identifier: $bundle_id" \
    || fail "unexpected bundle identifier: $bundle_id"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && pass "version: $version ($build)" \
    || fail "version is not semantic: $version"
release_notes="docs/releases/$version.md"
if [[ ! -f "$release_notes" ]]; then
    fail "versioned release notes missing: $release_notes"
elif git ls-files --error-unmatch "$release_notes" >/dev/null 2>&1; then
    pass "versioned release notes tracked: $release_notes"
else
    fail "versioned release notes are not tracked: $release_notes"
fi
if grep -q 'com.microsoft.waveform-audio' AlmRecorder/Info.plist \
    && ! grep -q 'public.wav-audio' AlmRecorder/Info.plist; then
    pass "WAV document type uses Apple's declared identifier"
else
    fail "WAV document type is missing or uses a non-system UTI"
fi

if rg -n -i 'yourusername|yourcompany|your-cdn\.com|YOUR_REPO' \
    AlmRecorder Package README.md CONTRIBUTING.md Scripts/package_dmg.sh Scripts/package_app.sh \
    >/dev/null; then
    fail "publication-facing source still contains placeholder identifiers or URLs"
else
    pass "no publication placeholders"
fi
if rg -n 'huggingface\.co/.*/resolve/main/' AlmRecorder --glob '*.swift' >/dev/null; then
    fail "production model downloads still reference a mutable Hugging Face branch"
else
    pass "production model downloads use immutable revisions"
fi

echo "==> Repository privacy"
if ./Scripts/check_repository_privacy.sh; then
    pass "working tree passes repository privacy policy"
else
    fail "working tree violates repository privacy policy"
fi

echo "==> Reproducible native sources"
while IFS= read -r path; do
    expected="$(git ls-files -s "$path" | awk '{print $2}')"
    actual="$(git -C "$path" rev-parse HEAD 2>/dev/null || true)"
    if [[ -z "$expected" || -z "$actual" ]]; then
        fail "submodule unavailable: $path"
    elif [[ "$expected" != "$actual" ]]; then
        fail "$path checkout $actual does not match recorded revision $expected"
    elif [[ -n "$(git -C "$path" status --porcelain)" ]]; then
        fail "$path has uncommitted source changes"
    else
        pass "$path pinned at ${actual:0:12}"
    fi
done < <(git config --file .gitmodules --get-regexp path | awk '{print $2}')

echo "==> Bundled native runtime"
required_binaries=(
    whisper-cli
    llama-mtmd-cli
    llama-completion
    llama-server
    llama-embedding
    vibeasr-stream-server
)
for name in "${required_binaries[@]}"; do
    path="AlmRecorder/Resources/Binaries/$name"
    if [[ ! -x "$path" ]]; then
        fail "required executable missing: $name"
    elif file "$path" | grep -q 'Mach-O 64-bit executable arm64'; then
        pass "$name is arm64 Mach-O"
    else
        fail "$name has an unexpected architecture or format"
    fi
done

while IFS= read -r binary; do
    while IFS= read -r dependency; do
        case "$dependency" in
            @rpath/*)
                leaf="${dependency##*/}"
                if ! find AlmRecorder/Resources/Libraries -type f -name "$leaf" -print -quit \
                    | grep -q .; then
                    fail "$(basename "$binary") references missing $leaf"
                fi
                ;;
        esac
    done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')
done < <(find AlmRecorder/Resources/Binaries -type f -perm +111)

require_file "AlmRecorder/Resources/Libraries/vectorlite.dylib" "vectorlite runtime"
require_file "AlmRecorder/Resources/Libraries/libsqlite3_custom.dylib" "custom SQLite runtime"

echo "==> Distribution notices"
license_stage="$(mktemp -d "${TMPDIR:-/tmp}/almrec-licenses.XXXXXX")"
trap 'rm -rf "$license_stage"' EXIT
if bash ./Scripts/stage_distribution_licenses.sh "$license_stage"; then
    pass "all required dependency license sources are present"
else
    fail "dependency license staging failed"
fi
require_file "$license_stage/THIRD-PARTY-NOTICES.md" "third-party notice"
require_file "$license_stage/llama.cpp/LICENSE.txt" "llama.cpp license"
require_file "$license_stage/whisper.cpp/LICENSE.txt" "whisper.cpp license"
require_file "$license_stage/VibeASR.cpp/LICENSE.txt" "VibeASR.cpp license"
require_file "$license_stage/GRDB/LICENSE.txt" "GRDB license"

if [[ -n "$APP_PATH" ]]; then
    echo "==> Packaged app"
    resources="$APP_PATH/Contents/Resources"
    require_file "$APP_PATH/Contents/Info.plist" "packaged Info.plist"
    require_file "$resources/PrivacyInfo.xcprivacy" "packaged privacy manifest"
    require_file "$resources/Licenses/THIRD-PARTY-NOTICES.md" "packaged notices"
    [[ ! -d "$resources/Models" ]] && pass "synthetic model resources excluded" \
        || fail "packaged app contains source-only Models directory"
    [[ ! -d "$resources/Python/__pycache__" ]] && pass "Python bytecode cache excluded" \
        || fail "packaged app contains Python bytecode cache"
    [[ ! -d "$resources/AlmRecorder_AlmRecorder.bundle" ]] \
        && pass "duplicate app resource bundle excluded" \
        || fail "packaged app contains duplicate app resource bundle"
    if find "$resources" -type f -name 'lib*.0.*.*.dylib' | grep -q .; then
        fail "packaged app contains duplicate exact-version llama libraries"
    else
        pass "duplicate exact-version llama libraries excluded"
    fi
    codesign --verify --deep --strict --verbose=2 "$APP_PATH" \
        && pass "bundle code signature verifies" \
        || fail "bundle code signature does not verify"
    signature_details="$(codesign -d --verbose=4 "$APP_PATH" 2>&1 || true)"
    case "$RELEASE_CHANNEL" in
        community)
            if grep -q 'Signature=adhoc' <<< "$signature_details"; then
                pass "community bundle has the expected ad-hoc signature"
                warn "community bundle is not Apple-notarized; publish first-launch instructions and SHA-256"
            else
                fail "community bundle does not have the expected ad-hoc signature"
            fi
            ;;
        developer-id)
            if grep -q 'Signature=adhoc' <<< "$signature_details"; then
                fail "Developer ID channel bundle is only ad-hoc signed"
            elif grep -q 'flags=.*runtime' <<< "$signature_details"; then
                pass "Developer ID hardened runtime signature present"
            else
                fail "hardened runtime signature not detected"
            fi
            ;;
        local)
            if grep -q 'Signature=adhoc' <<< "$signature_details"; then
                pass "local smoke bundle has an ad-hoc signature"
            else
                warn "local smoke bundle is not ad-hoc signed"
            fi
            ;;
    esac
fi

if (( failures > 0 )); then
    echo "release readiness failed with $failures issue(s)" >&2
    exit 1
fi

echo "release readiness passed"
