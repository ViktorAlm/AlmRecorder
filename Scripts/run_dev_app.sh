#!/bin/bash
# Build AlmRecorder and wrap it in a signed, NON-sandboxed .app bundle so macOS TCC will
# actually prompt for Calendar / Microphone / Voice Memos access (a bare SPM binary has no
# Info.plist, so no prompt can appear). Non-sandboxed = uses the real ~/Library/Application
# Support and the absolute dev paths the code already resolves for vectorlite/whisper/llama.
set -e
cd "$(dirname "$0")/.."   # project root
APP="build/AlmRecorder.app"

echo "🔨 swift build (debug)..."
swift build --jobs "${ALMREC_BUILD_JOBS:-2}"

echo "📁 Assembling $APP ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/debug/AlmRecorder "$APP/Contents/MacOS/AlmRecorder"
cp .build/debug/AlmRecorderMCPBridge "$APP/Contents/MacOS/AlmRecorderMCPBridge"
chmod +x "$APP/Contents/MacOS/AlmRecorderMCPBridge"
cp AlmRecorder/Info.plist "$APP/Contents/Info.plist"
cp AlmRecorder/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # Dock/Finder icon (CFBundleIconFile)
cp AlmRecorder/Assets.xcassets/MenuBarIcon.imageset/menubar.pdf \
   "$APP/Contents/Resources/MenuBarIcon.pdf"
mkdir -p "$APP/Contents/Resources/Python"
cp -R AlmRecorder/Resources/Python/. "$APP/Contents/Resources/Python/"
mkdir -p "$APP/Contents/Resources/Binaries" "$APP/Contents/Resources/Libraries" \
    "$APP/Contents/Resources/Models" "$APP/Contents/Resources/Licenses"
cp -R AlmRecorder/Resources/Binaries/. "$APP/Contents/Resources/Binaries/"
cp -R AlmRecorder/Resources/Libraries/. "$APP/Contents/Resources/Libraries/"
cp -R AlmRecorder/Resources/Models/. "$APP/Contents/Resources/Models/"
cp -R AlmRecorder/Resources/Licenses/. "$APP/Contents/Resources/Licenses/"
# Keep the development app self-contained too. In particular, Gemma audio consensus needs the
# exact llama-server and matching dylibs built from this checkout; falling through to a globally
# installed llama.cpp can silently change its multimodal request contract.

# Bundle the one dynamic framework the binary loads via @rpath (GRDB), and point an rpath at it.
mkdir -p "$APP/Contents/Frameworks"
cp -R .build/debug/GRDB.framework "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/AlmRecorder" 2>/dev/null || true

# Sign with a STABLE identity (Apple Development cert) so macOS TCC keeps its grants — most
# importantly Screen Recording / System Audio for ScreenCaptureKit — across rebuilds. Ad-hoc
# signing changes identity every build, which silently detaches those grants. Falls back to
# ad-hoc only if no stable identity exists.
IDENTITY=""
if [ "${ALMREC_ADHOC_SIGN:-0}" != "1" ]; then
  IDENTITY=$(security find-identity -v -p codesigning \
    | awk '/Apple Development|Developer ID/{gsub(/[()]/, "", $2); print $2; exit}')
fi
if [ -n "$IDENTITY" ]; then
  echo "✍️  Signing with valid stable identity: $IDENTITY"
  codesign --force --deep --sign "$IDENTITY" "$APP"
  if ! codesign --verify --deep "$APP" >/dev/null 2>&1; then
    echo "⚠️  The selected certificate is not trusted by macOS — falling back to ad-hoc signing"
    codesign --force --deep --sign - "$APP"
  fi
else
  echo "✍️  No stable identity found — signing ad-hoc (Screen Recording grant resets each build)"
  codesign --force --deep --sign - "$APP"
fi

echo "✅ Built $APP"
codesign -dvv "$APP" 2>&1 | grep -iE "Identifier|Authority|Signature|TeamIdentifier" | head
