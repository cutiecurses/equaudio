#!/bin/bash
# Checks that this Mac can build and run EquAudio. Installs nothing.
set -euo pipefail
source "$(dirname "$0")/scripts/common.sh"
ok=1
ver="$(sw_vers -productVersion)"
if [[ "$(printf '%s\n' "$EQ_MIN_MACOS" "$ver" | sort -V | head -1)" != "$EQ_MIN_MACOS" ]]; then eq_error "macOS $ver is too old (need $EQ_MIN_MACOS+ for process taps)"; ok=0; else eq_info "macOS $ver"; fi
[[ "$(uname -m)" == arm64 ]] || eq_warn "Not Apple Silicon ($(uname -m)); builds target arm64"
if ! xcode-select -p >/dev/null 2>&1; then eq_error "Command Line Tools missing. Run: xcode-select --install"; exit 1; fi
command -v swift >/dev/null || { eq_error "swift not found. Run: xcode-select --install"; exit 1; }
eq_info "$(swift --version 2>&1 | head -1)"
SDK="$(xcrun --show-sdk-path)"
[[ -f "$SDK/System/Library/Frameworks/CoreAudio.framework/Headers/CATapDescription.h" ]] || { eq_error "SDK lacks CATapDescription.h (update Command Line Tools)"; ok=0; }
for t in codesign ditto plutil iconutil; do command -v $t >/dev/null || { eq_error "missing tool: $t"; ok=0; }; done
eq_info "Build directory: $EQ_BUILD_DIR"
pgrep -fl "Boom 2|Boom 3D|eqMac|SoundSource" >/dev/null 2>&1 && eq_warn "Another audio enhancer is running (Boom/eqMac/SoundSource). Quit it, or audio is processed twice."
[[ $ok == 1 ]] && eq_info "Ready. Next: ./build.sh && ./run.sh   (or ./install.sh)" || exit 1
