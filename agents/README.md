# Agent setup

One maintained skill library, small project guidance, and native harnesses. OMP runs the sessions; Codex can be used entirely on its own.

`skills.json` selects 26 general skills. Pstack is the sole engineering playbook, entered through `poteto-mode`; its playbooks, principles and supporting skills are read on demand, not added to global discovery. `vendor/` holds unchanged pinned upstream sources and licenses; `adapt.py` makes approved changes only in generated copies. `skills/` holds the short local guides. Machine-specific procedure (`mac-gui`, `shared-machine` and `machine-health`) lives in skills, whose descriptions reach omp subagents, not in global instructions.

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

Global AGENTS/CLAUDE entry points link to `instructions.md`; never edit an installed copy, because a regular file there silently forks from the source. Native browser/computer tools come first. Herdr is the only retained custom hook. Extensions installed by other tools (easl, herdr) are left alone. Old custom MCP servers, imported workflow plugins, and legacy instruction/skill copies are archived; native capabilities and model accounts stay local. OMP's user `~/.omp/agent/mcp.json` is machine-local and survives installs; on twaldin-home it holds `computer-guest`. The `mac-gui` skill routes GUI tests through the home-only `agent-gui` CLI: a live kernel lease, orphan recovery, on-demand boot, fresh headless OMP worker and direct teardown. Only that worker calls the guest tools; the MCP startup warning while stopped is expected.

The `agent-browser` skill drives Vercel's agent-browser CLI, pinned at 0.38.2 on twaldin-home and deckbox (twaldin-work has none). Home: `npm install -g agent-browser@0.38.2 && agent-browser install`. Deckbox has no Node 24, so the npm tarball (sha1 `3eeb49e7d02a31be255a0462830dd8a147fc5f29`) is unpacked to `~/.local/lib/agent-browser-0.38.2`, `~/.local/bin/agent-browser` links to its `bin/agent-browser-linux-x64`, then `agent-browser install --with-deps`. Run installs through `machine-ok-queue run`. `agent-browser doctor --offline --quick` must report Chrome for Testing under `~/.agent-browser/browsers`: without it, agent-browser falls back to `/Applications/Google Chrome` on the Macs.

`omp.json` is the shared OMP baseline. It owns model roles and the explicitly listed shared preferences; installation replaces the entire role map, so removed roles such as vision stay unset. Fallback chains merge per role: the baseline's chains win, other roles keep their local chains. Keep permanent shared changes here and install separately on home, work and Deckbox. Interactive global role changes can cause drift until the next install. Authentication, provider accounts, local tools/connections, QA consent, Codex and Claude reset redemption, thinking-block display, `worktree` and project discovery exclusions remain machine-local; exclusions for directories that no longer exist are dropped. `config.yml` is rewritten only when its parsed settings change.

Native project settings and explicit session overrides can supersede the global baseline. Existing owners retain their saved models when available; installing a new default does not migrate or replace them. Future task launches reload settings, so verify the actual helper model when counting an independent review. A model listed by the native catalog confirms configured authentication, not a successful inference or available quota.

The model-cycle shortcut follows default → fable → slow: Opus 5.5 xhigh, Fable 5.1 xhigh, then GPT-6.1 Sol xhigh. `task` is GPT-6.1 Sol xhigh (since 2026-10-08, to keep subagent work off the scarcer Anthropic quota); `tiny` and `smol` are GLM 5.3 Flash. Failed turns fall back by role (`retry.fallbackChains` in `omp.json`): the default role never changes model, so lead tiles stay on Opus and only rotate between Anthropic accounts (Tim, 2026-10-08). The `opus` subagent role falls back to GPT-6.1 Sol, task and sol to Sonnet 5.5, review to Grok 4.7, tiny to GPT-6 Luna, and any OpenCode Go model to GLM 5.3 Flash. Usage-aware fallback is on with the `auto` reserve policy: before a turn, a session whose coding-plan account is near its limit moves to a healthy account of the same provider, then down its fallback chain, without asking. Cycling changes the active session model; it does not rewrite global role assignments.

The bundled reviewer and security-reviewer use the `review` role (GPT-6 Astra xhigh); scout uses `sol`. `interrogate` picks reviewers from a different family than the authors and verifies the resolved model after any fallback. It requires delta re-review after fixes and an acceptance receipt for the exact final head. Grok review is restricted to small, low-risk diffs. Selecting an advisor model does not enable the advisor; it remains disabled.

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

Each easl board has one Opus lead (`board-lead`) and a goal note keyed `goal` that only Tim edits; nothing sits above the leads. Efforts start from a board's lead or a conversation. Implementation lanes are ticket-first, with one isolated owner subagent per lane; research and discussion need no artificial ticket. A ticket records ownership and acceptance, not dispatch authorization. Nothing dispatches automatically. The home Linear dispatcher was retired on 2026-10-05. New repositories follow `new-project`: a private remote and pushes to `main` from day one, then PRs with auto-merge once a trigger holds.

Shared setup (this directory, skills, omp config, `instructions.md`, `~/agent-system`) changes only through `outer-loop`, a user-invoked skill Tim starts: a retro since its cursor (`~/.local/state/outer-loop/last-retro`), changes Tim agrees to landed by PR, then restarts of the affected leads. Leads and subagents propose setup changes as easl asks or board notes.

Work and personal are separate deployments. Lindy code, accounts, project guidance, and sessions stay on work, where the work seat (`~/work-agent-system/SEAT.md` on twaldin-work) creates lanes. Personal projects merge after their checks and reviews pass, unless Tim holds them. For Lindy, the agent that opens a PR against `main` arms auto-merge when it opens, unless Tim holds it or it waits on an open PR; GitHub's required checks and approvals decide the merge.

Project profiles, the sources of each repository's `AGENTS.override.md`, live in `~/agent-system/policy/repos/` and `~/.config/agent-setup/projects/`.

## Custom glue

Everything custom around the harnesses (omp extensions, herdr hooks, launchd jobs, shepherd scripts) lives in git with a smoke test. A new piece must replace or delete something; adding a daemon or scheduled job needs Tim's go. Prefer an upstream feature once one exists.

Inside an easl tile, easl's shipped omp extension handles cross-session `write agent://<name>` and `write agent://<name>@<board>`. From elsewhere, cross-session writes fail with `Unknown agent`; omp's own same-process subagent messaging still works. We maintain no inbox extension or shell messaging transport; the installer archives and removes the retired `omp-inbox.ts` extension and `agent-msg` command without changing easl's extension or herdr's externally owned state hook. The old `~/.local/state/omp-inbox/` spool is left untouched as historical state. Install this cut together with retirement of the `machine-watch` and `omp-update` callers.

Machine diagnostics return evidence to their caller, not to another agent. `logout-colorsync-test post` writes `~/.local/state/machine-shepherd/k-readout.txt` and prints its path for the agent to read after login. `deckbox-cpus` records CPU reservation intervals in `~/.local/state/deckbox-cpus/log.jsonl` and the journal (`logger -t deckbox-cpus`; read with `journalctl -t deckbox-cpus`); its holds and local audit remain authoritative if the journal write fails.

[shepherd/](shepherd/) holds the machine CLIs for twaldin-home and twaldin-work; deckbox gets the queue and offload. A recurring machine problem gets a CLI plus a skill any agent uses: `shared-machine` covers admission and `machine-health` covers diagnosis.
- `machine-ok` (the pinned headroom gate, whose bytes benchmark kits hash), `machine-ok-queue` (the heavy-step queue and QoS clamp) and `offload`/`offload-run` (Linux runs on deckbox): `shared-machine` says when and how to use them.
- `machine-watch`: on-demand only. It prints one JSON health report (census, FSEvents sample, ColorSync rates, WindowServer pid, input idle) and keeps no state, sends no alerts or messages and runs on no schedule.
- `machine-census` and `fsevents-top`: attribute memory, CPU and file-system churn.
- `omp-update` (launchd, hourly): installs the newest unblocked omp release published on both GitHub and npm for at least 3 h, in deckbox → work → home canary order; `hold_below` caps a host and nothing is downgraded. Keeps the newest binary backup and any still mapped by a process. Restarts older launchd broker/gateway services, and resumes idle/done named easl leads in place only for an older binary or RSS over 1.5 GB. Safety gates protect working/blocked or closed-board tiles, unseen/unknown done, drafts, focus, pending messages, child work and subagents; native easl conflicts are skips. Tim's unnamed tiles are never touched and `report_only` (`lindy-seat`) is only reported. Resumes must keep the session, get a new pid, and report protocol ≥ 1 plus the original model within 60 s. Errors end that host, log to `~/.local/state/omp-update/{actions.jsonl,last-run.json}`, and make the run exit nonzero; later hosts continue unless a target install or observed resume verification fails. Only protocol/model verification failures block a version later hosts lack. No fresh sessions, rotations, herdr support or injected messages.
- `omp-browser-cycle` (launchd, hourly): recycles omp's headless browsers.
- ColorSync and GPU diagnostics: `gpu-top`, `colorsync-k`, `cs-measure`, `logout-colorsync-test`. `machine-health` says which probe fits a symptom.
- `agent-gui` (twaldin-home only): `machine-ok-queue run -- agent-gui run -- '<GUI task and readback>'` owns one guest batch and recovers crash leftovers. A bounded keeper retains its lease across a parent crash; OMP and shell jobs never inherit it. The holder drains the worker group before teardown and lease release. `mac-gui` is the routing contract.
- `gui-launch` (twaldin-home): the `mac-gui` host-only fallback for work the guest cannot do; guards agent test apps and checks afterwards. Its event-driven guard is `src/gui-launch-guard.swift`.
- `deckbox/`: deckbox's system config, installed by hand as root, with the live copy under `/etc`. It holds:
  - the default-deny inbound firewall: `deckbox-inbound.nft` in its own `inet` table, loaded by `deckbox-firewall.service`. It never flushes Docker's or Tailscale's rules, and the stock `nftables.service` is masked;
  - `agents.slice` and herdr's drop-in: one CPU and memory budget shared by herdr and easld tiles;
  - `session-scope-cpus.conf`, installed as `/etc/systemd/system/session-.scope.d/50-off-measured-cpus.conf`: keeps SSH/logind login scopes off hone's measured CPUs (1–4 and 13–16), without changing `user@1000.service` or Docker's `system.slice` scopes;
  - security-only unattended upgrades with no automatic reboot (`20auto-upgrades`, `52deckbox-unattended-upgrades`); kernel and Docker updates wait for the monthly patch window;
  - a needrestart override (`50-deckbox.conf`) that keeps automatic runs from restarting agents, containers or the vault;
  - `agent-browser-chrome`, an AppArmor profile (`/etc/apparmor.d/`) that lets agent-browser's Chrome for Testing create the user namespaces its sandbox needs, which Ubuntu 24.04 denies by default.

  The monthly window is booked with hone. It runs `apt full-upgrade` and `snap refresh`, reboots when `/var/run/reboot-required` exists, then checks that the units in `~/.config/machine-shepherd/patch-hosts` are back. Release upgrades need Tim.

`shepherd/install.sh` links the scripts into `~/.local/bin`, builds the Swift tools in `src/` (`fsevents-top`; `gui-launch-guard` on twaldin-home), and installs the launchd jobs each host runs; `--check` reports drift. `python3 -m unittest discover -s agents/shepherd/tests` runs one smoke test per script.

Upstream: pstack from `cursor/plugins` at `ccb5507cec1546dc88135c1139c811e6c59115ba` (MIT, Lauren Tan); Matt Pocock skills v1.3.1 at `b40b9b199752462750c56d9a26655981e48a4344`; Vercel references at `063bee94c3f4df8453406c830b0a7df0f2860278`. Source metadata, per-file hashes and licenses are retained. Do not run bulk upstream installers over this selected library.

## Pstack adaptation

The selected entry points are `poteto-mode`, `show-me-your-work`, `figure-it-out`, `unslop` and `interrogate`. Omp discovers these directly. Supporting leaves, including pstack's narrow cheap-repro TDD skill, have resolving file links from the router; they are not another global workflow. Project feature-testing requirements still apply. `interrogate` deliberately synthesizes findings instead of retaining Matt's separate Standards/Spec reports, while its rubric still checks intent and repository standards.

Family independence is stricter than the retired mixed-author wrapper. A mixed Anthropic/OpenAI diff needs an available third-family agent type, such as `grok` within its risk limit; without one, review is incomplete. Omp `task` items choose models only through agent types, with no per-item `model` field. Outside omp, use the current harness and preserve the same model/evidence checks. The Grok risk limit applies to the resolved reviewer model even when the `reviewer` role or another agent falls back to it.

The port uses native task batches, isolated writer outputs, model roles, `agent://` results and `history://` transcripts. Every brief passes applicable standing orders; workers read the router in their first brief. Board leads do small tasks and investigation themselves and delegate parallel or larger code work. Parent todo owns phases, not lane concurrency. Human gates use background `easl ask … --wait`. Omp's `/loop 1h` is a duration deadline, not an hourly timer; a necessary timed re-check is one owned background sleep job that wakes the active lead, not a persistent scheduler. The generated plan template and its checker use those same native audit markers.

Opening-a-PR defaults to one trunk-based PR per effort, and opening a PR starts the babysit watch loop in the opening session: `~/agent-system/bin/watch-pr <url> --until event --state <file>` as an async background job, handled and acknowledged with `watch-pr --ack <file>`, then re-armed until the PR merges or closes. Lindy repositories use `lindyctl pr wait` where that command exists. Babysit and shipping run no other watcher, so `gh pr checks --watch` is gone.

Orchestrate is a smaller role-for-role interpretation using tickets, native task state, the board's rules and current-head receipt pointers. It does not install `orch`, Graphite, automations, a cloud control plane or a second status database. Optional Autopilot-stack is an operator-landed queue; Autopilot-full still requires merge authority and fresh per-round root verdicts. External Cursor control/deslop dependencies use real project checks, CLI proof and native browser/easl instead. Cleanup preserves shared-machine WIP, explicitly owned paths and processes.

The old globally selected engineering workflows and redundant grilling alias are retired through the existing installer; no old-name skill router remains. The custom hillclimb/review wrappers are deleted. Matt's complete pinned archive stays unchanged and inactive except for deliberately selected capabilities.

The runtime library retains the complete pstack snapshot, including inactive setup guides, docs, assets, automations and bookkeeping scripts, as inert provenance; copying them does not activate or run them. Catalog links and adapted on-demand references define the reachable surface. Source-pin hashes describe the unchanged tracked source files in this repository, not generated adapted copies.
