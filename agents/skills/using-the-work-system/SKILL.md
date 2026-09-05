---
name: using-the-work-system
description: Use the configured Linear work system to refine tickets, authorize dispatch, or check workers and deliverables. Only for projects enrolled in this system.
---

Start in the actual repository. Read its project guidance and pipeline. `~/.config/omp-linear/config.json` identifies the local workspace, Tim's assignee ID, repository routes, merge defaults, and any dispatch gate. Without that configuration, keep discussing the work; do not invent a runner or workspace.

Use native tools or the authenticated CLI: `linear --workspace <slug> …`. Check subcommand help before guessing flags. Credentials stay local. Work and personal are separate: Lindy code, accounts, context, and execution stay on work.

## Conversations and tickets

Read [authoring.md](authoring.md) when creating or refining work. Check existing tickets, PRs, active owners, and current source first. A Linear project describes an outcome, so several projects can use one repo. Use the configured project route or workspace default; add one `repo:<name>` label only for an otherwise ambiguous cross-repo project. Conflicting routes must be resolved before dispatch.

Assign our tickets to Tim. In a shared workspace, other people's tickets are context, not our queue. The CLI's default list shows assigned issues; use an explicit broader query when researching. Keep ideas in **Backlog**, unresolved intake decisions in **Triage**, and authorized, executable work in **Todo**. Use real blocking relations for technical dependencies, not rollout gates. Check the configured allowlist before promising execution. Preserve active ownership; never start a second implementation session for an owned ticket.

## Workers

One native OMP session owns each ticket through completion, including feedback and landing validation. Follow the project's pipeline. Choose the outputs that fit the task: findings, an artifact, a PR, or a stack. Attach every required PR to Linear so all are watched. Temporary reviewers report back to the same owner; they do not become pipeline-stage owners.

Linear is for people: a concise task, meaningful decisions or blockers, deliverable links, and a short outcome. Do not post claims, retry errors, session IDs, internal briefs, repeated checklists, or routine progress comments. Use status alone when it conveys the update. Keep optional execution notes and detailed review/check evidence in the private task directory supplied by the runner. Do not put secrets or private notes in Linear attachment metadata.

Merge authority comes from Tim's current ticket-specific instructions, then the repository's `merge_policy`, then the workspace default. Personal projects default to `auto`: the owner merges when the project's required reviews, checks, and acceptance pass, without waiting for Tim. Use the repository's normal merge method or native auto-merge; verify the current head and stack order, and respect branch protection. A ticket can explicitly require Tim's approval instead. Lindy's normal policy is `tim-enables-auto`: Tim enables PR auto-merge himself; the existing pipeline merges when its requirements pass. Agents prepare and watch Lindy PRs rather than enabling auto-merge or directly merging them. Historical manual-merge boilerplate is not a current ticket override.

Use the actual workspace states as applicable: **In Progress**, **In Review**, **Ready to Merge**, **Merged**, **Done**. Ready to Merge means prepared for the configured merge path; personal auto-merge work need not wait there for Tim. Use `blocked` only for a real unresolved task decision or dependency, with a concise explanation of what is needed. Clear it only when resolved. Runner/provider failures belong in private diagnostics.

When waiting, end the turn. The dispatcher resumes this same session when Linear or GitHub changes. A wake containing only your own prior update needs no reply. Determine Done from ticket acceptance and the project pipeline: code must reach its intended destination and pass applicable landing checks; findings-only work can finish without a PR and must leave no unshipped edits. Approval, green CI, or an ended turn alone is not completion. Preserve human comments and unrelated labels.

Immediately before marking a PR ready, enabling an authorized merge path, merging, or marking Done, refresh the ticket description/comments and the current PR state/reviews. Address new actionable feedback against acceptance. Investigate an unexpected draft transition before undoing it. Refresh and preserve existing private notes when writing evidence; another conversation may have added a finding during your turn.

`omp-tickets status` is private diagnostics. Configuration, recovery, and explicit retry are setup maintenance, not ordinary worker tasks.
