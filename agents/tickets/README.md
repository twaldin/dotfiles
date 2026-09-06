# Linear and native OMP owners

One dispatcher polls one workspace. A ticket gets one worktree and one native OMP session through investigation, questions, implementation, review, merge and landed acceptance. The owner follows its repository pipeline; the dispatcher delivers input and scheduled wakeups.

## Configuration and registry

`~/.config/omp-linear/config.json` pins the executing host, authenticated workspace/user, state directory, concurrency and poll cadence. An optional `registry` path loads maintained `repos`, `routes`, `teams`, `workflow`, `merge_policy`, `authoring` and `default_repo`. Credentials remain in native machine-local stores. The service reloads policy between polls; changing deployment identity requires a deliberate restart.

Each repository records `github`, `github_user`, checkout `path`, `profile` directory, `pipeline`, optional `base`, `model`, `merge_policy` and `workflow` overrides. Profile preparation uses the existing installer in project-only mode, backs up changes and verifies native OMP/Codex discovery. Subsequent worktrees receive it automatically before their owner starts. A host without Codex records that limitation.

`routes.labels` maps label UUIDs to repository keys; `routes.teams` and optional `routes.projects` provide other workspace hints. `default_repo` needs no public repository field. A conversation can directly register a ticket's repository. Existing ownership uses its saved route even if display hints change. A workspace may explicitly configure `routes.label_prefix`; the engine supplies no repository-label prefix. Migrate old conventions into policy before enabling the updated dispatcher.

Workspace `workflow` supports:

- `start_states`: existing state UUIDs/names that request an owner. Configure `["Todo"]` for the selected initial personal/work defaults; an absent mapping requests no owners.
- `defer_states` / `cancel_states` and `defer_types` / `cancel_types`: explicit withdrawal mappings. Defaults defer Backlog/Triage types and stop canceled/duplicate work.
- `excluded_labels`: optional intake exclusions chosen by this workspace.
- `states`: publication keys such as active/review/ready/landed/complete mapped to existing state names or UUIDs. An absent or empty map publishes no statuses. Unknown/unmapped stages leave the current field alone.
- `attention_labels`: optional existing label UUIDs/names used for human attention. Updates touch only these labels and preserve unrelated ones.

Team and repository workflow overrides refine the workspace mapping. `teams.<uuid>.states` records existing name-to-ID mappings. The shared engine requires no custom team, state or label. Personal repository labels and Lindy's existing authoring conventions belong in their maintained policy.

`pilot_issues` is an optional UUID/readable-identifier allowlist. Empty admits no new work; removing it admits eligible registered work. It does not remove an existing owner's identity. Concurrency counts running turns; waiting owners release their slots.

## Conversation and owner commands

```sh
omp-tickets status
omp-tickets attention
omp-tickets show TWA-7
omp-tickets enroll --input /absolute/path/repository.json
omp-tickets register TWA-7 --repo website
omp-tickets refine TWA-7 --input /absolute/path/brief.md
omp-tickets hold TWA-7 --reason 'Wait for the scope discussion'
omp-tickets release TWA-7
omp-tickets retry TWA-7
```

Enrollment input contains `key`, `repository` and optional `routing.label_id`. Create/reuse human fields through the workspace's authoring guidance; the engine validates supplied identities and retains the registry mapping. Enrollment does not itself promote Backlog work or create another dispatcher.

The global using-the-work-system skill directs any ticket conversation to workspace/project guidance. A small optional `~/.config/agent-setup/workspaces.json` index can identify the owning host/configuration when this machine has no deployment. Run operations on the owning host; ordinary coding conversations need no ticket.

An owner ends each turn with `settle`, supplying JSON with `lifecycle` active/waiting/complete, optional publication `stage`, `attention`, `next_check_at` (Unix timestamp), and acceptance `evidence` for completion. Its environment identifies the current ticket/turn/configuration. The skill contains the command and field guidance. An unfinished exit retries the same owner; exhausted retries become private attention.

## Durable behavior

The private SQLite record holds the canonical brief, explicit holds, attention, lifecycle and next check separately from runtime snapshots. Transactional control updates survive a worker saving an older runtime snapshot. They do not arbitrate conflicting conversations. Tim and the agents coordinate scope through ordinary discussion.

A Linear start/defer transition is an explicit input. Other permitted statuses/labels publish internal progress; failed publication is retried without preventing authorized coding. Questions and answers stay concise on Linear. Holds stop the current process group and preserve the native session/worktree; release returns to that owner. While Linear is unreadable, owner guidance permits coding but requires waiting before merge/deploy until new input can be checked.

Every changed ticket/PR snapshot is delivered regardless of comment author or prefix. A worker's own update can cause one quiet acknowledgement. Completed owners remain observed, with configurable `completed_poll_seconds` (default 300). Changes arriving during or after the final turn are not acknowledged from an unread snapshot. Scheduled checks wake the same owner. GitHub snapshots include PR head, draft/auto-merge signals, paginated checks, statuses, reviews/comments and all attached PRs in a stack.

Personal `auto` owners use the normal permitted merge path after required review/checks/acceptance, respecting holds and branch protections. Lindy `tim-enables-auto` means Tim enables auto-merge; owners watch its existing pipeline and verify landed/deployed acceptance. Repository-specific deployment interpretation stays in the pipeline reference and owner.

Native sessions are the transcript; stdout is discarded. Diagnostics and evidence stay in the private state directory. Missing/corrupt sessions or owned worktrees require explicit recovery. Keep ownership locks, local auth and original Git identities across rollout and restarts.
