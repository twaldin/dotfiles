#!/bin/sh
set -eu

DOMAIN="gui/$(id -u)"
YABAI_LABEL=com.asmvik.yabai
SKHD_LABEL=com.koekeishiya.skhd
YABAI_PLIST="$HOME/Library/LaunchAgents/$YABAI_LABEL.plist"
SKHD_PLIST="$HOME/Library/LaunchAgents/$SKHD_LABEL.plist"
CUTOVER_STARTED=0
COMPLETE=0

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

assert_job_absent() {
  label=$1
  if /bin/launchctl print "$DOMAIN/$label" >/dev/null 2>&1; then
    printf 'Launch agent %s is already loaded. Refusing an ambiguous cutover.
' "$label" >&2
    exit 1
  else
    status=$?
    if [ "$status" -ne 113 ]; then
      printf 'Could not inspect launch agent %s (status %s).
' "$label" "$status" >&2
      exit 1
    fi
  fi
}

yabai_config_equals() {
  key=$1
  expected=$2
  actual=$(/opt/homebrew/bin/yabai -m config "$key" 2>/dev/null) || return 1
  [ "$actual" = "$expected" ]
}

yabai_spaces_ready() {
  spaces=$(/opt/homebrew/bin/yabai -m query --spaces 2>/dev/null) || return 1
  [ "$(printf '%s' "$spaces" | /usr/bin/jq 'length')" -eq 9 ]
}

yabai_rules_ready() {
  rules=$(/opt/homebrew/bin/yabai -m rule --list 2>/dev/null) || return 1
  printf '%s' "$rules" | /usr/bin/jq -e '
    ([.[] | select(.label == "raycast" and .manage == false)] | length) == 1 and
    ([.[] | select(.label == "system-settings" and .manage == false)] | length) == 1
  ' >/dev/null
}

restore_aerospace_on_failure() {
  for label in "$SKHD_LABEL" "$YABAI_LABEL"; do
    /bin/launchctl bootout "$DOMAIN/$label" >/dev/null 2>&1 || true
    /bin/launchctl disable "$DOMAIN/$label" >/dev/null 2>&1 || true
  done

  yabai_status=0
  skhd_status=0
  /usr/bin/pgrep -x yabai >/dev/null 2>&1 || yabai_status=$?
  /usr/bin/pgrep -x skhd >/dev/null 2>&1 || skhd_status=$?

  if [ "$yabai_status" -eq 1 ] && [ "$skhd_status" -eq 1 ]; then
    /usr/bin/open -a AeroSpace
    printf 'Primary cutover failed. AeroSpace was restored without WM overlap.
' >&2
  else
    printf 'Primary cutover failed, and process inspection was not safely empty. AeroSpace was not opened. yabai=%s skhd=%s
' "$yabai_status" "$skhd_status" >&2
  fi
}

cleanup() {
  status=$1
  trap - EXIT HUP INT TERM
  if [ "$status" -ne 0 ] && [ "$CUTOVER_STARTED" -eq 1 ] && [ "$COMPLETE" -ne 1 ]; then
    restore_aerospace_on_failure
  fi
  exit "$status"
}
trap 'cleanup $?' EXIT
trap 'cleanup 129' HUP
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

assert_process_absent AeroSpace
assert_process_absent yabai
assert_process_absent skhd
assert_job_absent "$YABAI_LABEL"
assert_job_absent "$SKHD_LABEL"
/usr/bin/codesign --verify --deep --strict "$HOME/Applications/Yabai.app"
/usr/bin/codesign --verify --deep --strict "$HOME/Applications/skhd.app"
/usr/bin/plutil -lint "$YABAI_PLIST" >/dev/null
/usr/bin/plutil -lint "$SKHD_PLIST" >/dev/null

CUTOVER_STARTED=1
/bin/launchctl enable "$DOMAIN/$YABAI_LABEL"
/bin/launchctl bootstrap "$DOMAIN" "$YABAI_PLIST"

ready=0
attempt=0
while [ "$attempt" -lt 30 ]; do
  if yabai_spaces_ready &&
     yabai_rules_ready &&
     yabai_config_equals layout bsp &&
     yabai_config_equals split_type auto &&
     yabai_config_equals split_ratio 0.5500 &&
     yabai_config_equals auto_balance off &&
     yabai_config_equals window_placement second_child &&
     yabai_config_equals window_insertion_point last &&
     yabai_config_equals mouse_follows_focus off &&
     yabai_config_equals focus_follows_mouse disabled &&
     yabai_config_equals display_arrangement_order default &&
     yabai_config_equals window_origin_display default &&
     yabai_config_equals window_zoom_persist on &&
     yabai_config_equals skip_window_focus_animation on &&
     yabai_config_equals window_animation_duration 0.000000 &&
     yabai_config_equals external_bar all:32:0 &&
     yabai_config_equals top_padding 10 &&
     yabai_config_equals bottom_padding 10 &&
     yabai_config_equals left_padding 10 &&
     yabai_config_equals right_padding 10 &&
     yabai_config_equals window_gap 8 &&
     yabai_config_equals mouse_modifier fn &&
     yabai_config_equals mouse_action1 move &&
     yabai_config_equals mouse_action2 resize &&
     yabai_config_equals mouse_drop_action swap; then
    ready=1
    break
  fi
  attempt=$((attempt + 1))
  /bin/sleep 0.5
done
[ "$ready" -eq 1 ] || { printf 'yabai did not reach its final BSP config.
' >&2; exit 1; }

/bin/launchctl enable "$DOMAIN/$SKHD_LABEL"
/bin/launchctl bootstrap "$DOMAIN" "$SKHD_PLIST"

ready=0
attempt=0
while [ "$attempt" -lt 10 ]; do
  if /usr/bin/pgrep -x skhd >/dev/null 2>&1; then
    ready=1
    break
  else
    status=$?
    [ "$status" -eq 1 ] || { printf 'Could not inspect skhd process state.
' >&2; exit 1; }
  fi
  attempt=$((attempt + 1))
  /bin/sleep 0.2
done
[ "$ready" -eq 1 ] || { printf 'skhd did not remain active.
' >&2; exit 1; }

COMPLETE=1
printf 'yabai and skhd are active. AeroSpace is absent.
'
