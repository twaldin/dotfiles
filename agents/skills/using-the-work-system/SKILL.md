---
name: using-the-work-system
description: Linear tickets for personal and Lindy work. Use when deciding whether work needs a ticket or writing one. Ordinary efforts need no ticket.
---

Work starts as an **effort**: a session started from the chief-of-staff (CoS) or a conversation, using subagents freely. An effort needs no ticket.

## When a ticket earns its place

Create a Linear ticket only when at least one holds:

- someone else must act on it or wait on it;
- input arrives asynchronously (a reply, a review, an external event);
- it needs team prioritization or visibility;
- ownership or decisions must survive a session or machine restart;
- it is independently reviewable work likely to outlive the current effort.

If none holds, keep the work in the effort.

## Workspaces

- **Personal (`twaldin`, TWA team).** A ticket is a record. The effort or person working on it owns it: link the PR and move the status yourself. Nothing picks tickets up automatically; work starts when Tim or the CoS starts an effort.
- **Lindy (work).** Linear is team truth and the work seat on twaldin-work creates lanes. Follow `~/work-agent-system/SEAT.md` on twaldin-work.

## Writing a ticket

- One ticket per repository; link tickets for a cross-repository effort. Assign it to Tim.
- The description is the team-facing agreement: intent, scope, acceptance, links. Decisions live in comments; detailed evidence stays private.
- Backlog while refining; Todo when Tim has authorized the work and its acceptance and dependencies are clear. A specification alone is not authorization.

In OMP, run `gh` and `linear` through the Bash tool. Python eval filters `GH_TOKEN`, so its subprocesses can pick another GitHub account.
