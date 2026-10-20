#!/bin/bash
# Shared helpers for EquAudio's scripts. Source it; do not execute it.

# Repository root (directory containing Package.swift).
EQ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Build directory (SwiftPM scratch path + assembled app bundle). Inside iCloud Drive or another
# File Provider folder, macOS keeps re-adding com.apple.FinderInfo to bundle folders, which
# invalidates code signatures ("resource fork, Finder information, or similar detritus not
# allowed"). In that case build outside the synced folder.
if [[ -z "${EQ_BUILD_DIR:-}" ]]; then
    case "$EQ_ROOT" in
        */Library/Mobile\ Documents/*|*/Library/CloudStorage/*) EQ_BUILD_DIR="$HOME/Library/Caches/EquAudio/build" ;;
        *) EQ_BUILD_DIR="$EQ_ROOT/.build" ;;
    esac
fi
EQ_APP_NAME="EquAudio"
EQ_BUNDLE_ID="com.equaudio.EquAudio"
EQ_MIN_MACOS="14.2"
# Assembled, signed application bundle produced by build.sh.
EQ_APP_BUNDLE="$EQ_BUILD_DIR/app/$EQ_APP_NAME.app"

eq_info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
eq_warn()  { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
eq_error() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; }
eq_die()   { eq_error "$*"; exit 1; }

# Extra `swift test` arguments needed when only the Command Line Tools are installed: the CLT ship
# Swift Testing but SwiftPM does not add its framework/plugin search paths automatically.
eq_swift_test_flags() {
    local dev
    dev="$(xcode-select -p 2>/dev/null)" || return 0
    local fw="$dev/Library/Developer/Frameworks"
    local lib="$dev/Library/Developer/usr/lib"
    local plugins="$dev/usr/lib/swift/host/plugins/testing"
    if [[ "$dev" == *CommandLineTools* && -d "$fw/Testing.framework" ]]; then
        printf '%s\n' -Xswiftc -F -Xswiftc "$fw" -Xlinker -F -Xlinker "$fw" \
            -Xlinker -rpath -Xlinker "$fw" -Xlinker -rpath -Xlinker "$lib" \
            -Xswiftc -plugin-path -Xswiftc "$plugins"
    fi
}
