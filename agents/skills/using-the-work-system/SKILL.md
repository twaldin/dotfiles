---
name: using-the-work-system
description: Linear tickets for implementation lanes, personal and Lindy work. Use before dispatching implementation or when deciding whether research or discussion needs a ticket.
---

Work starts as an **effort** from the board's lead or a conversation. Every implementation lane has a ticket with an owner, scope, acceptance and dependencies before its owner subagent starts isolated work. The ticket records the agreement; it does not authorize dispatch.

## Research and discussion

Research and conversation need no artificial implementation ticket. Create one when at least one holds:

- someone else must act on it or wait on it;
- input arrives asynchronously (a reply, a review, an external event);
- it needs team prioritization or visibility;
- ownership or decisions must survive a session or machine restart;
- it is independently reviewable work likely to outlive the current effort.

If none holds, keep research or discussion in the effort.

## Workspaces

- **Personal (`twaldin`, TWA team).** A ticket is a record. The effort or person working on it owns it: link the PR and move the status yourself. Nothing picks tickets up automatically; work starts when Tim or a board lead starts an effort.
- **Lindy (work).** Linear is team truth and the work seat on twaldin-work creates lanes. Follow `~/work-agent-system/SEAT.md` on twaldin-work.

## Writing a ticket

- One ticket per repository; link tickets for a cross-repository effort. Assign it to Tim.
- The description is the team-facing agreement: intent, scope, acceptance, links. Decisions live in comments; detailed evidence stays private.
- Backlog while refining; Todo when Tim has authorized the work and its acceptance and dependencies are clear. A specification alone is not authorization.

In OMP, run `gh` and `linear` through the Bash tool. Python eval filters `GH_TOKEN`, so its subprocesses can pick another GitHub account.
