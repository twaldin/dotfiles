# Remaining Controls v2 prototype report

## Verdict

Source-only offline prototype complete. Nothing was installed, launched, signaled, or connected to live state. All tests use fake boundaries.

## Binding provenance

- Approved audit: `/tmp/remaining-controls-full-functionality-gap-audit.md` — `43899240514ebf3c81ca46b4197f39d351c94d10134cbb97129a63ab6d8a7146`
- Approved rereview: `/tmp/remaining-controls-full-functionality-gap-audit-rereview.json` — `dd20dfdfe4389fd2b7d04e596f49d3625f481ca95ecccbae1ae7205aaf35aefc`

## Implemented result

- Media uses fixed public-unavailable rows unless exact state belongs to this app. It has no private provider or external command.
- Front Window state, complete content, and native identities are package-private. The public shape is anonymous. Slot actions require the view generation, native inventory generation, exact topology, exact target, capability, one command, and a fresh strict readback.
- Workspaces require exact native Spaces 1 through 9. Static fallback rows are fixed and disabled. Focus, directional, recent, warp, float, zoom, balance, ratio, and send-follow contracts are represented behind one fake vendor boundary. Send-follow reports exact rollback, exact rollback with action failure, uncertain rollback, or partial/manual recovery without conflation.
- Focus, Do Not Disturb identity, built-in Control Center state/open, System Sleep, Display Sleep, Lock Screen, global Appearance, Night Shift, True Tone, brightness, and Stage Manager are non-actionable and accessibility-disabled. Sleep and display-sleep writer objects do not exist.
- The 13 Settings keys select only fixed copy. Every key verifies the same exact sealed main app path, bundle identity, Apple signature, and resource identity. Primary open uses only the fixed file URL. One unambiguous fallback uses only the fixed path. There is no pane route or Control Center launcher.
- Display reads require two equal online-display snapshots. Preview requires exactly two online displays and a fresh expected-snapshot match inside the CoreGraphics boundary. A shared display gate and WM gate stay held for the complete app-only lease. Keep revalidates, writes one session configuration, reads twice, rejects late state with conditional exact session rollback, ends the lease, and reads twice again. Crash/owner loss, Revert, and lifecycle cancellation distinguish exact rollback from partial/manual recovery. Undo requires the complete unchanged kept snapshot.
- Keep Awake uses exact bar-owned state, an explicit desired state, one operation, and separate readback. “Off” means only not owned by this coordinator. Low Power and effective rendered Appearance are read-only/scoped facts.
- Native window/display/resource values are package-private and are not Codable, printable, logged, placed in argv, or emitted in test evidence.

## Offline verification

| Gate | Result |
| --- | --- |
| Active SDK debug, warnings as errors | PASS — 58 scenarios, 578 assertions |
| Active SDK optimized, warnings as errors | PASS — 58 scenarios, 578 assertions |
| macOS 15.4 SDK debug typecheck/link, warnings as errors | PASS |
| macOS 15.4 SDK optimized typecheck/link, warnings as errors | PASS |
| macOS 26.4 SDK debug typecheck/link, warnings as errors | PASS |
| macOS 26.4 SDK optimized typecheck/link, warnings as errors | PASS |
| Public-link audit | PASS |
| Private-string audit | PASS |
| Privacy/serialization/output audit | PASS |
| No-live-exec audit | PASS |
| Sealed Settings launcher static and fake tests | PASS |
| Mutation/staleness/callback/rollback/crash fake tests | PASS |

## Adversarial review

Three cross-harness request-changes passes found and drove repairs for: full preview-lease gate ownership; stale and late Keep rollback; fresh in-transaction baseline binding; native panel generation enforcement; exact send-follow rollback preflight; full-state WM readback; and implementation-review provenance binding. Focused regression tests cover each repair.

The fourth cross-harness source rereview returned **approve** with no findings:

- `/tmp/remaining-controls-v2-fourth-review.json`
- SHA-256: `8d871cc6d0af8e0dddb08a4decb096c1d7af9abeecbd6ed0890ca62eb8fb412b`
- reviewer summary: safety, privacy, exact readback/rollback, crash/lifecycle, sealed-launcher, disabled-writer, and regression-test contracts are materially represented.

## Residual attended, permission, and hardware gates

None of these gates ran. Bot review cannot satisfy them.

- Window/Spaces: signed native panel lifecycle; Accessibility denied/granted; VoiceOver; Full Keyboard Access; all preserved physical chords; click/scroll; one minimized window; windows on all nine native Spaces; external focus; forced halfway send-follow failure; wake; display change; manager restart; content-masked evidence; external display when present.
- Manager cutover: full primary-to-alternate-to-primary transition, strict non-overlap, one bar instance, and inactive alternate login state afterward.
- Settings: human confirmation of the exact 13-key product set; all labels/manual instructions; exact main app only; already-open/closed states; focus return; every display; no pane claim.
- Focus: communication-service purpose approval and stable signing are still absent. No authorization request or Focus read is enabled. There is no programmatic action gate.
- Control Center: manual guide only. There is no programmatic gate.
- Keep Awake: exact owned on/status/off, stale ownership, unrelated assertion protection, reload, and wake.
- System Sleep and Display Sleep: only verify disabled copy, accessibility-disabled state, nil/rejected reserved slots, and zero calls. This gate can never enable a writer.
- Lock Screen: manual path only while disabled.
- Appearance, Night Shift, True Tone, brightness, Stage Manager, and Low Power mutation: disabled-row accessibility and the separate main Settings handoff. No live writer gate.
- Mirroring read: built-in and two-display online/active/hardware-mirror fixtures with content-free evidence.
- Mirroring write: two physical displays are mandatory. Test different scales/modes, software and hardware mirror when available, full-screen failure, hot-plug, sleep/wake, external and display-service epoch change, owner/helper crash, reload, Escape, timeout, Keep, Revert, valid/invalid Undo, fixed manual recovery, and exact nine-Space recovery. No write can ship before this human/hardware gate.
- Signing/install/launcher: stable signed identities, transactional installation, sealed resident owner channel, owner EOF, crash relaunch readback, and human approval. No installation or live launch occurred.
- UX: VoiceOver copy/state, Full Keyboard Access, focus rings, Increase Contrast, left-click-only actions, popup replacement/dismissal, and invariant geometry.

## Canonical source hashes

`SOURCE-MANIFEST.sha256` contains one SHA-256 for every source, test, script, and design file in canonical path order.

- Files: 25
- `SOURCE-MANIFEST.sha256`: `b871e75315730a9beac0d59a0346ac70ef75eb4b629d77eaa493e024f1ca25d0`
- `SHA256SUMS` also covers this report and the source manifest.
