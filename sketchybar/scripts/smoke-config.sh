#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
host_arch=$(/usr/bin/uname -m)
host_macos_version=$(/usr/bin/sw_vers -productVersion)
"$root/scripts/secure-file-install.py" host-contract "$host_arch" "$host_macos_version"
[ "$(/usr/bin/shasum -a 256 "$root/scripts/calendar-panel.swift" | /usr/bin/awk '{print $1}')" = 7fd04dc9e2d3fb4556dda41cd2aa5da38c2e2b622e74efc6be9a58cb0f812a72 ] || { echo "Immutable calendar source checksum failed" >&2; exit 1; }
bar_render=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/calendar-bar-render.png.XXXXXX")
native_build_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/calendar-native-build.XXXXXX")
cleanup() { /bin/rm -f "$bar_render"; /bin/rm -rf "$native_build_dir"; }
trap cleanup EXIT HUP INT TERM
case "$(/opt/homebrew/bin/lua -v 2>&1)" in "Lua 5.5."*) ;; *) echo "Lua 5.5.x is required" >&2; exit 1 ;; esac
case "$(/opt/homebrew/bin/luac -v 2>&1)" in "Lua 5.5."*) ;; *) echo "luac 5.5.x is required" >&2; exit 1 ;; esac
/usr/bin/python3 - "$root" <<'PY'
import ast
import pathlib
import sys
for path in pathlib.Path(sys.argv[1]).rglob('*.py'):
    if any(isinstance(node, ast.Assert) for node in ast.walk(ast.parse(path.read_text(), filename=str(path)))):
        raise SystemExit(f"Optimizable Python assertions are prohibited: {path}")
PY
find "$root" -type f -name '*.lua' -print | while IFS= read -r file; do /opt/homebrew/bin/luac -p "$file"; done
for file in "$root/sketchybarrc" "$root/install-deps.sh" "$root"/scripts/*.sh "$root"/tests/*.sh; do /bin/sh -n "$file"; done
/usr/bin/python3 "$root/tests/provider-runtime-test.py" "$root/scripts/provider-log.py" "$root/scripts/provider-launch.sh"
PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/tests/provider-runtime-test.py" "$root/scripts/provider-log.py" "$root/scripts/provider-launch.sh"
/usr/bin/python3 "$root/tests/sketchybarrc-runtime-test.py" "$root/sketchybarrc" "$root/scripts/provider-log.py" "$root/scripts/secure-file-install.py"
PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/tests/sketchybarrc-runtime-test.py" "$root/sketchybarrc" "$root/scripts/provider-log.py" "$root/scripts/secure-file-install.py"
/usr/bin/python3 "$root/tests/focus-space-test.py" "$root/scripts/focus-space.sh"
PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/tests/focus-space-test.py" "$root/scripts/focus-space.sh"
/usr/bin/python3 "$root/tests/yabai-window-guard-test.py" "$root/scripts/yabai-guard.py" "$root/scripts/focus-window.sh" "$root/scripts/yabai-windows.sh" "$root/items/front_window.lua"
PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/tests/yabai-window-guard-test.py" "$root/scripts/yabai-guard.py" "$root/scripts/focus-window.sh" "$root/scripts/yabai-windows.sh" "$root/items/front_window.lua"
/usr/bin/python3 "$root/tests/secure-file-install-test.py" "$root/scripts/secure-file-install.py" "$root/install-deps.sh"
PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/tests/secure-file-install-test.py" "$root/scripts/secure-file-install.py" "$root/install-deps.sh"
/usr/bin/python3 "$root/tests/system-controls-test.py" "$root/scripts/system-controls.swift"
PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/tests/system-controls-test.py" "$root/scripts/system-controls.swift"
/usr/bin/python3 "$root/tests/system-controls-install-test.py"
PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/tests/system-controls-install-test.py"
SKETCHYBAR_CONFIG_DIR="$root" /opt/homebrew/bin/lua "$root/tests/workspaces-test.lua"
SKETCHYBAR_CONFIG_DIR="$root" /opt/homebrew/bin/lua "$root/tests/text-test.lua"
SKETCHYBAR_CONFIG_DIR="$root" /opt/homebrew/bin/lua "$root/tests/window-pages-test.lua"
checked_binary="$native_build_dir/calendar-panel-arm64"
/usr/bin/xcrun swiftc -target arm64-apple-macosx15.0 -parse-as-library -typecheck "$root/scripts/calendar-panel.swift"
/usr/bin/xcrun swiftc -target arm64-apple-macosx15.0 -parse-as-library -O "$root/scripts/calendar-panel.swift" -o "$checked_binary"
[ "$(/usr/bin/lipo -archs "$checked_binary")" = arm64 ] || { echo "Calendar helper build architecture mismatch" >&2; exit 1; }
"$root/tests/calendar-panel-offline.sh"
/usr/bin/python3 "$root/tests/calendar-install-contract.py" "$root/install-deps.sh"
PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/tests/calendar-install-contract.py" "$root/install-deps.sh"
/usr/bin/xcrun swiftc -typecheck "$root/tests/render-calendar-bar.swift"
/usr/bin/xcrun swift "$root/tests/render-calendar-bar.swift" "$bar_render"
/usr/bin/python3 - "$bar_render" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
if not path.is_file() or path.stat().st_size <= 8 or path.read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
    raise SystemExit("Calendar bar synthetic renderer did not produce a PNG")
PY
if /usr/bin/grep -q 'calendar.next' "$root/tests/calendar-bar-runtime-shape.py"; then
  echo "Runtime shape probe must not query live event content" >&2
  exit 1
fi
if /opt/homebrew/bin/sketchybar --query calendar.bracket >/dev/null 2>&1 && /opt/homebrew/bin/sketchybar --query calendar >/dev/null 2>&1; then
  PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/tests/calendar-bar-runtime-shape.py"
else
  echo "Calendar runtime shape skipped: content-free bar items unavailable"
fi
SKETCHYBAR_CONFIG_DIR="$root" /opt/homebrew/bin/lua "$root/tests/calendar-test.lua"
/usr/bin/xcrun swift "$root/tests/calendar-bar-width.swift"
SKETCHYBAR_CONFIG_DIR="$root" /opt/homebrew/bin/lua "$root/tests/calendar-bar-test.lua"
"$root/tests/calendar-query-timeout.sh"
SKETCHYBAR_CONFIG_DIR="$root" /opt/homebrew/bin/lua "$root/tests/load-smoke.lua"
