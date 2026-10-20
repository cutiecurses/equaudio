#!/bin/bash
# Runs EquAudio's unit and offline integration tests (no audio permission or devices needed).
#
#   ./test.sh                 all tests (debug build)
#   ./test.sh --release       all tests against an optimised build (realistic DSP benchmarks)
#   ./test.sh --filter NAME   only tests whose name matches NAME
#
# The live end-to-end routing test needs the System Audio Recording permission and is run
# separately through the app bundle: ./run.sh --selftest
set -euo pipefail
source "$(dirname "$0")/scripts/common.sh"

args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --release) args+=(-c release) ;;
        --filter) args+=(--filter "$2"); shift ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) args+=("$1") ;;
    esac
    shift
done

flags=()
while IFS= read -r f; do [[ -n "$f" ]] && flags+=("$f"); done < <(eq_swift_test_flags)

cd "$EQ_ROOT"
eq_info "Running tests"
swift test --scratch-path "$EQ_BUILD_DIR" ${flags[@]+"${flags[@]}"} ${args[@]+"${args[@]}"}
