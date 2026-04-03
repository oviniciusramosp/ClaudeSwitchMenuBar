#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRODUCT_NAME="Claude Switch"
EXECUTABLE_NAME="ClaudeSwitchMenuBar"
APP_DIR="$ROOT_DIR/dist/$PRODUCT_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
ZIP_PATH="$ROOT_DIR/dist/$PRODUCT_NAME.zip"
APP_VERSION="${APP_VERSION:-1.0.0}"
BUILD_VERSION="${BUILD_VERSION:-1}"

cd "$ROOT_DIR"
swift build -c release

mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"
cp "$ROOT_DIR/.build/release/$EXECUTABLE_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"
cp "$ROOT_DIR/ThirdParty/cc-account-switcher/ccswitch.sh" "$RESOURCES_DIR/ccswitch.sh"
cp "$ROOT_DIR/ThirdParty/cc-account-switcher/LICENSE" "$RESOURCES_DIR/cc-account-switcher-LICENSE"
chmod +x "$RESOURCES_DIR/ccswitch.sh"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>ClaudeSwitchMenuBar</string>
    <key>CFBundleIdentifier</key>
    <string>com.viniciusramos.claudeswitch</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Claude Switch</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"
echo "Built app at: $APP_DIR"
rm -f "$ZIP_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
echo "Built zip at: $ZIP_PATH"
