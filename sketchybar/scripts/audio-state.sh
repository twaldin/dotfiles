#!/bin/sh
set -eu
case "${1:-}" in
  output)
    level=$(/usr/bin/osascript -e 'output volume of (get volume settings)')
    muted=$(/usr/bin/osascript -e 'output muted of (get volume settings)')
    device=$(/opt/homebrew/bin/SwitchAudioSource -t output -c 2>/dev/null || true)
    printf '%s\t%s\t%s\n' "$level" "$muted" "$(printf '%s' "$device" | /usr/bin/tr '\t\r\n' '   ')"
    ;;
  input)
    level=$(/usr/bin/osascript -e 'input volume of (get volume settings)')
    device=$(/opt/homebrew/bin/SwitchAudioSource -t input -c 2>/dev/null || true)
    printf '%s\t%s\n' "$level" "$(printf '%s' "$device" | /usr/bin/tr '\t\r\n' '   ')"
    ;;
  *) exit 64 ;;
esac
