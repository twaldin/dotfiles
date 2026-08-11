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
SYSTEM_CONTROLS_SOURCE_SHA256=bb2e07839781cd5a5cc7a68e3c4855ef4a3e1cc78de585f2086af278ff41461b
AUDIO_COORDINATOR_SOURCE="$CONFIG_DIR/scripts/audio-state.py"
AUDIO_COORDINATOR_SOURCE_SHA256=e20c622aa87372a941a01bec76a0815074c2d2350ca67a32d3032ce834b166fb

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
[ "$(/usr/bin/shasum -a 256 "$SYSTEM_CONTROLS_SOURCE" | /usr/bin/awk '{print $1}')" = "$SYSTEM_CONTROLS_SOURCE_SHA256" ] || { echo "Immutable system controls source checksum failed" >&2; exit 1; }
[ "$(/usr/bin/shasum -a 256 "$AUDIO_COORDINATOR_SOURCE" | /usr/bin/awk '{print $1}')" = "$AUDIO_COORDINATOR_SOURCE_SHA256" ] || { echo "Immutable audio coordinator source checksum failed" >&2; exit 1; }
SKETCHYBAR_LOG_DIR="$HOME/Library/Logs/sketchybar"
if [ ! -e "$SKETCHYBAR_LOG_DIR" ] && [ ! -L "$SKETCHYBAR_LOG_DIR" ]; then
  /bin/mkdir -m 0700 "$SKETCHYBAR_LOG_DIR"
fi
[ -d "$SKETCHYBAR_LOG_DIR" ] && [ ! -L "$SKETCHYBAR_LOG_DIR" ]   && [ "$(/usr/bin/stat -f %u "$SKETCHYBAR_LOG_DIR")" = "$(/usr/bin/id -u)" ]   && [ "$(/usr/bin/stat -f %Lp "$SKETCHYBAR_LOG_DIR")" = 700 ]   || { echo "SketchyBar launch log directory is unsafe" >&2; exit 73; }
/opt/homebrew/bin/brew install lua ical-buddy

public_stats_build=$(/usr/bin/mktemp -d "$runtime_base/sketchybar-public-stats-build.XXXXXX")
public_stats_build_cleanup() { /bin/rm -rf "$public_stats_build"; }
trap public_stats_build_cleanup EXIT HUP INT TERM
/usr/bin/swift build -c release --package-path "$PUBLIC_STATS_DIR" --scratch-path "$public_stats_build"
public_stats_candidate="$public_stats_build/release/sketchybar-public-stats"
public_stats_candidate_sha256=$(/usr/bin/shasum -a 256 "$public_stats_candidate" | /usr/bin/awk '{print $1}')
"$public_stats_candidate" --self-test
[ "$(/usr/bin/shasum -a 256 "$public_stats_candidate" | /usr/bin/awk '{print $1}')" = "$public_stats_candidate_sha256" ] || { echo "Public stats candidate changed after self-test" >&2; exit 75; }
"$SECURE_INSTALLER" executable "$public_stats_candidate" "$PUBLIC_STATS_BINARY" "$public_stats_candidate_sha256" --self-test
[ "$(/usr/bin/shasum -a 256 "$PUBLIC_STATS_BINARY" | /usr/bin/awk '{print $1}')" = "$public_stats_candidate_sha256" ] || { echo "Installed public stats checksum mismatch" >&2; exit 75; }
public_stats_build_cleanup
trap - EXIT HUP INT TERM

lua_version=$(/opt/homebrew/bin/lua -v 2>&1)
case "$lua_version" in "Lua 5.5"*) ;; *) echo "Lua 5.5 is required; found: $lua_version" >&2; exit 1 ;; esac

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
  controls_candidate=$(/usr/bin/mktemp "$SYSTEM_CONTROLS_HELPER_DIR/.system-controls.binary.XXXXXX")
  controls_marker_candidate=$(/usr/bin/mktemp "$SYSTEM_CONTROLS_HELPER_DIR/.system-controls.hash.XXXXXX")
  controls_fixture_debug=$(/usr/bin/mktemp "$SYSTEM_CONTROLS_HELPER_DIR/.system-controls.fixture-debug.XXXXXX")
  controls_fixture_optimized=$(/usr/bin/mktemp "$SYSTEM_CONTROLS_HELPER_DIR/.system-controls.fixture-optimized.XXXXXX")
  controls_install_cleanup() { /bin/rm -f "$controls_candidate" "$controls_marker_candidate" "$controls_fixture_debug" "$controls_fixture_optimized"; }
  trap controls_install_cleanup EXIT HUP INT TERM
  /usr/bin/xcrun swiftc -target arm64-apple-macosx15.0 -parse-as-library -warnings-as-errors -D SYSTEM_CONTROLS_TESTING "$SYSTEM_CONTROLS_SOURCE" -o "$controls_fixture_debug"
  "$controls_fixture_debug" --self-test >/dev/null
  /usr/bin/xcrun swiftc -target arm64-apple-macosx15.0 -parse-as-library -O -warnings-as-errors -D SYSTEM_CONTROLS_TESTING "$SYSTEM_CONTROLS_SOURCE" -o "$controls_fixture_optimized"
  "$controls_fixture_optimized" --self-test >/dev/null
  /usr/bin/xcrun swiftc -target arm64-apple-macosx15.0 -parse-as-library -O -warnings-as-errors "$SYSTEM_CONTROLS_SOURCE" -o "$controls_candidate"
  /bin/chmod 0755 "$controls_candidate"
  [ "$(/usr/bin/lipo -archs "$controls_candidate")" = arm64 ] || { echo "System controls helper architecture mismatch" >&2; exit 1; }
  if "$controls_candidate" --self-test >/dev/null 2>&1; then echo "Release system controls helper exposes the private fixture backend" >&2; exit 1
  else controls_private_status=$?; [ "$controls_private_status" -eq 64 ] || { echo "Release system controls helper private-boundary check failed" >&2; exit 1; }
  fi
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
  trap - EXIT HUP INT TERM
  /bin/rm -f "$controls_fixture_debug" "$controls_fixture_optimized"
fi

if ! "$SECURE_INSTALLER" prepare-sbarlua "$SBARLUA_DIR" "$SBARLUA_COMMIT" "$SBARLUA_LEGACY_SHA256"; then
  work=$(/usr/bin/mktemp -d "$runtime_base/SbarLua.XXXXXX")
  trap 'rm -rf "$work"' EXIT HUP INT TERM
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

"$CONFIG_DIR/scripts/smoke-config.sh"
echo "Dependencies are installed and the full offline smoke gate passed. Reload with: /opt/homebrew/bin/sketchybar --reload"
