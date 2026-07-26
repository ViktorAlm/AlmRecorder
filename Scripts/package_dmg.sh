#!/bin/bash
#
# Build a distributable AlmRecorder.app + .dmg (unsigned / ad-hoc signed).
#
# WHY THIS EXISTS (vs the older package_app.sh): the app resolves its native libraries
# (vectorlite, custom SQLite, whisper/ggml, llama) from its OWN bundle via Bundle.main. If
# vectorlite.dylib isn't in Contents/Resources/Libraries, the app hits its intentional
# "semantic search required" fatalError. So this script copies ALL of
# AlmRecorder/Resources/{Libraries,Binaries,Models} into the bundle — not just the llama subset.
#
# It then bundles SwiftPM dependency resource bundles + the prebuilt GRDB.framework, ad-hoc signs
# inside-out (REQUIRED on Apple Silicon for the app and its nested dylibs/CLIs to run), and builds
# a .dmg with hdiutil (no external create-dmg dependency).
#
# Distribution is UNSIGNED (not Apple-notarized): users bypass Gatekeeper on first launch
# (right-click -> Open, or `xattr -dr com.apple.quarantine /Applications/AlmRecorder.app`).
#
# Usage: ./Scripts/package_dmg.sh [version]
set -euo pipefail

APP_NAME="AlmRecorder"
VERSION="${1:-1.0.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/build"
DIST_DIR="$ROOT/dist"
APP="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"
RES="$CONTENTS/Resources"
FW="$CONTENTS/Frameworks"
REL="$ROOT/.build/release"

echo "==> Building $APP_NAME $VERSION (release)"
swift build -c release

echo "==> Assembling $APP_NAME.app"
rm -rf "$APP" "$DIST_DIR"
mkdir -p "$CONTENTS/MacOS" "$RES" "$FW" "$DIST_DIR"

cp "$REL/$APP_NAME" "$CONTENTS/MacOS/$APP_NAME"
cp "$REL/AlmRecorderMCPBridge" "$CONTENTS/MacOS/AlmRecorderMCPBridge"
cp "$ROOT/AlmRecorder/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/AlmRecorder/Resources/AppIcon.icns" "$RES/AppIcon.icns"   # Dock/Finder icon (CFBundleIconFile)

# App's own resources — resolved at runtime via Bundle.main (THIS is what fixes the vectorlite crash)
cp -R "$ROOT/AlmRecorder/Resources/Libraries" "$RES/Libraries"
cp -R "$ROOT/AlmRecorder/Resources/Binaries"  "$RES/Binaries"
cp -R "$ROOT/AlmRecorder/Resources/Models"    "$RES/Models"
cp -R "$ROOT/AlmRecorder/Resources/Python"    "$RES/Python"

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
    echo "  ! uv license files not found; set ALMREC_UV_LICENSE_DIR for distribution"
  fi
else
  echo "  ! uv missing; VibeVoice runtime installation will require Homebrew uv"
fi

# SwiftPM dependency resource bundles (e.g. FluidAudio models), resolved via Bundle.module
shopt -s nullglob
for b in "$REL"/*.bundle; do cp -R "$b" "$RES/"; done
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

echo "==> Ad-hoc signing (inside-out; unsandboxed for reliable first-run)"
# Sign nested code first, then the app. No entitlements => unsandboxed (most reliable for an
# unsigned download). The sandbox entitlements in AlmRecorder/AlmRecorder.entitlements are kept
# for a future signed+notarized build.
find "$RES" -name "*.dylib" -print0 | while IFS= read -r -d '' f; do
  codesign --force --timestamp=none --sign - "$f"
done
find "$RES/Binaries" -type f -perm +111 -print0 | while IFS= read -r -d '' f; do
  codesign --force --timestamp=none --sign - "$f"
done
codesign --force --timestamp=none --sign - "$FW/GRDB.framework"
codesign --force --timestamp=none --sign - "$CONTENTS/MacOS/AlmRecorderMCPBridge"
codesign --force --timestamp=none --sign - "$CONTENTS/MacOS/$APP_NAME"
codesign --force --timestamp=none --sign - "$APP"

echo "==> Verifying bundle"
ok=1
[ -f "$RES/Libraries/vectorlite.dylib" ]       && echo "  ✓ vectorlite.dylib"        || { echo "  ✗ vectorlite.dylib MISSING"; ok=0; }
[ -f "$RES/Libraries/libsqlite3_custom.dylib" ] && echo "  ✓ libsqlite3_custom.dylib" || { echo "  ✗ custom SQLite MISSING"; ok=0; }
[ -f "$RES/Binaries/whisper-cli" ]              && echo "  ✓ whisper-cli"             || echo "  ! whisper-cli missing"
[ -f "$RES/Binaries/uv" ]                       && echo "  ✓ uv (VibeVoice installer)" || echo "  ! bundled uv missing"
[ -f "$RES/Licenses/uv/LICENSE-MIT" ]           && echo "  ✓ uv licenses"              || echo "  ! uv licenses missing"
[ -x "$CONTENTS/MacOS/AlmRecorderMCPBridge" ]   && echo "  ✓ MCP stdio bridge"         || { echo "  ✗ MCP bridge MISSING"; ok=0; }
[ -d "$FW/GRDB.framework" ]                     && echo "  ✓ GRDB.framework"          || { echo "  ✗ GRDB.framework MISSING"; ok=0; }
codesign --verify --strict "$APP" && echo "  ✓ codesign verify" || ok=0
[ "$ok" = 1 ] || { echo "ERROR: bundle verification failed"; exit 1; }

echo "==> Building DMG"
STAGE="$BUILD_DIR/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DIST_DIR/$APP_NAME-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"

echo ""
echo "==> Done:"
echo "    App: $APP"
echo "    DMG: $DIST_DIR/$APP_NAME-$VERSION.dmg"
du -h "$DIST_DIR/$APP_NAME-$VERSION.dmg" | cut -f1 | sed 's/^/    Size: /'
