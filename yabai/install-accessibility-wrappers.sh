#!/bin/sh
set -eu

umask 022

YABAI_SOURCE=$(realpath /opt/homebrew/bin/yabai)
SKHD_SOURCE=$(realpath /opt/homebrew/bin/skhd)
APPLICATIONS="$HOME/Applications"
YABAI_DESTINATION="$APPLICATIONS/Yabai.app"
SKHD_DESTINATION="$APPLICATIONS/skhd.app"

assert_process_absent() {
  process=$1
  if output=$(/usr/bin/pgrep -x "$process" 2>&1); then
    printf 'Stop %s before replacing its signed Accessibility wrapper (%s).
' "$process" "$output" >&2
    exit 1
  else
    status=$?
    if [ "$status" -ne 1 ]; then
      printf 'Could not inspect %s processes: %s
' "$process" "$output" >&2
      exit 1
    fi
  fi
}

assert_process_absent yabai
assert_process_absent skhd

YABAI_VERSION=$($YABAI_SOURCE --version)
SKHD_VERSION=$($SKHD_SOURCE --version)
YABAI_VERSION=${YABAI_VERSION#yabai-v}
SKHD_VERSION=${SKHD_VERSION#skhd-v}

case "$YABAI_VERSION:$SKHD_VERSION" in
  *[!0-9.:]*)
    printf 'Could not derive safe wrapper versions: yabai=%s skhd=%s
' "$YABAI_VERSION" "$SKHD_VERSION" >&2
    exit 1
    ;;
esac

mkdir -p "$APPLICATIONS"
TEMPORARY_ROOT=$(mktemp -d "$APPLICATIONS/.accessibility-wrappers.XXXXXX")
BACKUP_ROOT="$TEMPORARY_ROOT/backups"
mkdir -p "$BACKUP_ROOT"
SWAP_STARTED=0
COMMITTED=0

cleanup() {
  status=$1
  trap - EXIT HUP INT TERM

  if [ "$SWAP_STARTED" -eq 1 ] && [ "$COMMITTED" -ne 1 ]; then
    rm -rf "$YABAI_DESTINATION" "$SKHD_DESTINATION"
    [ ! -e "$BACKUP_ROOT/Yabai.app" ] || mv "$BACKUP_ROOT/Yabai.app" "$YABAI_DESTINATION"
    [ ! -e "$BACKUP_ROOT/skhd.app" ] || mv "$BACKUP_ROOT/skhd.app" "$SKHD_DESTINATION"
  fi

  rm -rf "$TEMPORARY_ROOT"
  exit "$status"
}
trap 'cleanup $?' EXIT
trap 'cleanup 129' HUP
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

build_wrapper() {
  source=$1
  destination=$2
  executable=$3
  identifier=$4
  name=$5
  version=$6

  mkdir -p "$destination/Contents/MacOS"
  cp "$source" "$destination/Contents/MacOS/$executable"
  chmod 755 "$destination/Contents/MacOS/$executable"

  /usr/libexec/PlistBuddy -c 'Clear dict' "$destination/Contents/Info.plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $executable" "$destination/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $identifier" "$destination/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleInfoDictionaryVersion string 6.0' "$destination/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleName string $name" "$destination/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$destination/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $version" "$destination/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $version" "$destination/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$destination/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :NSAccessibilityUsageDescription string $name uses Accessibility to manage windows or keyboard shortcuts." "$destination/Contents/Info.plist"

  /usr/bin/xattr -cr "$destination"
  /usr/bin/codesign --force --sign - --identifier "$identifier" "$destination"
  /usr/bin/codesign --verify --deep --strict "$destination"
  chmod -R u+rwX,go-w "$destination"
}

build_wrapper "$YABAI_SOURCE" "$TEMPORARY_ROOT/Yabai.app" yabai com.asmvik.yabai Yabai "$YABAI_VERSION"
build_wrapper "$SKHD_SOURCE" "$TEMPORARY_ROOT/skhd.app" skhd com.koekeishiya.skhd skhd "$SKHD_VERSION"

SWAP_STARTED=1
[ ! -e "$YABAI_DESTINATION" ] || mv "$YABAI_DESTINATION" "$BACKUP_ROOT/Yabai.app"
[ ! -e "$SKHD_DESTINATION" ] || mv "$SKHD_DESTINATION" "$BACKUP_ROOT/skhd.app"
mv "$TEMPORARY_ROOT/Yabai.app" "$YABAI_DESTINATION"
mv "$TEMPORARY_ROOT/skhd.app" "$SKHD_DESTINATION"
/usr/bin/codesign --verify --deep --strict "$YABAI_DESTINATION"
/usr/bin/codesign --verify --deep --strict "$SKHD_DESTINATION"
COMMITTED=1

printf 'Installed Accessibility wrappers:
  %s (%s)
  %s (%s)
'   "$YABAI_DESTINATION" "$YABAI_VERSION"   "$SKHD_DESTINATION" "$SKHD_VERSION"
printf 'The ad-hoc code requirements changed. Remove stale Accessibility rows if needed, re-add both apps, and verify approval before starting either service.
'
