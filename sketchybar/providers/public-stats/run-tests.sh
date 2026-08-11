#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

scratch=$(mktemp -d "${TMPDIR:?macOS per-user TMPDIR is required}/public-stats-tests.XXXXXX")
chmod 700 "$scratch"
cleanup() {
  chmod -R u+w "$scratch" 2>/dev/null || true
  rm -rf -- "$scratch"
}
trap cleanup EXIT HUP INT TERM

sources=()
for source in Sources/PublicStats/*.swift; do
  [[ "$source" == "Sources/PublicStats/Main.swift" ]] || sources+=("$source")
done
[[ ${#sources[@]} -eq 11 ]] || { echo E_SOURCE_COUNT >&2; exit 1; }

test_sources=(Tests/PublicStatsTests/*.swift)
[[ ${#test_sources[@]} -eq 5 ]] || { echo E_TEST_SOURCE_COUNT >&2; exit 1; }

run_suite() {
  local output=$1
  shift
  xcrun swiftc     "$@"     -warnings-as-errors     -parse-as-library     -swift-version 6     -target arm64-apple-macosx15.0     "${sources[@]}"     "${test_sources[@]}"     -framework AppKit     -framework IOKit     -framework Metal     -framework Network     -o "$output"
  local result
  result=$("$output")
  [[ "$result" == '55 TESTS PASSED' ]] || { echo E_TEST_RESULT >&2; exit 1; }
}

run_suite "$scratch/public-stats-tests-normal"
run_suite "$scratch/public-stats-tests-optimized" -O
printf '%s
' '55 TESTS PASSED'
