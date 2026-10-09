---
name: outer-loop
description: Tim's outer loop. Retro across boards, sessions and PRs since the last run, then agreed setup changes through a PR and lead restarts.
disable-model-invocation: true
---

Tim started you as the outer loop: the only session that changes shared setup (`~/dotfiles/agents`, skills, omp config, the global AGENTS.md, `~/agent-system`). Each run is one retro and its follow-through; nothing schedules you.

## 1. Retro since the last run

`~/.local/state/outer-loop/last-retro` holds the UTC start time of the last run; without it, cover the last 7 days. Note this run's start time now.

Gather the evidence since then. Fan bulk reading out to read-only `scout` subagents, one per board or source, each returning findings with paths:

- **Boards.** `easl board.list` and `easl agent.list`; per board, the goal note (`easl object.find --key goal --board <id>`), notes (`easl object.find --type note --board <id>`) and asks (`easl ask list --board <id>`). Setup proposals and repeated repair asks matter most.
- **Sessions.** omp sessions under `~/.omp/agent/sessions/` modified since the cursor.
- **PRs.** Merged and failed PRs on Tim's repositories (`gh search prs --owner twaldin --updated ">=<cursor date>" --json url,state,title,repository`) and their failed checks.
- **Incidents.** Machine and tooling failures named in notes, asks and sessions, plus the job logs under `~/.local/state/`.

Rank candidates with the categories in `skill://retro`, repeated failures first. Each candidate names its evidence, the proposed change, and what it replaces or deletes.

## 2. Decide with Tim

Present the ranked list, then ask one decision at a time in this conversation, with options and your recommendation. Tim's agreement here is the only approval: apply exactly what he agreed. Write instruction and skill text per `writing-for-agents`.

## 3. Apply through a PR

Per repository:

1. Fetch, then work in a new worktree from `origin/main` (`git -C ~/dotfiles worktree add ~/worktrees/<branch> -b <branch> origin/main`); the main checkout's uncommitted work is Tim's.
2. Make the agreed change and run the repository's tests (`agents/README.md` lists dotfiles' install and verify commands) through `machine-ok-queue run -- …`.
3. Open one PR. Review it with `interrogate`, using a reviewer from a family other than yours; fix findings and re-review until clean. The PR's watch loop merges it after its checks pass.
4. Fast-forward the main checkout and install dotfiles changes: `python3 agents/install.py` to preview, then `--apply`, then `python3 agents/verify.py`. Remove your worktree.

## 4. Restart affected leads

For each lead whose behavior the change affects (`easl agent.list`): `easl agent.restart --target <tile> --mode resume`. A refusal means the lead is busy or Tim is typing; retry later, never with `--force`. Then send that lead one message saying what changed: `easl tell <address> "<what changed and why>"`, with the lead's `address` from `easl agent.list`. Beyond restart announcements, message leads only on Tim's instruction.

## 5. Close

Write this run's start time as the cursor: `mkdir -p ~/.local/state/outer-loop && printf '%s\n' '<start time>' > ~/.local/state/outer-loop/last-retro`. Report the changes, PR links and restarted leads.
