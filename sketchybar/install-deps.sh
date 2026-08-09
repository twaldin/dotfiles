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
SYSTEM_CONTROLS_SOURCE_SHA256=ebdca705586046f967eff2832abe683536badc5c74e8c206e8914a1e7b9220d1

command -v /opt/homebrew/bin/brew >/dev/null 2>&1 || { echo "Homebrew is required at /opt/homebrew/bin/brew" >&2; exit 69; }
STATS_FORMULA="$CONFIG_DIR/deps/sketchybar-system-stats.rb"
STATS_FORMULA_SHA256=639b236a164c049a98eab97265b8a3c333c5c5f39e7a95544302c89247715d55
host_arch=$(/usr/bin/uname -m)
host_macos_version=$(/usr/bin/sw_vers -productVersion)
"$SECURE_INSTALLER" host-contract "$host_arch" "$host_macos_version"
[ "$(/usr/bin/shasum -a 256 "$SYSTEM_CONTROLS_SOURCE" | /usr/bin/awk '{print $1}')" = "$SYSTEM_CONTROLS_SOURCE_SHA256" ] || { echo "Immutable system controls source checksum failed" >&2; exit 1; }
stats_expected_sha256=60c6e2c4af882ed656d1f8a81f3c8e4879a93d8d8e5c6d4039515d5b092e1b41
[ "$(/usr/bin/shasum -a 256 "$STATS_FORMULA" | /usr/bin/awk '{print $1}')" = "$STATS_FORMULA_SHA256" ] || { echo "Pinned stats_provider formula checksum failed" >&2; exit 1; }
/opt/homebrew/bin/brew install lua ical-buddy blueutil media-control

if ! /opt/homebrew/bin/brew tap | /usr/bin/grep -Fx 'twaldin/sketchybar-frozen' >/dev/null; then
  /opt/homebrew/bin/brew tap-new --no-git twaldin/sketchybar-frozen
fi
stats_tap=$(/opt/homebrew/bin/brew --repo twaldin/sketchybar-frozen)
[ -d "$stats_tap/Formula" ] && [ ! -L "$stats_tap/Formula" ] || { echo "Local frozen Homebrew tap is unsafe" >&2; exit 1; }
stats_formula_destination="$stats_tap/Formula/sketchybar-system-stats.rb"
"$SECURE_INSTALLER" asset "$STATS_FORMULA" "$stats_formula_destination"
stats_formula_installed_sha256=$(/usr/bin/shasum -a 256 "$stats_formula_destination" | /usr/bin/awk '{print $1}')
[ "$stats_formula_installed_sha256" = "$STATS_FORMULA_SHA256" ] || { echo "Installed frozen stats_provider formula checksum failed" >&2; exit 1; }
/opt/homebrew/bin/brew unpin sketchybar-system-stats >/dev/null 2>&1 || true
if /opt/homebrew/bin/brew list --versions sketchybar-system-stats >/dev/null 2>&1; then
  /opt/homebrew/bin/brew reinstall twaldin/sketchybar-frozen/sketchybar-system-stats
else
  /opt/homebrew/bin/brew install twaldin/sketchybar-frozen/sketchybar-system-stats
fi

lua_version=$(/opt/homebrew/bin/lua -v 2>&1)
case "$lua_version" in "Lua 5.5"*) ;; *) echo "Lua 5.5 is required; found: $lua_version" >&2; exit 1 ;; esac
stats_version=$(/opt/homebrew/bin/stats_provider --version 2>&1 | /usr/bin/awk '{print $2}')
stats_prefix=$(/opt/homebrew/bin/brew --prefix twaldin/sketchybar-frozen/sketchybar-system-stats)
stats_binary=$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' /opt/homebrew/bin/stats_provider)
stats_expected=$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$stats_prefix/bin/stats_provider")
[ "$stats_binary" = "$stats_expected" ] || { echo "stats_provider does not resolve to the frozen Homebrew formula" >&2; exit 1; }
stats_actual_sha256=$(/usr/bin/shasum -a 256 "$stats_binary" | /usr/bin/awk '{print $1}')
[ "$stats_actual_sha256" = "$stats_expected_sha256" ] || { echo "Frozen stats_provider binary checksum failed" >&2; exit 1; }
# The vendored formula pins the upstream 0.8.2 release URLs and SHA-256 values.
[ "$stats_version" = 0.8.2 ] || { echo "Expected released tap stats_provider 0.8.2; found $stats_version" >&2; exit 1; }
/opt/homebrew/bin/brew pin twaldin/sketchybar-frozen/sketchybar-system-stats >/dev/null
/opt/homebrew/bin/brew list --pinned | /usr/bin/awk '{print $1}' | /usr/bin/grep -Fx 'sketchybar-system-stats' >/dev/null || { echo "stats_provider formula is not pinned" >&2; exit 1; }

install_asset() {
  url=$1
  expected=$2
  destination=$3
  "$SECURE_INSTALLER" prepare-asset "$destination"
  actual=""
  if [ -r "$destination" ]; then actual=$(/usr/bin/shasum -a 256 "$destination" | /usr/bin/awk '{print $1}'); fi
  [ "$actual" = "$expected" ] && return 0
  temporary=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/sketchybar-asset.XXXXXX")
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
  work=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/SbarLua.XXXXXX")
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
