# Working with Tim

- Write PRs, tickets, plans and updates so Tim can scan them: lead with the outcome, use the project's terms and explain unfamiliar ones. PRs and tickets carry intent, scope, acceptance, validation and material limits; raw logs and execution notes stay private.
- Ask decisions one at a time, with options and your recommendation. In an easl tile, run `easl ask … --wait` as a background job and keep working: the answer wakes you when Tim picks, while a tile posted without `--wait` reaches you only with his next prompt. omp's question tool blocks your whole session, and every message queued meanwhile lands at once when Tim answers, so use it only outside easl.
- Use the machine's existing CLI auth and the project's account. Never print tokens or dump the environment. Keep the configured Git identity and add no agent co-author trailers.
- Personal-project PRs merge once required checks and reviews pass, unless Tim set a hold. For Lindy, the agent that opens a PR against `main` arms auto-merge when it opens it, unless Tim holds it or it waits on another open PR. Prefer one PR per effort, keep branch protections, and verify the landed result.
- On personal projects, CodeRabbit reviews are supplemental. A CodeRabbit review-limit notice counts as its approval: review the PR locally with the code-review skill instead, then merge once CI and that review pass, with `gh pr merge --admin` where a required approval is all that remains.
- In omp, the chief of staff and each effort session run on the default role (Opus 5.5). Inside an effort, the subagent type is the model choice:
  - `task` (Sonnet 5.5) by default.
  - `opus` (Opus 5.5) for hard judgment and integration.
  - `scout` (GPT-6.1 Sol) for research, or to move work off Anthropic quota.
  - `reviewer` (GPT-6 Astra) for reviews, chosen through the code-review skill.
  - Niche types: `grok` (Grok 4.7) for small reviews and second opinions; `sonic` (GLM 5.3 Flash) for mechanical fan-outs over ~10 agents.
  - Subagents never see this file, so brief them on any rule here that their task touches.
- Limits never block work. When a model's quota, credits or rate limit runs out, re-run the step on an available model of similar capability (another subagent type, or `model` set to another provider's model), name the substitute in your report, and switch back once the limit resets. This overrides rules that pin a model, project review rules included; a review substitute still comes from a family other than the authors'.
- To message another agent, use `write agent://<name>`. It reaches your subagents and every herdr agent on this machine; add `@<host>` for another machine, e.g. `agent://cos@twaldin-home`. Never use `herdr agent prompt` or `send-keys` on a pane that is running: they type into Tim's terminal, so the text can land in his draft or answer his open question.
- Keep Tim's agent setup small. Custom glue (omp extensions, herdr hooks, launchd jobs, agent-system scripts) lives in git with a smoke test and must replace or delete something; adding a daemon or scheduled job needs Tim's go.

# Shared machines

Many agents share each machine's CPU, RAM and GPU.

- Machine load never blocks agents. Under pressure or in a quiet window, pause or queue only your heavy processes (builds, dev servers, test runs, renders, encodes, benchmarks, game clients, captures), and keep reading, writing code, reviewing and running subagents.
- Stop what you start (servers, watchers, browsers, REPLs, Blender, game clients) when the task that needed it ends, and kill your own orphans. Reuse a running dev server instead of starting another. Say so when you keep a long render or bake running.
- Kill only processes you can prove are yours by port, working directory or target URL; omp's shared broker makes the process tree misleading. Send pressure you can't fix, with numbers, to the machine shepherd: `write agent://shepherd@twaldin-home` (from a shell script, `agent-msg shepherd '<what you measured>'`). Never kill system daemons or touch Colima/Docker.
- Delete only paths you created and recorded: make scratch with `mktemp -d`, and remove exactly that path. Never pattern-delete (`find … -delete`, `-exec rm`, globbed `rm -rf`) in a shared root such as /tmp, `$TMPDIR`, `$HOME`, `~/dev` or `~/worktrees`. `find` matches its own start point unless you pass `-mindepth 1`; that is how one cleanup wiped every file in /tmp and took yabai down.
- Cap each tool's own parallelism (`-j`, `--threads`, `--maxWorkers`, `MAGICK_THREAD_LIMIT`) as well as the number of runs. Test runners are the memory trap: a Lindy vitest worker holds about 2 GB.
- On twaldin-home and deckbox, run every build, test runner, typecheck and other heavy step as `machine-ok-queue run [--memory] [--gpu] -- <cmd>`: heavy steps take turns in the host's queue behind the `machine-ok` gate, and its exit status is the command's (`machine-ok-queue status` shows the queue). Run Linux-compatible test suites on deckbox with `offload -- <cmd>`; it never syncs `.git/`, so steps that need git run on home in the queue. On twaldin-work, gate with `machine-ok --wait --memory` and test its exit code directly.
- Before you launch, move, capture or show a GUI window on a Mac, read the `mac-gui` skill, and never move a window without its id. Use the agent Spaces first; when a run can't work there, use Tim's Spaces or windows rather than wait.
- Use twaldin-home's screen whenever a run needs it; Tim is usually at work over ssh. Keep anything you show brief, and when his activity disturbs a run, note it and rerun. No gate waits for Tim to be idle.
