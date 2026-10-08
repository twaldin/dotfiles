---
name: shared-machine
description: Heavy or measured work on Tim's shared machines. Use before builds, dev servers, tests, typechecks, renders, encodes, benchmarks, game clients or captures, and when choosing deckbox offload.
---

Machine load never blocks agent work: queue the heavy process and keep non-heavy work moving. There are no quiet windows or holds. A measured run tolerates load; repeat it or run it on deckbox.

## twaldin-home and deckbox: the queue

Run every heavy step as `machine-ok-queue run [--gpu] -- <cmd>`. It waits for a host slot and the memory gate, runs the command, and exits with the command's status. On a Mac the default gate is `machine-ok --memory`; deckbox admits by slots alone.

- On a Mac the command and every descendant run clamped by default (utility QoS, nice 10), so Tim's input wins. A slot caps jobs, not a job's own workers: also cap its parallelism.
- Add `--gpu` for MLX, whisper, Metal, Blender renders and hardware video encodes. GPU jobs run one at a time while Tim is active; non-GPU tickets pass a waiting GPU job.
- `machine-ok-queue status` lists runners, waiters and the GPU rule.

## twaldin-work

Run `machine-ok --wait --memory && <cmd>` (add `--gpu` for GPU work); test the gate's own status: in `machine-ok | tee`, `$?` is `tee`'s.

## Deckbox offload

From a twaldin-home worktree, `offload -- <cmd>` runs Linux-compatible suites, typechecks and headless builds on deckbox and returns the command's exit status.

- It syncs tracked and untracked non-ignored files, never `.git/` or secret-named paths, and runs from the same subdirectory through deckbox's queue in a unit capped by `--cpus` and `--mem`. On deckbox it runs in place.
- `--setup '<cmd>'` runs first on deckbox; `--fetch <relative path>` copies an artifact back whatever the exit status. Ignored directories (`node_modules`, `.venv`, `target`) persist there as the worktree's build cache.
- Over 200 MB of changes is refused unless `--big`; ignore build output and media in `.gitignore` instead.
- Steps that need git history, macOS or a display run on home through the queue. `offload` refuses a step mentioning `git `.
- Ctrl-C stops the remote unit. When the worktree goes, `offload --clean` removes its remote directory.
