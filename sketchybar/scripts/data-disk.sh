#!/bin/sh
set -eu
value=$(/bin/df -kP /System/Volumes/Data 2>/dev/null | /usr/bin/awk 'NR == 2 { gsub(/%/, "", $5); print $5 }')
case "$value" in ''|*[!0-9.]*) exit 1 ;; esac
printf '%s\n' "$value"
