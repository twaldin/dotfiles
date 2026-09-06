# Enroll a repository

Enroll persistent managed repositories when the user requests work-system participation. Reuse a current registration; temporary clones and worktrees are not new repositories.

On the execution host, read the deployment configuration, its maintained registry and workspace authoring policy. Inspect the checkout, GitHub identity, existing tickets/owners and local instructions. Reconcile existing work before selecting the baseline. Retain native local authentication and Git identity.

Maintain a small profile containing AGENTS.md and WORKFLOW.md (or the registered pipeline path): ticket conventions, required validation/review, permitted merge behavior, and how the owner verifies landed/deployed acceptance. Link existing technical references rather than copying them. Define different completion behavior for findings-only work where appropriate.

Follow workspace policy for human organization. In personal TWA, find/create the configured repository label through the authenticated native Linear CLI and retain its UUID. In Lindy, reuse its existing fields and required conventions; an explicit private route or default repository can suffice without any repository label. Linear projects remain efforts.

Prepare registration JSON with `key`, `repository` and optional `routing.label_id`. Repository fields are `github`, `github_user`, `path`, `profile`, `pipeline`, optional `base`, `merge_policy` and `workflow` overrides. Run:

```sh
omp-tickets enroll --input /absolute/path/registration.json
```

Enrollment validates workspace/account/checkout identity, installs the project profile with backups, verifies native discovery, and updates the maintained registry. The dispatcher reloads routes while preserving owners. Inspect the result and commit maintained policy changes in its private source repository when appropriate; no credentials or live records belong there.

Fresh worker worktrees receive the same project-only installation and native verification automatically before the owner starts. A missing/corrupt saved session or owned worktree needs explicit recovery; enrollment does not replace it. Respect any existing pilot allowlist until the planned rollout admits the repository/ticket. Defer intake until the profile and actual scope are ready.
