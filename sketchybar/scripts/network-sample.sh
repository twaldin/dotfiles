#!/bin/sh
set -eu

now=$(/bin/date +%s)
route=$(/sbin/route -n get default 2>/dev/null || true)
interface=$(printf '%s\n' "$route" | /usr/bin/awk '/^[[:space:]]*interface:/{print $2; exit}')
router=$(printf '%s\n' "$route" | /usr/bin/awk '/^[[:space:]]*gateway:/{print $2; exit}')
rx=0
tx=0
ip=""
ssid=""

if [ -n "$interface" ]; then
  counters=$(/usr/sbin/netstat -ibdn 2>/dev/null | /usr/bin/awk -v dev="$interface" '$1 == dev && $3 ~ /^<Link#/ { print $7 "\t" $10; exit }')
  if [ -n "$counters" ]; then
    rx=$(printf '%s' "$counters" | /usr/bin/awk -F '\t' '{print $1}')
    tx=$(printf '%s' "$counters" | /usr/bin/awk -F '\t' '{print $2}')
  fi
  ip=$(/usr/sbin/ipconfig getifaddr "$interface" 2>/dev/null || true)
  wifi_device=$(/usr/sbin/networksetup -listallhardwareports 2>/dev/null | /usr/bin/awk '/^Hardware Port: Wi-Fi$/{getline; if ($1 == "Device:") print $2; exit}')
  if [ "$interface" = "$wifi_device" ]; then
    ssid_line=$(/usr/sbin/networksetup -getairportnetwork "$interface" 2>/dev/null || true)
    case "$ssid_line" in *": "*) ssid=${ssid_line#*: } ;; esac
  fi
fi

clean() { printf '%s' "$1" | /usr/bin/tr '\t\r\n' '   '; }
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$(clean "$interface")" "$rx" "$tx" "$(clean "$ip")" "$(clean "$router")" "$(clean "$ssid")"
