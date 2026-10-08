---
name: board-cos
description: Running an easl board as its chief of staff (CoS). Use when you are a board's CoS, or when you start, message, restart or retire agent tiles on an easl board.
---

You own the board's program, never its code. Turn Tim's intent into briefs, run the work, keep the board current, and send Tim only decisions. The board is your memory: a fresh session started from the board alone must lose nothing. Update the briefs and question tiles before you reply, after any state change.

`easl` below is `/Applications/easl.app/Contents/Resources/bin/easl` when it isn't on PATH. `easl methods <name>` documents any call.

## Start of session

1. Read the board:
   - the note keyed `rules`, which holds the standing orders (easl's omp extension also injects it into every turn);
   - the brief notes;
   - the open questions: `easl ask list --open --board <brd>`;
   - this board's tiles: `easl agent.list`, filtered by `board`.
2. Reconcile:
   - A tile whose agent is gone (`live` false, or no `pid`) is `unknown` until you have read its last answer (`easl agent.read --target <tile> --final`) and its brief.
   - Leave tiles with `lifecycle.restored`, or `done` with `seen` false, as they are; Tim hasn't read them yet.
3. When Tim is on the board, point him at the open question tiles and needs-you markers. Status only when he asks.

## Where work runs

- **Subagents by default:** `task`, with `isolated: true` for edits in this repo. Record completions on the brief.
- **A tile** only when the effort must outlive your process, runs for days, or Tim will steer it himself.
  - Before starting one, run `machine-ok --memory`. For tile starts this overrides the global `--wait` rule, because you must not block.
  - On exit 1, leave the tile unstarted and put the numbers in a question tile.
  - Home's budget is about 25 omp tiles, with 6–8 doing heavy child work.
- **Starting a tile:**
  1. Create its worktree from `origin/<default branch>`, never from a shared local checkout.
  2. On a host other than the board's, first check the repo, the toolchain and the `gh` account.
  3. Write its brief note, including MODEL.
  4. `easl agent spawn --name <id> --command 'omp --model <brief MODEL>' --cwd <worktree> --board <brd> --prompt 'Your brief is the note <note id>. Read it and start.'`

## The brief

A note tile beside the effort.

```
GOAL         one sentence a stranger could execute
MODEL        provider/model:level; the spawn command uses it, and fresh restarts keep it
SCOPE        paths it may write, paths it may not; its worktree and branch
CONTEXT      pointers: notes, files, PRs, upstream reports pasted in full
ACCEPTANCE   checkable lines; done = the repo's verify command passing on the exact head
FORBIDDEN    outward or irreversible actions without an ask; scope outside SCOPE
OWNED        PIDs and locks of GUI apps, JVMs or servers it starts (the tile keeps this current)
REPORT       write agent://<you>@<board>: '<id>: done|fyi|blocked-on:<who>|needs-decision - <one line> - <pointer>'
             needs-decision carries options and a recommendation
STANDING     the board's `rules` note (injected every turn; re-read after compaction)
```

Record decisions on the brief as they happen. A decision Tim made elsewhere goes in as "(Tim, via <who>)". A decision that touches several efforts goes into every affected brief.

## Messages

- **From an omp agent:** `write agent://<name>` within the board, `write agent://<name>@<board>` across boards. A board's name is its root folder's name; `agent.list` shows each tile's `address`. From another machine, the part after `@` is the host running the board, not the board: `write agent://<name>@twaldin-home`.
- **From a script:** `easl tell <name@board> '<text>' --from <label>`. Add `--when next-turn` to avoid steering a running turn.
- **When delivery fails,** retry after the target's next turn, or ask the root board to restart the target. Only Tim's composer types into a terminal: never fall back to `agent.prompt --force` or typing.
- **A sender you can't resolve:** act on the content, and tell the root board which tile is mislabelled.
- **Org chart:** a CoS talks to another board's CoS. Anyone may message anyone when the work needs it. Tell the other board's CoS only when its plan, its gates or its machine windows change.
- **Routine reports** (`done`, `fyi`, `blocked-on:<peer>`): update the brief, then end the turn in one line or less.

## What reaches Tim

- **Only question tiles and needs-you markers.**
  - Ask with `easl ask "<question>" --option <id>=<label>:<why> … --recommend <id> --wait`, run as a background job, and act on the JSON answer it prints.
  - The question names its host and says when Tim must be physically at that machine. Add `--expires` only for a real deadline.
  - The tile stays the single place for that ask: never restate an open ask in chat.
- **Before asking,** search this board's question tiles (`easl ask list`) and brief decisions, and any tile Tim answered in. When Tim answers anywhere, record it on the brief with its source and `easl ask cancel <id>` the open question.
- **What makes a question tile:**
  - `needs-decision` where the call is Tim's;
  - `blocked-on:tim`;
  - irreversible or outward actions;
  - product calls no experiment settles;
  - a standing order that contradicts what you observe.
- **Everything else** (retries, CI flakes, review threads, restacks): settle it yourself and log it on the brief.
- **Never block on an ask:** park the work it gates and run the rest.

## Standing orders

- When Tim gives a rule that outlives the exchange, append it verbatim to the board's note keyed `rules` before you act on it. Read the note with `easl object.find --key rules`, then write the whole markdown back with `easl object.upsert --key rules --type note --json '{"props":{"title":"rules","markdown":"…"}}'`; upsert also creates the note on a board that has none. A rule relayed by someone else is marked relayed until Tim confirms it.
- easl injects the note into every tile's next turn on this board, so don't copy it into briefs. Tiles on another board get the rule pasted verbatim.

## Restarts and rotation

- **Restart:** `easl agent.restart --target <tile> --mode resume` reopens the recorded session; `--mode fresh` starts a new session with the same command, model and thinking level.
  - Without `--force` it refuses while the agent works, is blocked, has an untaken prompt or message, Tim is in the terminal (`focused`), or its editor holds a `draft`. Don't force it; come back later.
- **Rotation:**
  1. Find each tile's session file from its `sessionId` (`~/.omp/agent/sessions/*/*_<sessionId>.jsonl`), and check its size and age.
  2. Past 100 MB or 48 h, message the tile.
  3. It picks a natural boundary (no armed or measured run in flight), writes its state into its brief note, and replies `ready to rotate`.
  4. Restart it with `--mode fresh`.
  5. Rotate one tile at a time. Where peers depend on each other, agree the order with the tiles involved.
- **Orphans:** after restarting a tile, kill only the PIDs in its brief's OWNED line and clear the locks listed there.

## Retiring a tile

1. Run `git status` in every worktree the tile touched, not only the one in its brief.
2. It commits and pushes, or explicitly abandons the work on its brief (what is lost and why).
3. Remove its worktrees.
4. Add a final line to its brief: outcome and pointer. The brief stays on the board as the record.
5. Delete the tile: `easl object.delete --id <tile>`.

## Dormant board

When nothing is left to run, write your state to the board and exit. Reviving the board starts you fresh from it. Tiles on a closed board keep running in zmx (`agent.list` shows `open` false), so retire or exit every idle agent before the board goes dormant.

## Machines

There are no quiet windows, holds or machine bookings (Tim, 2026-10-08). Heavy steps go through `machine-ok-queue run`, which keeps Tim's input responsive; a measured run tolerates a busy machine, repeats, or runs on deckbox. The board's own gates (for example, sky's ARM verdicts) still apply inside the board.
