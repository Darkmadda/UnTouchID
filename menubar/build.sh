#!/bin/bash
# Build TouchBridgeMenu.app directly with swiftc — no XcodeGen or Xcode project
# required. Produces menubar/build/TouchBridgeMenu.app, ad-hoc signed so it can
# run (and remember its TCC/Bluetooth grants across rebuilds).
#
#   bash menubar/build.sh          # build
#   bash menubar/build.sh --run    # build, then relaunch the app
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/TouchBridgeMenu"
BUILD_DIR="$SCRIPT_DIR/build"
APP="$BUILD_DIR/TouchBridgeMenu.app"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
BIN="$MACOS_DIR/TouchBridgeMenu"

ARCH="$(uname -m)"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
DEPLOY_TARGET="13.0"

echo "==> Building TouchBridgeMenu ($ARCH, macOS $DEPLOY_TARGET target)"

rm -rf "$APP"
mkdir -p "$MACOS_DIR"

# Compile every Swift source into a single executable. -parse-as-library is
# required so the @main App struct provides the entry point.
# shellcheck disable=SC2046
xcrun swiftc \
    -sdk "$SDK" \
    -target "$ARCH-apple-macos$DEPLOY_TARGET" \
    -parse-as-library \
    -O \
    -o "$BIN" \
    $(find "$SRC_DIR" -name '*.swift')

# Resolve the templated Info.plist into the bundle with concrete values.
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>TouchBridge</string>
    <key>CFBundleExecutable</key>
    <string>TouchBridgeMenu</string>
    <key>CFBundleIdentifier</key>
    <string>dev.touchbridge.menubar</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>TouchBridgeMenu</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>TouchBridge needs Bluetooth to communicate with your phone.</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS will run it and TCC grants stick to a stable identity.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || \
    codesign --force --sign - "$APP"

echo "==> Built $APP"

if [ "${1:-}" = "--run" ]; then
    echo "==> Relaunching"
    pkill -x TouchBridgeMenu 2>/dev/null || true
    sleep 0.3
    open "$APP"
fi
