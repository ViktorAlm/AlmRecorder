#!/bin/bash
# Build AlmRecorder and wrap it in a signed, NON-sandboxed .app bundle so macOS TCC will
# actually prompt for Calendar / Microphone / Voice Memos access (a bare SPM binary has no
# Info.plist, so no prompt can appear). Non-sandboxed = uses the real ~/Library/Application
# Support and the absolute dev paths the code already resolves for vectorlite/whisper/llama.
set -e
cd "$(dirname "$0")/.."   # project root
APP="build/AlmRecorder.app"

echo "🔨 swift build (debug)..."
swift build

echo "📁 Assembling $APP ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/debug/AlmRecorder "$APP/Contents/MacOS/AlmRecorder"
cp .build/debug/AlmRecorderMCPBridge "$APP/Contents/MacOS/AlmRecorderMCPBridge"
chmod +x "$APP/Contents/MacOS/AlmRecorderMCPBridge"
cp AlmRecorder/Info.plist "$APP/Contents/Info.plist"
cp AlmRecorder/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # Dock/Finder icon (CFBundleIconFile)
# Note: the app uses SF Symbols / system colors (no Bundle.module), and resolves
# vectorlite/whisper/llama via absolute dev paths, so no resource bundle is needed here.

# Bundle the one dynamic framework the binary loads via @rpath (GRDB), and point an rpath at it.
mkdir -p "$APP/Contents/Frameworks"
cp -R .build/debug/GRDB.framework "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/AlmRecorder" 2>/dev/null || true

# Sign with a STABLE identity (Apple Development cert) so macOS TCC keeps its grants — most
# importantly Screen Recording / System Audio for ScreenCaptureKit — across rebuilds. Ad-hoc
# signing changes identity every build, which silently detaches those grants. Falls back to
# ad-hoc only if no stable identity exists.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID/{print $2; exit}')
if [ -n "$IDENTITY" ]; then
  echo "✍️  Signing with stable identity: $IDENTITY"
  codesign --force --deep --sign "$IDENTITY" "$APP"
else
  echo "✍️  No stable identity found — signing ad-hoc (Screen Recording grant resets each build)"
  codesign --force --deep --sign - "$APP"
fi

echo "✅ Built $APP"
codesign -dvv "$APP" 2>&1 | grep -iE "Identifier|Authority|Signature|TeamIdentifier" | head
