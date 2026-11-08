# Plan: per-call account ids, spread, and 429 events for the money runner

Status: plan only. Nothing here is built or deployed. Target: money SPEC G3 (`twaldin/money` `docs/SPEC.md:502`). Code references are to omp 18.18.1, the version the live broker reports at `100.85.222.119:8765/v1/healthz`. Paths are relative to `~/.bun/install/global/node_modules/@oh-my-pi/`.

## Where account choice happens today

The broker does not choose accounts. It holds the pool, usage reports, refreshes, and shared cooldown blocks. Each `omp` process picks an account in its own `AuthStorage` (`pi-ai/src/auth-broker/types.ts:1-6`, `discover.ts:496-540`). The money runner is such a process: `testers/tester.py:151` and `gen/gen0.py:372` run `omp -p --no-session` on the default profile, which points at the home broker. SPEC line 520 says jobs go through `omp auth-gateway`. They do not.

A new session ranks every credential (`pi-ai/src/auth/select.ts:577-720`). Safety checks come first: blocked, plan, allowance spent, inside reserve, 5h window above 85% (`pi-ai/src/auth/rank.ts:88-116`). Then "required drain" wins: headroom divided by hours to reset, so the account closest to its reset goes first (`pi-ai/src/auth/usage-report.ts:256-269`, `rank.ts:124-135`). Ties fall to stored order, not the session hash (`select.ts:689`). The session then stays on its pick while warm, one idle hour for Anthropic (`pi-ai/src/usage/claude.ts:918`).

That ranking explains 40 of 40 on one account. Every fresh process computes the same winner, here `#a290de86`. The default reserve is 10% (`pi-ai/src/auth/types.ts:25`), so omp keeps that account until 0.90 used, while the governor pauses the whole provider at 0.80 (`runner/governor.py:22,224-226`). Seats behave the same way: in the last 4 hours, deckbox seat sessions logged 12,616 Anthropic turns on credential row 22 and at most 1,586 on any other row.

## 1. Account id per call: already emitted

Every assistant message carries `credentialId`, the broker's durable row id for the credential that served the attempt, retries and errors included (`pi-ai/src/stream.ts:1241-1247`, `pi-ai/src/types.ts:1322`). `omp -p --mode json` prints it in `message_end` events (`pi-coding-agent/src/modes/print-mode.ts:104-105,361-362`). Seat session files already record it.

What is missing is the join to the meters: `omp usage --json` reports have `metadata.accountId`, `email`, and `orgId`, but no `credentialId` (`pi-coding-agent/src/cli/usage-cli.ts:1676-1722`), and Z.ai reports have no identity at all.

- **omp:** add `credentialId` to each `UsageReport` where the broker builds it per credential (`pi-ai/src/auth/usage.ts:809-845`), and keep it through `dedupeUsageReports` and the wire schema. The field is additive.
- **money:** run `omp -p --mode json`, take the final text from the last assistant message, and pass its `credentialId`s to `Governor.finish`. Key accounts by `hmac(salt, provider|credentialId)`, falling back to today's identity hash.

No gateway header is needed, because no money call uses the gateway.

## 2. Spread: an opt-in mode for one process

The choosing process must spread, so the change is a client setting: `auth.selection: drain | spread`, default `drain`. In `spread` mode the safety checks stay. `retry.usageReservePct` applies to every account, where today it needs at least one `auth.accountPolicies` entry (`select.ts:357-361`). The comparator stops after the safety checks, and ties break by the session-hashed order (`select.ts:122-142`). Each `omp -p` mints a fresh session id, so healthy accounts get a near-uniform share.

The runner opts in with the existing per-run flag, `omp --config ~/money/runner/omp-spread.yml`, holding `auth.selection: spread` and `retry.usageReservePct: 20`. A 20% reserve drops an account from money's picks at 0.80 used, the G2 line, so omp itself enforces the per-account pause. Seats never load the overlay and keep drain ranking.

The brief said "least used". I chose uniform among healthy accounts, because usage reports are cached up to 5 minutes (`pi-ai/src/auth/usage.ts:322-395`). Strict least-used would send every process to one account between refreshes and fail G3 again. I rejected reaching a 20% reserve today with a dummy account policy per provider. It needs no code, but it leans on a side effect and still concentrates load.

## 3. Rate-limit events

A quota 429 becomes a shared block that the client posts to the broker (`pi-ai/src/auth-broker/remote-store.ts:812-836`). A "slow down" 429 stays in the process that got it (`pi-ai/src/error/rate-limit.ts:469-497`). Blocks are visible only in `/v1/snapshot`, which also holds access tokens, and no route lists 429s (`pi-ai/src/auth-broker/server.ts:159-173`).

- **omp client:** post one event per 429 of any kind to `POST /v1/events/rate-limit`: provider, `credentialId`, kind, `retryAfterMs`, time. Fire and forget. A 404 from an older broker turns posting off for that process.
- **omp broker:** keep a 1-hour in-memory ring buffer.
- **`omp usage --json`:** add `rateLimitEvents` for the last 15 minutes and `blockedUntil` per report, both without credentials.

The governor already polls `omp usage --json` every 30 s, so it needs no new reader and no broker token. It halves a provider's AIMD limit on any event newer than its last poll (G5), whichever process hit the 429. Seats get the client half through the normal `omp-update` roll, with no config edits.

## How the governor uses it

- Count distinct `credentialId`s over the last 40 test calls per provider. Show `routing: spread` at 3 or more, `pinned` below.
- Under spread, pause per account (G2) and mark a provider unavailable only when every account is paused.
- G3 is measurable now with `--mode json` alone, before any omp change.
- Z.ai and xAI each have one account, so "3 or more" can never pass for them. The SPEC needs "all healthy accounts, up to 3".

## Risks to running seats, and rollback

- **OAuth refresh:** unchanged. The broker sweeps every 60 s (`pi-ai/src/auth-broker/refresher.ts:43-59`). Money may ask for a refresh on an account seats rarely use. That path is per credential and compare-and-set guarded (`remote-store.ts:1299-1353`).
- **Session affinity:** spread changes only a session's first pick. Warm pins work as today.
- **Prompt cache:** money's shared prompts warm on 3 to 6 accounts instead of 1, so more cache writes. Tokens do not gate (order 9). Seat caches are untouched.
- **Seat accounts:** spread can land on the account seats favor until it reaches 0.80, as money does today.
- **Event posts:** at most one small request per 429 per seat. Errors are swallowed, never retried.
- **Rollback:** drop `--config` from the runner, which stops spread at the next job. Roll omp back with `omp-update`. The event buffer is in memory, so nothing migrates.

## Size and where it lands

| Change | Code | Tests |
|---|---|---|
| omp: `credentialId` on usage reports | ~20 | ~30 |
| omp: `auth.selection: spread` | ~50 | ~60 |
| omp: rate-limit events, usage fields | ~110 | ~80 |
| money: `--mode json`, row-id accounts, events, overlay | ~120 | ~100 |

The broker's units live in dotfiles, but its code is omp. All omp work lands in `can1357/oh-my-pi`, because `omp-update` installs only upstream releases on both GitHub and npm (`agents/shepherd/bin/omp-update:28-29,731-743`). A local patch would be overwritten at the next roll.

## Tests

- **omp unit:** spread keeps the hashed order among healthy accounts and skips blocked, spent, reserve, and hot ones. Drain mode is unchanged. Over 1,000 random session ids on 3 healthy accounts, each gets 25-42%. `credentialId` survives dedupe and the wire. An event read returns no secrets. The buffer expires. An older broker's 404 is swallowed.
- **money unit:** parse a recorded `--mode json` stream, count distinct accounts, halve on new events, and pause per row id.
- **Live smoke, no model calls:** a Bun script resolves credentials for 40 random session ids through `AuthStorage` with the overlay and prints only `credentialId` counts. It reads cached usage and sends no inference request.
- **Live acceptance:** the runner's next 40 queued Anthropic test calls run with the overlay, so they add no extra quota. `money governor status --json` must show 3 or more distinct accounts. The runner refuses Codex jobs under G4, so Codex passes the smoke first and gets its live count once G4 lifts.
