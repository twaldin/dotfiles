#!/bin/sh
set -eu
umask 077

provider=/opt/homebrew/bin/stats_provider
uid=$(/usr/bin/id -u)
script_dir=$(CDPATH='' cd -- "$(/usr/bin/dirname -- "$0")" && pwd -P)
log_helper="$script_dir/provider-log.py"
runtime_base=${TMPDIR:-/tmp}
case "$runtime_base" in /*) ;; *) exit 64 ;; esac
runtime="$runtime_base/sketchybar-stats-provider-$uid"
if [ ! -e "$runtime" ] && [ ! -L "$runtime" ]; then /bin/mkdir -m 0700 "$runtime"; fi
[ -d "$runtime" ] && [ ! -L "$runtime" ] && [ "$(/usr/bin/stat -f %u "$runtime")" = "$uid" ] && [ "$(/usr/bin/stat -f %Lp "$runtime")" = 700 ] || exit 73
pidfile="$runtime/provider.pid"
pending_intent="$runtime/provider.pending"
legacy_pidfile="$runtime_base/sketchybar-stats-provider.${uid}.pid"
lockdir="$runtime/launcher.lock"
log="$runtime/provider.log"

case "${1:-restart}" in restart|start|stop) action=${1:-restart} ;; *) exit 64 ;; esac

validate_regular_metadata() {
  path=$1
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] && [ "$(/usr/bin/stat -f %u "$path")" = "$uid" ] && [ "$(/usr/bin/stat -f %l "$path")" = 1 ] && [ "$(/usr/bin/stat -f %Lp "$path")" = 600 ] || return 1
  fi
}

validate_regular_metadata "$pidfile" || exit 73
validate_regular_metadata "$pending_intent" || exit 73
if [ -e "$log" ] || [ -L "$log" ]; then
  [ -f "$log" ] && [ ! -L "$log" ] && [ "$(/usr/bin/stat -f %u "$log")" = "$uid" ] && [ "$(/usr/bin/stat -f %Lp "$log")" = 600 ] || exit 73
fi

log_message() {
  "$log_helper" append "$log" "$1"
}

acquire_lock() {
  "$log_helper" acquire-lock-directory "$lockdir" "$$"
}

if acquire_lock 2>/dev/null; then
  :
else
  lock_status=$?
  [ "$lock_status" -eq 75 ] && exit 0
  log_message "provider launcher lock acquisition failed" || true
  exit "$lock_status"
fi
new_pid=""
launch_committed=false
cleanup_lock() {
  "$log_helper" release-lock-directory "$lockdir" "$$" 2>/dev/null || true
}
cleanup() {
  if [ "$launch_committed" != true ] && [ -n "$new_pid" ] && pending_owned_pid "$new_pid"; then
    /bin/kill "$new_pid" 2>/dev/null || true
    wait "$new_pid" 2>/dev/null || true
  fi
  cleanup_lock
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[ "${SKETCHYBAR_PROVIDER_LOCK_TEST:-}" = 1 ] && exit 0

owned_pid() {
  pid=$1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  command=$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    "$provider --bar sketchybar --cpu usage --memory ram_usage --disk usage --battery percentage remaining state time_to_full --uptime day hour min --interval 3 --no-units") return 0 ;;
    *) return 1 ;;
  esac
}

pending_owned_pid() {
  pid=$1
  if owned_pid "$pid"; then return 0; fi
  command=$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$log_helper exec-owned $log $pidfile $pending_intent "*" $provider --bar sketchybar --cpu usage --memory ram_usage --disk usage --battery percentage remaining state time_to_full --uptime day hour min --interval 3 --no-units") return 0 ;;
    *) return 1 ;;
  esac
}

if [ -r "$pending_intent" ]; then
  count=0
  while [ -e "$pending_intent" ] && [ "$count" -lt 50 ]; do
    /bin/sleep 0.01
    count=$((count + 1))
  done
  validate_regular_metadata "$pending_intent" || exit 73
  if [ -e "$pending_intent" ]; then
    log_message "ambiguous provider launch intent; refusing duplicate"
    exit 75
  fi
fi

old_pid=""
if [ -r "$pidfile" ]; then
  old_pid=$(/bin/cat "$pidfile" 2>/dev/null || true)
elif [ -f "$legacy_pidfile" ] && [ ! -L "$legacy_pidfile" ] && [ "$(/usr/bin/stat -f %u "$legacy_pidfile")" = "$uid" ]; then
  old_pid=$(/bin/cat "$legacy_pidfile" 2>/dev/null || true)
fi
case "$old_pid" in ''|*[!0-9]*) [ -z "$old_pid" ] || exit 73 ;; esac
if [ -n "$old_pid" ] && [ -n "$(/bin/ps -p "$old_pid" -o pid= 2>/dev/null)" ] && ! owned_pid "$old_pid"; then
  count=0
  while pending_owned_pid "$old_pid" && /bin/kill -0 "$old_pid" 2>/dev/null && ! owned_pid "$old_pid" && [ "$count" -lt 20 ]; do
    /bin/sleep 0.01
    count=$((count + 1))
  done
  if /bin/kill -0 "$old_pid" 2>/dev/null && ! owned_pid "$old_pid"; then
    log_message "live pending or unverified stats_provider; refusing duplicate"
    exit 75
  fi
fi
if [ -n "$old_pid" ] && owned_pid "$old_pid"; then
  /bin/kill "$old_pid" 2>/dev/null || true
  count=0
  while /bin/kill -0 "$old_pid" 2>/dev/null && [ "$count" -lt 20 ]; do
    /bin/sleep 0.05
    count=$((count + 1))
  done
  if /bin/kill -0 "$old_pid" 2>/dev/null && owned_pid "$old_pid"; then
    log_message "owned stats_provider did not stop; refusing duplicate"
    exit 75
  fi
fi
/bin/rm -f "$pidfile"
if [ -f "$legacy_pidfile" ] && [ ! -L "$legacy_pidfile" ] && [ "$(/usr/bin/stat -f %u "$legacy_pidfile")" = "$uid" ]; then
  /bin/rm -f "$legacy_pidfile"
fi
[ "$action" = stop ] && exit 0
[ -x "$provider" ] || { log_message "stats_provider is not installed"; exit 69; }
"$log_helper" pid "$pending_intent" "$$"

"$log_helper" exec-owned "$log" "$pidfile" "$pending_intent" "$$" "$provider" --bar sketchybar --cpu usage --memory ram_usage --disk usage \
  --battery percentage remaining state time_to_full --uptime day hour min \
  --interval 3 --no-units &
new_pid=$!
if [ "${SKETCHYBAR_PROVIDER_ABORT_AFTER_FORK:-}" = 1 ]; then /bin/kill -KILL "$$"; fi
count=0
while /bin/kill -0 "$new_pid" 2>/dev/null && ! owned_pid "$new_pid" && [ "$count" -lt 20 ]; do
  /bin/sleep 0.01
  count=$((count + 1))
done
if ! owned_pid "$new_pid"; then
  /bin/kill "$new_pid" 2>/dev/null || true
  wait "$new_pid" 2>/dev/null || true
  log_message "stats_provider launch failed"
  exit 75
fi
validate_regular_metadata "$pidfile" || exit 75
published_pid=$(/bin/cat "$pidfile" 2>/dev/null || true)
if [ "$published_pid" != "$new_pid" ] || ! owned_pid "$new_pid"; then
  log_message "stats_provider ownership publication failed"
  exit 75
fi
launch_committed=true
