# Plan: account ids, spread, and 429 events for the money runner

Plan only. Target: money SPEC G3 (`docs/SPEC.md:502`). References are to omp 18.18.1, the live broker's version, under `~/.bun/install/global/node_modules/@oh-my-pi/`.

## Today

Each `omp` process picks its own account (`pi-ai/src/auth-broker/types.ts:1-6`). The broker only holds credentials, usage, refreshes, and cooldown blocks. Money's `omp -p` calls (`testers/tester.py:151`, `gen/gen0.py:372`) are such processes and skip the gateway, despite SPEC line 520.

After safety checks (blocks, plan, spent allowance, 5h window at 85%), a new session takes the highest required drain: headroom per hour left before reset (`pi-ai/src/auth/rank.ts:88-135`). Every fresh process picks the same winner, which fits 40 of 40 sessions on one account. Seats too: in the last 4 hours, row 22 served 12,616 Anthropic seat turns, and no other row passed 1,586.

## 1. Account id per call

Every completed turn already carries `credentialId`, the broker's durable row id (`pi-ai/src/stream.ts:1241-1247`), and `omp -p --mode json` prints it in `message_end` (`print-mode.ts:361`). A failed attempt that omp retried on another account is dropped (`stream.ts:1249-1267`).

- **omp:** add `credentialId`, `identityKey`, and `blockedUntil` to each `omp usage --json` report (`pi-ai/src/auth/usage.ts:809-845`). `--redact` masks `identityKey`.
- **money:** use `--mode json` and collect `credentialId` from every assistant `message_end`. Decode terminal errors from stdout, because today a JSON-mode 429 becomes a charged `omp exited 1` (`tester.py:155-156`, `run.py:199-202`).

## 2. Spread: per-job account pools

`OMP_AUTH_BROKER_ACCOUNT_POOL_FILE` limits one process to named accounts (`pi-ai/src/auth-broker/discover.ts:270-340`). `omp-broker-move-check:55-58` already uses it. For each LLM job, the runner:

1. Keeps the provider's accounts that are neither G2-paused (0.75 resume rule kept) nor blocked.
2. Picks the lowest `usedFraction`. Accounts within 0.05 of it tie, and ties go to the fewest jobs assigned in the last 30 minutes, so a cached meter cannot funnel every job to one account.
3. Writes a 0600 pool file with that one `identityKey` and `apiKeys: false` for that `omp -p` only. It drops provider API-key env vars and refuses a `models.yml` key for the provider, which the pool cannot hide (`pi-ai/src/auth/cascade.ts:385-405,458-462`).
4. Rejects a result whose turns lack `credentialId` or name another account.

Seats see nothing. Job pools wait for the omp fields, because omp serves a blocked account as a last resort (`select.ts:965-998`). A quota 429 inside a job cannot rotate, so the job fails as transient and retries uncharged elsewhere (G7).

## 3. Rate-limit events

Transient 429s stay in the process that got them (`pi-ai/src/error/rate-limit.ts:469-497`), and quota blocks show only in the token-bearing `/v1/snapshot`.

- **omp client:** post each 429 (provider, `credentialId`, kind, `retryAfterMs`) to `POST /v1/events/rate-limit`. Drop failed posts. Stop posting on a 404 from an older broker.
- **omp broker:** number events with `bootId` and `seq`, and keep one hour in memory. `omp usage --json` adds `rateLimitEvents`.

## Governor

- **G3:** count distinct `credentialId`s in the last 40 test calls per provider. `routing: spread` needs job pools on and 3 or more accounts. Otherwise routing is `pinned`, where any paused account stops the provider, as today.
- **429s:** each 30 s poll reads events past the `(bootId, seq)` cursor, and any new event halves its provider once (G5), whoever hit it. `finish` halves only on transport errors, so no 429 counts twice. The mode is fixed at startup. With no events at the first poll, `finish` keeps halving on 429. If events vanish later, LLM jobs stop until a restart. A dropped post loses one halving.

## Risks and rollback

- **Seats:** no config or ranking change. Event posts and usage fields arrive with the normal `omp-update` roll. OAuth refresh is unchanged (`remote-store.ts:1299-1353`).
- **Affinity and cache:** one job stays on one account. Money prompts warm several accounts' caches instead of one. Tokens do not gate (order 9).
- **Rollback:** one runner switch turns job pools off and returns routing to `pinned`. For omp, stop the runner and set `hold_below`, since `omp-update` never downgrades (`omp-update:588-611`). Reinstall the previous version (`bun install -g` on deckbox, the newest `.bak` on home), restart broker and gateway, roll seats, and start the runner last.

## Size and tests

omp work lands upstream in `can1357/oh-my-pi`, since `omp-update` installs only upstream releases (`omp-update:28-29,731-743`). Estimates: report fields ~30 lines plus ~40 test lines, events ~100 plus ~80, money ~170 plus ~140. The JSON-mode change and the G3 count ship before any omp release.

- **omp unit:** fields survive dedupe, the wire, and `--redact`. Events carry no secrets, expire, and change `bootId` on restart.
- **money unit:** 40 jobs over 3 tied accounts use all 3. The pick skips a blocked account at 0.10 and one at 0.78 that paused at 0.81. A JSON 429 is uncharged. A missing `credentialId` fails the job. Each 429 halves once in either arrival order and across a `seq` reset.
- **Live smoke, no model calls:** `identityKey`s in `omp usage --json` match `omp usage accounts --json` one to one.
- **Live acceptance:** the next 40 queued Anthropic test calls run with job pools, adding no quota. Each reports its pool's `credentialId`, and the governor shows 3 or more accounts.

## Open decisions for Tim

- **Codex:** G4 blocks Codex jobs until G3 passes, and G3 needs 40 Codex calls. Lifting G4 needs a bounded Codex run that Tim approves.
- **G3 shape:** G3 passes only while 3 accounts sit within 0.05 of the least used. Z.ai and xAI have one account each and can never pass.
