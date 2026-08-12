#!/bin/sh
set -eu
CLIENT=/Library/PrivilegedHelperTools/com.twaldin.sketchybar.fan-power-client
if [ ! -x "$CLIENT" ] || [ -L "$CLIENT" ]; then
  printf '%s\n' '{"recovery":"open_install_instructions","schema":"fan_power_client_v1","trusted":false}'
  exit 69
fi
case "$#:${1-}:${2-}:${3-}" in
  1:status::) exec "$CLIENT" status ;;
  2:fan:automatic:) exec "$CLIENT" fan automatic ;;
  2:fan:boost:) exec "$CLIENT" fan boost ;;
  3:power:battery:automatic|3:power:battery:low|3:power:battery:high)
    exec "$CLIENT" power battery "$3" ;;
  3:power:ac:automatic|3:power:ac:low|3:power:ac:high)
    exec "$CLIENT" power ac "$3" ;;
  *) exit 64 ;;
esac
