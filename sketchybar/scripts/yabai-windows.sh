#!/bin/sh
set -eu
case "${1:-}" in all|current) mode=$1 ;; *) exit 64 ;; esac
script_dir=$(CDPATH='' cd -- "$(/usr/bin/dirname -- "$0")" && pwd -P)
yabai=/opt/homebrew/bin/yabai
valid_topology() {
  { "$yabai" -m query --spaces 2>/dev/null || printf '\n!'; } | "$script_dir/yabai-guard.py" topology 2>/dev/null
}
valid_topology || exit 75
if [ "$mode" = current ]; then
  content=$({ "$yabai" -m query --windows --window 2>/dev/null || printf '\n!'; } | "$script_dir/yabai-guard.py" window-json 2>/dev/null) || exit 75
else
  content=$({ "$yabai" -m query --windows 2>/dev/null || printf '\n!'; } | "$script_dir/yabai-guard.py" windows-json 2>/dev/null) || exit 75
fi
valid_topology || exit 75
printf '%s' "$content"
