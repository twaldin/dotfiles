# Working with Tim

- Write PRs, tickets, plans and updates for scanning: lead with the outcome, use project terms and explain unfamiliar ones. PRs and tickets carry intent, scope, acceptance, validation and material limits; keep raw logs and execution notes private.
- Ask decisions one at a time, with options and your recommendation. In easl, run `easl ask … --wait` as a background job and keep unrelated work moving; use omp's blocking question tool only outside easl.
- Use the machine's existing CLI auth and the project's account. Never print tokens or dump the environment. Keep the configured Git identity and add no agent co-author trailers.
- Personal-project PRs merge after required checks and reviews pass, unless Tim set a hold. For Lindy, the opener arms auto-merge on PRs against `main` unless Tim holds them or they depend on another open PR. Prefer one PR per effort, preserve branch protections and verify the landed result.
- CodeRabbit reviews on personal projects are supplemental; a review-limit notice counts as its approval. Review locally with the code-review skill, then merge after CI and that review pass; use `gh pr merge --admin` only when a required approval is all that remains.
- Lead tiles run Opus 5.5 and never edit code; subagents do: `task` (GPT-6.1 Sol) by default, `opus` for hard judgment, `scout` (Sol) for research, `reviewer` (GPT-6 Astra) or `grok` for review from another family. Lead coordination lives in `board-cos`.
- Quota, credit and rate limits never block work: retry subagent work on another provider using its type or per-call `model`, report the substitute and switch back when limits reset. This overrides worker-model pins, including review rules; reviewers still need a family other than the authors'. Leads stay Opus, using another Anthropic account if needed.
- Pass applicable rules into subagent briefs; children do not see this file.
- Never type into another agent's running terminal (`herdr agent prompt`, `send-keys` or `agent.prompt --force`): it can corrupt Tim's draft or answer his open question.
- Keep the setup small: custom glue lives in git with a smoke test and must replace or delete something. A recurring machine or tooling problem gets a CLI plus a skill that any agent uses when it hits it, never a daemon, watcher or agent that messages others about it (Tim, 2026-10-08). New daemons or scheduled jobs need Tim's go.

# Shared machines

- Before heavy steps (builds, dev servers, tests, renders, encodes, benchmarks, game clients, captures) read `shared-machine`: queue them and keep non-heavy work moving. Machine load never blocks agents; there are no quiet windows or holds.
- Stop what you start (servers, watchers, browsers, REPLs, Blender, game clients) when its task ends, and kill your own orphans. Reuse running dev servers; say so when keeping a long render or bake running.
- Kill only processes you can prove are yours by port, cwd or target URL; omp's shared broker makes process trees misleading. Report unfixable pressure with numbers to your lead or Tim; subagents use their result. Never kill system daemons or touch Colima/Docker.
- Make scratch with `mktemp -d`, record its path and remove exactly that path. Delete only paths you created and recorded; never pattern-delete (`find … -delete`, `-exec rm`, globbed `rm -rf`) in shared roots such as /tmp, `$TMPDIR`, `$HOME`, `~/dev` or `~/worktrees`.
- Cap each tool's parallelism (`-j`, `--threads`, `--maxWorkers`, `MAGICK_THREAD_LIMIT`) and simultaneous runs. A Lindy vitest worker uses about 2 GB.
- Before launching, moving, capturing or showing a Mac GUI window, read `mac-gui`; never move a window without its id. Use agent Spaces first, then Tim's Spaces or windows if needed.
- Use twaldin-home's screen when needed; Tim is usually at work over ssh. Keep displays brief; if his activity disturbs a run, note it and rerun. No gate waits for Tim to be idle.
