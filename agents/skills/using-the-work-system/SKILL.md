---
name: using-the-work-system
description: Linear tickets and the personal ticket dispatcher. Use when deciding whether work needs a ticket, writing or marking one agent-ready, relaying an owner's question, holding or resuming an owner, enrolling a repository, or settling an owner turn. Ordinary efforts need no ticket.
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

- **Personal (`twaldin`, TWA team).** The dispatcher runs on twaldin-home (`~/.config/omp-linear/config.json`, registry `~/agent-system/policy/personal.json`). It picks up only tickets assigned to Tim, in **Todo**, labelled **`agent-ready`**, with a repository route. Tim decides what is agent-ready: add the label only when he says so. Every other ticket is a record that an effort or a person owns.
- **Lindy (work).** Linear is team truth and the work seat on twaldin-work creates lanes; no dispatcher runs there. Follow `~/work-agent-system/SEAT.md` on twaldin-work.

`omp-tickets` runs on the owning host; `~/.config/agent-setup/workspaces.json` names it when this machine has no deployment.

In OMP, run `omp-tickets`, `gh` and `linear` through the Bash tool. Python eval filters `GH_TOKEN` and `OMP_TICKET_*`, so its subprocesses can pick another GitHub account or lose the owner turn identity.

## References

- Writing a ticket, marking it agent-ready, relaying owner questions, holds: [authoring.md](authoring.md).
- Enrolling a repository with the dispatcher: [enrollment.md](enrollment.md).
- You are a dispatcher owner (your prompt says you own a ticket): [worker.md](worker.md).
