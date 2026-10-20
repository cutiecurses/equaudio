#!/bin/bash
# Installs EquAudio.app into /Applications (or ~/Applications when /Applications is not writable).
#
#   ./install.sh              build (release), quit a running EquAudio, install and register it
#   ./install.sh --no-build   install the bundle the last ./build.sh produced
#   ./install.sh --open       launch the installed app afterwards
#   ./install.sh --dest DIR   install into DIR/EquAudio.app instead (DIR is created if needed)
#
# Never uses sudo. If /Applications is not writable for your account, EquAudio goes to
# ~/Applications and the command for a system-wide install is printed instead.
# Remove everything again with ./uninstall.sh.
set -euo pipefail
source "$(dirname "$0")/scripts/common.sh"

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

build=1
launch=0
dest_dir=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-build) build=0 ;;
        --open) launch=1 ;;
        --dest)
            [[ $# -ge 2 && -n "$2" ]] || eq_die "--dest needs a folder, e.g. --dest ~/Applications"
            dest_dir="$2"
            shift ;;
        -h|--help) usage; exit 0 ;;
        *) eq_die "unknown option '$1' (see ./install.sh --help)" ;;
    esac
    shift
done
[[ "$EQ_BUILD_DIR" == /* ]] || eq_die "EQ_BUILD_DIR must be an absolute path, e.g. EQ_BUILD_DIR=\"$PWD/$EQ_BUILD_DIR\""

# True while any EquAudio process of this user runs.
equaudio_running() { pgrep -x -U "$(id -u)" "$EQ_APP_NAME" >/dev/null 2>&1; }

# Waits up to $1 seconds for every EquAudio process to exit.
wait_for_exit() {
    local i
    for ((i = 0; i < $1 * 5; i++)); do
        equaudio_running || return 0
        sleep 0.2
    done
    ! equaudio_running
}

# Quits every running EquAudio: first through Apple Events so it can stop its tap and save its
# settings, then SIGTERM, and SIGKILL only as a last resort.
quit_equaudio() {
    equaudio_running || return 0
    eq_info "Quitting the running $EQ_APP_NAME"
    osascript -e 'with timeout of 10 seconds' \
        -e "if application id \"$EQ_BUNDLE_ID\" is running then tell application id \"$EQ_BUNDLE_ID\" to quit" \
        -e 'end timeout' >/dev/null 2>&1 || true
    wait_for_exit 10 && return 0
    pkill -TERM -x -U "$(id -u)" "$EQ_APP_NAME" 2>/dev/null || true
    wait_for_exit 5 && return 0
    eq_warn "$EQ_APP_NAME did not quit; forcing it to stop"
    pkill -KILL -x -U "$(id -u)" "$EQ_APP_NAME" 2>/dev/null || true
    wait_for_exit 3 || eq_die "could not stop $EQ_APP_NAME (pid $(pgrep -x -U "$(id -u)" "$EQ_APP_NAME" | tr '\n' ' ')). Quit it from its menu and try again."
}

# Bundle identifier of an app bundle, or nothing if unreadable.
bundle_id_of() { plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null || true; }

# 1. The bundle to install.
if [[ $build == 1 ]]; then
    "$EQ_ROOT/build.sh"
fi
source_app="$EQ_APP_BUNDLE"
[[ -d "$source_app" ]] || eq_die "no app bundle at $source_app. Build it with: ./build.sh"
codesign --verify --strict "$source_app" >/dev/null 2>&1 ||
    eq_die "$source_app is not validly signed. Rebuild it with: ./build.sh"
[[ "$(bundle_id_of "$source_app")" == "$EQ_BUNDLE_ID" ]] || eq_die "$source_app is not $EQ_BUNDLE_ID. Rebuild it with: ./build.sh"

# 2. Where to install it.
if [[ -n "$dest_dir" ]]; then
    [[ "$dest_dir" != *.app && "$dest_dir" != *.app/ ]] || eq_die "--dest takes the folder to install into, not the app itself"
    mkdir -p -- "$dest_dir" || eq_die "cannot create $dest_dir"
    dest_dir="$(cd "$dest_dir" && pwd)"
    [[ -w "$dest_dir" ]] || eq_die "$dest_dir is not writable. Choose another folder with --dest DIR."
elif [[ -w /Applications ]]; then
    dest_dir=/Applications
else
    dest_dir="$HOME/Applications"
    mkdir -p -- "$dest_dir"
    eq_warn "/Applications is not writable for $(id -un), so EquAudio goes to $dest_dir (only for you)."
    printf '    For all users, ask an administrator to run:\n      sudo ditto "%s" "/Applications/%s.app"\n' "$source_app" "$EQ_APP_NAME" >&2
fi
target="$dest_dir/$EQ_APP_NAME.app"
if [[ -e "$target" ]]; then
    existing_id="$(bundle_id_of "$target")"
    [[ "$existing_id" == "$EQ_BUNDLE_ID" ]] ||
        eq_die "$target exists but is not EquAudio (bundle id '${existing_id:-unreadable}'). Move it away and run ./install.sh again."
fi

# 3. Copy: into a temporary name in the same folder first, then swap it in, so a failure never
# leaves a half-copied app behind and the previous version is restored if the swap fails.
quit_equaudio
staging="$dest_dir/.$EQ_APP_NAME.app.installing.$$"
previous="$dest_dir/.$EQ_APP_NAME.app.previous.$$"
trap 'rm -rf -- "$staging" "$previous"' EXIT
eq_info "Installing $target"
ditto --norsrc --noextattr --noacl "$source_app" "$staging" || eq_die "copying the app to $dest_dir failed"
if [[ -e "$target" ]]; then
    mv -- "$target" "$previous" || eq_die "cannot replace $target (is it in use?)"
fi
if ! mv -- "$staging" "$target"; then
    if [[ -e "$previous" ]]; then mv -- "$previous" "$target"; fi
    eq_die "cannot move the new app into $dest_dir"
fi
rm -rf -- "$previous"

# 4. Verify the installed copy and register it with LaunchServices (Finder, Spotlight, `open -b`).
if ! verify_output="$(codesign --verify --strict --verbose=2 "$target" 2>&1)"; then
    printf '%s\n' "$verify_output" | sed 's/^/    /' >&2
    eq_die "the installed app's signature does not verify. Rebuild and reinstall: ./build.sh --clean && ./install.sh --no-build"
fi
printf '%s\n' "$verify_output" | sed 's/^/    /'
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$target" || eq_warn "LaunchServices registration failed; Finder will pick the app up later"
else
    eq_warn "lsregister not found; Finder will pick the app up later"
fi

# Another copy elsewhere would compete for the same bundle identifier.
for other in "/Applications/$EQ_APP_NAME.app" "$HOME/Applications/$EQ_APP_NAME.app"; do
    if [[ "$other" != "$target" && -d "$other" && "$(bundle_id_of "$other")" == "$EQ_BUNDLE_ID" ]]; then
        eq_warn "another copy is installed at $other; remove it so macOS does not open the old one: rm -rf \"$other\""
    fi
done

version="$(plutil -extract CFBundleShortVersionString raw -o - "$target/Contents/Info.plist" 2>/dev/null || echo '?')"
eq_info "Installed $EQ_APP_NAME $version: $target"
cat <<EOF

First launch
    macOS asks whether EquAudio may record system audio ("System Audio Recording"). Click
    Allow: EquAudio needs it to receive the sound other apps play so it can process it.
    If you deny it, other apps' audio reaches EquAudio as silence and EquAudio shows a warning.
    Change it later in System Settings > Privacy & Security > Screen & System Audio Recording
    (macOS 15 and later list EquAudio under "System Audio Recording Only").
    The build is signed with a fixed identity requirement, so you approve once and later rebuilds keep it;
    a different EQ_SIGN_IDENTITY needs one new approval.
EOF

if [[ $launch == 1 ]]; then
    eq_info "Launching $target"
    open "$target" || eq_die "LaunchServices could not open $target"
fi
