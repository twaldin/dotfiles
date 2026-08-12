#!/bin/sh
set -eu
umask 077

SBARLUA_COMMIT=dba9cc421b868c918d5c23c408544a28aadf2f2f
SBARLUA_LEGACY_SHA256=53d7169806ba874f36b0f2f8128f3ad7c929ce969d40ef65ee23eb5cf0206c60
SBARLUA_DIR="$HOME/.local/share/sketchybar_lua"
CONFIG_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
SECURE_INSTALLER="$CONFIG_DIR/scripts/secure-file-install.py"
SYSTEM_CONTROLS_HELPER_DIR="$HOME/.local/share/sketchybar-controls"
SYSTEM_CONTROLS_SOURCE="$CONFIG_DIR/scripts/system-controls.swift"
SYSTEM_CONTROLS_SOURCE_SHA256=616ddedb9f89c0b0caa5fdf4aadb542c9411701855026fce2b57cbbbd29c2b45
AUDIO_COORDINATOR_SOURCE="$CONFIG_DIR/scripts/audio-state.py"
AUDIO_COORDINATOR_SOURCE_SHA256=ea5dd5631a3d9c3d23313dba1da08703c1edebe5667567c8e3b43f63986d4021
HARDWARE_METRICS_DIR="$HOME/.local/share/sketchybar-hardware"
HARDWARE_METRICS_BINARY="$HARDWARE_METRICS_DIR/hardware-metrics"
HARDWARE_METRICS_MARKER="$HARDWARE_METRICS_DIR/SOURCE_SHA256"
HARDWARE_METRICS_SOURCE="$CONFIG_DIR/scripts/hardware-metrics.swift"
HARDWARE_METRICS_SOURCE_SHA256=f1ba601e09a759dfce3c5802b6a469d5cf1acdb75da38b9c3c23c640f4d032aa
HARDWARE_METRICS_BRIDGE="$CONFIG_DIR/scripts/hardware-metrics-bridge.h"
HARDWARE_METRICS_BRIDGE_SHA256=cbc25b518590636f4594456f8ce9ed8037bd74dfbcfb804a7cdcd70801670e70
DISPLAY_CONTROL_DIR="$HOME/.local/share/sketchybar-display"
DISPLAY_CONTROL_BINARY="$DISPLAY_CONTROL_DIR/betterdisplay-control"
DISPLAY_CONTROL_MARKER="$DISPLAY_CONTROL_DIR/SOURCE_SHA256"
DISPLAY_CONTROL_SOURCE="$CONFIG_DIR/scripts/betterdisplay-control.swift"
DISPLAY_CONTROL_SOURCE_SHA256=e9cab6d9f619f1d76747112482b916ec42ddf7f44cc3ded003cd7a3fd270875b

uid=$(/usr/bin/id -u)
runtime_base_input=${TMPDIR:-}
case "$runtime_base_input" in /*) ;; *) echo "Installer requires macOS per-user TMPDIR (exit 64)" >&2; exit 64 ;; esac
runtime_base=$(CDPATH='' cd -P -- "$runtime_base_input" 2>/dev/null && pwd -P) || { echo "Installer requires a safe per-user TMPDIR (exit 73)" >&2; exit 73; }
[ -d "$runtime_base" ] && [ ! -L "$runtime_base" ]   && [ "$(/usr/bin/stat -f %u "$runtime_base")" = "$uid" ]   && [ "$(/usr/bin/stat -f %Lp "$runtime_base")" = 700 ]   || { echo "Installer requires a safe per-user TMPDIR (exit 73)" >&2; exit 73; }

command -v /opt/homebrew/bin/brew >/dev/null 2>&1 || { echo "Homebrew is required at /opt/homebrew/bin/brew" >&2; exit 69; }
PUBLIC_STATS_DIR="$CONFIG_DIR/providers/public-stats"
PUBLIC_STATS_BINARY="$HOME/.local/share/sketchybar-provider/sketchybar-public-stats"
host_arch=$(/usr/bin/uname -m)
host_macos_version=$(/usr/bin/sw_vers -productVersion)
"$SECURE_INSTALLER" host-contract "$host_arch" "$host_macos_version"
check_native_source_pins() {
  [ "$(/usr/bin/shasum -a 256 "$HARDWARE_METRICS_SOURCE" | /usr/bin/awk '{print $1}')" = "$HARDWARE_METRICS_SOURCE_SHA256" ] || { echo "Immutable hardware metrics source checksum failed" >&2; exit 1; }
  [ "$(/usr/bin/shasum -a 256 "$HARDWARE_METRICS_BRIDGE" | /usr/bin/awk '{print $1}')" = "$HARDWARE_METRICS_BRIDGE_SHA256" ] || { echo "Immutable hardware bridge source checksum failed" >&2; exit 1; }
  [ "$(/usr/bin/shasum -a 256 "$DISPLAY_CONTROL_SOURCE" | /usr/bin/awk '{print $1}')" = "$DISPLAY_CONTROL_SOURCE_SHA256" ] || { echo "Immutable display control source checksum failed" >&2; exit 1; }
}
check_native_source_pins
/usr/bin/python3 "$CONFIG_DIR/tests/config-fingerprint.py" "$CONFIG_DIR"
[ "$(/usr/bin/shasum -a 256 "$SYSTEM_CONTROLS_SOURCE" | /usr/bin/awk '{print $1}')" = "$SYSTEM_CONTROLS_SOURCE_SHA256" ] || { echo "Immutable system controls source checksum failed" >&2; exit 1; }
[ "$(/usr/bin/shasum -a 256 "$AUDIO_COORDINATOR_SOURCE" | /usr/bin/awk '{print $1}')" = "$AUDIO_COORDINATOR_SOURCE_SHA256" ] || { echo "Immutable audio coordinator source checksum failed" >&2; exit 1; }
/opt/homebrew/bin/brew install lua ical-buddy

# The pinned app-font assets must exist before the smoke gate: lib/icons.lua and
# the workspaces test read icon_map.lua, so a fresh host cannot pass the gate
# without them. Both installs are exact-hash checked and idempotent.

install_asset() {
  url=$1
  expected=$2
  destination=$3
  "$SECURE_INSTALLER" prepare-asset "$destination"
  actual=""
  if [ -r "$destination" ]; then actual=$(/usr/bin/shasum -a 256 "$destination" | /usr/bin/awk '{print $1}'); fi
  [ "$actual" = "$expected" ] && return 0
  temporary=$(/usr/bin/mktemp "$runtime_base/sketchybar-asset.XXXXXX")
  /usr/bin/curl --fail --location --proto '=https' --tlsv1.2 --output "$temporary" "$url"
  downloaded=$(/usr/bin/shasum -a 256 "$temporary" | /usr/bin/awk '{print $1}')
  [ "$downloaded" = "$expected" ] || { /bin/rm -f "$temporary"; echo "Checksum failed for $url" >&2; exit 1; }
  "$SECURE_INSTALLER" asset "$temporary" "$destination"
  /bin/rm -f "$temporary"
}

install_asset \
  "https://github.com/kvndrsslr/sketchybar-app-font/releases/download/v2.0.71/icon_map.lua" \
  "adbdd97d5137846babb2584de701f341541402bb2e1478d1ae031e07cc5e060c" \
  "$HOME/.local/share/sketchybar-app-font/icon_map.lua"
install_asset \
  "https://github.com/kvndrsslr/sketchybar-app-font/releases/download/v2.0.71/sketchybar-app-font.ttf" \
  "e015c40fbe95d85763b633eae54f7b8e1ded83cffbc15aff40b8b8f89717a0b1" \
  "$HOME/Library/Fonts/sketchybar-app-font.ttf"

# The pinned SbarLua module must also precede the gate: the Lua load/event
# smoke test requires the installed module on a fresh host.

if ! "$SECURE_INSTALLER" prepare-sbarlua "$SBARLUA_DIR" "$SBARLUA_COMMIT" "$SBARLUA_LEGACY_SHA256"; then
  work=$(/usr/bin/mktemp -d "$runtime_base/SbarLua.XXXXXX")
  sbarlua_build_cleanup() { /bin/rm -rf "$work"; }
  trap sbarlua_build_cleanup EXIT
  trap 'trap - EXIT HUP INT TERM; sbarlua_build_cleanup; exit 129' HUP
  trap 'trap - EXIT HUP INT TERM; sbarlua_build_cleanup; exit 130' INT
  trap 'trap - EXIT HUP INT TERM; sbarlua_build_cleanup; exit 143' TERM
  stage_home="$work/stage-home"
  /bin/mkdir -m 0700 "$stage_home"
  /usr/bin/git clone --filter=blob:none https://github.com/FelixKratz/SbarLua.git "$work/SbarLua"
  /usr/bin/git -C "$work/SbarLua" checkout --detach "$SBARLUA_COMMIT"
  [ "$(/usr/bin/git -C "$work/SbarLua" rev-parse HEAD)" = "$SBARLUA_COMMIT" ]
  HOME="$stage_home" /usr/bin/make -C "$work/SbarLua" install
  "$SECURE_INSTALLER" sbarlua "$stage_home/.local/share/sketchybar_lua/sketchybar.so" "$SBARLUA_COMMIT" "$SBARLUA_DIR"
  /bin/rm -rf "$work"
  trap - EXIT HUP INT TERM
fi

# Gate the complete immutable source tree before any release helper is published.
# Each later native build is self-tested again and each publication is transactional.
"$CONFIG_DIR/scripts/smoke-config.sh"

public_stats_build=$(/usr/bin/mktemp -d "$runtime_base/sketchybar-public-stats-build.XXXXXX")
public_stats_build_cleanup() { /bin/rm -rf "$public_stats_build"; }
trap public_stats_build_cleanup EXIT
trap 'trap - EXIT HUP INT TERM; public_stats_build_cleanup; exit 129' HUP
trap 'trap - EXIT HUP INT TERM; public_stats_build_cleanup; exit 130' INT
trap 'trap - EXIT HUP INT TERM; public_stats_build_cleanup; exit 143' TERM
/usr/bin/swift build -c release --package-path "$PUBLIC_STATS_DIR" --scratch-path "$public_stats_build"
public_stats_candidate="$public_stats_build/release/sketchybar-public-stats"
public_stats_candidate_sha256=$(/usr/bin/shasum -a 256 "$public_stats_candidate" | /usr/bin/awk '{print $1}')
"$public_stats_candidate" --self-test
[ "$(/usr/bin/shasum -a 256 "$public_stats_candidate" | /usr/bin/awk '{print $1}')" = "$public_stats_candidate_sha256" ] || { echo "Public stats candidate changed after self-test" >&2; exit 75; }
"$SECURE_INSTALLER" executable "$public_stats_candidate" "$PUBLIC_STATS_BINARY" "$public_stats_candidate_sha256" --self-test
[ "$(/usr/bin/shasum -a 256 "$PUBLIC_STATS_BINARY" | /usr/bin/awk '{print $1}')" = "$public_stats_candidate_sha256" ] || { echo "Installed public stats checksum mismatch" >&2; exit 75; }
public_stats_build_cleanup
trap - EXIT HUP INT TERM

hardware_build=$(/usr/bin/mktemp -d "$runtime_base/sketchybar-hardware-build.XXXXXX")
hardware_snapshot_dir="$hardware_build/source"
hardware_build_cleanup() { [ ! -d "$hardware_snapshot_dir" ] || /bin/chmod 0700 "$hardware_snapshot_dir"; /bin/rm -rf "$hardware_build"; }
trap hardware_build_cleanup EXIT
trap 'trap - EXIT HUP INT TERM; hardware_build_cleanup; exit 129' HUP
trap 'trap - EXIT HUP INT TERM; hardware_build_cleanup; exit 130' INT
trap 'trap - EXIT HUP INT TERM; hardware_build_cleanup; exit 143' TERM
/bin/mkdir -m 0700 "$hardware_snapshot_dir"
hardware_source_snapshot="$hardware_snapshot_dir/hardware-metrics.swift"
hardware_bridge_snapshot="$hardware_snapshot_dir/hardware-metrics-bridge.h"
"$SECURE_INSTALLER" asset "$HARDWARE_METRICS_SOURCE" "$hardware_source_snapshot"
"$SECURE_INSTALLER" asset "$HARDWARE_METRICS_BRIDGE" "$hardware_bridge_snapshot"
[ "$(/usr/bin/shasum -a 256 "$hardware_source_snapshot" | /usr/bin/awk '{print $1}')" = "$HARDWARE_METRICS_SOURCE_SHA256" ] || { echo "Hardware source snapshot checksum failed" >&2; exit 1; }
[ "$(/usr/bin/shasum -a 256 "$hardware_bridge_snapshot" | /usr/bin/awk '{print $1}')" = "$HARDWARE_METRICS_BRIDGE_SHA256" ] || { echo "Hardware bridge snapshot checksum failed" >&2; exit 1; }
/bin/chmod 0444 "$hardware_source_snapshot" "$hardware_bridge_snapshot"
/bin/chmod 0500 "$hardware_snapshot_dir"
hardware_candidate="$hardware_build/hardware-metrics"
/usr/bin/xcrun swiftc -target arm64-apple-macosx15.0 -parse-as-library -O -warnings-as-errors   -import-objc-header "$hardware_bridge_snapshot" -lIOReport   "$hardware_source_snapshot" -o "$hardware_candidate"
[ "$(/usr/bin/shasum -a 256 "$hardware_source_snapshot" | /usr/bin/awk '{print $1}')" = "$HARDWARE_METRICS_SOURCE_SHA256" ] || { echo "Hardware source snapshot changed during compilation" >&2; exit 1; }
[ "$(/usr/bin/shasum -a 256 "$hardware_bridge_snapshot" | /usr/bin/awk '{print $1}')" = "$HARDWARE_METRICS_BRIDGE_SHA256" ] || { echo "Hardware bridge snapshot changed during compilation" >&2; exit 1; }
/bin/chmod 0755 "$hardware_candidate"
hardware_binary_sha256=$(/usr/bin/shasum -a 256 "$hardware_candidate" | /usr/bin/awk '{print $1}')
hardware_marker_candidate="$hardware_build/SOURCE_SHA256"
{
  printf '%s\n' 'version=2'
  printf 'swift_sha256=%s\n' "$HARDWARE_METRICS_SOURCE_SHA256"
  printf 'bridge_sha256=%s\n' "$HARDWARE_METRICS_BRIDGE_SHA256"
  printf '%s\n' 'target=arm64-apple-macosx15.0' 'build_mode=-O'
  printf 'binary_sha256=%s\n' "$hardware_binary_sha256"
} >"$hardware_marker_candidate"
/bin/chmod 0644 "$hardware_marker_candidate"
hardware_marker_sha256=$(/usr/bin/shasum -a 256 "$hardware_marker_candidate" | /usr/bin/awk '{print $1}')
"$SECURE_INSTALLER" native-pair "$hardware_candidate" "$hardware_marker_candidate" \
  "$HARDWARE_METRICS_BINARY" "$HARDWARE_METRICS_MARKER" \
  "$hardware_binary_sha256" "$hardware_marker_sha256" --hardware \
  "$HARDWARE_METRICS_SOURCE_SHA256" "$HARDWARE_METRICS_BRIDGE_SHA256"
hardware_build_cleanup
trap - EXIT HUP INT TERM

display_control_build=$(/usr/bin/mktemp -d "$runtime_base/sketchybar-display-control-build.XXXXXX")
display_control_snapshot_dir="$display_control_build/source"
display_control_build_cleanup() { [ ! -d "$display_control_snapshot_dir" ] || /bin/chmod 0700 "$display_control_snapshot_dir"; /bin/rm -rf "$display_control_build"; }
trap display_control_build_cleanup EXIT
trap 'trap - EXIT HUP INT TERM; display_control_build_cleanup; exit 129' HUP
trap 'trap - EXIT HUP INT TERM; display_control_build_cleanup; exit 130' INT
trap 'trap - EXIT HUP INT TERM; display_control_build_cleanup; exit 143' TERM
/bin/mkdir -m 0700 "$display_control_snapshot_dir"
display_control_source_snapshot="$display_control_snapshot_dir/betterdisplay-control.swift"
"$SECURE_INSTALLER" asset "$DISPLAY_CONTROL_SOURCE" "$display_control_source_snapshot"
[ "$(/usr/bin/shasum -a 256 "$display_control_source_snapshot" | /usr/bin/awk '{print $1}')" = "$DISPLAY_CONTROL_SOURCE_SHA256" ] || { echo "Display control source snapshot checksum failed" >&2; exit 1; }
/bin/chmod 0444 "$display_control_source_snapshot"
/bin/chmod 0500 "$display_control_snapshot_dir"
display_control_candidate="$display_control_build/betterdisplay-control"
/usr/bin/xcrun swiftc -target arm64-apple-macosx15.0 -O -warnings-as-errors   "$display_control_source_snapshot" -o "$display_control_candidate"
[ "$(/usr/bin/shasum -a 256 "$display_control_source_snapshot" | /usr/bin/awk '{print $1}')" = "$DISPLAY_CONTROL_SOURCE_SHA256" ] || { echo "Display control source snapshot changed during compilation" >&2; exit 1; }
/bin/chmod 0755 "$display_control_candidate"
display_control_binary_sha256=$(/usr/bin/shasum -a 256 "$display_control_candidate" | /usr/bin/awk '{print $1}')
display_control_marker_candidate="$display_control_build/SOURCE_SHA256"
{
  printf '%s\n' 'version=2'
  printf 'source_sha256=%s\n' "$DISPLAY_CONTROL_SOURCE_SHA256"
  printf '%s\n' 'target=arm64-apple-macosx15.0' 'build_mode=-O'
  printf 'binary_sha256=%s\n' "$display_control_binary_sha256"
} >"$display_control_marker_candidate"
/bin/chmod 0644 "$display_control_marker_candidate"
display_control_marker_sha256=$(/usr/bin/shasum -a 256 "$display_control_marker_candidate" | /usr/bin/awk '{print $1}')
"$SECURE_INSTALLER" native-pair "$display_control_candidate" "$display_control_marker_candidate" \
  "$DISPLAY_CONTROL_BINARY" "$DISPLAY_CONTROL_MARKER" \
  "$display_control_binary_sha256" "$display_control_marker_sha256" --display \
  "$DISPLAY_CONTROL_SOURCE_SHA256"
display_control_build_cleanup
trap - EXIT HUP INT TERM

lua_version=$(/opt/homebrew/bin/lua -v 2>&1)
case "$lua_version" in "Lua 5.5"*) ;; *) echo "Lua 5.5 is required; found: $lua_version" >&2; exit 1 ;; esac

/bin/mkdir -p "$SYSTEM_CONTROLS_HELPER_DIR"
[ -d "$SYSTEM_CONTROLS_HELPER_DIR" ] && [ ! -L "$SYSTEM_CONTROLS_HELPER_DIR" ] && [ "$(/usr/bin/stat -f %u "$SYSTEM_CONTROLS_HELPER_DIR")" = "$(/usr/bin/id -u)" ] && [ "$(/usr/bin/stat -f %Lp "$SYSTEM_CONTROLS_HELPER_DIR")" = 700 ] || { echo "System controls helper directory is not an owned mode-0700 real directory" >&2; exit 1; }
controls_directory_logical=$(CDPATH='' cd -L -- "$SYSTEM_CONTROLS_HELPER_DIR" && pwd -L)
controls_directory_physical=$(CDPATH='' cd -P -- "$SYSTEM_CONTROLS_HELPER_DIR" && pwd -P)
[ "$controls_directory_logical" = "$controls_directory_physical" ] || { echo "System controls helper directory is not canonical" >&2; exit 1; }
controls_binary="$SYSTEM_CONTROLS_HELPER_DIR/system-controls"
controls_marker="$SYSTEM_CONTROLS_HELPER_DIR/SOURCE_SHA256"
if [ -e "$controls_binary" ] || [ -L "$controls_binary" ]; then
  [ -f "$controls_binary" ] && [ ! -L "$controls_binary" ] && [ "$(/usr/bin/stat -f %u "$controls_binary")" = "$(/usr/bin/id -u)" ] && [ "$(/usr/bin/stat -f %l "$controls_binary")" = 1 ] && [ "$(/usr/bin/stat -f %Lp "$controls_binary")" = 755 ] || { echo "Existing system controls helper is unsafe" >&2; exit 1; }
fi
if [ -e "$controls_marker" ] || [ -L "$controls_marker" ]; then
  [ -f "$controls_marker" ] && [ ! -L "$controls_marker" ] && [ "$(/usr/bin/stat -f %u "$controls_marker")" = "$(/usr/bin/id -u)" ] && [ "$(/usr/bin/stat -f %l "$controls_marker")" = 1 ] && [ "$(/usr/bin/stat -f %Lp "$controls_marker")" = 644 ] || { echo "Existing system controls marker is unsafe" >&2; exit 1; }
fi
controls_install_valid=false
if [ -f "$controls_binary" ] && [ -f "$controls_marker" ]; then
  if "$SECURE_INSTALLER" system-controls-provenance "$controls_binary" "$controls_marker" "$SYSTEM_CONTROLS_SOURCE_SHA256"; then controls_install_valid=true
  else controls_provenance_status=$?; [ "$controls_provenance_status" -eq 75 ] || exit "$controls_provenance_status"
  fi
fi
if [ "$controls_install_valid" != true ]; then
  controls_build=$(/usr/bin/mktemp -d "$runtime_base/sketchybar-system-controls-build.XXXXXX")
  controls_snapshot_dir="$controls_build/source"
  controls_candidate=
  controls_marker_candidate=
  controls_fixture_debug=
  controls_fixture_optimized=
  controls_install_cleanup() {
    [ -z "$controls_candidate" ] || /bin/rm -f "$controls_candidate"
    [ -z "$controls_marker_candidate" ] || /bin/rm -f "$controls_marker_candidate"
    [ -z "$controls_fixture_debug" ] || /bin/rm -f "$controls_fixture_debug"
    [ -z "$controls_fixture_optimized" ] || /bin/rm -f "$controls_fixture_optimized"
    [ ! -d "$controls_snapshot_dir" ] || /bin/chmod 0700 "$controls_snapshot_dir"
    /bin/rm -rf "$controls_build"
  }
  trap controls_install_cleanup EXIT
  trap 'trap - EXIT HUP INT TERM; controls_install_cleanup; exit 129' HUP
  trap 'trap - EXIT HUP INT TERM; controls_install_cleanup; exit 130' INT
  trap 'trap - EXIT HUP INT TERM; controls_install_cleanup; exit 143' TERM
  /bin/mkdir -m 0700 "$controls_snapshot_dir"
  controls_source_snapshot="$controls_snapshot_dir/system-controls.swift"
  "$SECURE_INSTALLER" asset "$SYSTEM_CONTROLS_SOURCE" "$controls_source_snapshot"
  [ "$(/usr/bin/shasum -a 256 "$controls_source_snapshot" | /usr/bin/awk '{print $1}')" = "$SYSTEM_CONTROLS_SOURCE_SHA256" ] || { echo "System controls source snapshot checksum failed" >&2; exit 1; }
  /bin/chmod 0444 "$controls_source_snapshot"
  /bin/chmod 0500 "$controls_snapshot_dir"
  check_controls_snapshot() {
    [ "$(/usr/bin/shasum -a 256 "$controls_source_snapshot" | /usr/bin/awk '{print $1}')" = "$SYSTEM_CONTROLS_SOURCE_SHA256" ] || { echo "System controls source snapshot changed during compilation" >&2; exit 1; }
  }
  controls_candidate=$(/usr/bin/mktemp "$SYSTEM_CONTROLS_HELPER_DIR/.system-controls.binary.XXXXXX")
  controls_marker_candidate=$(/usr/bin/mktemp "$SYSTEM_CONTROLS_HELPER_DIR/.system-controls.hash.XXXXXX")
  controls_fixture_debug=$(/usr/bin/mktemp "$SYSTEM_CONTROLS_HELPER_DIR/.system-controls.fixture-debug.XXXXXX")
  controls_fixture_optimized=$(/usr/bin/mktemp "$SYSTEM_CONTROLS_HELPER_DIR/.system-controls.fixture-optimized.XXXXXX")
  /usr/bin/xcrun swiftc -target arm64-apple-macosx15.0 -parse-as-library -warnings-as-errors -D SYSTEM_CONTROLS_TESTING "$controls_source_snapshot" -o "$controls_fixture_debug"
  check_controls_snapshot
  "$controls_fixture_debug" --self-test >/dev/null
  /usr/bin/xcrun swiftc -target arm64-apple-macosx15.0 -parse-as-library -O -warnings-as-errors -D SYSTEM_CONTROLS_TESTING "$controls_source_snapshot" -o "$controls_fixture_optimized"
  check_controls_snapshot
  "$controls_fixture_optimized" --self-test >/dev/null
  /usr/bin/xcrun swiftc -target arm64-apple-macosx15.0 -parse-as-library -O -warnings-as-errors "$controls_source_snapshot" -o "$controls_candidate"
  check_controls_snapshot
  /bin/chmod 0755 "$controls_candidate"
  controls_binary_hash=$(/usr/bin/shasum -a 256 "$controls_candidate" | /usr/bin/awk '{print $1}')
  {
    printf '%s\n' 'version=2'
    printf 'source_sha256=%s\n' "$SYSTEM_CONTROLS_SOURCE_SHA256"
    printf '%s\n' 'target=arm64-apple-macosx15.0' 'build_mode=-O'
    printf 'binary_sha256=%s\n' "$controls_binary_hash"
  } >"$controls_marker_candidate"
  /bin/chmod 0644 "$controls_marker_candidate"
  "$SECURE_INSTALLER" system-controls-candidate-provenance "$controls_candidate" "$controls_marker_candidate" "$SYSTEM_CONTROLS_SOURCE_SHA256"
  "$CONFIG_DIR/scripts/system-controls-helper-install-transaction.sh" "$controls_candidate" "$controls_marker_candidate" "$SYSTEM_CONTROLS_HELPER_DIR" "$SYSTEM_CONTROLS_SOURCE_SHA256"
  "$SECURE_INSTALLER" system-controls-provenance "$controls_binary" "$controls_marker" "$SYSTEM_CONTROLS_SOURCE_SHA256"
  controls_install_cleanup
  trap - EXIT HUP INT TERM
fi


"$CONFIG_DIR/scripts/sketchybar-launch-agent.py"
/usr/bin/python3 - <<'PY'
import json
import subprocess
import time

expected_items = [
    "release.probe", "popup.controller",
    "space.1", "space.2", "space.3", "space.4", "space.5",
    "space.6", "space.7", "space.8", "space.9", "front_window",
    "wifi", "bluetooth", "display",
    "audio", "microphone", "battery", "calendar", "calendar.next",
    "calendar.event.bracket", "calendar.date.bracket",
    "tmp", "ssd", "net", "ram", "gpu", "cpu", "system.bracket",
]
deadline = time.monotonic() + 10
valid = False
while time.monotonic() < deadline:
    try:
        result = subprocess.run(
            ["/opt/homebrew/opt/sketchybar/bin/sketchybar", "--query", "bar"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=2,
            check=False,
        )
        if result.returncode == 0 and len(result.stdout) <= 131072 and b"\x00" not in result.stdout:
            value = json.loads(result.stdout.decode("utf-8", "strict"))
            valid = (type(value) is dict
                     and value.get("drawing") == "on"
                     and type(value.get("height")) is int
                     and value.get("height") == 36
                     and value.get("items") == expected_items)
    except (OSError, subprocess.SubprocessError, UnicodeDecodeError,
            json.JSONDecodeError, TypeError, ValueError):
        valid = False
    if valid:
        break
    time.sleep(0.1)
if not valid:
    raise SystemExit("Configured SketchyBar runtime shape failed")
print("Configured SketchyBar runtime shape passed")
PY
echo "Dependencies are installed, the full offline smoke gate passed, and the configured LaunchAgent is loaded."
