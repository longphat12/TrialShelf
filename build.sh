#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
DIST_DIR="$ROOT/dist"
APP="$BUILD_DIR/TrialShelf.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DIST_DIR"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

swiftc \
  -parse-as-library \
  -swift-version 5 \
  -O \
  -target arm64-apple-macosx13.0 \
  -framework AppKit \
  -framework SwiftUI \
  "$ROOT/Sources/TrialShelfApp.swift" \
  -o "$APP/Contents/MacOS/TrialShelf"

codesign --force --deep --sign - "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST_DIR/TrialShelf-arm64.zip"

printf 'Built %s\n' "$APP"
printf 'Packaged %s\n' "$DIST_DIR/TrialShelf-arm64.zip"
