#!/bin/bash
set -f

data=$(cat)

if [ -z "$data" ]; then
  exit 0
fi

# --- Gruvbox ANSI palette (Ghostty maps these) ---
R=$'\033[1;0m'
GRY=$'\033[1:30m'
RED=$'\033[1;31m'
GRN=$'\033[1;32m'
YEL=$'\033[1;33m'
BLU=$'\033[1;95m'
AQA=$'\033[1;95m'
ORG=$'\033[1;33m'
FG=$'\033[1;m'

SEP=" ${GRY}|${R} "

# --- CWD ---
cwd=$(echo "$data" | jq -r '.cwd // empty')
[ -z "$cwd" ] && cwd=$(pwd)
raw_cwd="$cwd"

# Worktrees: show project dir instead (we have wt:name in branch)
if [[ "$cwd" == */.claude/worktrees/* ]]; then
  proj=$(echo "$data" | jq -r '.workspace.project_dir // empty')
  [ -n "$proj" ] && cwd="$proj"
fi

cwd="${cwd/#$HOME/~}"
IFS='/' read -ra parts <<< "$cwd"
n=${#parts[@]}
if [ "$n" -gt 2 ]; then
  cwd="${parts[$((n-2))]}/${parts[$((n-1))]}"
fi

# --- Git ---
branch=""
staged=0
unstaged=0
added=0
if git -C "$raw_cwd" rev-parse --git-dir >/dev/null 2>&1; then
  branch=$(git -C "$raw_cwd" symbolic-ref --short HEAD 2>/dev/null \
           || git -C "$raw_cwd" rev-parse --short HEAD 2>/dev/null)

  # Shorten worktree branch names: worktree-foo-bar-baz → wt:foo-bar-baz
  if [[ "$branch" == worktree-* ]]; then
    branch="wt:${branch#worktree-}"
  fi
  [ ${#branch} -gt 25 ] && branch="${branch:0:23}.."

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    x="${line:0:1}"
    y="${line:1:1}"
    if [ "$x" = "?" ]; then
      added=$((added + 1))
    else
      [ "$x" != " " ] && staged=$((staged + 1))
      [ "$y" != " " ] && unstaged=$((unstaged + 1))
    fi
  done < <(git -C "$raw_cwd" status --porcelain 2>/dev/null)
fi

# --- Context bar + percent ---
ctx=""
used_pct=$(echo "$data" | jq -r '.context_window.used_percentage // empty')
if [ -n "$used_pct" ] && [ "$used_pct" != "null" ]; then
  pct=$(printf "%.0f" "$used_pct" 2>/dev/null)
  [ "$pct" -gt 100 ] 2>/dev/null && pct=100

  # Color based on usage tier
  if [ "$pct" -lt 25 ] 2>/dev/null; then CC="$GRN"
  elif [ "$pct" -lt 50 ] 2>/dev/null; then CC="$YEL"
  elif [ "$pct" -lt 75 ] 2>/dev/null; then CC="$ORG"
  else CC="$RED"; fi

  # Build 10-segment bar
  filled=$(( pct / 10 ))
  empty=$(( 10 - filled ))
  bar="${CC}"
  for ((i=0; i<filled; i++)); do bar+="●"; done
  bar+="${GRY}"
  for ((i=0; i<empty; i++)); do bar+="○"; done
  bar+="${R}"

  ctx="${SEP}${bar} ${CC}${pct}%${R}"
fi

# --- Model ---
model=$(echo "$data" | jq -r '.model.display_name // .model.id // empty')
mdl=""
[ -n "$model" ] && mdl="${SEP}${GRY}${model}${R}"

# --- Output (context first so it's always visible regardless of width) ---
printf '%b' "${ctx#$SEP}"
printf '%b' "${SEP}${AQA}${cwd}${R}"
[ -n "$branch" ] && printf '%b' "${SEP}${ORG}${branch}${R}"
printf '%b' "${SEP}${GRY}S ${GRN}${staged}${R}"
printf '%b' "${SEP}${GRY}U ${RED}${unstaged}${R}"
printf '%b' "${SEP}${GRY}A ${YEL}${added}${R}"
printf '%b' "${mdl}"
