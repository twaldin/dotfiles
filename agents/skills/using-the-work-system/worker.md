# Owning a dispatched ticket

You own one ticket, its worktree and its native session from first wake to landed acceptance. Every wake: read the brief, new ticket input, private `notes.md` and the repository pipeline.

## Delivery

- Follow the pipeline: findings or PR, required checks and independent reviews, feedback, merge, landed or deployed acceptance. Attach every PR to the ticket.
- Local edits are unfinished work. Complete with findings only when the finding itself satisfies the brief and no intended change is left unshipped; check the actual worktree, PR and landed revision first.
- One PR per effort. Split only for a different owner, a separate deploy or rollback, or a protected-path split; a dependent PR targets the default branch, says "Depends on #N" and stays unarmed until #N merges.
- Immediately before marking ready, merging, deploying or completing, re-read ticket discussion and the PR head, draft state, checks and reviews. If Linear is unreadable, keep coding but wait before merge or deploy.

## Merge authority

Tim's current ticket instruction, then repository policy, then workspace default.

- Personal `auto`: merge through the normal allowed path once required checks, reviews and acceptance pass, respecting branch protection and stack order.
- Lindy `arm-auto-at-open`: arm auto-merge when opening a PR against `main` that waits on no open PR; GitHub's required checks and approvals decide. Any other base stays unarmed until retargeted. A hold keeps it unarmed.

## Questions and probes

- A decision Tim must make: write the question and your recommended default to `notes.md`, settle `waiting` with that question as `attention`, and leave ticket state and comments alone. The answer wakes this same session.
- Give each probe or helper a finite lifetime and record its process handles. Clean up only those recorded handles, after confirming they still belong to the probe; name or pattern matches (`pkill -f`, `killall`) are not ownership. If ownership is unclear, report the targets instead of killing.

## Settle every turn

Linear status does not tell the runner your outcome. Write an outcome JSON in the private task directory and run:

```sh
python3 "$OMP_TICKETS_RUNNER" settle "$OMP_TICKET_ID" --input /absolute/path/outcome.json
```

- `lifecycle`: `active` (needs another turn), `waiting` (park), or `complete` (landed and accepted).
- `stage`: optional publication key such as `review`, `ready`, `landed`; completion selects `complete`.
- `attention`: null, or `{reason, kind?, url?}` where `reason` is the question plus your recommended default.
- `next_check_at`: null, or a Unix timestamp for the next pipeline check. Waiting on an answer needs no timer.
- `evidence`: concise acceptance evidence; required for `complete`, including findings-only work.

Completed tickets stay watched. When later feedback needs more work, settle `active` before starting it.
