# Verification report

## Binding and scope

- Bound audit: `/tmp/battery-power-full-functionality-gap-audit.md`
- Required and observed SHA-256: `76274bc15a50f2e86673ea8bafc7145753f391117a8f9c60de7daf977816090b`
- Implemented scope: source-only on-intent public power detail reader and sealed main System Settings command.
- Excluded scope: Keep Awake, all power writers, direct Sleep, Display Sleep, Lock, charging writers, schedule writers, Shortcut execution, installation, and persistent service mutation.
- Live boundary: no production binding, observation backend, application opener, installer, power writer, or power assertion was executed during verification.

## Offline results

`./scripts/verify.sh /tmp/battery-power-full-functionality-gap-audit.md` passed with:

- source and binding-audit digest gate: pass;
- macOS SDK 15.4 type-check, normal and optimized, warnings as errors: pass;
- macOS SDK 26.4 type-check, normal and optimized, warnings as errors: pass;
- 39 injected synthetic tests, normal: pass;
- 39 injected synthetic tests, optimized: pass;
- seven mutation cases detected: 7/7;
- required reviewed public-link symbols: pass;
- forbidden link, source string, binary string, privacy, and no-live-test paths: pass;
- extensionless Mach-O/fat/ELF/bitcode/archive/PE content and build/bundle shape rejection self-test: pass;
- source-only tree check after artifact removal: pass.

Swift Package Manager debug and release builds also passed with warnings as errors. The generated `.build` directory was then removed, and the content-based source-only gate passed again.

No sampled power value, hardware fact, application state, display topology, schedule item, transition time, user fact, or process fact was collected in these checks.

## Adversarial review

The initial cross-harness Codex review returned `request_changes` with two medium findings. The exact structured output is `docs/ADVERSARIAL-REVIEW-INITIAL.json`.

1. **Source-only gate was suffix-limited.** Fixed by checking compiled file magic, extensionless binaries, archives, privileged bits, build-output names, and application/framework/bundle shapes. Added synthetic negative fixtures.
2. **Source-notification failure stopped the heartbeat.** Fixed with an injectable registration backend. Independent invalidations and the 60-second heartbeat install before the source notification. A source-registration failure returns `polling_only`, emits fixed `observation_unavailable`, and remains refresh-capable. Added a no-live synthetic failure-path test and mutation.

The first repaired-tree review confirmed both initial fixes, then returned `request_changes` for one medium cross-generation privacy issue. The exact output is `docs/ADVERSARIAL-REVIEW-REPAIR.json`. Transition mutation occurred before the active-generation guard, so events received while closed could appear in a later popup. Transition state is now generation-scoped: closed events are ignored, begin/close reset to `unknown`, and a synthetic plus mutation test detects leakage.

The final stable-byte review result is delivered with the external review artifact. The review runs only after this report and the canonical manifest exist; no prototype byte changes are permitted after it.

## Residual hardware and attended gates

No hardware or attended gate ran. Release remains blocked on:

- supported portable AC/battery/adapter convergence without forced drain or charge;
- health, capacity, and cycle label comparison without equivalence claims or captured values;
- supported and unsupported Low Power wording;
- disabled Automatic/High Power and charging-mode fallback wording;
- manual sleep and physical wake refresh;
- built-in/external all-awake, mixed, all-asleep, and topology-change display checks;
- active/inactive session transitions with no lock claim;
- one main System Settings launch on macOS 15 and 26 with no pane claim;
- schedule-count and privacy checks;
- pointer, keyboard, focus, VoiceOver, privacy mode, display scale, hot-plug, restart, staleness, callback burst, and one-popup checks;
- future source-pinned installer no-follow, owner, mode, architecture, hash, flush, recovery, and rollback proof; and
- a separate sandbox-boundary proof if sandboxing is proposed.

The complete checklist is `docs/ATTENDED-GATES.md`. Keep Awake remains owned and gated separately.

## Hash convention

`MANIFEST.sha256` is the canonical sorted SHA-256 list for every regular delivery file except `MANIFEST.sha256` itself. Excluding the manifest avoids an impossible self-hash. The delivery message reports the manifest file hash. A final reviewer receives these exact bytes and no file is edited after approval.
