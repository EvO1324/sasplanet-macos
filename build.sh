#!/bin/bash
# Builds SASPlanet.app (release) next to this script.
set -e
cd "$(dirname "$0")"
# Universal binary: Apple Silicon + Intel
swift build -c release --triple arm64-apple-macosx12.0 --scratch-path .build/arm64
swift build -c release --triple x86_64-apple-macosx12.0 --scratch-path .build/x86_64
APP="SASPlanet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create .build/arm64/arm64-apple-macosx/release/SASPlanet .build/x86_64/x86_64-apple-macosx/release/SASPlanet \
  -output "$APP/Contents/MacOS/SASPlanet"
cp Resources/*.png "$APP/Contents/Resources/"
# App icon from SAS.Planet's original icon
if [ ! -f Resources/AppIcon.icns ]; then
  T=$(mktemp -d)
  cp Resources/AppIcon.png "$T/icon128.png"
  mkdir "$T/AppIcon.iconset"
  for s in 16 32 64 128 256 512; do
    sips -z $s $s "$T/icon128.png" --out "$T/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  done
  for s in 16 32 128 256; do
    d=$((s*2)); cp "$T/AppIcon.iconset/icon_${d}x${d}.png" "$T/AppIcon.iconset/icon_${s}x${s}@2x.png" 2>/dev/null || true
  done
  iconutil -c icns "$T/AppIcon.iconset" -o Resources/AppIcon.icns
  rm -rf "$T"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SAS.Planet</string>
  <key>CFBundleDisplayName</key><string>SAS.Planet</string>
  <key>CFBundleIdentifier</key><string>org.sasgis.sasplanet.macos</string>
  <key>CFBundleExecutable</key><string>SASPlanet</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
echo "Built $(pwd)/$APP"
if [ "$1" = "--zip" ]; then
  mkdir -p dist
  rm -f dist/SASPlanet-macOS.zip
  ditto -c -k --keepParent "$APP" dist/SASPlanet-macOS.zip
  echo "Packaged $(pwd)/dist/SASPlanet-macOS.zip"
fi
