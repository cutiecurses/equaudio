#!/bin/bash
# Builds and launches EquAudio.app from the build directory.
#
#   ./run.sh                     build (release), quit a running EquAudio, launch the app
#   ./run.sh --no-build          launch the existing bundle without building
#   ./run.sh --debug             build and launch the debug configuration
#   ./run.sh --console           run the app inside this terminal to watch its log live
#   ./run.sh --selftest [--audible] [--seconds N]
#                                live end-to-end test: tap -> DSP -> device -> recording;
#                                prints the report, exits 0 if it passed and 1 if not
#   ./run.sh --quit              quit a running EquAudio and exit
#   ./run.sh [...] -- ARGS       pass ARGS on to the app (normal and --console launches)
#
# A normal launch goes through LaunchServices (`open`), so macOS asks for the System Audio
# Recording permission on behalf of EquAudio itself. With --console the terminal app becomes the
# "responsible" process and the permission is requested for (and stored under) the terminal.
# Logs: ~/Library/Logs/EquAudio/EquAudio.log, or live:
#   log stream --predicate 'subsystem == "com.equaudio.EquAudio"'
set -euo pipefail
source "$(dirname "$0")/scripts/common.sh"

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }

mode=open
build=1
build_args=()
audible=0
seconds=""
app_args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-build) build=0 ;;
        --debug) build_args+=(--debug) ;;
        --console) mode=console ;;
        --selftest) mode=selftest ;;
        --audible) audible=1 ;;
        --seconds)
            [[ $# -ge 2 ]] || eq_die "--seconds needs a value, e.g. --seconds 10"
            seconds="$2"
            shift ;;
        --quit) mode=quit ;;
        --) shift; app_args=("$@"); break ;;
        -h|--help) usage; exit 0 ;;
        *) eq_die "unknown option '$1' (see ./run.sh --help)" ;;
    esac
    shift
done

if [[ $mode != selftest && ( $audible == 1 || -n "$seconds" ) ]]; then
    eq_die "--audible and --seconds only apply to --selftest"
fi
if [[ -n "$seconds" ]]; then
    number_re='^[0-9]+([.][0-9]+)?$'
    zero_re='^0+([.]0+)?$'
    if [[ ! "$seconds" =~ $number_re || "$seconds" =~ $zero_re ]]; then
        eq_die "--seconds needs a positive number (got '$seconds')"
    fi
fi
if [[ $mode == selftest && ${#app_args[@]} -gt 0 ]]; then
    eq_die "the self-test takes no extra app arguments"
fi
if [[ $build == 0 && ${#build_args[@]} -gt 0 ]]; then
    eq_warn "--debug has no effect with --no-build (the existing bundle is launched as built)"
fi

# True while any EquAudio process of this user runs (also catches the --console variant).
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

if [[ $mode == quit ]]; then
    if equaudio_running; then quit_equaudio; else eq_info "$EQ_APP_NAME is not running"; fi
    exit 0
fi

[[ "$EQ_BUILD_DIR" == /* ]] || eq_die "EQ_BUILD_DIR must be an absolute path, e.g. EQ_BUILD_DIR=\"$PWD/$EQ_BUILD_DIR\""
if [[ $build == 1 ]]; then
    "$EQ_ROOT/build.sh" ${build_args[@]+"${build_args[@]}"}
fi
[[ -x "$EQ_APP_BUNDLE/Contents/MacOS/$EQ_APP_NAME" ]] || eq_die "no app bundle at $EQ_APP_BUNDLE. Build it with: ./build.sh"

quit_equaudio

case "$mode" in
    open)
        eq_info "Launching $EQ_APP_BUNDLE"
        if [[ ${#app_args[@]} -gt 0 ]]; then
            open "$EQ_APP_BUNDLE" --args "${app_args[@]}" || eq_die "LaunchServices could not open $EQ_APP_BUNDLE"
        else
            open "$EQ_APP_BUNDLE" || eq_die "LaunchServices could not open $EQ_APP_BUNDLE"
        fi
        printf '    Log: ~/Library/Logs/EquAudio/EquAudio.log\n'
        ;;

    console)
        eq_warn "Running inside the terminal: macOS attributes the System Audio Recording permission to ${TERM_PROGRAM:-your terminal app}, not to EquAudio. Use ./run.sh without --console for the normal permission flow."
        eq_info "Running $EQ_APP_NAME in the foreground (Ctrl-C to quit)"
        exec "$EQ_APP_BUNDLE/Contents/MacOS/$EQ_APP_NAME" ${app_args[@]+"${app_args[@]}"}
        ;;

    selftest)
        report_dir="$EQ_BUILD_DIR/selftest"
        report_json="$report_dir/report.json"
        report_txt="$report_dir/report.txt"
        mkdir -p "$report_dir"
        # A report left over from an earlier run must never count as this run's result.
        rm -f -- "$report_json" "$report_txt"

        selftest_args=(--selftest --report "$report_json")
        if [[ $audible == 1 ]]; then selftest_args+=(--audible); fi
        if [[ -n "$seconds" ]]; then selftest_args+=(--seconds "$seconds"); fi

        eq_info "Running the live self-test (${seconds:-default} s, $([[ $audible == 1 ]] && echo audible || echo silent output))"
        printf '    If macOS asks whether EquAudio may record system audio, click Allow; the test waits.\n'
        trap 'echo; eq_warn "self-test interrupted"; quit_equaudio; exit 130' INT TERM
        open -W -n "$EQ_APP_BUNDLE" --args "${selftest_args[@]}" || eq_die "LaunchServices could not open $EQ_APP_BUNDLE"
        trap - INT TERM

        if [[ -f "$report_txt" ]]; then
            echo
            cat "$report_txt"
            echo
        else
            eq_warn "no text report at $report_txt"
        fi
        [[ -f "$report_json" ]] ||
            eq_die "the self-test wrote no report (did EquAudio crash or quit early?). See ~/Library/Logs/EquAudio/EquAudio.log"
        passed="$(plutil -extract passed raw -o - "$report_json" 2>/dev/null || true)"
        case "$passed" in
            true) eq_info "Self-test PASSED (report: $report_json)"; exit 0 ;;
            false) eq_error "Self-test FAILED (report: $report_json)"; exit 1 ;;
            *) eq_die "$report_json has no boolean \"passed\" field" ;;
        esac
        ;;
esac
