#!/bin/sh
set -eu
case "${1:-}" in 1|2|3|4|5|6|7|8|9|prev|next) requested=$1 ;; *) exit 64 ;; esac
script_dir=$(CDPATH='' cd -- "$(/usr/bin/dirname -- "$0")" && pwd -P)
yabai="$HOME/Applications/Yabai.app/Contents/MacOS/yabai"
space_target() {
  { "$yabai" -m query --spaces 2>/dev/null || printf '\n!'; } | "$script_dir/yabai-guard.py" space-target "$requested" 2>/dev/null
}
target=$(space_target) || exit 75
confirmed_target=$(space_target) || exit 75
[ "$target" = "$confirmed_target" ] || exit 75
case "$target" in 1|2|3|4|5|6|7|8|9) ;; *) exit 75 ;; esac
"$yabai" -m space --focus "$target" >/dev/null 2>&1
