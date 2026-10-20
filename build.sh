#!/bin/bash
# Builds EquAudio and assembles the signed application bundle <build dir>/app/EquAudio.app.
#
#   ./build.sh               release build for Apple Silicon (arm64)
#   ./build.sh --debug       debug configuration (assertions on, faster to compile, slower DSP)
#   ./build.sh --clean       delete the build directory first (full rebuild, icon re-rendered)
#   ./build.sh --skip-icon   do not render the icon; reuse the last rendered one if there is one
#
# Signing is ad-hoc unless EQ_SIGN_IDENTITY names a code-signing certificate, e.g.
#   EQ_SIGN_IDENTITY="Apple Development: Jane Doe (AB12CD34EF)" ./build.sh
# (list yours with: security find-identity -v -p codesigning). macOS ties the System Audio
# Recording approval to the signature: ad-hoc builds need a new approval whenever the app changes,
# certificate-signed builds keep it. A rebuild that changes nothing keeps the existing bundle and
# signature untouched. EQ_BUILD_DIR=/absolute/path overrides the build directory.
set -euo pipefail
source "$(dirname "$0")/scripts/common.sh"

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }

config=release
clean=0
skip_icon=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug) config=debug ;;
        --clean) clean=1 ;;
        --skip-icon) skip_icon=1 ;;
        -h|--help) usage; exit 0 ;;
        *) eq_die "unknown option '$1' (see ./build.sh --help)" ;;
    esac
    shift
done

[[ "$EQ_BUILD_DIR" == /* ]] || eq_die "EQ_BUILD_DIR must be an absolute path, e.g. EQ_BUILD_DIR=\"$PWD/$EQ_BUILD_DIR\""
case "$EQ_BUILD_DIR" in
    */Library/Mobile\ Documents/*|*/Library/CloudStorage/*)
        eq_warn "EQ_BUILD_DIR is inside a synced folder ($EQ_BUILD_DIR): macOS adds Finder metadata to bundles there and code signing may fail." ;;
esac

# Fails early with the exact fix when a required tool is missing (./setup.sh checks everything).
xcode-select -p >/dev/null 2>&1 || eq_die "the Xcode Command Line Tools are not installed. Install them with: xcode-select --install"
for tool in swift codesign plutil lipo iconutil ditto xattr shasum; do
    command -v "$tool" >/dev/null 2>&1 || eq_die "'$tool' was not found. Run ./setup.sh to check the toolchain."
done

# SHA-256 (hex) of stdin.
sha256() { shasum -a 256 | cut -d ' ' -f 1; }

# Indents command output under the step that produced it.
indent() { sed 's/^/    /'; }

# --clean: deletes the build directory, but only if it really is one.
if [[ $clean == 1 && -e "$EQ_BUILD_DIR" ]]; then
    case "${EQ_BUILD_DIR%/}" in
        ""|/|"${HOME%/}"|"${EQ_ROOT%/}") eq_die "refusing to delete EQ_BUILD_DIR='$EQ_BUILD_DIR'" ;;
    esac
    if [[ -n "$(ls -A "$EQ_BUILD_DIR")" && ! -e "$EQ_BUILD_DIR/workspace-state.json" && ! -e "$EQ_BUILD_DIR/build.db" && ! -d "$EQ_BUILD_DIR/app" ]]; then
        eq_die "refusing to delete '$EQ_BUILD_DIR': it does not look like a SwiftPM build directory"
    fi
    eq_info "Cleaning $EQ_BUILD_DIR"
    rm -rf -- "$EQ_BUILD_DIR"
fi

version="$(tr -d '[:space:]' < "$EQ_ROOT/VERSION")"
version_re='^[0-9]+\.[0-9]+(\.[0-9]+)?$'
[[ "$version" =~ $version_re ]] || eq_die "VERSION must contain a version like 1.2.3 (found '$version')"

# 1. Compile.
swift_args=(-c "$config" --arch arm64 --product "$EQ_APP_NAME" --package-path "$EQ_ROOT" --scratch-path "$EQ_BUILD_DIR")
eq_info "Building $EQ_APP_NAME $version ($config, arm64)"
swift build "${swift_args[@]}"
bin_dir="$(swift build "${swift_args[@]}" --show-bin-path)"
executable="$bin_dir/$EQ_APP_NAME"
[[ -x "$executable" ]] || eq_die "the build did not produce $executable"

# 2. Icon: rendered once per revision of scripts/make-icon.swift and cached in the build directory.
icon=""
icon_cache="$EQ_BUILD_DIR/icon"
icon_key="$(sha256 < "$EQ_ROOT/scripts/make-icon.swift" | cut -c 1-16)"
if [[ -s "$icon_cache/AppIcon-$icon_key.icns" ]]; then
    icon="$icon_cache/AppIcon-$icon_key.icns"
elif [[ $skip_icon == 1 ]]; then
    icon="$(ls -t "$icon_cache"/AppIcon-*.icns 2>/dev/null | head -n 1 || true)"
    if [[ -n "$icon" ]]; then
        eq_info "Skipping icon rendering; reusing $icon"
    else
        eq_warn "--skip-icon: no rendered icon cached yet, the app will show the generic icon"
    fi
else
    eq_info "Rendering the app icon (scripts/make-icon.swift)"
    mkdir -p "$icon_cache"
    rendering="$icon_cache/.AppIcon-$icon_key.$$.icns"
    if ! swift "$EQ_ROOT/scripts/make-icon.swift" "$rendering" --png "$icon_cache/AppIcon-$icon_key.png" >/dev/null; then
        rm -f -- "$rendering"
        eq_die "icon rendering failed (see above). To build without an icon: ./build.sh --skip-icon"
    fi
    mv -f -- "$rendering" "$icon_cache/AppIcon-$icon_key.icns"
    icon="$icon_cache/AppIcon-$icon_key.icns"
    printf '    %s (preview: AppIcon-%s.png)\n' "$icon" "$icon_key"
    # Keep only the current revision (icns + its preview png).
    find "$icon_cache" -maxdepth 1 -type f -name 'AppIcon-*' ! -name "AppIcon-$icon_key.*" -delete
fi

# 3. Assemble and sign, unless nothing that goes into the bundle changed since the last build.
# Re-signing an unchanged app would still produce a new signature (a new build number is part of
# it), which costs ad-hoc users another System Audio Recording approval for nothing.
identity="${EQ_SIGN_IDENTITY:--}"
fingerprint="$(
    {
        sha256 < "$executable"
        sha256 < "$EQ_ROOT/Resources/Info.plist"
        sha256 < "$EQ_ROOT/build.sh"
        if [[ -n "$icon" ]]; then sha256 < "$icon"; fi
        printf '%s\n' "$version" "$config" "$identity"
    } | sha256
)"
stamp="$EQ_BUILD_DIR/app/.$EQ_APP_NAME.app.fingerprint"
signed_now=0
if [[ -d "$EQ_APP_BUNDLE" && -f "$stamp" && "$(cat "$stamp")" == "$fingerprint" ]] &&
    codesign --verify --strict "$EQ_APP_BUNDLE" >/dev/null 2>&1; then
    eq_info "App bundle is up to date; keeping its signature"
else
    staging_root="$EQ_BUILD_DIR/app/.staging.$$"
    trap 'rm -rf -- "$staging_root"' EXIT
    staging="$staging_root/$EQ_APP_NAME.app"
    contents="$staging/Contents"
    eq_info "Assembling $EQ_APP_NAME.app"
    mkdir -p "$contents/MacOS" "$contents/Resources"
    cp -- "$executable" "$contents/MacOS/$EQ_APP_NAME"

    # Info.plist: fill in the placeholders, normalise through plutil (validates, drops comments).
    build_number="$(date '+%Y%m%d%H%M')"
    sed -e "s/__VERSION__/$version/g" -e "s/__BUILD__/$build_number/g" "$EQ_ROOT/Resources/Info.plist" |
        plutil -convert xml1 -o "$contents/Info.plist" - ||
        eq_die "Resources/Info.plist is not a valid property list (check it with: plutil -lint Resources/Info.plist)"
    if grep -q '__[A-Z][A-Z_]*__' "$contents/Info.plist"; then
        eq_die "Resources/Info.plist has unknown placeholders: $(grep -o '__[A-Z][A-Z_]*__' "$contents/Info.plist" | sort -u | tr '\n' ' ')"
    fi
    plist_value() { plutil -extract "$1" raw -o - "$contents/Info.plist" 2>/dev/null || true; }
    [[ "$(plist_value CFBundleIdentifier)" == "$EQ_BUNDLE_ID" ]] || eq_die "Resources/Info.plist: CFBundleIdentifier must be $EQ_BUNDLE_ID"
    [[ "$(plist_value CFBundleExecutable)" == "$EQ_APP_NAME" ]] || eq_die "Resources/Info.plist: CFBundleExecutable must be $EQ_APP_NAME"

    printf 'APPL????' > "$contents/PkgInfo"
    if [[ -n "$icon" ]]; then cp -- "$icon" "$contents/Resources/AppIcon.icns"; fi
    # Now-playing helper: loaded by /usr/bin/perl so MediaRemote answers (see Sources/EquAudio/NowPlaying.swift).
    clang -dynamiclib -fobjc-arc -framework Foundation -arch arm64 -mmacosx-version-min="$EQ_MIN_MACOS" \
        -o "$contents/Resources/libequnp.dylib" "$EQ_ROOT/Resources/NowPlayingAdapter.m" ||
        eq_die "Could not compile Resources/NowPlayingAdapter.m (needs the Command Line Tools: xcode-select --install)"

    # Extended attributes (Finder info, quarantine) are not allowed in a signed bundle.
    xattr -cr "$staging"
    if [[ "$identity" == "-" ]]; then eq_info "Signing (ad-hoc)"; else eq_info "Signing with '$identity'"; fi
    # (The linker's ad-hoc signature of the bare executable is replaced; that notice is noise.)
    # Ad-hoc signatures are normally identified by the binary's hash, so macOS forgets the System Audio Recording
    # approval after every rebuild. Pinning the designated requirement to the bundle identifier keeps the approval
    # across rebuilds (trade-off: any ad-hoc build with this identifier satisfies it; fine for a local tool).
    req=()
    if [[ "$identity" == "-" ]]; then req=(--requirements "=designated => identifier \"$EQ_BUNDLE_ID\""); fi
    codesign --force --timestamp=none --identifier "$EQ_BUNDLE_ID" ${req[@]+"${req[@]}"} --sign "$identity" "$staging" 2>&1 |
        sed '/replacing existing signature/d' | indent ||
        eq_die "codesign failed. Check EQ_SIGN_IDENTITY against: security find-identity -v -p codesigning"

    # Swap the finished bundle in (a running copy keeps its already-open files).
    rm -rf -- "$EQ_APP_BUNDLE"
    mv -- "$staging" "$EQ_APP_BUNDLE"
    printf '%s\n' "$fingerprint" > "$stamp"
    signed_now=1

    # Debug symbols for symbolicating crash reports, kept next to (not inside) the bundle.
    rm -rf -- "$EQ_APP_BUNDLE.dSYM"
    if [[ -d "$bin_dir/$EQ_APP_NAME.dSYM" ]]; then
        ditto "$bin_dir/$EQ_APP_NAME.dSYM" "$EQ_APP_BUNDLE.dSYM"
    fi
fi

# 4. Verify what was produced and show the results.
plist="$EQ_APP_BUNDLE/Contents/Info.plist"
eq_info "Verifying"
if ! verify_output="$(codesign --verify --strict --verbose=2 "$EQ_APP_BUNDLE" 2>&1)"; then
    printf '%s\n' "$verify_output" | indent >&2
    eq_die "code signature verification failed. Rebuild from scratch with: ./build.sh --clean"
fi
printf '%s\n' "$verify_output" | indent
codesign -dvvv "$EQ_APP_BUNDLE" 2>&1 | grep -E '^(Identifier|Signature|Authority|TeamIdentifier|CDHash)=' | indent || true
plutil -lint "$plist" | indent || eq_die "the bundle's Info.plist is invalid"
archs="$(lipo -archs "$EQ_APP_BUNDLE/Contents/MacOS/$EQ_APP_NAME")" || eq_die "lipo could not read the executable"
printf '    architectures: %s\n' "$archs"
[[ " $archs " == *" arm64 "* ]] || eq_die "the executable does not contain arm64 code (found: $archs)"

built_version="$(plutil -extract CFBundleShortVersionString raw -o - "$plist")"
built_number="$(plutil -extract CFBundleVersion raw -o - "$plist")"
if [[ "$identity" == "-" ]]; then signature="ad-hoc signed"; else signature="signed by '$identity'"; fi
eq_info "Built $EQ_APP_NAME $built_version (build $built_number, $config, $signature):"
printf '    %s\n' "$EQ_APP_BUNDLE"
if [[ $signed_now == 1 && "$identity" == "-" ]]; then
    printf '    Ad-hoc signature: macOS asks for the System Audio Recording permission again for this build.\n'
fi
