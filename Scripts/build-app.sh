#!/bin/bash
# Builds "K24 Zipper.app" into ./dist (universal arm64 + x86_64 release build, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/K24 Zipper.app"
VERSION="1.0.0"

# Build each architecture in its own scratch folder, then merge into one universal binary.
BINS=()
for ARCH in arm64 x86_64; do
  SCRATCH=".build/$ARCH"
  swift build -c release --triple "$ARCH-apple-macosx14.0" --scratch-path "$SCRATCH"
  BINS+=("$(swift build -c release --triple "$ARCH-apple-macosx14.0" --scratch-path "$SCRATCH" --show-bin-path)/K24Zipper")
done
mkdir -p dist
BIN="dist/K24Zipper-universal"
lipo -create "${BINS[@]}" -output "$BIN"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/K24Zipper"

# App icon rendered from the SwiftUI icon view.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
"$BIN" --export-icon "$WORK/icon.png"
ICONSET="$WORK/AppIcon.iconset"
mkdir "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>K24 Zipper</string>
  <key>CFBundleDisplayName</key><string>K24 Zipper</string>
  <key>CFBundleIdentifier</key><string>com.k24.zipper</string>
  <key>CFBundleExecutable</key><string>K24Zipper</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP"
echo "Built $APP"
