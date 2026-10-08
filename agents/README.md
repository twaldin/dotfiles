# Agent setup

One maintained skill library, small project guidance, and native harnesses. OMP runs the sessions; Codex can be used entirely on its own.

`skills.json` selects 24 general skills. `vendor/` holds pinned upstream sources and licenses; `adapt.py` makes approved changes only in generated copies. `skills/` holds the short local guides. Machine-specific procedure (such as `mac-gui` for Spaces, yabai and virtual screens) lives in skills, not in `instructions.md`, because skill descriptions reach omp subagents and AGENTS.md files do not.

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

Global AGENTS/CLAUDE entry points link to `instructions.md`; never edit an installed copy, because a regular file there silently forks from the source. Native browser/computer tools come first. Herdr is the only retained custom hook. Extensions installed by other tools (herdr, Canvas) are left alone. Old custom MCP servers, imported workflow plugins, and legacy instruction/skill copies are archived; native capabilities and model accounts stay local. OMP's user `~/.omp/agent/mcp.json` is machine-local and survives installs.

The `agent-browser` skill drives Vercel's agent-browser CLI, pinned at 0.38.2 on twaldin-home and deckbox (twaldin-work has none). Home: `npm install -g agent-browser@0.38.2 && agent-browser install`. Deckbox has no Node 24, so the npm tarball (sha1 `3eeb49e7d02a31be255a0462830dd8a147fc5f29`) is unpacked to `~/.local/lib/agent-browser-0.38.2`, `~/.local/bin/agent-browser` links to its `bin/agent-browser-linux-x64`, then `agent-browser install --with-deps`. Run installs through `machine-ok-queue run`. `agent-browser doctor --offline --quick` must report Chrome for Testing under `~/.agent-browser/browsers`: without it, agent-browser falls back to `/Applications/Google Chrome` on the Macs.

`omp.json` is the shared OMP baseline. It owns model roles and the explicitly listed shared preferences; installation replaces the entire role map, so removed roles such as vision stay unset. Fallback chains merge per role: the baseline's chains win, other roles keep their local chains. Keep permanent shared changes here and install separately on home, work and Deckbox. Interactive global role changes can cause drift until the next install. Authentication, provider accounts, local tools/connections, QA consent, Codex and Claude reset redemption, thinking-block display, `worktree` and project discovery exclusions remain machine-local; exclusions for directories that no longer exist are dropped. `config.yml` is rewritten only when its parsed settings change.

Native project settings and explicit session overrides can supersede the global baseline. Existing owners retain their saved models when available; installing a new default does not migrate or replace them. Future task launches reload settings, so verify the actual helper model when counting an independent review. A model listed by the native catalog confirms configured authentication, not a successful inference or available quota.

The model-cycle shortcut follows default → fable → slow: Opus 5.5 xhigh, Fable 5.1 xhigh, then GPT-6.1 Sol xhigh. `task` is GPT-6.1 Sol xhigh (since 2026-10-08, to keep subagent work off the scarcer Anthropic quota); `tiny` and `smol` are GLM 5.3 Flash. Failed turns fall back by role (`retry.fallbackChains` in `omp.json`): the default role never changes model, so lead tiles stay on Opus and only rotate between Anthropic accounts (Tim, 2026-10-08). The `opus` subagent role falls back to GPT-6.1 Sol, task and sol to Sonnet 5.5, review to Grok 4.7, tiny to GPT-6 Luna, and any OpenCode Go model to GLM 5.3 Flash. Usage-aware fallback is on with the `auto` reserve policy: before a turn, a session whose coding-plan account is near its limit moves to a healthy account of the same provider, then down its fallback chain, without asking. Cycling changes the active session model; it does not rewrite global role assignments.

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

The team's `.agent/skills` join the project view too, linked in place, so new team skills appear on the next preparation. Codex enables each team skill by resolved path. Existing name-level retirement and legacy-copy disables remain; the explicit project path enables the team copy without enabling other copies of that name.

The installer backs up every replaced path under `~/.local/state/agent-setup/backups` and records a manifest. `--restore <backup>` restores only if none of those paths changed afterward; otherwise use the manifest for selective recovery without overwriting newer work. Credentials, native sessions, Git history, and running sessions are never synchronized or reset. Existing conversations retain old context; verify with fresh sessions.

## Work system

Efforts start from a board's chief of staff (the `board-cos` skill, on Tim's easl boards) or a conversation. Linear tickets are records that an effort or person owns; the `using-the-work-system` skill says when one earns its place. Nothing dispatches tickets automatically. The home Linear dispatcher was retired on 2026-10-05; its records are archived in `~/archives/meta-audit-2026-10-05/dispatcher/`.

Work and personal are separate deployments. Lindy code, accounts, project guidance, and sessions stay on work, where the work seat (`~/work-agent-system/SEAT.md` on twaldin-work) creates lanes. Personal projects merge after their checks and reviews pass, unless Tim holds them. For Lindy, the agent that opens a PR against `main` arms auto-merge when it opens, unless Tim holds it or it waits on an open PR; GitHub's required checks and approvals decide the merge.

Project profiles, the sources of each repository's `AGENTS.override.md`, live in `~/agent-system/policy/repos/` and `~/.config/agent-setup/projects/`.

## Custom glue

Everything custom around the harnesses (omp extensions, herdr hooks, launchd jobs, shepherd and CoS scripts) lives in git with a smoke test. A new piece must replace or delete something; adding a daemon or scheduled job needs Tim's go. Prefer an upstream feature once one exists.

[inbox/](inbox/) is the one omp extension: `write agent://<name>[@host]` reaches any herdr agent through a file inbox, never by typing into its terminal (`agent-msg` is the same path for shell scripts). It is owned and frozen: fix bugs, add nothing. Tim decided on 2026-10-05 that home agents become easl tiles and peer messaging moves into easl's omp integration. Delete this once no agent runs in herdr; deckbox waits for easld. omp stays the harness, and custom code stays on its public extension API. Fork only if that integration has to patch omp internals or omp releases break it twice in a month. `python3 -m unittest discover -s agents/inbox` checks the delivery rules.

The easl fallback requires easl 0.2.4+ for caller-supplied message IDs. `omp-inbox` reuses a valid `details.easl.message` (`msg_` followed by 8–64 letters, digits, `_` or `-`), or mints one ID for that write. The optional `agent-msg --message ID` carries the same ID through `easl tell`, including a selected SSH route: an earlier prompt may still queue after its sender times out, so every easl attempt must share the ID. Failed sends retain the native error and nested details; successful sends mark native receipts delivered. Herdr inbox delivery is unchanged, and `--herdr-only` remains accepted for older live extensions until they rotate naturally.

[shepherd/](shepherd/) is the machine shepherd's health glue for twaldin-home and twaldin-work:
- `machine-ok`: the headroom gate agents run before heavy work.
- `machine-watch` (launchd, every minute; the full watch every 2 min): logs machine health and alerts the shepherd. While Tim is typing, a CPU under 15% idle on two checks in a row messages the agents that own the top consumers to stop them and rerun them through `machine-ok-queue` or `offload` (`machine-watch --consumers` previews who they are). It also checks deckbox's path to home's auth broker and reports deckbox's patch state daily (reboot required, pending updates, required units down: urgent).
- `machine-census` and `fsevents-top`: attribute memory, CPU and file-system churn.
- `omp-update` (launchd, daily): moves every host to the vetted omp release and restarts idle panes onto it.
- `omp-browser-cycle` (launchd, hourly): recycles omp's headless browsers.
- ColorSync and GPU diagnostics: `gpu-top`, `colorsync-k`, `cs-measure`, `logout-colorsync-test`.
- `gui-launch` (twaldin-home): launches an agent's GUI test app off Tim's Spaces, reverts any focus it takes, and checks afterwards; its event-driven guard is `src/gui-launch-guard.swift`.
- `deckbox/`: deckbox's system config, installed by hand as root, with the live copy under `/etc`. It holds:
  - the default-deny inbound firewall: `deckbox-inbound.nft` in its own `inet` table, loaded by `deckbox-firewall.service`. It never flushes Docker's or Tailscale's rules, and the stock `nftables.service` is masked;
  - `agents.slice` and herdr's drop-in: one CPU and memory budget shared by herdr and easld tiles;
  - `session-scope-cpus.conf`, installed as `/etc/systemd/system/session-.scope.d/50-off-measured-cpus.conf`: keeps SSH/logind login scopes off hone's measured CPUs (1–4 and 13–16), without changing `user@1000.service` or Docker's `system.slice` scopes;
  - security-only unattended upgrades with no automatic reboot (`20auto-upgrades`, `52deckbox-unattended-upgrades`); kernel and Docker updates wait for the monthly patch window;
  - a needrestart override (`50-deckbox.conf`) that keeps automatic runs from restarting agents, containers or the vault;
  - `agent-browser-chrome`, an AppArmor profile (`/etc/apparmor.d/`) that lets agent-browser's Chrome for Testing create the user namespaces its sandbox needs, which Ubuntu 24.04 denies by default.

  The monthly window is booked with hone. It runs `apt full-upgrade` and `snap refresh`, reboots when `/var/run/reboot-required` exists, then checks that the units in `~/.config/machine-shepherd/patch-hosts` are back. Release upgrades need Tim.

`shepherd/install.sh` links the scripts into `~/.local/bin`, builds the Swift tools in `src/` (`fsevents-top`; `gui-launch-guard` on twaldin-home), and installs the launchd jobs each host runs; `--check` reports drift. `python3 -m unittest discover -s agents/shepherd/tests` runs one smoke test per script.

Upstream: Matt Pocock skills v1.3.1 at `b40b9b199752462750c56d9a26655981e48a4344`; Vercel references at `063bee94c3f4df8453406c830b0a7df0f2860278`. Source metadata and licenses are retained. Do not run their bulk installers over this selected library.
