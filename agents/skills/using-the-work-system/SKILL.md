---
name: using-the-work-system
description: Create or refine Linear work-system tickets, enroll repositories, answer worker questions, hold or resume owners, and inspect their progress. Load the target workspace and repository policy; ordinary coding conversations need no ticket.
---

Resolve the target from the repository, ticket URL or user's request. Read the executing host's `~/.config/omp-linear/config.json` and its referenced registry. When this host has no deployment, `~/.config/agent-setup/workspaces.json` may point to its owning host and configuration. Match the requested ticket/workspace to that configuration before any mutation; do not fall back to this machine's other workspace. Run commands on the owning host with its existing local authentication. Without a known deployment, discuss the work or follow enrollment; do not invent an account, queue or dispatcher.

Load the configured workspace authoring reference and repository profile/pipeline before changing a ticket. Linear's visible teams, labels, projects and states are workspace conventions. The private registry and ticket record hold resolved routing, canonical scope and execution state.

In OMP, run authenticated CLI commands and ticket-control commands through the native Bash tool. Python eval filters the launch-selected `GH_TOKEN` and `OMP_TICKET_*` variables; its subprocesses can select a different GitHub account or lose the owner turn identity. Verify the selected account in the environment that will perform the operation. Keep the Python filter intact rather than copying credentials into eval.

Choose the relevant reference:

- Creating/refining tickets, answering questions or pausing work: [authoring.md](authoring.md).
- Adding a persistent repository or preparing its policy: [enrollment.md](enrollment.md).
- Owning a ticket through work, waiting and completion: [worker.md](worker.md).

Use `omp-tickets show <issue>` and live Linear/PR context before contributing to existing work. Preserve its owner, session and worktree. Questions and answers belong in concise Linear comments; detailed execution evidence stays in the private task directory. Ordinary conversations can contribute without becoming another implementation owner.

Keep credentials and work code on their owning host. Follow the selected workspace's existing conventions and merge authority. Personal repository labels are personal policy; Lindy requires its own existing fields and authoring guidance.
