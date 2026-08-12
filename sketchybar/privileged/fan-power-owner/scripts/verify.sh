#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin
export PATH PYTHONDONTWRITEBYTECODE=1
ROOT=$(/bin/realpath "$(/usr/bin/dirname "$0")/..")
REPOSITORY=$(/bin/realpath "$ROOT/../../..")
uid=$(/usr/bin/id -u)
runtime_base_input=${TMPDIR:-}
[[ $runtime_base_input == /* ]] || { printf '%s\n' "fan/power verification requires a private TMPDIR" >&2; exit 64; }
runtime_base=$(cd -P -- "$runtime_base_input" 2>/dev/null && pwd -P) || exit 73
[[ -d $runtime_base && ! -L $runtime_base && $(/usr/bin/stat -f %u "$runtime_base") == "$uid" &&
   $(/usr/bin/stat -f %Lp "$runtime_base") == 700 ]] || exit 73
WORK=$(/usr/bin/mktemp -d "$runtime_base/fan-power-owner-verify.XXXXXX")
/bin/chmod 0700 "$WORK"
trap '/bin/rm -rf "$WORK"' EXIT
/bin/mkdir -m 0700 "$WORK/tmp"
export TMPDIR="$WORK/tmp"

[[ $ROOT == /Users/twaldin/dotfiles/sketchybar/privileged/fan-power-owner ]]
[[ ! -e "$ROOT/.build" && ! -e "$ROOT/.swiftpm" ]]
(cd "$ROOT" && /usr/bin/shasum -a 256 -c RELEASE-MANIFEST.sha256 >/dev/null)
/usr/bin/python3 "$ROOT/audit/source_audit.py"
/usr/bin/python3 "$ROOT/audit/mutation_test.py"
/usr/bin/python3 "$REPOSITORY/sketchybar/tests/fan-power-owner-release-test.py"
/bin/bash -n "$ROOT/install.sh"
/bin/sh -n "$REPOSITORY/sketchybar/scripts/fan-power-client.sh"
/usr/bin/plutil -lint "$ROOT/LaunchDaemon.plist" >/dev/null

/usr/bin/xcrun swift run --package-path "$ROOT" --scratch-path "$WORK/build"   fan-power-owner-self-tests
/usr/bin/xcrun swift build --package-path "$ROOT" --scratch-path "$WORK/build"   -c release --product fan-power-client
/usr/bin/xcrun swift build --package-path "$ROOT" --scratch-path "$WORK/build"   -c release --product fan-power-owner
/usr/bin/codesign --force --sign - --identifier com.twaldin.sketchybar.fan-power-client   --timestamp=none --options runtime "$WORK/build/release/fan-power-client" >/dev/null 2>&1
/usr/bin/codesign --force --sign - --identifier com.twaldin.sketchybar.fan-power-owner   --timestamp=none --options runtime "$WORK/build/release/fan-power-owner" >/dev/null 2>&1
/usr/bin/codesign --verify --strict "$WORK/build/release/fan-power-client"
/usr/bin/codesign --verify --strict "$WORK/build/release/fan-power-owner"

SKETCHYBAR_CONFIG_DIR="$REPOSITORY/sketchybar" /opt/homebrew/bin/lua   "$REPOSITORY/sketchybar/tests/fan-power-control-test.lua"
[[ ! -e "$ROOT/.build" && ! -e "$ROOT/.swiftpm" ]]
printf '%s\n' "fan/power owner non-installed release verification passed"
