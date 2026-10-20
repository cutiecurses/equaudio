#!/bin/bash
# Removes EquAudio and everything it created, and nothing else.
#
#   ./uninstall.sh                      quit EquAudio, remove it and all of its data
#   ./uninstall.sh --dry-run            only list what would be removed
#   ./uninstall.sh --keep-presets       keep your presets (~/Library/Application Support/EquAudio/Presets)
#   ./uninstall.sh --keep-build         keep the build cache (~/Library/Caches/EquAudio)
#   ./uninstall.sh --clean-repo         also delete this repository's .build and .build.nosync folders
#   ./uninstall.sh --dest DIR           also remove DIR/EquAudio.app (an ./install.sh --dest install)
#   ./uninstall.sh --remove-blackhole   also uninstall BlackHole 2ch if ./setup.sh installed it
#
# Removed: EquAudio.app in /Applications and ~/Applications, ~/Library/Application Support/EquAudio,
# ~/Library/Logs/EquAudio, ~/Library/Caches/EquAudio, the app's caches, preferences
# (com.equaudio.EquAudio) and saved window state, and the System Audio Recording approvals of
# EquAudio and its proof of concept (com.equaudio.EquAudio.poc).
# Never removed: your recordings (~/Music/EquAudio Recordings or the folder chosen in EquAudio)
# and anything else that EquAudio did not create. Running it twice is harmless.
#
# EQ_HOME=DIR (testing) works on DIR instead of your home folder and leaves everything outside it
# alone: /Applications, running apps, the preferences daemon, privacy settings and Homebrew.
set -euo pipefail
custom_build_dir="${EQ_BUILD_DIR:-}"
source "$(dirname "$0")/scripts/common.sh"

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
POC_BUNDLE_ID="$EQ_BUNDLE_ID.poc"

dry_run=0
keep_presets=0
keep_build=0
clean_repo=0
remove_blackhole=0
dest_dir=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run|-n) dry_run=1 ;;
        --keep-presets) keep_presets=1 ;;
        --keep-build) keep_build=1 ;;
        --clean-repo) clean_repo=1 ;;
        --remove-blackhole) remove_blackhole=1 ;;
        --dest)
            [[ $# -ge 2 && -n "$2" ]] || eq_die "--dest needs the folder that contains EquAudio.app"
            dest_dir="$2"
            shift ;;
        -h|--help) usage; exit 0 ;;
        *) eq_die "unknown option '$1' (see ./uninstall.sh --help)" ;;
    esac
    shift
done

home="${EQ_HOME:-$HOME}"
[[ "$home" == /* && -d "$home" ]] || eq_die "EQ_HOME must be an existing absolute folder (got '$home')"
home="$(cd "$home" && pwd -P)"
# 1 = also act outside $home (running app, /Applications, defaults, TCC, Homebrew); 0 in EQ_HOME tests.
system=1
[[ "$home" == "$(cd "$HOME" && pwd -P)" ]] || system=0

if [[ -n "$dest_dir" ]]; then
    case "$dest_dir" in "~/"*) dest_dir="$HOME/${dest_dir#"~/"}" ;; esac
    [[ "$dest_dir" != *.app && "$dest_dir" != *.app/ ]] || eq_die "--dest takes the folder that contains EquAudio.app, not the app itself"
    if [[ -d "$dest_dir" ]]; then dest_dir="$(cd "$dest_dir" && pwd -P)"; fi
fi

support_dir="$home/Library/Application Support/EquAudio"
blackhole_marker="$support_dir/.blackhole-installed-by-equaudio"

changed=0   # items removed (or that would be removed)
failures=0

# One line per action: verb column, then the subject.
report() { printf '  %-13s %s\n' "$1" "$2"; }

# Path for display: ~/... inside the real home folder.
show() {
    local path="$1"
    if [[ $system == 1 && "$path" == "$home"/* ]]; then path="~${path#"$home"}"; fi
    printf '%s' "$path"
}

# MARK: Recordings are never touched

# Recording folders: the default one plus any folder configured in Settings.json, i.e. string values
# of keys under a "record..." key path named like a folder/directory/path/url/location.
recording_folders=("$home/Music/EquAudio Recordings")
read -r -d '' find_recording_folders_js <<'JXA' || true
function run(argv) {
    ObjC.import('Foundation');
    const text = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
    if (text.isNil()) return '';
    let settings;
    try { settings = JSON.parse(text.js); } catch (e) { return ''; }
    const home = argv[1];
    const folders = [];
    const visit = (value, keyPath, key) => {
        if (typeof value === 'string') {
            if (!/record/i.test(keyPath) || !/(folder|director|dir|path|url|location)/i.test(key)) return;
            let path = value;
            if (/^file:/i.test(path)) {
                const url = $.NSURL.URLWithString(path);
                path = url.isNil() ? '' : url.path.js;
            }
            if (path.startsWith('~/')) path = home + path.slice(1);
            if (path.startsWith('/')) folders.push(path);
        } else if (Array.isArray(value)) {
            value.forEach(v => visit(v, keyPath, key));
        } else if (value !== null && typeof value === 'object') {
            Object.keys(value).forEach(k => visit(value[k], keyPath + '.' + k, k));
        }
    };
    visit(settings, '', '');
    return folders.join('\n');
}
JXA
if [[ -f "$support_dir/Settings.json" ]]; then
    while IFS= read -r folder; do
        if [[ -n "$folder" ]]; then recording_folders+=("${folder%/}"); fi
    done < <(osascript -l JavaScript -e "$find_recording_folders_js" "$support_dir/Settings.json" "$home" 2>/dev/null || true)
fi

# True if deleting $1 would delete a recordings folder (it is one, or contains one).
holds_recordings() {
    local target="${1%/}" folder
    for folder in "${recording_folders[@]}"; do
        if [[ "$folder" == "$target" || "$folder" == "$target"/* ]]; then return 0; fi
    done
    return 1
}

# MARK: Removal primitives

# Removes one item EquAudio created. Only EquAudio-named paths are accepted, so a wrong variable can
# never delete anything else. $2 = "quiet" skips the "not found" line for optional extras.
remove_path() {
    local path="$1" mode="${2:-}"
    case "$path" in
        /?*/EquAudio.app|/?*/EquAudio\ PoC.app|/?*/EquAudio|/?*/com.equaudio.EquAudio*|/?*/.build|/?*/.build.nosync) ;;
        "$support_dir"/?*) ;;
        *) eq_die "internal error: refusing to remove unexpected path '$path'" ;;
    esac
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        if [[ "$mode" != quiet ]]; then report "not found" "$(show "$path")"; fi
        return 0
    fi
    if holds_recordings "$path"; then
        report "kept" "$(show "$path") (it holds your recordings)"
        return 0
    fi
    local size
    size="$(du -sh "$path" 2>/dev/null | cut -f 1 | tr -d ' ' || true)"
    if [[ $dry_run == 1 ]]; then
        report "would remove" "$(show "$path")${size:+ ($size)}"
    elif rm -rf -- "$path"; then
        report "removed" "$(show "$path")${size:+ ($size)}"
    else
        eq_warn "could not remove $path"
        failures=$((failures + 1))
        return 0
    fi
    changed=$((changed + 1))
}

# Removes an EquAudio app bundle after checking its bundle identifier, and drops its LaunchServices
# registration so Finder and `open -b` forget it.
remove_app() {
    local app="$1" mode="${2:-}" id
    if [[ ! -e "$app" ]]; then
        if [[ "$mode" != quiet ]]; then report "not found" "$(show "$app")"; fi
        return 0
    fi
    id="$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$id" != "$EQ_BUNDLE_ID" && "$id" != "$POC_BUNDLE_ID" ]]; then
        report "kept" "$(show "$app") is not EquAudio (bundle id '${id:-unreadable}'); remove it yourself if it is"
        return 0
    fi
    if [[ $dry_run == 0 && -x "$LSREGISTER" ]]; then "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true; fi
    remove_path "$app"
}

# Removes a build directory, including the app bundles built into it.
remove_build_dir() {
    local dir="$1" mode="${2:-}"
    if [[ -d "$dir" ]] && ! holds_recordings "$dir"; then
        remove_app "$dir/app/$EQ_APP_NAME.app" quiet
        remove_app "$dir/build/app/$EQ_APP_NAME.app" quiet
        remove_app "$dir/poc/$EQ_APP_NAME PoC.app" quiet
        remove_app "$dir/build/poc/$EQ_APP_NAME PoC.app" quiet
    fi
    remove_path "$dir" "$mode"
}

# Resets one privacy (TCC) approval. Needs the bundle id to be known to LaunchServices, so this runs
# before the bundles are removed.
reset_privacy() {
    local service="$1" bundle_id="$2"
    if [[ $system == 0 ]]; then report "skipped" "tccutil reset $service $bundle_id (EQ_HOME test mode)"; return 0; fi
    if [[ $dry_run == 1 ]]; then report "would run" "tccutil reset $service $bundle_id"; return 0; fi
    if tccutil reset "$service" "$bundle_id" >/dev/null 2>&1; then
        report "reset" "privacy approvals: tccutil reset $service $bundle_id"
    else
        report "not found" "privacy approvals for $bundle_id (not registered; if it is still listed in System Settings > Privacy & Security, remove it there)"
    fi
}

# MARK: Quit EquAudio

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
    osascript -e 'with timeout of 10 seconds' \
        -e "if application id \"$EQ_BUNDLE_ID\" is running then tell application id \"$EQ_BUNDLE_ID\" to quit" \
        -e 'end timeout' >/dev/null 2>&1 || true
    wait_for_exit 10 && return 0
    pkill -TERM -x -U "$(id -u)" "$EQ_APP_NAME" 2>/dev/null || true
    wait_for_exit 5 && return 0
    eq_warn "$EQ_APP_NAME did not quit; forcing it to stop"
    pkill -KILL -x -U "$(id -u)" "$EQ_APP_NAME" 2>/dev/null || true
    wait_for_exit 3 || eq_die "could not stop $EQ_APP_NAME (pid $(pgrep -x -U "$(id -u)" "$EQ_APP_NAME" | tr '\n' ' ')). Quit it from its menu and run ./uninstall.sh again."
}

# MARK: Uninstall

if [[ $dry_run == 1 ]]; then eq_info "Uninstalling EquAudio (dry run: nothing is changed)"; else eq_info "Uninstalling EquAudio"; fi
if [[ $system == 0 ]]; then
    eq_warn "EQ_HOME=$home: test mode, only files under it (and --dest) are touched"
fi
blackhole_ours=0
if [[ -f "$blackhole_marker" ]]; then blackhole_ours=1; fi

if [[ $system == 1 ]] && equaudio_running; then
    pids="$(pgrep -x -U "$(id -u)" "$EQ_APP_NAME" | tr '\n' ' ')"
    if [[ $dry_run == 1 ]]; then
        report "would quit" "$EQ_APP_NAME (pid ${pids% })"
    else
        quit_equaudio
        report "quit" "$EQ_APP_NAME (pid ${pids% })"
    fi
fi

reset_privacy AudioCapture "$EQ_BUNDLE_ID"
reset_privacy All "$POC_BUNDLE_ID"

if [[ $system == 1 ]]; then
    remove_app "/Applications/$EQ_APP_NAME.app"
else
    report "skipped" "/Applications/$EQ_APP_NAME.app (EQ_HOME test mode)"
fi
if [[ "$home/Applications" != /Applications ]]; then
    remove_app "$home/Applications/$EQ_APP_NAME.app"
fi
if [[ -n "$dest_dir" ]]; then
    remove_app "${dest_dir%/}/$EQ_APP_NAME.app"
fi

if [[ $keep_presets == 1 && -d "$support_dir/Presets" ]]; then
    while IFS= read -r -d '' item; do
        remove_path "$item"
    done < <(find "$support_dir" -mindepth 1 -maxdepth 1 ! -name Presets -print0)
    report "kept" "$(show "$support_dir/Presets") (--keep-presets)"
else
    remove_path "$support_dir"
fi
remove_path "$home/Library/Logs/EquAudio"
if [[ $keep_build == 1 ]]; then
    if [[ -e "$home/Library/Caches/EquAudio" ]]; then report "kept" "$(show "$home/Library/Caches/EquAudio") (--keep-build)"; fi
else
    remove_build_dir "$home/Library/Caches/EquAudio"
fi
remove_path "$home/Library/Caches/$EQ_BUNDLE_ID" quiet
remove_path "$home/Library/HTTPStorages/$EQ_BUNDLE_ID" quiet
remove_path "$home/Library/HTTPStorages/$EQ_BUNDLE_ID.binarycookies" quiet
remove_path "$home/Library/WebKit/$EQ_BUNDLE_ID" quiet

if [[ $system == 1 ]] && defaults read "$EQ_BUNDLE_ID" >/dev/null 2>&1; then
    if [[ $dry_run == 1 ]]; then
        report "would run" "defaults delete $EQ_BUNDLE_ID"
    elif defaults delete "$EQ_BUNDLE_ID" >/dev/null 2>&1; then
        report "removed" "preferences (defaults delete $EQ_BUNDLE_ID)"
    fi
fi
remove_path "$home/Library/Preferences/$EQ_BUNDLE_ID.plist"
remove_path "$home/Library/Preferences/$POC_BUNDLE_ID.plist" quiet
for byhost in "$home/Library/Preferences/ByHost/$EQ_BUNDLE_ID".*.plist; do
    if [[ -e "$byhost" ]]; then remove_path "$byhost"; fi
done
remove_path "$home/Library/Saved Application State/$EQ_BUNDLE_ID.savedState"
remove_path "$home/Library/Saved Application State/$POC_BUNDLE_ID.savedState" quiet

if [[ $clean_repo == 1 ]]; then
    remove_build_dir "$EQ_ROOT/.build"
    remove_build_dir "$EQ_ROOT/.build.nosync" quiet
fi
if [[ -n "$custom_build_dir" && -e "$custom_build_dir" ]]; then
    case "$custom_build_dir" in
        "$home/Library/Caches/EquAudio"|"$home/Library/Caches/EquAudio/"*|"$EQ_ROOT/.build"|"$EQ_ROOT/.build/"*) ;;
        *) report "kept" "$custom_build_dir (EQ_BUILD_DIR; delete it yourself if you no longer need it)" ;;
    esac
fi

# BlackHole: removed only when EquAudio's setup.sh installed it and --remove-blackhole asks for it.
blackhole_driver=""
for driver in /Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver /Library/Audio/Plug-Ins/HAL/BlackHole.driver; do
    if [[ -d "$driver" ]]; then blackhole_driver="$driver"; fi
done
if [[ $blackhole_ours == 0 ]]; then
    if [[ $remove_blackhole == 1 ]]; then
        report "kept" "BlackHole 2ch: not installed by EquAudio's setup.sh, so it is left alone"
    elif [[ -n "$blackhole_driver" ]]; then
        report "kept" "BlackHole ($blackhole_driver; not installed by EquAudio)"
    fi
elif [[ $remove_blackhole == 0 ]]; then
    report "kept" "BlackHole 2ch (installed by ./setup.sh --with-blackhole). Remove it with: brew uninstall --cask blackhole-2ch"
elif [[ $system == 0 ]]; then
    report "skipped" "brew uninstall --cask blackhole-2ch (EQ_HOME test mode)"
elif [[ $dry_run == 1 ]]; then
    report "would run" "brew uninstall --cask blackhole-2ch (asks for an administrator password, restarts the audio system)"
else
    brew="$(command -v brew || true)"
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [[ -z "$brew" && -x "$candidate" ]]; then brew="$candidate"; fi
    done
    if [[ -z "$brew" ]]; then
        eq_warn "Homebrew not found, BlackHole 2ch stays installed. Remove it with Homebrew: brew uninstall --cask blackhole-2ch"
        failures=$((failures + 1))
    elif ! "$brew" list --cask blackhole-2ch >/dev/null 2>&1; then
        report "not found" "BlackHole 2ch (no longer installed through Homebrew)"
    else
        eq_info "Uninstalling BlackHole 2ch (Homebrew asks for an administrator password; audio stops briefly)"
        if "$brew" uninstall --cask blackhole-2ch; then
            report "removed" "BlackHole 2ch"
            changed=$((changed + 1))
        else
            eq_warn "brew uninstall --cask blackhole-2ch failed; run it again to remove BlackHole"
            failures=$((failures + 1))
        fi
    fi
fi

# Recordings: listed, never removed.
for folder in "${recording_folders[@]}"; do
    if [[ -d "$folder" ]]; then
        count="$(find "$folder" -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')"
        report "kept" "$(show "$folder") (your recordings: $count file(s), never removed)"
    fi
done

echo
if [[ $dry_run == 1 ]]; then
    eq_info "Dry run: $changed item(s) would be removed. Run without --dry-run to remove them."
elif [[ $changed == 0 && $failures == 0 ]]; then
    eq_info "Nothing to remove: EquAudio is not installed."
elif [[ $failures == 0 ]]; then
    eq_info "EquAudio removed ($changed item(s))."
else
    eq_die "$failures item(s) could not be removed (see the warnings above)."
fi
