#!/bin/sh
set -eu

# Tailscale is a split-tunnel VPN and does not appear in `scutil --nc list`.
for tailscale in /opt/homebrew/bin/tailscale /usr/local/bin/tailscale; do
  if [ -x "$tailscale" ]; then
    status="$($tailscale status --json 2>/dev/null || true)"
    if printf '%s' "$status" | /usr/bin/grep -q '"BackendState"[[:space:]]*:[[:space:]]*"Running"'       && printf '%s' "$status" | /usr/bin/grep -q '"TUN"[[:space:]]*:[[:space:]]*true'; then
      printf '%s
' 'Tailscale on'
      exit 0
    fi
  fi
done

name=$(/usr/sbin/scutil --nc list 2>/dev/null | /usr/bin/awk -F'"' '/\(Connected\)/ {print $2; exit}')
if [ -n "${name:-}" ]; then
  printf '%s
' "$name on"
  exit 0
fi

# Cover other split tunnels that do not register as NetworkExtension services.
tunnel=$(/usr/sbin/netstat -rn -f inet 2>/dev/null | /usr/bin/awk '$NF ~ /^utun[0-9]+$/ {print $NF; exit}')
if [ -n "${tunnel:-}" ]; then
  printf '%s
' "Tunnel on ($tunnel)"
else
  printf '%s
' 'Off'
fi
