#!/usr/bin/env bash
set -euo pipefail

choose=0
verbose=0
attachable_statuses="Attached Ready AgentWorking IdleWaiting Paused IdlePaused"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --choose)
            choose=1
            shift
            ;;
        --verbose)
            verbose=1
            shift
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if ! command -v lndev >/dev/null 2>&1; then
    [[ "$verbose" -eq 1 ]] && tmux display-message "lndev not found on PATH"
    exit 1
fi

created=0
seen=0

while read -r id status; do
    [[ -z "${id:-}" || -z "${status:-}" ]] && continue
    if [[ " $attachable_statuses " != *" $status "* ]]; then
        continue
    fi

    seen=$((seen + 1))
    short_id="${id:0:6}"
    session_name="lndev-${short_id}"

    if tmux has-session -t "=${session_name}" 2>/dev/null; then
        continue
    fi

    tmux new-session -ds "$session_name" \
        "lndev shell attach '$id'; printf '\\n[lndev detached from %s]\\n' '$id'; read -r"
    tmux rename-window -t "=${session_name}:1" "$short_id"
    created=$((created + 1))
done < <(
    lndev shell ls | awk '
        NR == 1 { next }
        {
            id_index = 0
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[0-9a-f]{24}$/) {
                    id_index = i
                    break
                }
            }
            if (id_index > 0 && (id_index + 1) <= NF) {
                print $id_index, $(id_index + 1)
            }
        }
    '
)

if [[ "$verbose" -eq 1 ]]; then
    tmux display-message "lndev tmux sync: ${seen} attachable, ${created} created"
fi

if [[ "$choose" -eq 1 ]]; then
    tmux choose-session
fi
