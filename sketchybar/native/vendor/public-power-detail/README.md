# Public Power Detail prototype

This directory is a source-only prototype for Slice B of the Battery and Power audit. It is bound to:

- `/tmp/battery-power-full-functionality-gap-audit.md`
- SHA-256 `76274bc15a50f2e86673ea8bafc7145753f391117a8f9c60de7daf977816090b`

The package has no executable product. A host must create `DarwinPublicPowerBindings` only after a popup generation starts. Tests inject `FakeBindings`; they do not read host power, display, session, schedule, or application state.

## Components

- `Contract.swift`: closed, identity-free `public_power_detail_v1` JSON types.
- `DarwinPublicBindings.swift`: strict Core Foundation bridge and reviewed public reads.
- `Reader.swift`: inventory, contradiction, sentinel, applicability, and privacy rules.
- `PowerDetailAgent.swift`: popup generation, one-generation cache, callback coalescing, and stale-token rejection.
- `ObservationDriver.swift`: injectable public source, Low Power, load, sleep/wake, screen, session, and 60-second heartbeat invalidations. Callback payloads are ignored. Source-registration failure reports a fixed error and continues in polling-only mode.
- `SystemSettingsCommand.swift`: one sealed main-application command through AppKit. It has no pane input.
- `Tests/.../PublicPowerDetailTests.swift`: synthetic, injected test executable.
- `audit/`: source, public-link, string, privacy, no-live-execution, and mutation gates.

## Supported output

The JSON document has an exact top-level key set:

`schema`, `freshness`, `inventory`, `power`, `health`, `electrical`, `energy`, `sleepAndDisplay`, `session`, `schedule`, `fallbacks`, `settings`, `errors`.

Unavailable scalar values retain both `state` and a JSON-null `value`. Times distinguish calculating, unavailable, and not applicable. Aggregate time recognizes only the exact public unknown and unlimited sentinels. Errors are fixed enums; native error text is never emitted.

The output has no source dictionary, source name, serial, vendor, product, transport identity, source identifier, display identifier, user fact, process fact, application name, event time, or wall-clock time. Generation and sample counters are local freshness values, not durable identifiers.

## Deliberate disabled surface

The contract emits fixed disabled or unavailable rows for direct Sleep, Display Sleep, Lock, Automatic/High Power, Optimized Battery Charging, Charge Limit, Charge to Full, Apple Maximum Capacity, and usage history. Scheduled power data is a count only. The separate Settings action claims only the main System Settings application.

Keep Awake is not in this prototype. Another owner supplies it.

## Offline verification

```sh
./scripts/verify.sh /tmp/battery-power-full-functionality-gap-audit.md
```

The gate:

1. verifies the binding audit digest;
2. checks source bans, fixed power keys, strict bridge markers, privacy, and no live adapter use in tests;
3. type-checks macOS SDK 15.4 and 26.4 in normal and optimized modes with warnings as errors;
4. compiles and runs normal and optimized synthetic tests against SDK 26.4;
5. links a probe without executing it, then checks reviewed public symbols and strings;
6. proves seven controlled semantic mutations are detected; and
7. self-tests content-magic and bundle-shape rejection, then verifies that the prototype tree contains source only.

The verification does not install files, register a persistent service, create a power assertion, run a power writer, open an application, or construct a production binding.
