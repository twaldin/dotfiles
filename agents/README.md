# Agent setup

One maintained skill library, small project guidance, and native harnesses. OMP runs tickets; Codex can be used entirely on its own.

`skills.json` selects 26 general skills. `vendor/` holds pinned upstream sources and licenses; `adapt.py` makes approved changes only in generated copies. `skills/` holds the short local guides. The work-system guide is globally discoverable and loads workspace/repository policy only for relevant ticket operations.

## Install and verify

Requires Python 3.11+ and Bun for existing OMP YAML settings. Run separately on each machine:

```sh
python3 agents/install.py                         # preview
python3 agents/install.py --apply                 # archive and install
python3 agents/verify.py                          # native OMP, no model turn
python3 agents/verify_codex.py                    # native Codex, no model turn
```

`~/.agents/skills` is the canonical discovery path. Codex, Claude, OMP, Pi, Factory, Cursor, and other detected global skill directories point to it. Generated skill/reference files live in `~/.local/share/agent-setup/library`. Codex's native `.system` skills and installed native plugins remain separate from the selected catalog. Generated vendor plugin manifests are omitted so skill names are consistent across harnesses.

Global AGENTS/CLAUDE entry points link to `instructions.md`: concise writing, simple solutions, local authentication, and respect for project scope. Native browser/computer tools come first. Herdr is the only retained custom hook. Old custom MCP servers, imported workflow plugins, and legacy instruction/skill copies are archived; native capabilities and model accounts stay local.

`omp.json` is the shared OMP baseline. It owns model roles and the explicitly listed shared preferences; installation replaces the entire role map, so removed roles such as vision stay unset. Keep permanent shared changes here and install separately on home, work and Deckbox. Interactive global role changes can cause drift until the next install. Authentication, provider accounts, local tools/connections, QA consent and project discovery exclusions remain machine-local.

Native project settings and explicit session overrides can supersede the global baseline. Existing owners retain their saved models when available; installing a new default does not migrate or replace them. Future task launches reload settings, so verify the actual helper model when counting an independent review. A model listed by the native catalog confirms configured authentication, not a successful inference or available quota.

The model-cycle shortcut follows default → fable → slow: Astra high, Fable 5.1 xhigh, then Sol xhigh. The native custom fable role gives the shortcut its requested effort while the task role remains Fable 5.1 high. Cycling changes the active session model; it does not rewrite global role assignments.

The bundled reviewer and security-reviewer use `@review` (Grok 4.6 xhigh). Run Standards and Spec in separate contexts. This shared route differs from the OpenAI and Anthropic authoring roles; if an author switches to xAI, explicitly select an available reviewer from another family and verify its actual model. Selecting an advisor model does not enable the advisor; it remains disabled.

## Project scope

Open conversations in the actual repository or worktree. A project source contains a short `AGENTS.md`, optional selected `skills/`, and its pipeline when enrolled in ticket execution:

```sh
python3 agents/install.py --project /path/to/repo --project-source /path/to/guidance --apply
python3 agents/verify.py /path/to/repo/nested --project /path/to/repo
python3 agents/verify_codex.py /path/to/repo /path/to/repo/nested
```

Repeat `--project` for existing worktrees sharing a profile. Installation adds the work-system skill, local ignored project entry points, and native discovery exclusions. Team-owned skill files remain intact; Codex hides their old skill names and explicitly enables the selected canonical paths. The filters are shared across worktrees. Registered ticket worktrees receive project-only installation and verification automatically. Standalone checkouts can use --project-only with --project and --project-source after global setup; this preserves global models and local settings while updating discovery exclusions. Nested subsystem instructions still apply and must be checked for conflicting process.

Tracked `.agents/skills` remains intact. Its team skills join the managed OMP view for that worktree; managed additions are exposed separately through ignored native Codex links. Each worktree keeps its own view, and preparation refreshes when team skill inventory changes. Conflicting tracked managed entry points or skill projection paths require reconciliation rather than replacement.

The installer backs up every replaced path under `~/.local/state/agent-setup/backups` and records a manifest. `--restore <backup>` restores only if none of those paths changed afterward; otherwise use the manifest for selective recovery without overwriting newer work. Credentials, native sessions, Git history, and running sessions are never synchronized or reset. Existing conversations retain old context; verify with fresh sessions.

## Work system

[tickets/](tickets/) contains the small Linear-to-OMP dispatcher. One session owns each ticket through its project's pipeline, including waits and landing validation. Linear holds the human task, decisions, status, and deliverable links. Canonical briefs, owner outcomes, holds, attention and wake bookkeeping stay privately on the executing host, alongside review evidence, diagnostics and native sessions. Linear fields are configured intake/publication mappings.

Work and personal are separate deployments. Lindy code, accounts, project guidance, and sessions stay on work. Home executes the personal queue; Deckbox has the same general setup but is not a second dispatcher. Personal owners merge after their project checks and reviews pass, unless Tim specifies a ticket override. For Lindy, Tim enables PR auto-merge himself and the existing pipeline merges when ready. No duplicate ownership or shared credential store is introduced.

The home catch-up directory is `~/agent-system`. Its README records the current rollout and points to the actual sources, local configuration, private notes, and Linear. Live Lindy ownership changes only through a deliberate later cutover.

Upstream: Matt Pocock skills at `3cca18b368ae95cdbdebbff572ccafa662551015`; Vercel references at `063bee94c3f4df8453406c830b0a7df0f2860278`. Source metadata and licenses are retained. Do not run their bulk installers over this selected library.
