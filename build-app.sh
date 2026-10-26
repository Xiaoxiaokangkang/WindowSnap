#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
APP_NAME="WindowSnap"
APP_VERSION="$(plutil -extract CFBundleShortVersionString raw "$ROOT_DIR/Resources/Info.plist")"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
ZIP_PATH="$ROOT_DIR/dist/$APP_NAME-$APP_VERSION.zip"

cd "$ROOT_DIR"
if [[ -z "${SDKROOT:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.build/swift-cache"
swift package --disable-sandbox clean
swift build -c release --disable-sandbox -debug-info-format none --product "$APP_NAME"
BUILD_DIR="$(swift build -c release --disable-sandbox --show-bin-path)"
[[ -x "$BUILD_DIR/$APP_NAME" ]]

rm -rf "$APP_DIR"
rm -f "$ZIP_PATH"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
SIGNING_IDENTITY="${WINDOWSNAP_SIGNING_IDENTITY:--}"
codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_DIR"
echo "$APP_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
