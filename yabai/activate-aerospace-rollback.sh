#!/bin/sh
set -eu

DOMAIN="gui/$(id -u)"

assert_process_absent() {
  process=$1
  if output=$(/usr/bin/pgrep -x "$process" 2>&1); then
    printf 'Refusing WM overlap: %s is still active (%s).
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

unload_and_disable() {
  label=$1
  if /bin/launchctl print "$DOMAIN/$label" >/dev/null 2>&1; then
    /bin/launchctl bootout "$DOMAIN/$label"
  else
    status=$?
    if [ "$status" -ne 113 ]; then
      printf 'Could not inspect launch agent %s (status %s).
' "$label" "$status" >&2
      exit 1
    fi
  fi
  /bin/launchctl disable "$DOMAIN/$label"
}

unload_and_disable com.koekeishiya.skhd
unload_and_disable com.asmvik.yabai
assert_process_absent skhd
assert_process_absent yabai

/usr/bin/open -a AeroSpace
printf 'AeroSpace rollback started only after yabai and skhd were absent and disabled.
'
