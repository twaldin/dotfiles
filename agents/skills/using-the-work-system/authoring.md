# Writing a useful ticket

The Linear description is the human-facing agreement: intent, scope, and observable acceptance. Keep it small enough to read easily. Fold decisions that change the task back into that description. Link maintained specifications where useful.

Use the selected grilling, wayfinding, and to-tickets skills to clarify and split outcomes. Scale the result to the task:

- What should change or become known, and why?
- What belongs in scope, and what constraints actually matter?
- How will we know the outcome is achieved?

Put investigation trails, implementation suggestions, detailed check/review evidence, and runner data outside Linear. When extra agent context is useful, use `~/.local/state/omp-linear/<issue-uuid>/notes.md` on the executing host (directory 700, file 600). It is optional and supplements the ticket; it cannot silently change public scope or acceptance. Resolve the UUID through Linear rather than guessing. The runner supplies this path to its owner. Notes alone do not dispatch or wake work; the current ticket state controls authorization.

Set Tim as assignee, choose the outcome project, and use the smallest routing signal the configuration needs. Add genuine technical dependencies as blocking relations. Backlog holds ideas; Triage holds unresolved intake decisions; Todo authorizes executable work. Read the live board and current code before adding or promoting a ticket. Preserve existing ownership and check any dispatch allowlist.

A scoped investigation is executable even when its answer is unknown. A task with unclear permission, ownership, or desired change is not. Let the worker choose findings, artifacts, one PR, or a stack unless the required output matters to acceptance. Put shared review/merge policy in the project pipeline rather than every ticket.

For docs cleanup, correct demonstrated inaccuracies and remove demonstrated duplication or obsolete process. A name like plan, spec, or handoff is not evidence that a file is disposable. Preserve useful constraints, decisions, research, third-party material, and user content. Keep uncertain removals as specific follow-ups. Finding no justified change is a valid result; do not invent a cosmetic PR.
