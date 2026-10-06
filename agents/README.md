# Agent setup

One maintained skill library, small project guidance, and native harnesses. OMP runs the sessions; Codex can be used entirely on its own.

`skills.json` selects 21 general skills. `vendor/` holds pinned upstream sources and licenses; `adapt.py` makes approved changes only in generated copies. `skills/` holds the short local guides. Machine-specific procedure (such as `mac-gui` for Spaces, yabai and virtual screens) lives in skills, not in `instructions.md`, because skill descriptions reach omp subagents and AGENTS.md files do not.

## Install and verify

Requires Python 3.11+ and Bun for existing OMP YAML settings. Run separately on each machine:

```sh
python3 agents/install.py                         # preview
python3 agents/install.py --apply                 # archive and install
python3 agents/install.py --library-only --apply  # skills, instructions and agents only; no harness settings
python3 agents/verify.py                          # native OMP, no model turn
python3 agents/verify_codex.py                    # native Codex, no model turn
```

`~/.agents/skills` is the canonical discovery path. Codex, Claude, OMP, Pi, Factory, Cursor, and other detected global skill directories point to it. Generated skill/reference files live in `~/.local/share/agent-setup/library`. Codex's native `.system` skills, Claude Code's `synced` organization skills, and installed native plugins remain separate from the selected catalog and survive reinstalls. Generated vendor plugin manifests are omitted so skill names are consistent across harnesses.

Global AGENTS/CLAUDE entry points link to `instructions.md`; never edit an installed copy, because a regular file there silently forks from the source. Native browser/computer tools come first. Herdr is the only retained custom hook. Extensions installed by other tools (herdr, Canvas) are left alone. Old custom MCP servers, imported workflow plugins, and legacy instruction/skill copies are archived; native capabilities and model accounts stay local.

`omp.json` is the shared OMP baseline. It owns model roles and the explicitly listed shared preferences; installation replaces the entire role map, so removed roles such as vision stay unset. Fallback chains merge per role: the baseline's chains win, other roles keep their local chains. Keep permanent shared changes here and install separately on home, work and Deckbox. Interactive global role changes can cause drift until the next install. Authentication, provider accounts, local tools/connections, QA consent, Codex reset redemption, thinking-block display and project discovery exclusions remain machine-local; exclusions for directories that no longer exist are dropped.

Native project settings and explicit session overrides can supersede the global baseline. Existing owners retain their saved models when available; installing a new default does not migrate or replace them. Future task launches reload settings, so verify the actual helper model when counting an independent review. A model listed by the native catalog confirms configured authentication, not a successful inference or available quota.

The model-cycle shortcut follows default → fable → slow: Opus 5.5 xhigh, Fable 5.1 xhigh, then GPT-6.1 Sol xhigh. `task` is Sonnet 5.5 xhigh; `tiny` and `smol` are GLM 5.3 Flash. Failed turns fall back by role (`retry.fallbackChains` in `omp.json`): default and task to GPT-6.1 Sol, sol to Sonnet 5.5, review to Grok 4.7, tiny to GPT-6 Luna, any OpenCode Go model to GLM 5.3 Flash. Cycling changes the active session model; it does not rewrite global role assignments.

The bundled reviewer and security-reviewer use the `review` role (GPT-6 Astra xhigh); scout uses `sol`. The code-review skill picks reviewers from a different family than the author. Selecting an advisor model does not enable the advisor; it remains disabled.

## Project scope

Open conversations in the actual repository or worktree. A project source contains a short `AGENTS.md` and optional selected `skills/`:

```sh
python3 agents/install.py --project /path/to/repo --project-source /path/to/guidance --apply
python3 agents/verify.py /path/to/repo/nested --project /path/to/repo
python3 agents/verify_codex.py /path/to/repo /path/to/repo/nested
```

Repeat `--project` for existing worktrees sharing a profile. Installation adds the work-system skill, local ignored project entry points, and native discovery exclusions. Team-owned skill files remain intact; Codex hides their old skill names and explicitly enables the selected canonical paths. The filters are shared across worktrees. Standalone checkouts can use --project-only with --project and --project-source after global setup; this preserves global models and local settings while updating discovery exclusions. Nested subsystem instructions still apply and must be checked for conflicting process.

Tracked `.agents/skills` remains intact. Its team skills join the managed OMP view for that worktree; managed additions are exposed separately through ignored native Codex links. Each worktree keeps its own view, and preparation refreshes when team skill inventory changes. Conflicting tracked managed entry points or skill projection paths require reconciliation rather than replacement.

The installer backs up every replaced path under `~/.local/state/agent-setup/backups` and records a manifest. `--restore <backup>` restores only if none of those paths changed afterward; otherwise use the manifest for selective recovery without overwriting newer work. Credentials, native sessions, Git history, and running sessions are never synchronized or reset. Existing conversations retain old context; verify with fresh sessions.

## Work system

Efforts start from a board's chief of staff (the `board-cos` skill, on Tim's easl boards) or a conversation. Linear tickets are records that an effort or person owns; the `using-the-work-system` skill says when one earns its place. Nothing dispatches tickets automatically. The home Linear dispatcher was retired on 2026-10-05; its records are archived in `~/archives/meta-audit-2026-10-05/dispatcher/`.

Work and personal are separate deployments. Lindy code, accounts, project guidance, and sessions stay on work, where the work seat (`~/work-agent-system/SEAT.md` on twaldin-work) creates lanes. Personal projects merge after their checks and reviews pass, unless Tim holds them. For Lindy, the agent that opens a PR against `main` arms auto-merge when it opens, unless Tim holds it or it waits on an open PR; GitHub's required checks and approvals decide the merge.

Project profiles, the sources of each repository's `AGENTS.override.md`, live in `~/agent-system/policy/repos/` and `~/.config/agent-setup/projects/`.

## Custom glue

Everything custom around the harnesses (omp extensions, herdr hooks, launchd jobs, shepherd and CoS scripts) lives in git with a smoke test. A new piece must replace or delete something; adding a daemon or scheduled job needs Tim's go. Prefer an upstream feature once one exists.

[inbox/](inbox/) is the one omp extension: `write agent://<name>[@host]` reaches any herdr agent through a file inbox, never by typing into its terminal (`agent-msg` is the same path for shell scripts). It is owned and frozen: fix bugs, add nothing. Tim decided on 2026-10-05 that home agents become easl tiles and peer messaging moves into easl's omp integration. Delete this once no agent runs in herdr; deckbox waits for easld. omp stays the harness, and custom code stays on its public extension API. Fork only if that integration has to patch omp internals or omp releases break it twice in a month. `python3 -m unittest discover -s agents/inbox` checks the delivery rules.

[shepherd/](shepherd/) is the machine shepherd's health glue for twaldin-home and twaldin-work:
- `machine-ok`: the headroom gate agents run before heavy work.
- `machine-watch` (launchd, every 2 min): logs machine health and alerts the shepherd. It also checks deckbox's path to home's auth broker and reports deckbox's patch state daily (reboot required, pending updates, required units down: urgent).
- `machine-census` and `fsevents-top`: attribute memory, CPU and file-system churn.
- `omp-update` (launchd, daily): moves every host to the vetted omp release and restarts idle panes onto it.
- `quiet-window` and `quiet-check`: book and enforce quiet windows for measured runs.
- `omp-browser-cycle` (launchd, hourly): recycles omp's headless browsers.
- ColorSync and GPU diagnostics: `gpu-top`, `colorsync-k`, `cs-measure`, `logout-colorsync-test`.
- `gui-launch` (twaldin-home): launches an agent's GUI test app off Tim's Spaces, reverts any focus it takes, and checks afterwards; its event-driven guard is `src/gui-launch-guard.swift`.
- `deckbox/`: deckbox's system config, installed by hand as root, with the live copy under `/etc`. It holds:
  - the default-deny inbound firewall: `deckbox-inbound.nft` in its own `inet` table, loaded by `deckbox-firewall.service`. It never flushes Docker's or Tailscale's rules, and the stock `nftables.service` is masked;
  - `agents.slice` and herdr's drop-in: one CPU and memory budget shared by herdr and easld tiles;
  - security-only unattended upgrades with no automatic reboot (`20auto-upgrades`, `52deckbox-unattended-upgrades`); kernel and Docker updates wait for the monthly patch window;
  - a needrestart override (`50-deckbox.conf`) that keeps automatic runs from restarting agents, containers or the vault.

  The monthly window is booked with hone. It runs `apt full-upgrade` and `snap refresh`, reboots when `/var/run/reboot-required` exists, then checks that the units in `~/.config/machine-shepherd/patch-hosts` are back. Release upgrades need Tim.

`shepherd/install.sh` links the scripts into `~/.local/bin`, builds the Swift tools in `src/` (`fsevents-top`; `gui-launch-guard` on twaldin-home), and installs the launchd jobs each host runs; `--check` reports drift. `python3 -m unittest discover -s agents/shepherd/tests` runs one smoke test per script.

Upstream: Matt Pocock skills v1.3.1 at `b40b9b199752462750c56d9a26655981e48a4344`; Vercel references at `063bee94c3f4df8453406c830b0a7df0f2860278`. Source metadata and licenses are retained. Do not run their bulk installers over this selected library.
