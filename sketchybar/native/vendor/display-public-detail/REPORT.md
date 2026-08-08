# Verification report

## Verdict

**PASS for this source-only, anonymous, read-only prototype. NO-GO for all display writes, BetterDisplay invocation, app launch, installation, deployment, and unattended use.**

Artifact: `/tmp/display-public-detail-prototype`

The dotfiles repository was not edited. Verification did not instantiate the system binding, read a live display, launch BetterDisplay or System Settings, mutate a display, run a Display Sleep writer, or install a file.

## Bound inputs

| Input | Required SHA-256 | Verified |
|---|---:|---:|
| `/tmp/display-betterdisplay-full-functionality-gap-audit.md` | `dbe0722b08fb101794dc846f619d9426fb48d36701097f659d1d9037221714cb` | PASS |
| `/tmp/display-betterdisplay-full-functionality-gap-audit-rereview.json` | `0b23f1f072862b0ddea4a9ae2c46f714160ca383eb9513d82167ff2603f8a702` | PASS |

## Canonical source manifest

Canonical manifest SHA-256: `d4dddf0ec161da8421ae08706ac75c79d6b54affe51d9cccfc6b5bd4230c22e6`

The canonical hash is SHA-256 over the exact bytes of `SOURCE-MANIFEST.sha256`. That file is sorted by relative path and uses one `<file-sha256><two spaces><relative-path><LF>` record for each payload source, test, script, and README file. `REPORT.md` and `SOURCE-MANIFEST.sha256` are excluded from the manifest to avoid recursive self-hashes. The final same-bytes directory hash and final review hash are external completion evidence.

```text
3bb4f741bd5bbab9a5f8ed7c333b22aa76df01274aed05de2abab7d6fa1681c6  README.md
b81753e75c358c9cf622112b8caf6e685cf25bcdf7582fc3fca504870e9767c2  Sources/BetterDisplayContract.swift
088bbb81c86e95b6c7369c500d0ee511a30dfc593fe4e1f1e3c9d8939b6887e0  Sources/BindingsModel.swift
05d90f656db3a0ca60a12a97bf770cc2ff533eb6c1ccdd6c2f8d27b6c86ef49e  Sources/Contract.swift
30e6fd77ff8103834f6267bf49b2747f803a491e7e1e93476231e21c48daab80  Sources/PolicySurface.swift
dbf60916b975686480744b775b243781e82a40f2c73f2abd3fda1fae57c667c9  Sources/SnapshotCoordinator.swift
f7ae244e04441795f81dda02df831e371edb171b9833173089574ef92f3dfb31  Sources/StrictJSON.swift
af9d10d38dcd4596956fab65ed28abfd2dcf11cd752813bffbbb84f611104805  Sources/SystemPublicBindings.swift
5c892e57ad287e0b7a537781f6f610b9f4a26614c4c287b715713fce8362ca49  Tests/main.swift
4a70ae8fc6c43b1f451cad18f96a37b7ece8f2b0aeea3750430021a5559c0a93  scripts/policy_audit.py
29feae204cb71faf97f2d5005416979da239033ce9c126d26fa9a8f66dc7ba3c  scripts/verify.sh
```

## Implemented contract result

- Public CoreGraphics/AppKit/ColorSync binding is injectable and has no executable entry point.
- One publishable result needs two equal complete semantic snapshots. The read starts are at least 100 ms apart, the full transaction is at most 3 seconds, and the generation must remain unchanged.
- Callback and notification inputs invalidate the generation. Failed, raced, rate-limited, and expired reads publish no cached state.
- Snapshot output is closed, bounded, finite, strict JSON with anonymous ordinals only. It has no display/native mode identifier, name, UUID, serial, vendor/model value, EDID, registry path, profile path, raw helper output, or raw native token.
- Inventory and topology include exact present-union, online, active, main, built-in, asleep, stereo, mirror-set, hardware-mirror, and anonymous mirror-edge facts.
- Mode facts separate point and pixel sizes and preserve non-integral scale. Current mode is exactly one bounded advertised desktop-usable mode. Refresh zero is unavailable. Rotation, AppKit refresh intervals, maximum FPS, VRR relation, EDR headroom, ColorSync facts, and HDR-setting unavailability use closed truth states.
- `ApplePublicSurfaceMatrix` has P01-P22. Every write/unsupported/not-linked row registers no action.
- `BetterDisplayCapabilityMatrix` has exact B01-B29 rows and all audited v4 families, including `underscan`, nits, CEC, DPCD, and DSC drift. Every row registers no action.
- Future BetterDisplay evidence checks exact version/schema, use class and v4 Pro entitlement when required, already-running integration, explicit approval, target/generation, capability/hardware, exact old state/range/unit/step and in-range input, automatic/coupled state, fresh independent readback, residency, app-loss recovery, exact rollback, and separate approval. Production has an empty version/schema allow-list.
- System Settings and BetterDisplay handoffs are fixed main-application designs only. They have no URL, pane claim, arguments, dynamic destination, opener, or action callback. Popup guidance is non-interactive.
- Installer, resident guard, journal, preview, Keep/Revert/Undo, and recovery behavior are design records only. No install destination or lifecycle process was created.

## Exact local verification

Command: `scripts/verify.sh`

| Gate | Result |
|---|---|
| macOS 15.4 SDK, arm64 macOS 15 target, `-Onone -warnings-as-errors -typecheck` | PASS |
| macOS 15.4 SDK, arm64 macOS 15 target, `-O -warnings-as-errors -typecheck` | PASS |
| macOS 26.4 SDK, arm64 macOS 15 target, `-Onone -warnings-as-errors -typecheck` with the SDK-26 public property guard | PASS |
| macOS 26.4 SDK, arm64 macOS 15 target, `-O -warnings-as-errors -typecheck` with the SDK-26 public property guard | PASS |
| Normal warnings-as-errors synthetic executable | PASS, 149 assertions |
| Optimized warnings-as-errors synthetic executable | PASS, 149 assertions |
| Mutation-discriminating inventory/topology/mode/generation/freshness/strict-JSON fixtures | PASS |
| BetterDisplay version/schema/license/use/capability/hardware/old/range/in-range/readback/residency/loss/rollback gate mutations | PASS |
| `underscan` missing/false/failed gate cases and no-action checks | PASS |
| Direct public link audit | PASS: AppKit, ColorSync, CoreGraphics, CoreFoundation, Foundation, system/Swift runtime only; no direct IOKit, ScreenCaptureKit, AVFoundation, SkyLight, or BetterDisplay framework/app link |
| Private-symbol, identity-read, privacy, no-live-execution, no-mutation, fixed-handoff, Display Sleep, arbitrary URL/VCP, permanent-commit, and source-only audit | PASS |
| Negative source-policy fixtures | PASS: every prohibited fixture rejected without execution |
| Retained build artifacts or unexpected executables | PASS: none |

All test executables were created in a temporary directory and deleted. The tests use only `FakeBindings`, `FakeClock`, and fake invalidation registration.

## Cross-harness review loop

| Review | SHA-256 | Verdict | Result |
|---|---:|---|---|
| First prototype review | `776c57051221fcb0cc99ba1784b5c806cc21f6b53c64e079242841a18f193d06` | request changes | Repaired profile evidence, non-interactive handoff guidance, and rate-limit cache invalidation. |
| First re-review | `95877ce7dd4a81fd44b8e133cf54c7650188c131829f6801a4551c0acdc7656d` | request changes | Repaired injected false profile evidence and added a strict negative fixture. |
| Clean source review | `d5f6701021cae816dbeeafade06e852cde084a3c3107466c0357c5131db886dc` | **approve** | No findings. |

A final cross-harness review is run on the exact report-and-manifest bytes after this report is written. Its external JSON and same-bytes directory hash are completion evidence; they are not copied into this self-referential artifact.

## Residual gates

### Entitlement and vendor gates

- Use class is not confirmed. Free-feature use is not permitted for business use.
- A valid BetterDisplay v4 Pro entitlement is not proved.
- `proAvailable`, integration enabled, one already-running instance, and explicit invocation approval were not read or proved.
- Installed v4.2.3 is audit evidence only. No exact stable output schema is approved; current vendor documentation describes v4.4.0. The production exact-version/schema allow-list stays empty.
- BetterDisplay app-loss recovery, startup/wake enforcement inventory, exact target privacy approval, and typed redacted output remain blocked.

### Hardware and recovery gates

- No external display, DDC, brightness method, hardware volume/mute/contrast, HDR/XDR, profile, rotation, connection, Sidecar, display-audio association, camera clean-feed, or `underscan` capability is proved.
- No resident guard, private journal recovery, exact rollback after wrapper/app loss, wake/reconnect, or attended secondary recovery path is implemented.
- Public CoreGraphics mode/topology writes still need the separate app-only lease, complete graph rollback, session-only promotion, and physical proof.
- Display Sleep, arbitrary DDC/VCP/specifier, reset/power/reinitialize, EDID/link/framebuffer identity operations, permanent commits, URL integration, and app management stay disabled. Attended proof cannot make one-way or permanently disabled commands eligible.

### Attended gates

- **H0:** anonymous read-only proof on each supported macOS version and 1x/2x scale.
- **H1:** compatible built-in brightness/True Tone or XDR proof.
- **H2:** two- and three-display mode, origin, main, mirror, hot-plug, wake, and lease-crash proof.
- **H3:** separate disposable external-hardware proof for each exact DDC brightness, volume, mute, and contrast capability.
- **H4:** compatible HDR/XDR/profile/rotation proof with a second recovery path.
- **H5:** camera and external clean-feed proof for the separate AVFoundation feature.
- Fixed main-app handoff focus/return behavior also remains attended and unimplemented.

No residual gate registers an action in this prototype.
