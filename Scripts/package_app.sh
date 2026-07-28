#!/bin/bash

# Complete packaging script for AlmRecorder with llama.cpp and models
set -e

APP_NAME="AlmRecorder"
VERSION="1.0.0"
BUILD_DIR="./build"
DIST_DIR="./dist"
RESOURCES_DIR="$BUILD_DIR/$APP_NAME.app/Contents/Resources"
BUILD_CONFIGURATION="${ALMREC_BUILD_CONFIGURATION:-release}"

echo "📦 Packaging $APP_NAME v$VERSION..."

# Clean and create directories
rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$RESOURCES_DIR/Binaries"

# Step 1: Build the app
echo "🔨 Building Swift app..."
# Keep packaging itself from creating another memory spike on unified-memory Macs. Callers can
# override this, but two compiler jobs is a safe default for the 24 GB development machine.
if [ "${ALMREC_SKIP_SWIFT_BUILD:-0}" != "1" ]; then
    swift build -c "$BUILD_CONFIGURATION" --jobs "${ALMREC_BUILD_JOBS:-2}"
else
    echo "Using previously validated $BUILD_CONFIGURATION build to avoid a memory-heavy rebuild"
fi
cp -r ".build/$BUILD_CONFIGURATION/$APP_NAME" "$BUILD_DIR/"

# Step 2: Package llama.cpp tools (transcription + text) and their matching dylibs
echo "📦 Packaging llama.cpp tools..."
if [ ! -f "./AlmRecorder/Resources/Binaries/llama-mtmd-cli" ] || [ ! -f "./AlmRecorder/Resources/Binaries/llama-completion" ]; then
    echo "Building llama.cpp from source..."
    ./Scripts/package_llama.sh
fi
mkdir -p "$RESOURCES_DIR/Binaries" "$RESOURCES_DIR/Libraries" "$RESOURCES_DIR/Models"
# These resources must live directly below Contents/Resources because the production database and
# process runners resolve them through Bundle.main. SwiftPM's nested resource bundle is retained for
# Bundle.module consumers, but it is not a substitute for this production layout.
cp -R ./AlmRecorder/Resources/Binaries/. "$RESOURCES_DIR/Binaries/"
cp -R ./AlmRecorder/Resources/Libraries/. "$RESOURCES_DIR/Libraries/"
cp -R ./AlmRecorder/Resources/Models/. "$RESOURCES_DIR/Models/"
mkdir -p "$RESOURCES_DIR/Python"
cp -R ./AlmRecorder/Resources/Python/. "$RESOURCES_DIR/Python/"
mkdir -p "$RESOURCES_DIR/Licenses"
cp -R ./AlmRecorder/Resources/Licenses/. "$RESOURCES_DIR/Licenses/"
cp ./AlmRecorder/Resources/AppIcon.icns "$RESOURCES_DIR/AppIcon.icns"
cp ./AlmRecorder/Assets.xcassets/MenuBarIcon.imageset/menubar.pdf \
    "$RESOURCES_DIR/MenuBarIcon.pdf"

if [ -n "${ALMREC_UV_BINARY:-}" ] && [ -x "$ALMREC_UV_BINARY" ]; then
    cp -L "$ALMREC_UV_BINARY" "$RESOURCES_DIR/Binaries/uv"
elif [ -x /opt/homebrew/bin/uv ]; then
    cp -L /opt/homebrew/bin/uv "$RESOURCES_DIR/Binaries/uv"
elif [ -x /usr/local/bin/uv ]; then
    cp -L /usr/local/bin/uv "$RESOURCES_DIR/Binaries/uv"
else
    echo "Warning: uv not found; VibeVoice runtime installation will require Homebrew uv"
fi
if [ -f "$RESOURCES_DIR/Binaries/uv" ]; then
    UV_LICENSE_DIR="${ALMREC_UV_LICENSE_DIR:-}"
    if [ -z "$UV_LICENSE_DIR" ] && command -v brew >/dev/null 2>&1; then
        UV_LICENSE_DIR="$(brew --prefix uv 2>/dev/null || true)"
    fi
    if [ -n "$UV_LICENSE_DIR" ] \
        && [ -f "$UV_LICENSE_DIR/LICENSE-APACHE" ] \
        && [ -f "$UV_LICENSE_DIR/LICENSE-MIT" ]; then
        mkdir -p "$RESOURCES_DIR/Licenses/uv"
        cp "$UV_LICENSE_DIR/LICENSE-APACHE" "$RESOURCES_DIR/Licenses/uv/"
        cp "$UV_LICENSE_DIR/LICENSE-MIT" "$RESOURCES_DIR/Licenses/uv/"
    else
        echo "Warning: uv licenses not found; set ALMREC_UV_LICENSE_DIR for distribution"
    fi
fi

# Step 3: Create app bundle structure
echo "📁 Creating app bundle..."
mkdir -p "$BUILD_DIR/$APP_NAME.app/Contents/MacOS"
mkdir -p "$BUILD_DIR/$APP_NAME.app/Contents/Frameworks"

# Move executable
mv "$BUILD_DIR/$APP_NAME" "$BUILD_DIR/$APP_NAME.app/Contents/MacOS/"
cp ".build/$BUILD_CONFIGURATION/AlmRecorderMCPBridge" \
    "$BUILD_DIR/$APP_NAME.app/Contents/MacOS/AlmRecorderMCPBridge"
chmod +x "$BUILD_DIR/$APP_NAME.app/Contents/MacOS/AlmRecorderMCPBridge"

# SwiftPM leaves the binary GRDB dependency as a dynamic framework. Embed it in the standard app
# location and add that location to the executable's runtime search paths so the packaged app can
# launch independently of the build directory and Xcode toolchain.
GRDB_FRAMEWORK=".build/arm64-apple-macosx/$BUILD_CONFIGURATION/GRDB.framework"
if [ ! -d "$GRDB_FRAMEWORK" ]; then
    echo "Error: $BUILD_CONFIGURATION GRDB.framework was not produced by SwiftPM"
    exit 1
fi
cp -R "$GRDB_FRAMEWORK" "$BUILD_DIR/$APP_NAME.app/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$BUILD_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME"

# Copy the app's canonical Info.plist. The legacy distribution template used a placeholder bundle
# identifier, which creates a different macOS app identity and loses existing permissions/bookmarks.
cp ./AlmRecorder/Info.plist "$BUILD_DIR/$APP_NAME.app/Contents/Info.plist"

# Step 4: Sign the app
echo "✍️ Signing app..."
codesign --force --deep --sign - "$BUILD_DIR/$APP_NAME.app"

# Step 5: Create DMG installer
echo "💿 Creating DMG..."
if command -v create-dmg >/dev/null 2>&1; then
    create-dmg \
        --volname "$APP_NAME" \
        --volicon "./AlmRecorder/Resources/AppIcon.icns" \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "$APP_NAME.app" 175 120 \
        --hide-extension "$APP_NAME.app" \
        --app-drop-link 425 120 \
        "$DIST_DIR/$APP_NAME-$VERSION.dmg" \
        "$BUILD_DIR/"
else
    echo "Warning: create-dmg not found; signed app bundle is ready in $BUILD_DIR"
fi

echo "✅ Packaging complete!"
if [ -f "$DIST_DIR/$APP_NAME-$VERSION.dmg" ]; then
    echo "📦 DMG: $DIST_DIR/$APP_NAME-$VERSION.dmg"
else
    echo "📦 App: $BUILD_DIR/$APP_NAME.app"
fi

# Step 6: Generate download script for models
cat > "$DIST_DIR/download_models.sh" << 'EOF'
#!/bin/bash
# Script to download Voxtral models after installation

echo "🤖 AlmRecorder Model Downloader"
echo "================================"
echo ""
echo "This script will download the AI models needed for transcription."
echo "Models will be stored in: ~/Library/Application Support/AlmRecorder/VoxtralModels"
echo ""

MODELS_DIR="$HOME/Library/Application Support/AlmRecorder/VoxtralModels"
mkdir -p "$MODELS_DIR"

# Function to download with progress
download_model() {
    local name=$1
    local url=$2
    local file=$3
    
    echo "📥 Downloading $name..."
    curl -L --progress-bar -o "$MODELS_DIR/$file" "$url"
}

echo "Available models:"
echo "1. Q4_K_M (2.47 GB) - Fastest, good quality"
echo "2. Q5_K_M (2.87 GB) - Balanced (recommended)"
echo "3. Q8_0 (4.27 GB) - High quality, 8-bit"
echo "4. BF16 (8.04 GB) - Highest quality"
echo ""
read -p "Which model would you like to download? (1-4): " choice

case $choice in
    1)
        download_model "Q4_K_M model" \
            "https://huggingface.co/bartowski/mistralai_Voxtral-Mini-3B-2507-GGUF/resolve/main/mistralai_Voxtral-Mini-3B-2507-Q4_K_M.gguf" \
            "mistralai_Voxtral-Mini-3B-2507-Q4_K_M.gguf"
        download_model "Q4_K_M projector" \
            "https://huggingface.co/bartowski/mistralai_Voxtral-Mini-3B-2507-GGUF/resolve/main/mmproj-mistralai_Voxtral-Mini-3B-2507-f16.gguf" \
            "mmproj-mistralai_Voxtral-Mini-3B-2507-f16.gguf"
        ;;
    2)
        download_model "Q5_K_M model" \
            "https://huggingface.co/bartowski/mistralai_Voxtral-Mini-3B-2507-GGUF/resolve/main/mistralai_Voxtral-Mini-3B-2507-Q5_K_M.gguf" \
            "mistralai_Voxtral-Mini-3B-2507-Q5_K_M.gguf"
        download_model "Q5_K_M projector" \
            "https://huggingface.co/bartowski/mistralai_Voxtral-Mini-3B-2507-GGUF/resolve/main/mmproj-mistralai_Voxtral-Mini-3B-2507-f16.gguf" \
            "mmproj-mistralai_Voxtral-Mini-3B-2507-f16.gguf"
        ;;
    3)
        download_model "Q8_0 model" \
            "https://huggingface.co/bartowski/mistralai_Voxtral-Mini-3B-2507-GGUF/resolve/main/mistralai_Voxtral-Mini-3B-2507-Q8_0.gguf" \
            "mistralai_Voxtral-Mini-3B-2507-Q8_0.gguf"
        download_model "Q8_0 projector" \
            "https://huggingface.co/bartowski/mistralai_Voxtral-Mini-3B-2507-GGUF/resolve/main/mmproj-mistralai_Voxtral-Mini-3B-2507-f16.gguf" \
            "mmproj-mistralai_Voxtral-Mini-3B-2507-f16.gguf"
        ;;
    4)
        download_model "BF16 model" \
            "https://huggingface.co/bartowski/mistralai_Voxtral-Mini-3B-2507-GGUF/resolve/main/mistralai_Voxtral-Mini-3B-2507-BF16.gguf" \
            "mistralai_Voxtral-Mini-3B-2507-BF16.gguf"
        download_model "BF16 projector" \
            "https://huggingface.co/bartowski/mistralai_Voxtral-Mini-3B-2507-GGUF/resolve/main/mmproj-mistralai_Voxtral-Mini-3B-2507-bf16.gguf" \
            "mmproj-mistralai_Voxtral-Mini-3B-2507-bf16.gguf"
        ;;
    *)
        echo "Invalid choice"
        exit 1
        ;;
esac

echo ""
echo "✅ Model downloaded successfully!"
echo "You can now use AlmRecorder with AI transcription."
EOF

chmod +x "$DIST_DIR/download_models.sh"

echo ""
echo "📝 Distribution files created:"
if [ -f "$DIST_DIR/$APP_NAME-$VERSION.dmg" ]; then
    echo "  - $DIST_DIR/$APP_NAME-$VERSION.dmg (Main installer)"
else
    echo "  - $BUILD_DIR/$APP_NAME.app (Signed application)"
fi
echo "  - $DIST_DIR/download_models.sh (Model downloader script)"
