#!/usr/bin/env bash
# Firstmate fleet segment for the tmux status line.
# Prints: fleet:wN nN bN fN dN
#   w = working  n = needs-decision  b = blocked  f = failed  d = done
# Counts the LAST status line of each task that has a live state/<id>.meta
# record, so stale/orphan status logs never inflate the counts.
set -euo pipefail

firstmate_home="${FIRSTMATE_HOME:-/Users/twaldin/firstmate}"
state_dir="$firstmate_home/state"

if [ ! -d "$state_dir" ]; then
    printf 'fleet:state-missing'
    exit 0
fi

latest_lines=""
for meta in "$state_dir"/*.meta; do
    [ -e "$meta" ] || continue
    id="$(basename "$meta" .meta)"
    status_file="$state_dir/$id.status"
    [ -f "$status_file" ] || continue
    line="$(tail -n 1 "$status_file" 2>/dev/null || true)"
    [ -n "$line" ] && latest_lines="$latest_lines$line
"
done

if [ -z "$latest_lines" ]; then
    printf 'fleet:idle'
    exit 0
fi

working="$(printf '%s' "$latest_lines" | grep -c '^working:' || true)"
blocked="$(printf '%s' "$latest_lines" | grep -c '^blocked:' || true)"
needs="$(printf '%s' "$latest_lines" | grep -c '^needs-decision:' || true)"
failed="$(printf '%s' "$latest_lines" | grep -c '^failed:' || true)"
done_count="$(printf '%s' "$latest_lines" | grep -c '^done:' || true)"

printf 'fleet:w%s n%s b%s f%s d%s' "$working" "$needs" "$blocked" "$failed" "$done_count"
