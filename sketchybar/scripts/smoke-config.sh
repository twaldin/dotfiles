#!/bin/sh
set -eu
export PYTHONDONTWRITEBYTECODE=1
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
uid=$(/usr/bin/id -u)
runtime_base_input=${TMPDIR:-}
case "$runtime_base_input" in /*) ;; *) echo "Smoke gate requires macOS per-user TMPDIR (exit 64)" >&2; exit 64 ;; esac
runtime_base=$(CDPATH='' cd -P -- "$runtime_base_input" 2>/dev/null && pwd -P) || { echo "Smoke gate requires a safe per-user TMPDIR (exit 73)" >&2; exit 73; }
[ -d "$runtime_base" ] && [ ! -L "$runtime_base" ]   && [ "$(/usr/bin/stat -f %u "$runtime_base")" = "$uid" ]   && [ "$(/usr/bin/stat -f %Lp "$runtime_base")" = 700 ]   || { echo "Smoke gate requires a safe per-user TMPDIR (exit 73)" >&2; exit 73; }
require_live_shape=${SKETCHYBAR_REQUIRE_LIVE_SHAPE:-0}
case "$require_live_shape" in 0|1) ;; *) echo "SKETCHYBAR_REQUIRE_LIVE_SHAPE must be 0 or 1" >&2; exit 1 ;; esac
host_arch=$(/usr/bin/uname -m)
host_macos_version=$(/usr/bin/sw_vers -productVersion)
"$root/scripts/secure-file-install.py" host-contract "$host_arch" "$host_macos_version"
yabai="$HOME/Applications/Yabai.app/Contents/MacOS/yabai"
[ -x "$yabai" ] || { echo "Yabai is required at the documented user-app path" >&2; exit 69; }
[ "$("$yabai" --version)" = "yabai-v7.1.25" ] || { echo "Yabai 7.1.25 is required" >&2; exit 69; }
/usr/bin/codesign --verify --deep --strict "$HOME/Applications/Yabai.app" >/dev/null 2>&1 || { echo "Yabai code signature is invalid" >&2; exit 69; }
bar_render=$(/usr/bin/mktemp "$runtime_base/calendar-bar-render.png.XXXXXX")
cleanup() { /bin/rm -f "$bar_render"; }
trap cleanup EXIT HUP INT TERM
case "$(/opt/homebrew/bin/lua -v 2>&1)" in "Lua 5.5."*) ;; *) echo "Lua 5.5.x is required" >&2; exit 1 ;; esac
case "$(/opt/homebrew/bin/luac -v 2>&1)" in "Lua 5.5."*) ;; *) echo "luac 5.5.x is required" >&2; exit 1 ;; esac
/usr/bin/python3 - "$root" <<'PY'
import ast
import pathlib
import re
import sys
repository = pathlib.Path(sys.argv[1])
approved_native_vendor = repository / 'native' / 'vendor'
production_paths = {repository / 'sketchybarrc', repository / 'install-deps.sh'}
for directory in (repository / 'scripts', repository / 'providers' / 'public-stats'):
    production_paths.update(path for path in directory.rglob('*')
                            if path.is_file() and path.suffix in {'.sh', '.py', '.swift'})
shared_root = '/' + 'tmp'
shell_default = re.compile(r'\$\{TMPDIR(?::-|-|:=)' + re.escape(shared_root) + r'\}')
for path in sorted(production_paths):
    try:
        text = path.read_text()
    except (OSError, UnicodeDecodeError):
        raise SystemExit("production temporary-path source is unreadable")
    if (shared_root + '/') in text or shell_default.search(text):
        raise SystemExit("production source contains a shared temporary path")
    if ('tempfile.' + 'gettempdir') in text or 'NSTemporary' + 'Directory' in text:
        raise SystemExit("production source uses an implicit temporary directory")
    if path.suffix == '.py':
        try:
            tree = ast.parse(text)
        except SyntaxError:
            raise SystemExit("production Python source cannot be parsed")
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Attribute):
                continue
            if (isinstance(node.func.value, ast.Name)
                    and node.func.value.id == 'tempfile'
                    and node.func.attr in {'mkstemp', 'mkdtemp', 'NamedTemporaryFile', 'TemporaryDirectory'}
                    and not any(keyword.arg == 'dir' for keyword in node.keywords)):
                raise SystemExit("production Python temporary creation requires an explicit private directory")
required_shell_preflights = {
    repository / 'sketchybarrc',
    repository / 'install-deps.sh',
    repository / 'scripts/provider-launch.sh',
    repository / 'scripts/smoke-config.sh',
}
for path in required_shell_preflights:
    text = path.read_text()
    if ('runtime_base_input=${TMPDIR:-}' not in text
            or 'stat -f %u "$runtime_base"' not in text
            or 'stat -f %Lp "$runtime_base"' not in text):
        raise SystemExit("production shell entrypoint lacks the private TMPDIR preflight")
for path in repository.rglob('*.py'):
    if approved_native_vendor in path.parents:
        continue
    try:
        tree = ast.parse(path.read_text())
    except (OSError, UnicodeDecodeError, SyntaxError):
        raise SystemExit("Python assertion source cannot be parsed")
    if any(isinstance(node, ast.Assert) for node in ast.walk(tree)):
        raise SystemExit("Optimizable Python assertions are prohibited")
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
"$root/providers/public-stats/run-tests.sh"
"$root/providers/public-stats/audit-public-stats.sh"
/usr/bin/python3 "$root/tests/sketchybarrc-runtime-test.py" "$root/sketchybarrc" "$root/scripts/provider-log.py" "$root/scripts/secure-file-install.py"
PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/tests/sketchybarrc-runtime-test.py" "$root/sketchybarrc" "$root/scripts/provider-log.py" "$root/scripts/secure-file-install.py"
/usr/bin/python3 "$root/tests/focus-space-test.py" "$root/scripts/focus-space.sh"
PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/tests/focus-space-test.py" "$root/scripts/focus-space.sh"
/usr/bin/python3 "$root/tests/yabai-window-guard-test.py" "$root/scripts/yabai-guard.py" "$root/scripts/focus-window.sh" "$root/scripts/yabai-windows.sh" "$root/items/front_window.lua"
PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/tests/yabai-window-guard-test.py" "$root/scripts/yabai-guard.py" "$root/scripts/focus-window.sh" "$root/scripts/yabai-windows.sh" "$root/items/front_window.lua"
/usr/bin/python3 "$root/tests/secure-file-install-test.py" "$root/scripts/secure-file-install.py" "$root/install-deps.sh"
PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/tests/secure-file-install-test.py" "$root/scripts/secure-file-install.py" "$root/install-deps.sh"
/usr/bin/python3 "$root/tests/settings-handoff-test.py"
PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/tests/settings-handoff-test.py"
/usr/bin/python3 "$root/tests/system-controls-test.py" "$root/scripts/system-controls.swift"
PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/tests/system-controls-test.py" "$root/scripts/system-controls.swift"
/usr/bin/python3 "$root/tests/system-controls-install-test.py"
PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/tests/system-controls-install-test.py"
SKETCHYBAR_CONFIG_DIR="$root" /opt/homebrew/bin/lua "$root/tests/workspaces-test.lua"
SKETCHYBAR_CONFIG_DIR="$root" /opt/homebrew/bin/lua "$root/tests/stats-contract-test.lua"
SKETCHYBAR_CONFIG_DIR="$root" /opt/homebrew/bin/lua "$root/tests/stats-items-test.lua"
/usr/bin/python3 "$root/tests/left-layout-test.py"
PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/tests/left-layout-test.py"
/usr/bin/python3 "$root/tests/right-layout-test.py"
PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/tests/right-layout-test.py"
/usr/bin/python3 "$root/tests/spacing-language-test.py"
PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/tests/spacing-language-test.py"
/usr/bin/python3 "$root/../yabai/tests/yabairc-test.py"
PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/../yabai/tests/yabairc-test.py"
/usr/bin/python3 "$root/tests/yabai-runtime-contract-test.py"
PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/tests/yabai-runtime-contract-test.py"
/usr/bin/python3 "$root/tests/front-window-test.py"
PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/tests/front-window-test.py"
/usr/bin/python3 "$root/tests/connectivity-controls-test.py"
PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/tests/connectivity-controls-test.py"
SKETCHYBAR_CONFIG_DIR="$root" /opt/homebrew/bin/lua "$root/tests/connectivity-items-test.lua"
/usr/bin/python3 "$root/tests/audio-state-test.py"
PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/tests/audio-state-test.py"
/usr/bin/python3 "$root/tests/battery-state-test.py"
PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/tests/battery-state-test.py"
/usr/bin/python3 "$root/tests/battery-privacy-quarantine-test.py"
PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/tests/battery-privacy-quarantine-test.py"
/usr/bin/python3 "$root/tests/display-state-test.py"
PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/tests/display-state-test.py"
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
/usr/bin/python3 "$root/tests/popup-grid-test.py"
PYTHONOPTIMIZE=1 /usr/bin/python3 "$root/tests/popup-grid-test.py"
SKETCHYBAR_CONFIG_DIR="$root" /opt/homebrew/bin/lua "$root/tests/calendar-bar-test.lua"
"$root/tests/calendar-query-timeout.sh"
SKETCHYBAR_CONFIG_DIR="$root" /opt/homebrew/bin/lua "$root/tests/load-smoke.lua"
