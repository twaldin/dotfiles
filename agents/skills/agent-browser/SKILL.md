---
name: agent-browser
description: Headless browser CLI (`agent-browser`) for agents on twaldin-home and deckbox. Use to open, read, click, fill or screenshot web pages when the harness has no browser tool or its tool lacks the capability.
---

Agents share the installed CLI, never a browser. Each task drives its own headless Chrome, launched by agent-browser for that task's session and closed when the task ends, so every page stays off Tim's screen, input, clipboard and Chrome profile.

## Before the first command

1. Run `agent-browser skills get core` (add `--full` for every command) for the usage guide matching the installed version. Where it differs from this skill, this skill wins: its `session id --scope worktree` names collide when agents share a worktree.
2. Check the environment: `env | cut -d= -f1 | grep '^AGENT_BROWSER_'` prints nothing. Any name it prints overrides the clean config below (auto-connect, a profile, a cloud provider): stop and report it to your lead.
3. Name a session for this task alone: `ab-<agent>-<task>-<unix time>`. In a shell that keeps no variables between calls, repeat the literal name.

## Every command

Every call carries the same `--config ~/.agents/skills/agent-browser/config.json --session <name> --headed false`. The config replaces any user or project `agent-browser.json`. Repeat every other launch flag the first call used (`--allowed-domains`, …) as well: a call whose launch flags differ lands in a fresh blank page.

```sh
C=$HOME/.agents/skills/agent-browser/config.json S=ab-docs-check-1791402000
agent-browser --config "$C" --session "$S" --headed false open https://example.com
agent-browser --config "$C" --session "$S" --headed false snapshot -i -c
agent-browser --config "$C" --session "$S" --headed false click @e1
agent-browser --config "$C" --session "$S" --headed false close
```

- Read the page from the compact AX snapshot (`snapshot -i -c`), `read` or `get text`. Screenshot only after a snapshot, and only when layout, canvas or imagery is the question. Write captures to a `mktemp -d` scratch dir.
- `close` ends every task, failed ones included. A browser left open exits after an idle hour.

## Off limits

Drive only the fresh browser your session launched. These reach Tim's live session, his logins, or paid services:

- `--auto-connect`, `--cdp`, `connect`, `--profile`, `profiles`, `--state` from his browser: his running Chrome, its profiles and logins.
- `--args` and `--executable-path`: launch overrides that can name his profile, a debugging port, or his Chrome.
- `--headed true`, `inspect`, `-p ios`, `dashboard`: windows and servers on his Mac.
- `clipboard`: the system clipboard he types with.
- `chat` and cloud providers (`-p browserbase`, `browseruse`, …): paid inference and hosting.
- `install` and `upgrade`: the version is pinned (0.38.2) by the agent setup in `~/dotfiles/agents`.

A site that needs Tim's login gets a separate test account or a login he approves; ask him through your lead.

## Other routes

- Tim wants to watch the page: an easl browser tile (easl skill).
- Deterministic tests and captures (terms capture and e2e, 3d-game Playwright Test) stay on their own libraries; bulk captures run on deckbox through `offload`.
- A headed browser or desktop GUI runs in a VM, never on a host session: report the need to your lead.
- twaldin-work has no agent-browser: use the harness's browser tool there.
