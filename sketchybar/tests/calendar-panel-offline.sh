#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
host_arch=$(/usr/bin/uname -m)
[ "$host_arch" = arm64 ] || { echo "This release requires an Apple-silicon host" >&2; exit 1; }
calendar_target=arm64-apple-macosx15.0
[ "$(/usr/bin/shasum -a 256 "$root/scripts/calendar-panel.swift" | /usr/bin/awk '{print $1}')" = 7fd04dc9e2d3fb4556dda41cd2aa5da38c2e2b622e74efc6be9a58cb0f812a72 ] || { echo "Immutable calendar source checksum failed" >&2; exit 1; }
work=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/calendar-panel-test.XXXXXX")
binary="$work/calendar-panel"
self_test_tmp="$work/self-test-tmp"
/bin/mkdir -p "$self_test_tmp"
instance=""
stale_holder=""
stale_victim=""
cleanup() {
  if [ -n "$instance" ] && [ -x "$binary" ]; then SKETCHYBAR_CALENDAR_PANEL_INSTANCE="$instance" "$binary" --close >/dev/null 2>&1 || true; fi
  if [ -n "$stale_victim" ] && [ -x "$binary" ]; then SKETCHYBAR_CALENDAR_PANEL_INSTANCE="$stale_victim" "$binary" --close >/dev/null 2>&1 || true; fi
  if [ -n "$stale_holder" ] && [ -x "$binary" ]; then SKETCHYBAR_CALENDAR_PANEL_INSTANCE="$stale_holder" "$binary" --close >/dev/null 2>&1 || true; fi
  /bin/rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM
/usr/bin/xcrun swiftc -target "$calendar_target" -parse-as-library -typecheck "$root/scripts/calendar-panel.swift"
if /usr/bin/grep -q 'AXHeading' "$root/scripts/calendar-panel.swift"; then
  echo "Raw AXHeading role is prohibited" >&2
  exit 1
fi
/usr/bin/python3 - "$root/tests/validate-calendar-panel.py" "$root/tests/validate-calendar-events.py" <<'PY'
import ast
import pathlib
import sys
for argument in sys.argv[1:]:
    path = pathlib.Path(argument)
    tree = ast.parse(path.read_text(), filename=str(path))
    if any(isinstance(node, ast.Assert) for node in ast.walk(tree)):
        raise SystemExit("Optimizable Python assertions are prohibited")
PY
/usr/bin/xcrun swiftc -target "$calendar_target" -parse-as-library -O "$root/scripts/calendar-panel.swift" -o "$binary"
[ "$(/usr/bin/lipo -archs "$binary")" = "$host_arch" ] || { echo "Calendar helper architecture mismatch" >&2; exit 1; }
TMPDIR="$self_test_tmp" "$binary" --self-test
expect_usage_64() {
  if "$binary" "$@" >"$work/usage.out" 2>"$work/usage.err"; then
    echo "Malformed arguments unexpectedly succeeded: $*" >&2
    exit 1
  else
    status=$?
  fi
  [ "$status" -eq 64 ] || { echo "Malformed arguments returned $status instead of 64: $*" >&2; exit 1; }
}
for truncated in --state-report --render --geometry --fixture --ical-buddy --anchor --display --date --now --anchor-cg; do
  expect_usage_64 "$truncated"
done
expect_usage_64 --unknown-calendar-option
if /usr/bin/env -u SKETCHYBAR_CALENDAR_PANEL_INSTANCE "$binary" --hold-test >"$work/usage.out" 2>"$work/usage.err"; then
  echo "Hold test without a private instance unexpectedly succeeded" >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 64 ] || { echo "Hold test without an instance returned $status instead of 64" >&2; exit 1; }
if /usr/bin/env -u SKETCHYBAR_CALENDAR_PANEL_INSTANCE "$binary" --contender-test --ical-buddy /bin/false >"$work/usage.out" 2>"$work/usage.err"; then
  echo "Contender test without a private instance unexpectedly succeeded" >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 64 ] || { echo "Contender test without an instance returned $status instead of 64" >&2; exit 1; }
expect_usage_64 --toggle
expect_usage_64 --fixture "$root/tests/fixtures/calendar-events.json" --render "$work/invalid-date.png" --date 2026-02-30
expect_usage_64 --fixture "$root/tests/fixtures/calendar-events.json" --render "$work/invalid-now.png" --now not-a-time
[ ! -e "$work/invalid-date.png" ] && [ ! -e "$work/invalid-now.png" ]
expect_usage_64 --toggle --anchor-cg nan 0 116 32
expect_usage_64 --close --close
echo "Calendar panel malformed and bare-toggle arguments fail with EX_USAGE"
self_test_pids=""
self_test_index=0
while [ "$self_test_index" -lt 4 ]; do
  TMPDIR="$self_test_tmp" "$binary" --self-test >"$work/self-test-$self_test_index.out" 2>"$work/self-test-$self_test_index.err" &
  self_test_pids="$self_test_pids $!"
  self_test_index=$((self_test_index + 1))
done
for self_test_pid in $self_test_pids; do wait "$self_test_pid"; done
deliberate_pid_report="$work/deliberate.pid"
if TMPDIR="$self_test_tmp" CALENDAR_PANEL_SELF_TEST_FAIL_CLEANUP=1 CALENDAR_PANEL_SELF_TEST_PID_REPORT="$deliberate_pid_report"     "$binary" --self-test >"$work/deliberate.out" 2>"$work/deliberate.err"; then
  echo "Deliberate self-test failure unexpectedly passed" >&2
  exit 1
fi
/usr/bin/grep -q 'Self-test failed: deliberate cleanup path' "$work/deliberate.err"
[ -f "$deliberate_pid_report" ] || { echo "Deliberate cleanup PID report is missing" >&2; exit 1; }
deliberate_pid=$(/bin/cat "$deliberate_pid_report")
case "$deliberate_pid" in ''|*[!0-9]*) echo "Invalid deliberate cleanup PID report" >&2; exit 1 ;; esac
if /bin/kill -0 "$deliberate_pid" 2>/dev/null; then
  echo "Deliberate cleanup left owned PID $deliberate_pid alive" >&2
  exit 1
fi
temp_base=$self_test_tmp
if /usr/bin/find "$temp_base" -maxdepth 1 \( -name 'calendar-panel-sleeper-*' -o -name 'calendar-panel-self-test-*' -o -name 'calendar-panel-descriptor-*' -o -name 'calendar-panel-provider-*' \) -print | /usr/bin/grep -q .; then
  echo "Calendar self-test artifacts remain" >&2
  exit 1
fi
echo "Calendar panel repeated and deliberate-failure cleanup passed"
if /usr/bin/find "$root" -type f \( -name '*.lua' -o -name 'sketchybarrc' \) -exec /usr/bin/grep -l -e '--anchor-current-pointer' -e '--state-report' {} + | /usr/bin/grep -q .; then
  echo "Attended-only pointer flags leaked into production Lua/config" >&2
  exit 1
fi
render_case() {
  date=$1; name=$2; state=$3; count=$4; shift 4
  "$binary" --fixture "$root/tests/fixtures/calendar-events.json" --date "$date" --now "${date}T12:00:00-07:00" "$@"     --render "$work/$name.png" --geometry "$work/$name.json"
  "$root/tests/validate-calendar-panel.py" "$work/$name.json" "$state" "$count"
}
render_case_at() {
  date=$1; now=$2; name=$3; state=$4; count=$5; shift 5
  "$binary" --fixture "$root/tests/fixtures/calendar-events.json" --date "$date" --now "$now" "$@" --render "$work/$name.png" --geometry "$work/$name.json"
  "$root/tests/validate-calendar-panel.py" "$work/$name.json" "$state" "$count"
}
render_case 2026-08-01 empty empty 0
render_case 2026-08-02 one events 1
render_case 2026-08-03 mixed events 4
render_case 2026-08-04 many events 16
render_case 2026-08-04 many-bottom events 16 --scroll-bottom
render_case 2026-08-05 all-day events 2
render_case_at 2026-08-05 2026-08-04T23:00:00-07:00 all-day-upcoming events 2
render_case_at 2026-08-05 2026-08-05T12:00:00-07:00 all-day-current events 2
render_case_at 2026-08-05 2026-08-06T00:00:00-07:00 all-day-ended events 2
render_case_at 2026-08-01 2026-08-02T12:00:00-07:00 away-today empty 0
render_case 2026-08-06 recurring events 1
render_case 2026-08-07 long events 1
render_case 2026-08-08 links events 4
render_case 2026-08-09 error error 0
render_case 2026-08-10 permission permission 0
render_case 2026-08-11 malformed malformed 0
render_case 2026-08-12 full-day events 4
render_case 2026-03-08 spring-dst events 1
render_case 2026-11-01 fall-dst events 1
render_case 2026-08-13 malicious events 1
render_case 2026-08-14 reorder-a events 2
render_case 2026-08-15 reorder-b events 2
render_case 2026-08-16 normalization events 3
render_case 2026-08-17 boundaries events 2
render_case 2026-08-18 duplicate-identity malformed 0
render_case 2026-08-19 recurring-next events 1
render_case 2026-08-20 multi-day-a events 2
render_case 2026-08-21 multi-day-b events 2
render_case 2026-08-22 multi-day-c events 1
render_case 2026-08-23 multi-day-exclusive empty 0
render_case 2026-08-04 low-clamp events 16 --anchor 700 568 116 32 --display 0 0 1512 600
render_case 2026-08-04 secondary-clamp events 16 --anchor -800 632 116 32 --display -1440 -100 1440 900
"$root/tests/validate-calendar-events.py" "$work"
PYTHONOPTIMIZE=1 "$root/tests/validate-calendar-panel.py" "$work/many-bottom.json" events 16
PYTHONOPTIMIZE=1 "$root/tests/validate-calendar-events.py" "$work"
if "$binary" --fixture "$work/missing.json" --render "$work/invalid.png" >/dev/null 2>&1; then
  echo "Invalid fixture did not fail closed" >&2
  exit 1
fi
[ ! -e "$work/invalid.png" ]
runtime=$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)/sketchybar-runtime
uid=$(/usr/bin/id -u)
stale_holder="stale-holder.$$"
stale_victim="stale-victim.$$"
/bin/rm -f "$runtime/calendar-panel.$uid.$stale_holder.pid" "$runtime/calendar-panel.$uid.$stale_holder.pid.lock" \
  "$runtime/calendar-panel.$uid.$stale_victim.pid" "$runtime/calendar-panel.$uid.$stale_victim.pid.lock"
SKETCHYBAR_CALENDAR_PANEL_INSTANCE="$stale_holder" "$binary" --hold-test &
stale_holder_pid=$!
/bin/sleep 0.2
/bin/kill -0 "$stale_holder_pid"
printf '%s\n' "$stale_holder_pid" >"$runtime/calendar-panel.$uid.$stale_victim.pid"
SKETCHYBAR_CALENDAR_PANEL_INSTANCE="$stale_victim" "$binary" --toggle --hold-test &
stale_victim_pid=$!
/bin/sleep 0.2
/bin/kill -0 "$stale_holder_pid"
/bin/kill -0 "$stale_victim_pid"
SKETCHYBAR_CALENDAR_PANEL_INSTANCE="$stale_victim" "$binary" --close
wait "$stale_victim_pid"
/bin/kill -0 "$stale_holder_pid"
SKETCHYBAR_CALENDAR_PANEL_INSTANCE="$stale_holder" "$binary" --close
wait "$stale_holder_pid"
/bin/rm -f "$runtime/calendar-panel.$uid.$stale_holder.pid.lock" "$runtime/calendar-panel.$uid.$stale_victim.pid.lock"
echo "Calendar panel stale PID cannot signal a same-binary non-lock-holder"

contender_provider="$work/contender-provider.sh"
contender_report="$work/contender-provider.report"
/bin/cat >"$contender_provider" <<'SH'
#!/bin/sh
printf '%s\n' "$$" >>"$CALENDAR_CONTENDER_REPORT"
exit 0
SH
/bin/chmod 0700 "$contender_provider"
instance="provider-order.$$"
runtime=$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)/sketchybar-runtime
weak_lock="$runtime/calendar-panel.$(/usr/bin/id -u).$instance.pid.lock"
/bin/mkdir -p "$runtime"
: >"$weak_lock"
/bin/chmod 0644 "$weak_lock"
pids=""
index=0
while [ "$index" -lt 32 ]; do
  CALENDAR_CONTENDER_REPORT="$contender_report" SKETCHYBAR_CALENDAR_PANEL_INSTANCE="$instance" "$binary" --contender-test --ical-buddy "$contender_provider" &
  pids="$pids $!"
  index=$((index + 1))
done
/bin/sleep 1
owners=0
for pid in $pids; do
  if /bin/kill -0 "$pid" 2>/dev/null; then owners=$((owners + 1)); fi
done
[ "$owners" -eq 1 ] || { echo "Expected one provider-order owner; found $owners" >&2; exit 1; }
[ "$(/usr/bin/stat -f %Lp "$weak_lock")" = 600 ] || { echo "Production reservation did not harden stale lock mode" >&2; exit 1; }
contender_pid_file="$runtime/calendar-panel.$(/usr/bin/id -u).$instance.pid"
[ -f "$contender_pid_file" ] && [ ! -L "$contender_pid_file" ] && [ "$(/usr/bin/stat -f %u "$contender_pid_file")" = "$(/usr/bin/id -u)" ] && [ "$(/usr/bin/stat -f %Lp "$contender_pid_file")" = 600 ] || { echo "Production PID publication is not hardened" >&2; exit 1; }
[ -f "$contender_report" ] || { echo "Production contender owner did not query provider" >&2; exit 1; }
[ "$(/usr/bin/wc -l <"$contender_report" | /usr/bin/tr -d ' ')" -eq 1 ] || { echo "Losing contenders initialized the provider" >&2; exit 1; }
SKETCHYBAR_CALENDAR_PANEL_INSTANCE="$instance" "$binary" --close
for pid in $pids; do wait "$pid"; done
runtime=$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)/sketchybar-runtime
/bin/rm -f "$runtime/calendar-panel.$(/usr/bin/id -u).$instance.pid.lock"
echo "Calendar production singleton precedes provider initialization for 32 contenders"

instance="offline.$$"
pids=""
index=0
while [ "$index" -lt 32 ]; do
  SKETCHYBAR_CALENDAR_PANEL_INSTANCE="$instance" "$binary" --hold-test &
  pids="$pids $!"
  index=$((index + 1))
done
/bin/sleep 1
owners=0
for pid in $pids; do
  if /bin/kill -0 "$pid" 2>/dev/null; then owners=$((owners + 1)); fi
done
[ "$owners" -eq 1 ] || { echo "Expected one singleton owner; found $owners" >&2; exit 1; }
SKETCHYBAR_CALENDAR_PANEL_INSTANCE="$instance" "$binary" --close
for pid in $pids; do wait "$pid"; done
runtime=$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)/sketchybar-runtime
[ ! -e "$runtime/calendar-panel.$(/usr/bin/id -u).$instance.pid" ]
/bin/rm -f "$runtime/calendar-panel.$(/usr/bin/id -u).$instance.pid.lock"
instance=""
echo "Calendar panel singleton stress passed: 32 contenders, one owner, synchronous close"
/bin/cp "$work/mixed.png" "${CALENDAR_PANEL_SCREENSHOT:-/tmp/calendar-panel-offline-final.png}"
/bin/cp "$work/mixed.json" "${CALENDAR_PANEL_GEOMETRY:-/tmp/calendar-panel-offline-geometry.json}"
/bin/cp "$work/many.png" /tmp/calendar-panel-many-top.png
/bin/cp "$work/many-bottom.png" /tmp/calendar-panel-many-bottom.png
/bin/cp "$work/links.png" /tmp/calendar-panel-links.png
/bin/cp "$work/full-day.png" /tmp/calendar-panel-phases.png
/bin/cp "$work/all-day-current.png" /tmp/calendar-panel-all-day-phases.png
/bin/cp "$work/away-today.png" /tmp/calendar-panel-away-today.png
echo "Calendar panel offline gate passed"
