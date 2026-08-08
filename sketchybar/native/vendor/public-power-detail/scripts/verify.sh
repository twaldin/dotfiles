#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BINDING_AUDIT="${1:-/tmp/battery-power-full-functionality-gap-audit.md}"
SDK15="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
SDK26="/Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk"
TARGET="arm64-apple-macosx12.0"

for sdk in "$SDK15" "$SDK26"; do
    test -d "$sdk" || { echo "verify: required SDK unavailable" >&2; exit 1; }
done

temporary="$(mktemp -d "${TMPDIR:-/tmp}/public-power-detail-verify.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
sources=("$ROOT"/Sources/PublicPowerDetail/*.swift)
test_source="$ROOT/Tests/PublicPowerDetailTests/PublicPowerDetailTests.swift"
frameworks=(-framework AppKit -framework CoreGraphics -framework IOKit)
common=(-I "$ROOT/Sources/CDarwinNotify" -swift-version 5 -warnings-as-errors -parse-as-library -target "$TARGET")

python3 "$ROOT/audit/verify.py" --binding-audit "$BINDING_AUDIT"

for sdk in "$SDK15" "$SDK26"; do
    for optimization in -Onone -O; do
        swiftc "${common[@]}" "$optimization" -typecheck -sdk "$sdk" \
            "${sources[@]}" "$test_source"
    done
done
echo "typecheck: pass (2 SDKs x 2 optimization modes, warnings as errors)"

for optimization in -Onone -O; do
    suffix="debug"
    test "$optimization" = "-O" && suffix="optimized"
    binary="$temporary/synthetic-$suffix"
    swiftc "${common[@]}" "$optimization" -sdk "$SDK26" \
        "${sources[@]}" "$test_source" "${frameworks[@]}" -o "$binary"
    "$binary"
done

link_probe="$temporary/no-live-link-probe"
swiftc "${common[@]}" -Onone -sdk "$SDK26" \
    "${sources[@]}" "$ROOT/audit/NoLiveLinkProbe.swift" \
    "${frameworks[@]}" -o "$link_probe"
python3 "$ROOT/audit/verify.py" --binding-audit "$BINDING_AUDIT" --binary "$link_probe"

python3 "$ROOT/audit/mutation_test.py" --sdk "$SDK26"

python3 "$ROOT/audit/source_only.py" --self-test "$ROOT"
python3 "$ROOT/audit/manifest.py" verify "$ROOT"

echo "verify: pass"
