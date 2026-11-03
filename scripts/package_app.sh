#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
BUILD_DIR="$ROOT_DIR/.build"
APP_DIR="$ROOT_DIR/dist/GamePulse.app"
COMPATIBLE_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"

cd "$ROOT_DIR"

if [[ -n "${GAMEPULSE_SDK:-}" ]]; then
    SDK_PATH="$GAMEPULSE_SDK"
elif [[ -d "$COMPATIBLE_SDK" ]]; then
    SDK_PATH="$COMPATIBLE_SDK"
else
    SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
fi

mkdir -p "$BUILD_DIR/direct" "$BUILD_DIR/clang-cache-arm64" "$BUILD_DIR/clang-cache-x86_64"

build_arch() {
    local arch="$1"
    CLANG_MODULE_CACHE_PATH="$BUILD_DIR/clang-cache-$arch" xcrun swiftc \
        -sdk "$SDK_PATH" \
        -target "$arch-apple-macosx14.0" \
        -parse-as-library \
        -O \
        "$ROOT_DIR"/Sources/GamePulse/*.swift \
        -o "$BUILD_DIR/direct/GamePulse-$arch" \
        -framework SwiftUI \
        -framework AppKit \
        -framework Security \
        -framework LocalAuthentication \
        -framework CoreImage \
        -framework CryptoKit \
        -framework WebKit
}

build_arch arm64
build_arch x86_64
xcrun lipo -create \
    "$BUILD_DIR/direct/GamePulse-arm64" \
    "$BUILD_DIR/direct/GamePulse-x86_64" \
    -output "$BUILD_DIR/direct/GamePulse"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/direct/GamePulse" "$APP_DIR/Contents/MacOS/GamePulse"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
