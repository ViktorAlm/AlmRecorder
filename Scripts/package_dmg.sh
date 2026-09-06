#!/bin/bash
#
# Build a distributable AlmRecorder.app + .dmg.
#
# WHY THIS EXISTS (vs the older package_app.sh): the app resolves its native libraries
# (vectorlite, custom SQLite, whisper/ggml, llama) from its OWN bundle via Bundle.main. If
# vectorlite.dylib isn't in Contents/Resources/Libraries, the app hits its intentional
# "semantic search required" fatalError. So this script copies ALL of
# AlmRecorder/Resources/{Libraries,Binaries} into the bundle — not just the llama subset.
#
# It then bundles SwiftPM dependency resource bundles + the prebuilt GRDB.framework, signs nested
# code inside-out, and builds the DMG. The explicit release channel controls whether the app uses
# an ad-hoc community signature or a Developer ID signature plus Apple notarization.
#
# Public community release (no paid Apple developer account):
#   ALMREC_RELEASE_CHANNEL=community ./Scripts/package_dmg.sh
#
# Developer ID release:
#   ALMREC_SIGNING_IDENTITY="Developer ID Application: ..." \
#   ALMREC_NOTARY_PROFILE="almrecorder-notary" ./Scripts/package_dmg.sh
#
# Local packaging smoke test (never publish this artifact):
#   ALMREC_ALLOW_ADHOC=1 ./Scripts/package_dmg.sh
set -euo pipefail

APP_NAME="AlmRecorder"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [ "$#" -ge 1 ]; then
  VERSION="$1"
else
  VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/AlmRecorder/Info.plist")"
fi
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/AlmRecorder/Info.plist")"
if [ "$VERSION" != "$PLIST_VERSION" ]; then
  echo "ERROR: requested version $VERSION does not match Info.plist version $PLIST_VERSION" >&2
  exit 1
fi

SIGNING_IDENTITY="${ALMREC_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${ALMREC_NOTARY_PROFILE:-}"
if [ -n "${ALMREC_RELEASE_CHANNEL:-}" ]; then
  RELEASE_CHANNEL="$ALMREC_RELEASE_CHANNEL"
elif [ "${ALMREC_ALLOW_ADHOC:-0}" = "1" ]; then
  # Backward-compatible spelling for local smoke packages only.
  RELEASE_CHANNEL="local"
else
  RELEASE_CHANNEL="developer-id"
fi

ADHOC_BUILD=false
COMMUNITY_BUILD=false
case "$RELEASE_CHANNEL" in
  community)
    if [ -n "$SIGNING_IDENTITY" ] || [ -n "$NOTARY_PROFILE" ]; then
      echo "ERROR: community builds are intentionally ad-hoc signed and not notarized." >&2
      echo "Use ALMREC_RELEASE_CHANNEL=developer-id with Apple release credentials instead." >&2
      exit 1
    fi
    ADHOC_BUILD=true
    COMMUNITY_BUILD=true
    ;;
  developer-id)
    if [ -z "$SIGNING_IDENTITY" ]; then
      echo "ERROR: the developer-id channel requires ALMREC_SIGNING_IDENTITY." >&2
      echo "Without an Apple developer account, use ALMREC_RELEASE_CHANNEL=community." >&2
      exit 1
    fi
    if [ -z "$NOTARY_PROFILE" ] && [ "${ALMREC_SKIP_NOTARIZATION:-0}" != "1" ]; then
      echo "ERROR: the developer-id channel requires ALMREC_NOTARY_PROFILE for notarytool." >&2
      echo "Set ALMREC_SKIP_NOTARIZATION=1 only for a signed local smoke test." >&2
      exit 1
    fi
    ;;
  local)
    if [ "${ALMREC_ALLOW_ADHOC:-0}" != "1" ]; then
      echo "ERROR: local packaging must be explicitly enabled with ALMREC_ALLOW_ADHOC=1." >&2
      exit 1
    fi
    if [ -n "$SIGNING_IDENTITY" ] || [ -n "$NOTARY_PROFILE" ]; then
      echo "ERROR: local ad-hoc packaging does not accept Apple release credentials." >&2
      exit 1
    fi
    ADHOC_BUILD=true
    ;;
  *)
    echo "ERROR: unsupported ALMREC_RELEASE_CHANNEL '$RELEASE_CHANNEL'." >&2
    echo "Choose community, developer-id, or local." >&2
    exit 1
    ;;
esac

if [ "$RELEASE_CHANNEL" != "local" ]; then
  echo "==> Running source release gate"
  ALMREC_RELEASE_CHANNEL="$RELEASE_CHANNEL" "$ROOT/Scripts/check_release_readiness.sh"
fi

BUILD_DIR="$ROOT/build"
DIST_DIR="$ROOT/dist"
APP="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"
RES="$CONTENTS/Resources"
FW="$CONTENTS/Frameworks"
REL="$ROOT/.build/release"

echo "==> Building $APP_NAME $VERSION (release)"
if [ "${ALMREC_SKIP_SWIFT_BUILD:-0}" != "1" ]; then
  swift build -c release --jobs "${ALMREC_BUILD_JOBS:-2}"
else
  echo "Using previously validated release build"
fi

echo "==> Assembling $APP_NAME.app"
rm -rf "$APP" "$DIST_DIR"
mkdir -p "$CONTENTS/MacOS" "$RES" "$FW" "$DIST_DIR"

cp "$REL/$APP_NAME" "$CONTENTS/MacOS/$APP_NAME"
cp "$REL/AlmRecorderMCPBridge" "$CONTENTS/MacOS/AlmRecorderMCPBridge"
cp "$ROOT/AlmRecorder/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/AlmRecorder/PrivacyInfo.xcprivacy" "$RES/PrivacyInfo.xcprivacy"
cp "$ROOT/AlmRecorder/Resources/AppIcon.icns" "$RES/AppIcon.icns"   # Dock/Finder icon (CFBundleIconFile)
cp "$ROOT/AlmRecorder/Assets.xcassets/MenuBarIcon.imageset/menubar.pdf" \
   "$RES/MenuBarIcon.pdf"

# App's own resources — resolved at runtime via Bundle.main (THIS is what fixes the vectorlite crash)
cp -R "$ROOT/AlmRecorder/Resources/Libraries" "$RES/Libraries"
cp -R "$ROOT/AlmRecorder/Resources/Binaries"  "$RES/Binaries"
# llama.cpp's release directory contains exact-version copies as well as the stable install-name
# files actually referenced by the CLIs. Do not ship duplicate stale/current copies.
rm -f "$RES/Libraries/llama/"lib*.0.*.*.dylib
mkdir -p "$RES/Python"
cp "$ROOT/AlmRecorder/Resources/Python/vibevoice_helper.py" "$RES/Python/"
cp -R "$ROOT/AlmRecorder/Resources/Licenses"  "$RES/Licenses"
bash "$ROOT/Scripts/stage_distribution_licenses.sh" "$RES/Licenses"

# VibeVoice installs its pinned MLX-Audio environment on first use. Bundle the standalone uv
# executable when it is available on the build Mac so installed copies do not depend on Homebrew.
UV_BIN="${ALMREC_UV_BINARY:-}"
if [ -z "$UV_BIN" ]; then
  if [ -x /opt/homebrew/bin/uv ]; then
    UV_BIN=/opt/homebrew/bin/uv
  elif [ -x /usr/local/bin/uv ]; then
    UV_BIN=/usr/local/bin/uv
  fi
fi
if [ -n "$UV_BIN" ] && [ -x "$UV_BIN" ]; then
  cp -L "$UV_BIN" "$RES/Binaries/uv"
  UV_LICENSE_DIR="${ALMREC_UV_LICENSE_DIR:-}"
  if [ -z "$UV_LICENSE_DIR" ] && command -v brew >/dev/null 2>&1; then
    UV_LICENSE_DIR="$(brew --prefix uv 2>/dev/null || true)"
  fi
  if [ -n "$UV_LICENSE_DIR" ] \
      && [ -f "$UV_LICENSE_DIR/LICENSE-APACHE" ] \
      && [ -f "$UV_LICENSE_DIR/LICENSE-MIT" ]; then
    mkdir -p "$RES/Licenses/uv"
    cp "$UV_LICENSE_DIR/LICENSE-APACHE" "$RES/Licenses/uv/"
    cp "$UV_LICENSE_DIR/LICENSE-MIT" "$RES/Licenses/uv/"
  else
    echo "ERROR: uv license files not found; set ALMREC_UV_LICENSE_DIR" >&2
    exit 1
  fi
else
  echo "ERROR: uv is required for the fully featured VibeVoice distribution" >&2
  echo "Set ALMREC_UV_BINARY to the standalone arm64 uv executable." >&2
  exit 1
fi

# SwiftPM dependency resource bundles (e.g. FluidAudio models), resolved via Bundle.module
shopt -s nullglob
for b in "$REL"/*.bundle; do
  # The app target's resources were copied into their legal Bundle.main destinations above.
  # Copying its generated bundle as well would duplicate every native runtime by ~48 MB.
  [ "$(basename "$b")" = "AlmRecorder_AlmRecorder.bundle" ] && continue
  cp -R "$b" "$RES/"
done
shopt -u nullglob

# Prebuilt GRDB.framework — the executable links @rpath/GRDB.framework and carries an
# @executable_path/../Frameworks rpath, so it must live in Contents/Frameworks.
cp -R "$ROOT/GRDBCustom/Binary/GRDB.xcframework/macos-arm64_x86_64/GRDB.framework" "$FW/GRDB.framework"

# SwiftPM does not consistently preserve that bundle-relative rpath in release binaries. Add it
# explicitly so the installed app can load GRDB from Contents/Frameworks instead of only looking
# beside the executable and in the system Swift paths.
if ! otool -l "$CONTENTS/MacOS/$APP_NAME" | grep -Fq "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$CONTENTS/MacOS/$APP_NAME"
fi

chmod +x "$RES/Binaries/"* 2>/dev/null || true

if $COMMUNITY_BUILD; then
  echo "==> Ad-hoc signing community build (inside-out; no Apple identity)"
  CODESIGN_ARGS=(--force --timestamp=none --sign -)
elif $ADHOC_BUILD; then
  echo "==> Ad-hoc signing local smoke build (inside-out)"
  CODESIGN_ARGS=(--force --timestamp=none --sign -)
else
  echo "==> Developer ID signing with hardened runtime (inside-out)"
  CODESIGN_ARGS=(--force --options runtime --timestamp --sign "$SIGNING_IDENTITY")
fi

# Direct distribution deliberately does not enable App Sandbox. The app uses hardened runtime,
# TCC usage descriptions, security-scoped bookmarks, and same-team signed native dependencies.
# App Store submission is a separate packaging target and would require a sandbox-specific audit.
find "$RES" -name "*.dylib" -print0 | while IFS= read -r -d '' f; do
  codesign "${CODESIGN_ARGS[@]}" "$f"
done
find "$RES/Binaries" -type f -perm +111 -print0 | while IFS= read -r -d '' f; do
  if file "$f" | grep -q "Mach-O"; then
    codesign "${CODESIGN_ARGS[@]}" "$f"
  fi
done
codesign "${CODESIGN_ARGS[@]}" "$FW/GRDB.framework"
codesign "${CODESIGN_ARGS[@]}" "$CONTENTS/MacOS/AlmRecorderMCPBridge"
codesign "${CODESIGN_ARGS[@]}" "$APP"

echo "==> Verifying bundle"
ok=1
[ -f "$RES/Libraries/vectorlite.dylib" ]       && echo "  ✓ vectorlite.dylib"        || { echo "  ✗ vectorlite.dylib MISSING"; ok=0; }
[ -f "$RES/Libraries/libsqlite3_custom.dylib" ] && echo "  ✓ libsqlite3_custom.dylib" || { echo "  ✗ custom SQLite MISSING"; ok=0; }
[ -f "$RES/Binaries/whisper-cli" ]              && echo "  ✓ whisper-cli"             || echo "  ! whisper-cli missing"
[ -x "$RES/Binaries/llama-server" ]              && echo "  ✓ llama-server (Gemma audio)" || { echo "  ✗ llama-server MISSING"; ok=0; }
[ -x "$RES/Binaries/vibeasr-stream-server" ]    && echo "  ✓ VibeASR realtime server" || echo "  ! VibeASR server missing"
[ -f "$RES/Licenses/VibeASR.cpp/LICENSE" ]      && echo "  ✓ VibeASR license"          || echo "  ! VibeASR license missing"
[ -f "$RES/Licenses/THIRD-PARTY-NOTICES.md" ]  && echo "  ✓ third-party notices"      || { echo "  ✗ third-party notices MISSING"; ok=0; }
[ -f "$RES/PrivacyInfo.xcprivacy" ]             && echo "  ✓ privacy manifest"         || { echo "  ✗ privacy manifest MISSING"; ok=0; }
[ -f "$RES/Binaries/uv" ]                       && echo "  ✓ uv (VibeVoice installer)" || echo "  ! bundled uv missing"
[ -f "$RES/Licenses/uv/LICENSE-MIT" ]           && echo "  ✓ uv licenses"              || echo "  ! uv licenses missing"
[ -x "$CONTENTS/MacOS/AlmRecorderMCPBridge" ]   && echo "  ✓ MCP stdio bridge"         || { echo "  ✗ MCP bridge MISSING"; ok=0; }
[ -d "$FW/GRDB.framework" ]                     && echo "  ✓ GRDB.framework"          || { echo "  ✗ GRDB.framework MISSING"; ok=0; }
[ ! -d "$RES/Models" ]                          && echo "  ✓ no synthetic test models" || { echo "  ✗ test Models directory bundled"; ok=0; }
[ ! -d "$RES/Python/__pycache__" ]              && echo "  ✓ no Python cache"          || { echo "  ✗ Python cache bundled"; ok=0; }
[ ! -d "$RES/AlmRecorder_AlmRecorder.bundle" ]  && echo "  ✓ no duplicate app resource bundle" || { echo "  ✗ duplicate app resource bundle"; ok=0; }
if find "$RES" -type f -name 'lib*.0.*.*.dylib' | grep -q .; then
  echo "  ✗ duplicate exact-version llama libraries bundled"
  ok=0
else
  echo "  ✓ no duplicate exact-version llama libraries"
fi
codesign --verify --deep --strict --verbose=2 "$APP" && echo "  ✓ codesign verify" || ok=0
if ! $ADHOC_BUILD; then
  signature_details="$(codesign -d --verbose=4 "$APP" 2>&1 || true)"
  grep -q "flags=.*runtime" <<< "$signature_details" \
    && echo "  ✓ hardened runtime" \
    || { echo "  ✗ hardened runtime missing"; ok=0; }
fi
[ "$ok" = 1 ] || { echo "ERROR: bundle verification failed"; exit 1; }

if [ "$RELEASE_CHANNEL" != "local" ]; then
  echo "==> Running packaged-app release gate"
  ALMREC_RELEASE_CHANNEL="$RELEASE_CHANNEL" \
    "$ROOT/Scripts/check_release_readiness.sh" "$APP"
fi

echo "==> Building DMG"
STAGE="$BUILD_DIR/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
if $COMMUNITY_BUILD; then
  cp "$ROOT/docs/COMMUNITY_BUILD_INSTALL.txt" "$STAGE/READ ME - COMMUNITY BUILD.txt"
  DMG_BASENAME="$APP_NAME-$VERSION-community.dmg"
elif $ADHOC_BUILD; then
  DMG_BASENAME="$APP_NAME-$VERSION-local.dmg"
else
  DMG_BASENAME="$APP_NAME-$VERSION.dmg"
fi
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DIST_DIR/$DMG_BASENAME" >/dev/null
rm -rf "$STAGE"

DMG="$DIST_DIR/$DMG_BASENAME"
if ! $ADHOC_BUILD; then
  echo "==> Signing DMG"
  codesign "${CODESIGN_ARGS[@]}" "$DMG"
  codesign --verify --strict --verbose=2 "$DMG"

  if [ "${ALMREC_SKIP_NOTARIZATION:-0}" != "1" ]; then
    echo "==> Submitting to Apple notarization service"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type install --verbose=2 "$DMG"
  else
    echo "WARNING: notarization skipped; this artifact is not publishable"
  fi
elif $COMMUNITY_BUILD; then
  echo "WARNING: community artifact is not Developer ID signed or Apple-notarized."
  echo "Publish only with its SHA-256 digest and the documented first-launch instructions."
else
  echo "WARNING: ad-hoc artifact is for local smoke testing only; do not publish it"
fi

echo ""
echo "==> Done:"
echo "    App: $APP"
echo "    DMG: $DMG"
du -h "$DMG" | cut -f1 | sed 's/^/    Size: /'
DMG_SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
CHECKSUM_FILE="$DMG.sha256"
printf '%s  %s\n' "$DMG_SHA256" "$DMG_BASENAME" > "$CHECKSUM_FILE"
(cd "$DIST_DIR" && shasum -a 256 -c "$(basename "$CHECKSUM_FILE")")
echo "    SHA-256: $DMG_SHA256"
echo "    Checksum: $CHECKSUM_FILE"
