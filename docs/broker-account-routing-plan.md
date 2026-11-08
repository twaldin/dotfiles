# Plan: per-call account ids, spread, and 429 events for the money runner

Status: plan only, nothing built or deployed. Target: money SPEC G3 (`twaldin/money` `docs/SPEC.md:502`). References are to omp 18.18.1, the live broker's version, relative to `~/.bun/install/global/node_modules/@oh-my-pi/`.

## Where account choice happens today

The broker does not choose accounts. It holds the pool, usage reports, refreshes, and shared cooldown blocks. Each `omp` process ranks and picks in its own `AuthStorage` (`pi-ai/src/auth-broker/types.ts:1-6`, `discover.ts:496-540`). The money runner is such a process: `testers/tester.py:151` and `gen/gen0.py:372` run `omp -p --no-session` against the home broker. SPEC line 520 says jobs go through `omp auth-gateway`. They do not.

A new session ranks credentials in this order (`pi-ai/src/auth/rank.ts:88-135`): blocks, plan, spent allowance, reserve (active only when an `auth.accountPolicies` entry exists, `select.ts:357-361`), priority boost, 5h window at 85%, configured priority, measured before unmeasured. Then it sorts by required drain, descending: headroom divided by hours to reset (`pi-ai/src/auth/usage-report.ts:256-269`). Ties fall to stored order (`select.ts:689`). A warm session keeps its pick (`select.ts:638-658`).

Every fresh process computes the same winner from the same cached meters, so the ranking concentrates load by design, consistent with 40 of 40 test sessions on one account. In the last 4 hours, deckbox seats logged 12,616 Anthropic turns on credential row 22 and at most 1,586 on any other row.

## 1. Account id per call

Each completed assistant turn carries `credentialId`, the broker's durable row id for the credential that served it (`pi-ai/src/stream.ts:1241-1247`, `pi-ai/src/types.ts:1322`). `omp -p --mode json` prints it in `message_end` events (`pi-coding-agent/src/modes/print-mode.ts:104-105,361-362`). A failed attempt that omp retries on another account is buffered and dropped (`stream.ts:1249-1267`), so this names the serving account, not every attempt. Section 3 covers the failed attempts.

`omp usage --json` cannot be joined to that id. Its reports carry `metadata.accountId`, `email`, and `orgId`, but no `credentialId` and no `identityKey`, the key that account pools match (`pi-ai/src/auth/sqlite-credential-store.ts:192-228`).

- **omp:** add `credentialId` and `identityKey` to each `UsageReport` where the broker builds it per credential (`pi-ai/src/auth/usage.ts:809-845`), and keep both through `dedupeUsageReports` and the wire schema. The fields are additive.
- **money:** run `omp -p --mode json`. Collect `credentialId` from every assistant `message_end`, not only the last, and take the answer text separately.

## 2. Spread: the runner picks, omp obeys

omp already lets one process see a chosen subset of accounts. `OMP_AUTH_BROKER_ACCOUNT_POOL_FILE` filters the broker pool by `identityKey` for that process only (`pi-ai/src/auth-broker/discover.ts:270-340`, `remote-store.ts:55-98`). `agents/shepherd/bin/omp-broker-move-check:55-58` uses it today to pin one account per check.

For each LLM job, the runner:

1. Picks an account among the provider's unpaused accounts (G2, with its 0.75 resume rule). It takes the account with the fewest jobs assigned in the last 30 minutes, then the lowest `usedFraction`. The assignment count moves on every job, so concurrent and back-to-back jobs spread even while the meters are cached.
2. Writes a 0600 pool file `{"*": true, "<provider>": {"accounts": ["<identityKey>"], "apiKeys": false}}` and sets the env var on that `omp -p` only.
3. Checks that every `credentialId` the job reports maps to that one account.

This needs no new omp selection code and no seat change, and it enforces G2 exactly. Until the omp fields land, the runner can derive Anthropic keys as `email:<lowercase email>|org:<orgId>`, the form `omp-broker-move-check` proves against the live broker. A wrong key yields an empty pool, and the job fails fast, so the error is visible.

Rejected: an upstream `auth.selection: spread` setting. It needs ranking changes, and hashing over the full credential list skews: with 6 rows and only rows 0-2 healthy, row 0 takes 4 of 6 start positions.

## 3. Rate-limit events

A quota 429 becomes a shared block that the client posts to the broker (`pi-ai/src/auth-broker/remote-store.ts:812-836`). A transient "slow down" 429 stays in the process that got it (`pi-ai/src/error/rate-limit.ts:469-497`). Blocks appear only in `/v1/snapshot`, which also holds access tokens, and no route lists 429s (`pi-ai/src/auth-broker/server.ts:159-173`).

- **omp client:** post every 429 to `POST /v1/events/rate-limit` with provider, `credentialId`, kind, and `retryAfterMs`. A failed post is dropped, not retried. A 404 from an older broker turns posting off for that process.
- **omp broker:** stamp each event with a sequence number and keep the last hour in memory.
- **`omp usage --json`:** add `rateLimitEvents` with `seq`, provider, `credentialId`, and kind. No credentials.

The governor already polls `omp usage --json` every 30 s. It keeps the last `seq` it read, resets that cursor when `seq` goes backwards after a broker restart, and halves the provider's AIMD limit once per new event (G5). Its own 429s arrive through the same events, so `finish` stops halving on 429. `finish` still halves on transport errors, and on 429 when the usage JSON lacks `rateLimitEvents`.

## How the governor uses it

- G3 measure: distinct `credentialId`s over the last 40 test calls per provider. `routing: spread` at 3 or more, `pinned` below.
- Under spread, G2 pauses per account. A provider is unavailable only when every account is paused.

## Risks to running seats, and rollback

- **Seats:** no config, setting, or ranking change. They get event posting and the new usage fields through the normal `omp-update` roll.
- **OAuth refresh:** unchanged. A pinned money process refreshes through the broker like any client (`remote-store.ts:1299-1353`).
- **Session affinity and prompt cache:** one job stays on one account, so a multi-turn tester keeps its cache. Shared money prompts warm on several accounts instead of one. Tokens do not gate (order 9).
- **Pinned job hits a quota 429:** omp cannot rotate inside the job, so the job fails as transient. The runner retries it on another account (G7, uncharged).
- **Rollback, runner:** stop setting the pool env var. Routing returns to omp's ranking at the next job.
- **Rollback, omp:** `omp-update` never downgrades (`agents/shepherd/bin/omp-update:588-611`). Set `hold_below` for each host, then reinstall the previous version with `bun install -g @oh-my-pi/pi-coding-agent@<previous>` on deckbox, or restore the `.bak` binary that `swap_binary` keeps on home. Restart the broker and gateway first, then roll seats.

## Size and where it lands

| Change | Code | Tests |
|---|---|---|
| omp: `credentialId`, `identityKey` on usage reports | ~20 | ~30 |
| omp: rate-limit events and cursor | ~100 | ~80 |
| money: JSON mode, pool-file pinning, account pick, events | ~150 | ~120 |

The broker's units live in dotfiles. Its code is omp, so omp work lands in `can1357/oh-my-pi`, because `omp-update` installs only upstream releases (`omp-update:28-29,731-743`). Pinning works before any omp release.

## Tests

- **omp unit:** report fields survive dedupe and the wire. Events get increasing `seq`, expire after an hour, and carry no secrets. An older broker's 404 turns posting off.
- **money unit:** pick spreads 40 back-to-back jobs over 3 unpaused accounts. Pick skips an account at 0.78 that paused at 0.81 and has not reset. Every account paused means no job starts. A job that reports two `credentialId`s fails the pin check. The event cursor survives a delayed event and a `seq` reset, and counts each 429 once.
- **Live smoke, no model calls:** run `omp usage --json` and check that each report's `identityKey` matches the pool-file key that the runner derives.
- **Live acceptance:** the runner's next 40 queued Anthropic test calls run pinned. They are planned work, so they add no extra quota. Each pinned account must map to exactly one `credentialId`, and the governor must show 3 or more distinct accounts.

## Open decisions for Tim

- **Codex:** G4 refuses Codex jobs until Codex passes G3, and G3 needs 40 Codex calls. Lifting needs a bounded 40-call Codex run that Tim approves.
- **One-account providers:** Z.ai and xAI each show one account in `omp usage --json`, so "3 or more" can never pass for them. The SPEC needs a rule for them.
