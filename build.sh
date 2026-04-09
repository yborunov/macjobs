#!/usr/bin/env bash
set -euo pipefail

APP_NAME="MacJobs"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$ROOT_DIR/dist"
APP_DIR="$OUT_DIR/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cat > "$APP_DIR/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>MacJobs</string>
  <key>CFBundleIdentifier</key>
  <string>com.wannabe.macjobs</string>
  <key>CFBundleIconFile</key>
  <string>MacJobs</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>MacJobs</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
EOF

swift "$ROOT_DIR/generate_icon.swift"

mkdir -p "$ROOT_DIR/icon.iconset"
sips -z 16 16 "$ROOT_DIR/icon_1024.png" --out "$ROOT_DIR/icon.iconset/icon_16x16.png" >/dev/null
sips -z 32 32 "$ROOT_DIR/icon_1024.png" --out "$ROOT_DIR/icon.iconset/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ROOT_DIR/icon_1024.png" --out "$ROOT_DIR/icon.iconset/icon_32x32.png" >/dev/null
sips -z 64 64 "$ROOT_DIR/icon_1024.png" --out "$ROOT_DIR/icon.iconset/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ROOT_DIR/icon_1024.png" --out "$ROOT_DIR/icon.iconset/icon_128x128.png" >/dev/null
sips -z 256 256 "$ROOT_DIR/icon_1024.png" --out "$ROOT_DIR/icon.iconset/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ROOT_DIR/icon_1024.png" --out "$ROOT_DIR/icon.iconset/icon_256x256.png" >/dev/null
sips -z 512 512 "$ROOT_DIR/icon_1024.png" --out "$ROOT_DIR/icon.iconset/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ROOT_DIR/icon_1024.png" --out "$ROOT_DIR/icon.iconset/icon_512x512.png" >/dev/null
cp "$ROOT_DIR/icon_1024.png" "$ROOT_DIR/icon.iconset/icon_512x512@2x.png"
iconutil -c icns "$ROOT_DIR/icon.iconset" -o "$RESOURCES_DIR/MacJobs.icns"

xcrun swiftc \
  -parse-as-library \
  -O \
  -target arm64-apple-macos13.0 \
  -framework SwiftUI \
  -framework AppKit \
  "$ROOT_DIR/MacJobs.swift" \
  -o "$MACOS_DIR/$APP_NAME"

codesign --force --deep --sign - "$APP_DIR"

echo "Built: $APP_DIR"
