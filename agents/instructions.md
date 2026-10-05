# Working with Tim

- Write PRs, tickets, plans and updates so Tim can scan them: lead with the outcome, use the project's terms and explain unfamiliar ones. PRs and tickets carry intent, scope, acceptance, validation and material limits; raw logs and execution notes stay private.
- Ask decisions through the question tool, one question at a time, and keep the conversation open while you wait.
- Use the machine's existing CLI auth and the project's account. Never print tokens or dump the environment. Keep the configured Git identity and add no agent co-author trailers.
- Personal-project PRs merge once required checks and reviews pass, unless Tim set a hold. For Lindy, the agent that opens a PR against `main` arms auto-merge when it opens it, unless Tim holds it or it waits on another open PR. Prefer one PR per effort, keep branch protections, and verify the landed result.
- In omp, the chief of staff and each effort session run on the default role (Opus 5.5). Inside an effort, the subagent type is the model choice:
  - `task` (Sonnet 5.5) by default.
  - `opus` (Opus 5.5) for hard judgment and integration.
  - `scout` (GPT-6.1 Sol) for research, or to move work off Anthropic quota.
  - `reviewer` (GPT-6 Astra) for reviews, chosen through the code-review skill.
  - Niche types: `grok` (Grok 4.7) for small reviews and second opinions; `sonic` (GLM 5.3 Flash) for mechanical fan-outs over ~10 agents.
  - Subagents never see this file, so brief them on any rule here that their task touches.
- To message another agent, run `agent-msg <name> '<text>'`. Never use `herdr agent prompt` or `send-keys` on a pane that is running. Those type into Tim's terminal, so the text can land in his draft or answer his open question.

# Shared machines

Many agents share each machine's CPU, RAM and GPU.

- Stop what you start (servers, watchers, browsers, REPLs, Blender, game clients) when the task that needed it ends, and kill your own orphans. Reuse a running dev server instead of starting another. Say so when you keep a long render or bake running.
- Kill only processes you can prove are yours by port, working directory or target URL; omp's shared broker makes the process tree misleading. Send pressure you can't fix, with numbers, to the machine shepherd: `agent-msg "$(cat ~/.config/machine-shepherd/pane)" '<what you measured>'`. If that file is missing, tell Tim. Never kill system daemons or touch Colima/Docker.
- Cap each tool's own parallelism (`-j`, `--threads`, `--maxWorkers`, `MAGICK_THREAD_LIMIT`) as well as the number of runs. Test runners are the memory trap: a Lindy vitest worker holds about 2 GB.
- Gate heavy jobs with `machine-ok --wait` (`--memory` for tests and typechecks; `machine-ok --help` explains the checks), not the load average, and test its exit code directly rather than through a pipe.
- Before you launch, move, capture or show a GUI window on a Mac, read the `mac-gui` skill. Never put test windows on Tim's Spaces, and never move a window without its id.
