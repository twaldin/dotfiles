#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
require_live_shape=${SKETCHYBAR_REQUIRE_LIVE_SHAPE:-0}
case "$require_live_shape" in 0|1) ;; *) echo "SKETCHYBAR_REQUIRE_LIVE_SHAPE must be 0 or 1" >&2; exit 1 ;; esac
host_arch=$(/usr/bin/uname -m)
host_macos_version=$(/usr/bin/sw_vers -productVersion)
"$root/scripts/secure-file-install.py" host-contract "$host_arch" "$host_macos_version"
bar_render=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/calendar-bar-render.png.XXXXXX")
cleanup() { /bin/rm -f "$bar_render"; }
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
/usr/bin/python3 "$root/tests/config-fingerprint.py" "$root"
PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/tests/config-fingerprint.py" "$root"
/usr/bin/python3 "$root/tests/unicode-grapheme-ranges-test.py" "$root/lib/unicode_grapheme_ranges.lua"
PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/tests/unicode-grapheme-ranges-test.py" "$root/lib/unicode_grapheme_ranges.lua"
/usr/bin/python3 "$root/tests/sharp-continuous-style-test.py" "$root"
PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/tests/sharp-continuous-style-test.py" "$root"
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
/opt/homebrew/bin/lua "$root/tests/audio-coordinator-test.lua"
/opt/homebrew/bin/lua "$root/tests/audio-items-test.lua"
/usr/bin/xcrun swiftc -typecheck "$root/tests/render-calendar-bar.swift"
for state in idle event-hover date-hover system-hover; do
  /usr/bin/xcrun swift "$root/tests/render-calendar-bar.swift" "$bar_render" "$state"
done
/usr/bin/python3 - "$bar_render" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
if not path.is_file() or path.stat().st_size <= 8 or path.read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
    raise SystemExit("Calendar bar synthetic renderer did not produce a PNG")
PY
/usr/bin/python3 "$root/tests/native-approved-artifacts-test.py"
if [ "$require_live_shape" = 1 ]; then
  if /opt/homebrew/bin/sketchybar --query calendar.event.bracket >/dev/null 2>&1 \
    && /opt/homebrew/bin/sketchybar --query calendar.date.bracket >/dev/null 2>&1 \
    && /opt/homebrew/bin/sketchybar --query system.bracket >/dev/null 2>&1 \
    && /opt/homebrew/bin/sketchybar --query calendar >/dev/null 2>&1 \
    && /opt/homebrew/bin/sketchybar --query release.probe >/dev/null 2>&1; then
    PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/tests/calendar-bar-runtime-shape.py"
  else
    echo "Calendar runtime shape required but content-redacted bar items are unavailable" >&2
    exit 1
  fi
else
  echo "Calendar runtime shape skipped: explicit live gate not requested"
fi
SKETCHYBAR_CONFIG_DIR="$root" /opt/homebrew/bin/lua "$root/tests/calendar-test.lua"
SKETCHYBAR_CONFIG_DIR="$root" /usr/bin/xcrun swift "$root/tests/calendar-bar-width.swift"
/usr/bin/xcrun swift "$root/tests/calendar-font-scalar-scan.swift" "$root"
SKETCHYBAR_CONFIG_DIR="$root" /opt/homebrew/bin/lua "$root/tests/hover-test.lua"
SKETCHYBAR_CONFIG_DIR="$root" /opt/homebrew/bin/lua "$root/tests/popup-test.lua"
SKETCHYBAR_CONFIG_DIR="$root" /opt/homebrew/bin/lua "$root/tests/calendar-bar-test.lua"
"$root/tests/calendar-query-timeout.sh"
SKETCHYBAR_CONFIG_DIR="$root" /opt/homebrew/bin/lua "$root/tests/load-smoke.lua"
