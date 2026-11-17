#!/bin/zsh
# Builds a universal (Apple Silicon + Intel) MacMonitor.app next to this script.
# Usage: ./build.sh            build the app
#        ./build.sh --zip      also create dist/MacMonitor.zip for a release
set -euo pipefail
cd "$(dirname "$0")"

APP=MacMonitor.app
BUILD=.build
VERSION=${VERSION:-1.0.0}
MIN_MACOS=13.0

rm -rf "$APP" "$BUILD" && mkdir -p "$BUILD" "$APP/Contents/MacOS"

for ARCH in arm64 x86_64; do
  clang -O2 -arch $ARCH -mmacosx-version-min=$MIN_MACOS -c Sources/sensors.c -o "$BUILD/sensors-$ARCH.o"
  swiftc -O -parse-as-library -import-objc-header Sources/sensors.h \
    Sources/App.swift Sources/Stats.swift "$BUILD/sensors-$ARCH.o" \
    -framework IOKit -framework CoreFoundation \
    -target $ARCH-apple-macos$MIN_MACOS -o "$BUILD/MacMonitor-$ARCH"
done
lipo -create "$BUILD"/MacMonitor-arm64 "$BUILD"/MacMonitor-x86_64 -output "$APP/Contents/MacOS/MacMonitor"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>MacMonitor</string>
  <key>CFBundleDisplayName</key><string>MacMonitor</string>
  <key>CFBundleIdentifier</key><string>local.macmonitor</string>
  <key>CFBundleExecutable</key><string>MacMonitor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

codesign --force --sign - "$APP"   # ad-hoc signature (no Apple Developer ID)
echo "Built $PWD/$APP"

if [[ "${1:-}" == "--zip" ]]; then
  mkdir -p dist
  rm -f dist/MacMonitor.zip
  ditto -c -k --keepParent "$APP" dist/MacMonitor.zip
  echo "Packaged $PWD/dist/MacMonitor.zip"
fi
