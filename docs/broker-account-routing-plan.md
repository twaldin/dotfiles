# Plan: per-call account ids, spread, and 429 events for the money runner

Status: plan only, nothing built or deployed. Target: money SPEC G3 (`twaldin/money` `docs/SPEC.md:502`). References are to omp 18.18.1, the live broker's version, relative to `~/.bun/install/global/node_modules/@oh-my-pi/`.

## Where account choice happens today

The broker does not choose accounts. It holds the pool, usage reports, refreshes, and shared cooldown blocks. Each `omp` process ranks and picks in its own `AuthStorage` (`pi-ai/src/auth-broker/types.ts:1-6`, `discover.ts:496-540`). The money runner is such a process: `testers/tester.py:151` and `gen/gen0.py:372` run `omp -p --no-session` against the home broker. SPEC line 520 says jobs go through `omp auth-gateway`. They do not.

A new session ranks credentials in this order (`pi-ai/src/auth/rank.ts:88-135`): blocks, plan, spent allowance, reserve (active only when an `auth.accountPolicies` entry exists, `select.ts:357-361`), priority boost, 5h window at 85%, configured priority, measured before unmeasured. Then it sorts by required drain, descending: headroom divided by hours to reset (`pi-ai/src/auth/usage-report.ts:256-269`). Ties fall to stored order (`select.ts:689`). A warm session keeps its pick (`select.ts:638-658`).

Every fresh process computes the same winner from the same cached meters, so the ranking concentrates load by design, consistent with 40 of 40 test sessions on one account. In the last 4 hours, deckbox seats logged 12,616 Anthropic turns on credential row 22 and at most 1,586 on any other row.

## 1. Account id per call

Each completed assistant turn carries `credentialId`, the broker's durable row id for the credential that served it (`pi-ai/src/stream.ts:1241-1247`, `pi-ai/src/types.ts:1322`). `omp -p --mode json` prints it in `message_end` events (`pi-coding-agent/src/modes/print-mode.ts:104-105,361-362`). A failed attempt that omp retries on another account is dropped (`stream.ts:1249-1267`), so this names the serving account, not every attempt. Section 3 covers failures.

`omp usage --json` cannot be joined to that id: reports carry `metadata.accountId`, `email`, and `orgId`, but no `credentialId`, `identityKey`, or block state.

- **omp:** add `credentialId`, `identityKey`, and `blockedUntil` to each `UsageReport` where the broker builds it per credential (`pi-ai/src/auth/usage.ts:809-845`). Keep them through `dedupeUsageReports` and the wire schema. `--redact` masks `identityKey` (`pi-coding-agent/src/cli/usage-cli.ts:1154-1178`).
- **money:** run `omp -p --mode json`. Collect `credentialId` from every assistant `message_end`. In JSON mode a terminal error goes to stdout, not stderr (`print-mode.ts:633-645`), so the tester must decode it and report a 429 as transient. Today it reports `omp exited 1` (`testers/tester.py:155-156`), which `runner/run.py:199-202` charges.

## 2. Spread: the runner picks, omp obeys

`OMP_AUTH_BROKER_ACCOUNT_POOL_FILE` limits one process to chosen accounts by `identityKey` (`pi-ai/src/auth-broker/discover.ts:270-340`, `remote-store.ts:83-98`). `agents/shepherd/bin/omp-broker-move-check:55-58` uses it today to pin one account per check. For each LLM job, the runner:

1. Builds the candidate set: the provider's accounts that are not G2-paused (with the 0.75 resume rule) and not blocked.
2. Takes the lowest `usedFraction`. Accounts within 0.05 of the lowest count as tied, and ties go to the account with the fewest jobs assigned in the last 30 minutes. The band stops a 5-minute-old meter from sending every job to one account.
3. Writes a 0600 pool file `{"*": true, "<provider>": {"accounts": ["<identityKey>"], "apiKeys": false}}` and sets the env var on that `omp -p` only. It also drops provider API-key env vars, which the pool cannot hide (`pi-ai/src/auth/cascade.ts:458-462`).
4. Rejects a result whose assistant turns lack `credentialId` or name another account.

Seats see nothing. Pinning waits for the omp fields: without `credentialId` and `blockedUntil` on reports, the runner cannot check a pin or skip a blocked account, and omp serves a blocked account as a last resort (`pi-ai/src/auth/select.ts:965-998`).

Rejected: an upstream `auth.selection: spread` setting. It changes ranking for every user, and G2's 0.75 resume rule has no omp equivalent.

## 3. Rate-limit events

A quota 429 becomes a shared block (`pi-ai/src/auth-broker/remote-store.ts:812-836`). A transient "slow down" 429 stays in the process that got it (`pi-ai/src/error/rate-limit.ts:469-497`). Blocks appear only in `/v1/snapshot`, which also holds access tokens, and no route lists 429s (`pi-ai/src/auth-broker/server.ts:159-173`).

- **omp client:** post every 429 to `POST /v1/events/rate-limit` with provider, `credentialId`, kind, and `retryAfterMs`. A failed post is dropped. A 404 from an older broker turns posting off for that process.
- **omp broker:** stamp each event with `bootId` and an increasing `seq`, and keep the last hour in memory.
- **`omp usage --json`:** add `rateLimitEvents: {bootId, events: [{seq, provider, credentialId, kind}]}`.

The governor polls `omp usage --json` every 30 s and keeps a `(bootId, seq)` cursor. A new `bootId` means it reads every event. Events are the only 429 signal: a poll with any new event for a provider halves that provider once (G5), whether a seat or a money job hit it and whether omp recovered. `finish` halves only on transport errors, so no 429 counts twice. The mode is fixed at startup, before any job runs. If the first poll carries `rateLimitEvents`, the governor uses events with the cursor at the newest `seq`. Otherwise `finish` halves on 429 as today. If events vanish in event mode, no LLM job starts until a restart. Limit: a dropped post loses one halving.

## How the governor uses it

- G3 measure: distinct `credentialId`s over the last 40 test calls per provider. `routing: spread` at 3 or more, `pinned` below.
- Under spread, G2 pauses per account. A provider is unavailable only when no account is a candidate.

## Risks to running seats, and rollback

- **Seats:** no config, setting, or ranking change. They get event posting and the usage fields through the normal `omp-update` roll.
- **OAuth refresh:** unchanged. A pinned process refreshes through the broker like any client (`remote-store.ts:1299-1353`).
- **Affinity and prompt cache:** one job stays on one account, so a multi-turn tester keeps its cache. Shared money prompts warm on several accounts instead of one. Tokens do not gate (order 9).
- **Pinned job hits a quota 429:** omp cannot rotate inside the job, so the job fails as transient and the runner retries it uncharged on another account (G7).
- **Fallback keys:** a `models.yml` key for a pinned provider would bypass the pool (`cascade.ts:385-405`). The runner refuses to start if `omp` resolves one.
- **Rollback, runner:** stop setting the pool env var. Routing returns to omp's ranking at the next job.
- **Rollback, omp:** stop the money runner first. `omp-update` never downgrades (`agents/shepherd/bin/omp-update:588-611`), so set `hold_below` for each host. Then reinstall the previous version with `bun install -g @oh-my-pi/pi-coding-agent@<previous>` on deckbox, or restore the newest `.bak` binary on home. Restart the broker and gateway, roll seats, then start the runner.

## Size and where it lands

| Change | Code | Tests |
|---|---|---|
| omp: three usage-report fields, redaction | ~30 | ~40 |
| omp: rate-limit events | ~100 | ~80 |
| money: JSON mode, pick, pinning, events | ~170 | ~140 |

The broker's units live in dotfiles. Its code is omp, so omp work lands in `can1357/oh-my-pi`, because `omp-update` installs only upstream releases (`omp-update:28-29,731-743`). The money JSON-mode change, and with it the G3 count, can ship first. Pinning and event halving start once the omp changes reach a release.

## Tests

- **omp unit:** report fields survive dedupe and the wire, and `--redact` masks `identityKey`. Events carry no secrets, expire after an hour, and restart with a new `bootId`. An older broker's 404 turns posting off.
- **money unit:** 40 back-to-back jobs over 3 accounts in the band use all 3. The pick skips a blocked account at 0.10 and an account at 0.78 that paused at 0.81. A JSON 429 with empty stderr ends `charge: false`. A turn without `credentialId` fails the pin check. A restart whose new `seq` passes the old cursor still delivers every event. In event mode, a job's terminal 429 halves once, in either order of `finish` and poll, and a 429 recovered inside a successful job halves once. The mode set at startup holds for the run, and losing events in event mode stops new LLM jobs.
- **Live smoke, no model calls:** check that every `omp usage --json` report carries `credentialId` and `identityKey`, and that the keys match `omp usage accounts --json` one to one.
- **Live acceptance:** the runner's next 40 queued Anthropic test calls run pinned, as planned work with no extra quota. Each must report its pinned account's `credentialId`, and the governor must show 3 or more distinct accounts.

## Open decisions for Tim

- **Codex:** G4 refuses Codex jobs until Codex passes G3, and G3 needs 40 Codex calls. Lifting needs a bounded 40-call Codex run that Tim approves.
- **Spread versus G3:** least-used puts load on accounts within 0.05 of the lowest. G3's "3 or more distinct" passes only while 3 accounts sit in that band. Z.ai and xAI have one account each, so they can never pass. The SPEC needs a rule for both cases.
