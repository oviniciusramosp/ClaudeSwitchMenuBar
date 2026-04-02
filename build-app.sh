#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRODUCT_NAME="Claude Switch"
EXECUTABLE_NAME="ClaudeSwitchMenuBar"
APP_DIR="$ROOT_DIR/dist/$PRODUCT_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"

cd "$ROOT_DIR"
swift build -c release

mkdir -p "$MACOS_DIR"
cp "$ROOT_DIR/.build/release/$EXECUTABLE_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
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
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"
echo "Built app at: $APP_DIR"
