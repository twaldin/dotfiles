#!/bin/sh
# Start the chief-of-staff (CoS) omp session in a herdr tab named `cos`.
#   start-cos.sh            start it; refuses if a `cos` agent already exists
#   start-cos.sh --replace  rotate: close the old `cos` pane and start fresh.
#                           Requires ~/cos/handoff.md written in the last hour.
set -eu

COS_HOME="$HOME/cos"
PROMPT_SRC="$HOME/dotfiles/agents/cos/COS.md"
MODEL="${COS_MODEL:-anthropic/claude-opus-5-5:xhigh}"
HERDR="${HERDR:-herdr}"

mkdir -p "$COS_HOME/.omp" "$COS_HOME/efforts"
ln -sfn "$PROMPT_SRC" "$COS_HOME/.omp/AGENTS.md"

if "$HERDR" agent get cos >/dev/null 2>&1; then
  if [ "${1:-}" != "--replace" ]; then
    echo "a cos agent is already running; use --replace to rotate it" >&2
    exit 1
  fi
  if [ -z "$(find "$COS_HOME/handoff.md" -mmin -60 2>/dev/null)" ]; then
    echo "refusing to rotate: ~/cos/handoff.md is missing or older than 60 min" >&2
    exit 1
  fi
  old_pane=$("$HERDR" agent get cos | jq -r '.result.agent.pane_id')
  "$HERDR" pane close "$old_pane"
fi

# The CoS lives in the `ops` workspace; create it if missing.
ws=$("$HERDR" workspace list | jq -r '.result.workspaces[] | select(.label == "ops") | .workspace_id' | head -n 1)
if [ -z "$ws" ]; then
  created=$("$HERDR" workspace create --cwd "$COS_HOME" --label ops --no-focus)
  ws=$(printf '%s' "$created" | jq -r '.result.workspace.workspace_id')
  pane=$(printf '%s' "$created" | jq -r '.result.root_pane.pane_id')
  "$HERDR" tab rename "$(printf '%s' "$created" | jq -r '.result.tab.tab_id')" cos >/dev/null 2>&1 || true
else
  pane=$("$HERDR" tab create --workspace "$ws" --cwd "$COS_HOME" --label cos --no-focus | jq -r '.result.root_pane.pane_id')
fi

"$HERDR" agent start cos --kind omp --pane "$pane" -- --model "$MODEL"
"$HERDR" agent prompt cos "Start of session: follow the Start of session steps."
echo "cos started in pane $pane"
