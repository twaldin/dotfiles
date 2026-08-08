#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="/tmp/remaining-controls-v2-offline-build"
cleanup() {
  rm -rf "${BASE}-test-debug" "${BASE}-test-release" \
    "${BASE}-15-debug" "${BASE}-15-release" \
    "${BASE}-26-debug" "${BASE}-26-release"
  rm -f "${BASE}"-*.log
}
trap cleanup EXIT
cleanup

python3 "$ROOT/scripts/static_audit.py"

run_self_test() {
  local configuration="$1"
  local scratch="${BASE}-test-${configuration}"
  local log="${scratch}.log"
  if ! swift run \
      --package-path "$ROOT" \
      --scratch-path "$scratch" \
      --configuration "$configuration" \
      -Xswiftc -warnings-as-errors \
      RemainingControlsSelfTests >"$log" 2>&1; then
    cat "$log" >&2
    return 1
  fi
  grep -q '^PASS self-tests 578 assertions$' "$log"
  printf 'PASS active-SDK %s Werror self-tests (578 assertions)\n' "$configuration"
}

run_typecheck() {
  local sdk="$1"
  local label="$2"
  local configuration="$3"
  local scratch="${BASE}-${label}-${configuration}"
  local log="${scratch}.log"
  if ! SDKROOT="$sdk" swift build \
      --package-path "$ROOT" \
      --scratch-path "$scratch" \
      --configuration "$configuration" \
      -Xswiftc -warnings-as-errors >"$log" 2>&1; then
    cat "$log" >&2
    return 1
  fi
  printf 'PASS SDK-%s %s Werror typecheck/link\n' "$label" "$configuration"
}

run_self_test debug
run_self_test release
run_typecheck /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk 15 debug
run_typecheck /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk 15 release
run_typecheck /Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk 26 debug
run_typecheck /Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk 26 release

binary="${BASE}-test-release/arm64-apple-macosx/release/RemainingControlsSelfTests"
python3 "$ROOT/scripts/link_audit.py" "$binary"
printf 'PASS complete offline gate\n'
