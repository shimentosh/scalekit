#!/usr/bin/env bash
# run-tests.sh — runs the ScaleKit test suite with SwiftPM and prints a summary.
#
# Usage: scripts/run-tests.sh [extra `swift test` arguments, e.g. --filter RecommendationTests]
#
# Environment:
#   SCALEKIT_SCRATCH_PATH   SwiftPM scratch (build) directory. Default: <repo>/.build

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="${SCALEKIT_SCRATCH_PATH:-$ROOT/.build}"
LOG="$(mktemp -t scalekit-tests)"
trap 'rm -f "$LOG" "$LOG.clean"' EXIT

# With only the Command Line Tools installed (no Xcode), the default `swiftbuild`
# build system does not hand the Swift Testing macro plugin to the compiler, so
# every @Test / #expect fails with "plugin for module 'TestingMacros' not found".
# Point the compiler at the plugin explicitly in that case.
EXTRA_ARGS=()
SWIFT_BIN="$(xcrun --find swift 2>/dev/null || true)"
if [[ -n "$SWIFT_BIN" && "$SWIFT_BIN" == */CommandLineTools/* ]]; then
    TESTING_PLUGINS="$(dirname "$SWIFT_BIN")/../lib/swift/host/plugins/testing"
    if [[ -d "$TESTING_PLUGINS" ]]; then
        EXTRA_ARGS+=(-Xswiftc -plugin-path -Xswiftc "$(cd "$TESTING_PLUGINS" && pwd)")
    fi
fi

echo "Running tests"
echo "  package: $ROOT"
echo "  scratch: $SCRATCH"
((${#EXTRA_ARGS[@]})) && echo "  note:    Command Line Tools toolchain; adding the Swift Testing macro plugin path"
echo

START=$SECONDS
set +e
swift test --package-path "$ROOT" --scratch-path "$SCRATCH" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} "$@" 2>&1 | tee "$LOG"
STATUS=${PIPESTATUS[0]}
set -e
ELAPSED=$((SECONDS - START))

# Strip colour codes before parsing.
sed $'s/\x1b\\[[0-9;]*m//g' "$LOG" >"$LOG.clean"

# XCTest:        Executed 12 tests, with 0 failures (0 unexpected) in 0.034 (0.036) seconds
# Swift Testing: ✔ Test run with 8 tests in 3 suites passed after 0.012 seconds.
#                ✘ Test run with 8 tests in 3 suites failed after 0.012 seconds with 2 issues.
XCTEST_SUMMARY="$(grep -E '^[[:space:]]*Executed [0-9]+ tests?, with [0-9]+ failures?' "$LOG.clean" | tail -1 | sed 's/^[[:space:]]*//' || true)"
TESTING_SUMMARY="$(grep -E 'Test run with [0-9]+ tests?' "$LOG.clean" | tail -1 | sed 's/^[[:space:]]*//' || true)"
# Compile errors, XCTest assertion failures, and Swift Testing issues/failed tests.
FAILURES="$(grep -E '(\.swift:[0-9]+:[0-9]+: error:|^error: |error: -\[|Test .*(recorded an issue|failed after))' "$LOG.clean" \
    | grep -vE 'Test run with|^error: (Build failed|fatalError)|failed with a nonzero exit code' \
    | cut -c1-240 | awk '!seen[$0]++' | head -25 || true)"

echo
echo "================ Test summary ================"
[[ -n "$XCTEST_SUMMARY" ]] && echo "XCTest:        $XCTEST_SUMMARY"
[[ -n "$TESTING_SUMMARY" ]] && echo "Swift Testing: $TESTING_SUMMARY"
if [[ -z "$XCTEST_SUMMARY" && -z "$TESTING_SUMMARY" ]]; then
    echo "No test results found (the build probably failed before any test ran)."
fi
if [[ -n "$FAILURES" ]]; then
    echo
    echo "Problems:"
    sed "s|$ROOT/||; s/^/  /" <<<"$FAILURES"
fi
echo
if ((STATUS == 0)); then
    echo "PASSED in ${ELAPSED}s"
else
    echo "FAILED (swift test exit status $STATUS) in ${ELAPSED}s"
fi
exit "$STATUS"
