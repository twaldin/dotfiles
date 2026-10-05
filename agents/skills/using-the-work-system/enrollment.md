# Enroll a repository

Enroll a persistent repository only when Tim wants unattended `agent-ready` tickets for it; efforts need no enrollment. Reuse an existing registration; clones and worktrees are not new repositories. Run on the dispatcher host.

1. Write the repository profile: `AGENTS.md` and `WORKFLOW.md` (or the registered pipeline path) covering required validation and reviews, merge behavior, and how the owner verifies landed or deployed acceptance. Link existing technical docs rather than copying them.
2. Personal: find or create the `repo:<key>` label with the native Linear CLI and note its UUID.
3. Write the registration JSON: `key`, `repository` (`github`, `github_user`, `path`, `profile`, `pipeline`, optional `base`, `merge_policy`, `workflow`) and optional `routing.label_id`.
4. Run `omp-tickets enroll --input /absolute/path/registration.json`. It validates identities, installs the profile with backups, verifies native discovery and updates the registry; the dispatcher reloads it without touching existing owners.
5. Commit the registry and profile change in `~/agent-system`. Credentials and live records stay out of it.

A missing or corrupt owner session or worktree needs explicit recovery; enrollment does not replace it.
