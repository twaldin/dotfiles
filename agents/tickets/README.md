# Linear → OMP

One process polls one Linear workspace. Each authorized ticket gets one worktree and one native OMP session. That session follows its project's pipeline through implementation, review, feedback, Tim's merge, and landing validation. Temporary reviewers do not take over ownership. There is no stage scheduler or Symphony runtime fork.

```sh
omp-tickets status
omp-tickets check          # candidates, no dispatch; stop the service first
omp-tickets once
omp-tickets serve
omp-tickets retry TWA-7    # explicit retry of its existing owner
```

`~/.config/omp-linear/config.json` pins the executing hostname, workspace and authenticated assignee. `repos` supplies checkout, GitHub repository/account, pipeline and optional model. `projects` maps outcome projects to repositories; an optional `default_repo` suits a one-repo workspace. Use one repo label only for otherwise ambiguous cross-repo tickets. Conflicts and unknown routes fail closed.

Only Tim's assigned Todo tickets dispatch. Backlog/Triage/Canceled or reassignment withdraw execution. Real dependencies gate work. `pilot_issues` is an optional allowlist: an empty list admits nothing; removing the key allows configured, eligible Todo tickets. Concurrency limits running turns, not outputs: findings, artifacts, one PR, and stacks are supported. Attach every required PR to Linear so all are watched.

Linear is human-facing. Keep intent, scope, observable acceptance, useful decisions, state, deliverable links, and a short outcome there. The runner posts no claim/retry comments and creates no infrastructure-error labels. Detailed context and evidence can live in `~/.local/state/omp-linear/<issue-uuid>/notes.md` (700 directory, 600 file). It is optional and cannot silently change ticket acceptance. No hidden Linear metadata is used as private storage.

The local SQLite record holds execution identity, delivered event fingerprints and retries. Native OMP session files are the transcript; stdout is discarded instead of duplicated. Private worker/stderr logs retain operational diagnostics. A turn that ends while still In Progress is retried so unfinished work cannot silently park. Three failed attempts pause for explicit retry; inspect `status` or the private monitor. No secrets should be printed by workers.

Parked owners remain watched and release their coding slots. Every new Linear comment is delivered, regardless of author or prefix. A worker's own meaningful update can cause a no-op wake; its instructions say to finish quietly. Events arriving during a turn are not silently acknowledged. GitHub checks/reviews are read on current PR heads, with pagination; larger queues/stacks may need a longer poll interval to respect API limits.

Completion comes from ticket acceptance and project prose. Ready to Merge and Merged remain watched; an approval or green check alone is not Done. After required landing checks, the owner marks Done. Missing/corrupt sessions or missing owned worktrees require explicit recovery rather than silently discarding context. Owner locks survive a polling-process restart and a killed Python wrapper.

One dispatcher host per deployment. Home runs personal work; Deckbox is not a competing dispatcher. Lindy cutover remains separate. Credentials, sessions and worktrees stay on their owning host.
