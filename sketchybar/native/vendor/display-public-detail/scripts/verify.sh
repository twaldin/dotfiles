#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SDK15=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
SDK26=/Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk
TARGET=arm64-apple-macos15.0
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/display-public-detail-verify.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM

set -- "$ROOT"/Sources/*.swift

xcrun swiftc -sdk "$SDK15" -target "$TARGET" -warnings-as-errors -Onone -typecheck "$@"
xcrun swiftc -sdk "$SDK15" -target "$TARGET" -warnings-as-errors -O -typecheck "$@"
xcrun swiftc -sdk "$SDK26" -target "$TARGET" -D DISPLAY_SDK_26 -warnings-as-errors -Onone -typecheck "$@"
xcrun swiftc -sdk "$SDK26" -target "$TARGET" -D DISPLAY_SDK_26 -warnings-as-errors -O -typecheck "$@"

xcrun swiftc -sdk "$SDK26" -target "$TARGET" -D DISPLAY_SDK_26 -warnings-as-errors -Onone \
  -o "$BUILD/tests-debug" "$@" "$ROOT/Tests/main.swift"
"$BUILD/tests-debug"

xcrun swiftc -sdk "$SDK26" -target "$TARGET" -D DISPLAY_SDK_26 -warnings-as-errors -O \
  -o "$BUILD/tests-optimized" "$@" "$ROOT/Tests/main.swift"
"$BUILD/tests-optimized"

LINKS=$(otool -L "$BUILD/tests-optimized")
printf '%s\n' "$LINKS"
if printf '%s\n' "$LINKS" | grep -E '/(IOKit|ScreenCaptureKit|AVFoundation|SkyLight)\.framework/|BetterDisplay\.app/' >/dev/null; then
  echo "FAIL: prohibited linked framework" >&2
  exit 1
fi
for framework in AppKit ColorSync CoreGraphics Foundation; do
  if ! printf '%s\n' "$LINKS" | grep "/$framework.framework/" >/dev/null; then
    echo "FAIL: expected public framework is not linked: $framework" >&2
    exit 1
  fi
done

python3 "$ROOT/scripts/policy_audit.py"

if find "$ROOT" -type f \( -name '*.o' -o -name '*.swiftmodule' -o -perm -111 \) \
  ! -path "$ROOT/scripts/verify.sh" ! -path "$ROOT/scripts/policy_audit.py" | grep . >/dev/null; then
  echo "FAIL: source tree contains a build artifact or unexpected executable" >&2
  exit 1
fi

echo "PASS all verification gates"
