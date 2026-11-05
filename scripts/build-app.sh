#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIGURATION="${1:-release}"
swift build -c "$CONFIGURATION"
APP="$ROOT/build/Companion.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/build/Companion.iconset"
cp ".build/$CONFIGURATION/Companion" "$APP/Contents/MacOS/Companion"

swift scripts/generate-icon.swift "$ROOT/build/Companion-icon.png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ROOT/build/Companion-icon.png" --out "$ROOT/build/Companion.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$ROOT/build/Companion-icon.png" --out "$ROOT/build/Companion.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ROOT/build/Companion.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Companion</string>
<key>CFBundleIdentifier</key><string>com.m-robot404.Companion</string>
<key>CFBundleName</key><string>Companion</string>
<key>CFBundleShortVersionString</key><string>0.2</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleGetInfoString</key><string>Companion 0.2 Beta</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
echo "Built: $APP"
