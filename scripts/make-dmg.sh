#!/bin/bash
# Packages EquAudio.app into a compressed disk image: <build dir>/dist/EquAudio-<version>-arm64.dmg
# plus a .sha256 file next to it.
#
#   ./scripts/make-dmg.sh              build (release), then package
#   ./scripts/make-dmg.sh --no-build   package the bundle the last ./build.sh produced
#   ./scripts/make-dmg.sh --plain      skip the Finder window layout (no Automation permission needed)
#   ./scripts/make-dmg.sh --out DIR    write the image to DIR instead of <build dir>/dist
#
# The window layout (icon size, positions, hidden toolbar) is applied through Finder with AppleScript.
# If macOS blocks that or it times out, the image is still produced, just with the default layout.
# The app inside is signed the way ./build.sh signs it (ad-hoc unless EQ_SIGN_IDENTITY is set). The
# image itself is neither signed nor notarized; see the README for what that means for users.
set -euo pipefail
source "$(dirname "$0")/common.sh"

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }

build=1
style=1
out_dir=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-build) build=0 ;;
        --plain) style=0 ;;
        --out)
            [[ $# -ge 2 && -n "$2" ]] || eq_die "--out needs a folder"
            out_dir="$2"
            shift ;;
        -h|--help) usage; exit 0 ;;
        *) eq_die "unknown option '$1' (see ./scripts/make-dmg.sh --help)" ;;
    esac
    shift
done

for tool in hdiutil ditto osascript shasum; do
    command -v "$tool" >/dev/null 2>&1 || eq_die "'$tool' was not found"
done

if [[ $build == 1 ]]; then "$EQ_ROOT/build.sh"; fi
[[ -d "$EQ_APP_BUNDLE" ]] || eq_die "$EQ_APP_BUNDLE does not exist. Run ./build.sh first (or drop --no-build)."
codesign --verify --strict "$EQ_APP_BUNDLE" >/dev/null 2>&1 || eq_die "the app bundle's signature is invalid. Rebuild with: ./build.sh --clean"

version="$(plutil -extract CFBundleShortVersionString raw -o - "$EQ_APP_BUNDLE/Contents/Info.plist")"
volume="$EQ_APP_NAME"
out_dir="${out_dir:-$EQ_BUILD_DIR/dist}"
dmg_name="$EQ_APP_NAME-$version-arm64.dmg"
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"
final="$out_dir/$dmg_name"

work="$(mktemp -d "${TMPDIR:-/tmp}/equaudio-dmg.XXXXXX")"
mount_point=""
cleanup() {
    if [[ -n "$mount_point" && -d "$mount_point" ]]; then hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true; fi
    rm -rf -- "$work"
}
trap cleanup EXIT

# 1. Staging folder: the app and a shortcut to /Applications.
eq_info "Staging $EQ_APP_NAME $version"
staging="$work/stage"
mkdir -p "$staging"
ditto "$EQ_APP_BUNDLE" "$staging/$EQ_APP_NAME.app"
ln -s /Applications "$staging/Applications"
# Volume icon: the app icon, so the mounted disk looks like the app.
icon_file="$EQ_APP_BUNDLE/Contents/Resources/AppIcon.icns"
if [[ -f "$icon_file" ]]; then cp -- "$icon_file" "$staging/.VolumeIcon.icns"; fi

# 2. Writable image, sized to the content plus headroom for the Finder's metadata.
size_mb=$(( $(du -sk "$staging" | cut -f 1) / 1024 + 24 ))
rw="$work/rw.dmg"
eq_info "Creating the disk image (${size_mb} MB, HFS+)"
hdiutil create -quiet -srcfolder "$staging" -volname "$volume" -fs HFS+ -format UDRW -size "${size_mb}m" -ov "$rw"

# 3. Mount it, set the custom-icon flag and lay out the window.
attach_output="$(hdiutil attach "$rw" -readwrite -noverify -noautoopen)"
mount_point="$(printf '%s\n' "$attach_output" | awk -F'\t' '/\/Volumes\// { print $NF; exit }')"
[[ -d "$mount_point" ]] || eq_die "could not mount the disk image"
if [[ -f "$mount_point/.VolumeIcon.icns" ]] && command -v SetFile >/dev/null 2>&1; then
    SetFile -a C "$mount_point" || true
fi

if [[ $style == 1 ]]; then
    eq_info "Laying out the Finder window"
    layout='
        tell application "Finder"
            tell disk "'"$volume"'"
                open
                set current view of container window to icon view
                set toolbar visible of container window to false
                set statusbar visible of container window to false
                set the bounds of container window to {200, 140, 760, 500}
                set opts to the icon view options of container window
                set arrangement of opts to not arranged
                set icon size of opts to 128
                set text size of opts to 13
                set position of item "'"$EQ_APP_NAME"'.app" of container window to {150, 170}
                set position of item "Applications" of container window to {410, 170}
                update without registering applications
                delay 1
                close
            end tell
        end tell'
    # macOS has no timeout(1): run osascript in the background and give it 30 seconds.
    osascript -e "$layout" >/dev/null 2>"$work/osascript.err" &
    osa_pid=$!
    waited=0
    while kill -0 "$osa_pid" 2>/dev/null && (( waited < 60 )); do sleep 0.5; waited=$((waited + 1)); done
    if kill -0 "$osa_pid" 2>/dev/null; then
        kill "$osa_pid" 2>/dev/null || true
        eq_warn "Finder did not answer in 30 s (Automation permission prompt?). Using the default layout."
    elif ! wait "$osa_pid"; then
        eq_warn "Finder layout failed ($(tr '\n' ' ' < "$work/osascript.err")). Using the default layout."
    fi
fi

# 4. Flush, unmount, compress.
sync
hdiutil detach "$mount_point" -quiet || hdiutil detach "$mount_point" -force -quiet
mount_point=""
eq_info "Compressing"
rm -f -- "$final"
hdiutil convert "$rw" -quiet -format UDZO -imagekey zlib-level=9 -o "$final"

# 5. Checksum (relative file name, so `shasum -a 256 -c` works next to the image).
( cd "$out_dir" && shasum -a 256 "$dmg_name" > "$dmg_name.sha256" )
hdiutil verify -quiet "$final" || eq_die "the disk image failed verification"

eq_info "Built $dmg_name ($(du -h "$final" | cut -f 1 | tr -d ' ')):"
printf '    %s\n    %s\n' "$final" "$(cat "$out_dir/$dmg_name.sha256")"
