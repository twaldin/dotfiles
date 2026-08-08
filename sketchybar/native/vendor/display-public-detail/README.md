# Anonymous public Display detail prototype

This source-only Swift prototype binds the approved audit and review exactly:

- audit SHA-256: `dbe0722b08fb101794dc846f619d9426fb48d36701097f659d1d9037221714cb`
- approval review SHA-256: `0b23f1f072862b0ddea4a9ae2c46f714160ca383eb9513d82167ff2603f8a702`

It does not edit the dotfiles repository. It has no production entry point, command runner, installer, writer, action callback, app opener, or BetterDisplay adapter. Verification executes only injected synthetic bindings. It does not instantiate `SystemPublicDisplayBindings`.

## Implemented read contract

`SystemPublicDisplayBindings` is an injectable public-framework adapter. It is present for SDK type checking only. If a later approved host calls it, it reads public CoreGraphics, AppKit, and ColorSync facts. It does not read display names, UUIDs, serials, vendor/model values, EDID, registry data, or content.

`ConfirmedSnapshotCoordinator` accepts a snapshot only when:

1. two complete normalized semantic reads match;
2. the second read starts at least 100 ms after the first;
3. the transaction ends within 3 seconds;
4. its generation did not change; and
5. the result passes the closed schema and bounds checks.

A display callback or public AppKit/workspace notification increments the generation and removes the publishable snapshot. A failed refresh also removes it. A confirmed value expires after one second and is never returned after expiration. Thus the cache can contain only a fresh, current-generation value. A full mode-bearing confirmation transaction starts at most once per five seconds; event coalescing is 250 ms, and the popup-only fallback design is 30 seconds.

The output has snapshot-scoped ordinals only. It includes exact counts and per-display facts for presence in the captured union, online, active, main, built-in, asleep, stereo, mirror membership, hardware mirror membership, and anonymous mirror edges. It keeps CoreGraphics global bounds separate from AppKit point geometry. It reports point and pixel mode sizes, non-integral X/Y scale, HiDPI relation, current usable mode, rotation, refresh-zero-as-unavailable, public AppKit refresh intervals/maximum FPS/VRR relation, and EDR current/potential/reference headroom. EDR never becomes an HDR-toggle claim.

AppKit facts are `unavailable` for no active screen match and `ambiguous` for multiple matches. Current mode and mirror endpoint ambiguity reject the snapshot. Color facts have closed available/unavailable states. The system adapter reports current ColorSync profile existence as available only when the public call returns a profile; a nil result is explicit unavailable evidence, never factual false. It reports public color-space capability facts. It keeps factory/custom classification unavailable unless an injected binding supplies an exact public classification. No profile path, bytes, digest, or description is emitted.

`StrictSnapshotJSON` checks a closed recursive key set before decoding. It also validates fixed hashes, finite ranges, caps, exact summaries, topology, one current mode, and closed evidence states. Unknown keys and identity-shaped additions fail. It emits sorted JSON with no raw native token or mode token.

## Capability truth

`ApplePublicSurfaceMatrix` represents P01-P22. P01-P06, the read part of P15, P17 asleep state, and P19 events are read-only/event inputs. All writes and unsupported/not-linked surfaces have no action registration. Display Sleep is a fixed non-clickable row:

`Display Sleep: Disabled — use macOS controls`

`BetterDisplayCapabilityMatrix` represents every B01-B29 family from the approved audit, including `underscan`, version-drift names, low-level reports, nits, CEC, DPCD, and DSC. Every row has an exact read disposition, write disposition, license tier, audit state, and `actionRegistration = none`. There is no BetterDisplay process path in executable code and no output parser or runner.

`BetterDisplayWriteGateEvaluator` is an inert future design. Eligibility for a separate implementation requires all of these injected facts at once:

- one exact installed-version/schema pair in an explicit allow-list;
- an already-running single app instance, enabled integration, and explicit invocation approval;
- confirmed personal non-business use for F* without Pro, or exact v4 Pro entitlement for business/P/U→P rows;
- one exact private target and current topology generation;
- proved capability and attended per-hardware support;
- closed exact old state, range, unit, step, an input proved inside that exact range, automatic state, and coupled state;
- independent fresh matching readback;
- resident guard and private journal;
- recovery after BetterDisplay loss; and
- exact rollback readback plus separate feature approval.

Unknown or failed gates block. Disabled, unsupported, and permanently disabled rows block even if evidence is otherwise complete. A successful future-gate evaluation still returns no action; it only marks evidence as sufficient for a separate reviewed implementation.

## Sealed handoff and lifecycle designs

`SealedHandoffDestination` has only two fixed cases:

- `/System/Applications/System Settings.app`, manual instruction `Select Displays.`
- `/Applications/BetterDisplay.app`, disabled until license and explicit invocation approval, with a fixed manual instruction.

Both plans have no arguments, URL, pane identifier, destination input, or execution implementation. The prototype makes no exact pane claim. The popup row is non-interactive manual guidance; only a separately approved host can implement the sealed handoff later.

`InstallerLifecycleDesign` is declarative only. It requires checksum pinning, atomic replacement, fixed file modes, no install during reload, a UID-private resident guard, a `0600` journal, exact old-state rollback, and lifecycle handling for crash, restart, wake, loss/reconnect, app loss, reload, logout, Escape, and popup close. No destination is created. `MutationContractDesign` records the future 15-second preview/Keep/Revert/Undo rules but implements no mutation.

## Verification

Run `scripts/verify.sh`. It performs:

- warnings-as-errors type checks against the installed macOS 15.4 and 26.4 public SDKs in `-Onone` and `-O` modes;
- warnings-as-errors synthetic tests in normal and optimized builds;
- runtime strict-JSON privacy checks and mutation-discriminating fixtures;
- an `otool` public-link audit;
- private-symbol, mutation, identity-read, Display Sleep, URL/pane, low-level action, underscan-action, no-live-execution, and source-only scans; and
- negative policy fixtures that must be rejected without executing them.

All executables are built in a temporary directory and deleted by a trap. No build artifact is kept in this source tree.

## Residual gates

No live display or app proof was performed. H0-H5 remain attended gates. BetterDisplay use class, v4 Pro entitlement where required, exact installed output schema, integration, explicit invocation approval, app-loss recovery, automatic-state inventory, and all per-hardware capabilities remain unproved. Public mode/topology writes still require the resident app-only lease and H2. Color profile selection still requires its independent guard and H4. Display Sleep, arbitrary DDC/VCP, reset/power, private/link/EDID, app-management, and other permanent disabled rows do not become eligible through attended proof.
