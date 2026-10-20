#!/bin/bash
# Builds and runs the Phase-1 tap playthrough proof of concept.
#
#   Prototype/run_poc.sh [--seconds N] [--silent] [--output-uid UID]
#       Runs the PoC directly from the terminal. macOS attributes the System Audio Recording
#       permission to the terminal app that launched it.
#   Prototype/run_poc.sh --app [--seconds N] [--silent]
#       Wraps the PoC in "EquAudio PoC.app" and launches it through LaunchServices, so the
#       permission prompt is for the PoC app itself. It waits up to 15 minutes for approval and
#       writes its report to <build dir>/poc/output/poc.log.
set -euo pipefail
source "$(dirname "$0")/../scripts/common.sh"
BUILD="$EQ_BUILD_DIR/poc"
OUT="$BUILD/output"
mkdir -p "$BUILD" "$OUT"
swiftc -O -target arm64-apple-macos14.2 -o "$BUILD/tap-poc" "$EQ_ROOT/Prototype/TapPoC/main.swift"

if [[ "${1:-}" != "--app" ]]; then
    exec "$BUILD/tap-poc" --out "$OUT" "$@"
fi
shift

APP="$BUILD/EquAudio PoC.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BUILD/tap-poc" "$APP/Contents/MacOS/EquAudioPoC"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.equaudio.EquAudio.poc</string>
    <key>CFBundleName</key><string>EquAudio PoC</string>
    <key>CFBundleExecutable</key><string>EquAudioPoC</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.2</string>
    <key>LSUIElement</key><true/>
    <key>NSAudioCaptureUsageDescription</key>
    <string>EquAudio PoC captures audio played by other apps to verify that it can be processed and played back.</string>
</dict>
</plist>
PLIST
xattr -cr "$APP"
codesign --force --sign - "$APP"
rm -f "$OUT/poc.log"
open -n "$APP" --args --out "$OUT" --wait-permission 900 "$@"
echo "Launched $APP; report: $OUT/poc.log"
