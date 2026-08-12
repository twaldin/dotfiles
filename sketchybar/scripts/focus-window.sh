#!/bin/sh
set -eu
case "${1:-}" in ''|0|0*|*[!0-9]*) exit 64 ;; esac
requested=$1
script_dir=$(CDPATH='' cd -- "$(/usr/bin/dirname -- "$0")" && pwd -P)
yabai="$HOME/Applications/Yabai.app/Contents/MacOS/yabai"
valid_topology() {
  { "$yabai" -m query --spaces 2>/dev/null || printf '\n!'; } | "$script_dir/yabai-guard.py" topology 2>/dev/null
}
window_token() {
  { "$yabai" -m query --windows 2>/dev/null || printf '\n!'; } | "$script_dir/yabai-guard.py" window-token "$requested" 2>/dev/null
}
valid_topology || exit 75
accepted=$(window_token) || exit 75
valid_topology || exit 75
confirmed=$(window_token) || exit 75
valid_topology || exit 75
[ "$accepted" = "$confirmed" ] || exit 75
case "$confirmed" in "$requested":????????????????????????????????????????????????????????????????) ;; *) exit 75 ;; esac
"$yabai" -m window --focus "$requested" >/dev/null 2>&1
