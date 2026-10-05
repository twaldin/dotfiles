# Tickets and owners

Read the workspace authoring policy named by the registry's `authoring` field before writing a personal ticket. For Lindy, SEAT.md governs.

## Writing a ticket

- One ticket per repository; link tickets for a cross-repository effort. Assign it to Tim.
- The description is the team-facing agreement: intent, scope, acceptance, links. Decisions live in comments; detailed evidence stays private.
- A ticket an effort is already working on stays without `agent-ready`. The effort owns it: link the PR and move the status itself.

## Handing a ticket to the dispatcher

Only when Tim marks it ready:

1. Create it in Backlog and route it: the `repo:<key>` label, or `omp-tickets register <issue> --repo <key>`.
2. Save the private brief: `omp-tickets refine <issue> --input <file>`.
3. Add `agent-ready` and move it to Todo.

Report it started only when `omp-tickets show <issue>` names a native session. If none starts, check in order: `agent-ready`, assignee, Todo, route, hold or blocking dependencies, `pilot_issues`, capacity, preparation errors. Fix the input and keep the existing record. Removing `agent-ready` later does not stop an owner that already started; use `hold`.

## Existing owners

```sh
omp-tickets show TWA-7        # record, brief, phase
omp-tickets attention         # owner questions waiting on Tim
omp-tickets refine TWA-7 --input /abs/brief.md   # new scope or an answer; wakes the same owner
omp-tickets hold TWA-7 --reason '...'            # stop the turn, keep session and worktree
omp-tickets release TWA-7
omp-tickets retry TWA-7
```

Owner questions are private attention, not Linear comments. Relay them to Tim and deliver his answer with `refine`, or as his Linear comment when the team should see the decision. Either wakes the same owner. A brief edit does not release a hold.
