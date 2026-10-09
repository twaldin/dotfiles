---
name: new-project
description: Starting a project repository and graduating it to PRs. Use when creating a new project, or when a push-to-main project gains a conflicting second writer, a deploy or users, or CI.
---

## Day one

1. `git init`, commit the first files, then create the private remote and push: `gh repo create <name> --private --source . --push`.
2. Open the project's board (`easl board.open --root <dir>`; it prints the board id) and ask Tim for its goal note: `easl ask "Goal note for <name>: outcome, output metric, current milestone, non-goals, where to look?" --board <board> --wait` as a background bash job (`async: true`, `timeout: 0`). With no options, his answer is a note. Create the note from his words verbatim: `easl object.upsert --board <board> --key goal --type note --json '{"props":{"title":"goal","markdown":"…"}}'`. From then on only Tim edits it.

## Push to main

Until graduation, push straight to `main`. Subagents work in isolated worktrees (`task` with `isolated: true`); the lead merges their results locally, runs the checks and pushes `main`.

## Graduate to PRs

Switch to PRs with auto-merge as soon as any of these holds:

- a second parallel writer stream that can conflict;
- the project deploys or has users;
- CI exists.

To switch, enable auto-merge (`gh repo edit --enable-auto-merge --delete-branch-on-merge`), protect `main` so merges wait for the required checks, and record the switch and its trigger in a board note. From then on, follow AGENTS.md's pull-request rules.
