# Approved native source artifacts

This directory is a source-only fan-in of three separately approved artifacts. It does not activate native integration.

## Approval pins

| Artifact | Immutable destination | Canonical manifest SHA-256 | Approved whole-tree SHA-256 | Final same-byte review SHA-256 |
|---|---|---|---|---|
| Public Power Detail | `vendor/public-power-detail` | `ba85e0a9b5084c1e317dc9636ffdfbb815fcbbc9135a902be061915e23bb5d8b` | Not supplied | `5b918a625d2c61ef142b29dba69cc3b84970cd0e5002b61971e795b054093059` |
| Display Public Detail | `vendor/display-public-detail` | `d4dddf0ec161da8421ae08706ac75c79d6b54affe51d9cccfc6b5bd4230c22e6` | `d7cd6a00727a25ea76b0c45cfc35ff13a9956a1289be0ef41effabdbf432fde4` | `79a01e8e6c7cae924eaa67c65198f3802268e4681299878f2da6e1ba89042547` |
| Remaining Controls v2 | `vendor/remaining-controls-v2` | `b871e75315730a9beac0d59a0346ac70ef75eb4b629d77eaa493e024f1ca25d0` | Not supplied | `bd491660aafb0cec0a64d74ab1c0cce14a51e240b1e14587a6f883cdc81d31b1` |

The approved binding-plan digest is `62b6c8f8955e11b24b9771d14937b6620ea40c5cd4b0a8711a43883211c71bc9`. Its final same-byte Codex stdout review approved with no findings at digest `df73944445cc078e405a588d424bd3ba965f0ef1e4dc98eb50a879cb1d525fdd`.

`APPROVED-ARTIFACTS.tsv` is the repository receipt. The Display `REPORT.md`, Remaining Controls `REPORT.md`, and Remaining Controls `SHA256SUMS` pins close canonical-manifest exclusions. These supplemental pins provide repository byte coverage. They are not separate approval evidence. “Not supplied” stays explicit; no repository hash is presented as an approved whole-tree hash.

## Immutable source boundary

Every file below `vendor/` is an immutable approved byte. Do not edit, normalize, generate, rename, delete, or add a file in a vendor tree. Keep the three modules separate. Their manifests, package declarations, verification scripts, test entries, module boundaries, and access rules are evidence, not repository integration points.

The source-only guard checks the exact 66-file path and mode table, manifest grammar and coverage, payload and supplemental hashes, directory prefixes, real-file and single-link identity, source-only content, phase inventory, dormant runtime state, and the existing query gates. A change to an approved tree needs a new exact-source approval and new pins.

## No entry and no live state

This fan-in adds no root `Package.swift`, root `Sources`, production `main`, executable product, integration adapter, action registration, install path, launch agent, daemon, runtime directory, generated output, or repository runtime entry. The approved Remaining Controls self-test product and Display `Tests/main.swift` remain unreachable test evidence inside their frozen trees.

Nothing here is built, signed, installed, launched, loaded, queried, or connected to host state. No production binding is constructed. No Power, Display, Settings, Keep Awake, window-manager, session, application, hardware, entitlement, TCC, process, or BetterDisplay state is read or changed. Existing Lua, builders, providers, installers, settings paths, and the five-name live-query allow-list remain unchanged.

## Shared boundaries for later reviewed work

Later adapters must stay outside `vendor/`. The reviewed locations are:

- `Package.swift` for the one repository native build;
- `Sources/SketchyBarNativeContracts/HostContract.swift` for the shared closed host contract;
- `Sources/SketchyBarNativeService/NativeCoordinator.swift` for the one service coordinator;
- `Sources/SketchyBarNativeUI/NativePanel.swift` for the one panel and view adapter;
- `Sources/SketchyBarNativeSettings/SettingsLauncherAdapter.swift` for the one sealed main-System-Settings adapter;
- `Sources/SketchyBarNativeDisplayGate/DisplayGateAdapter.swift` for the one cross-domain display gate; and
- matching injected tests under `Tests/`.

A later reviewed host must keep one native UI owner, one service owner, one fixed Settings launcher, one global display gate, and one window-manager exclusion gate. The only reviewed process-bound exception is a separately signed, short-lived display lease helper for a future attended 15-second Keep/Revert preview. It must hold inherited live authority, roll back on owner loss, and exit at terminal handling. These decisions do not authorize those paths or processes now.

## Future gates

Each later phase needs new source approval and must stop on a failed gate:

1. Adapter source-only: add only dormant library and injected-test targets outside the vendor trees.
2. Read-only host: add one reviewed entry with on-intent Power and anonymous Display reads, with no actions.
3. Stable signing: approve fixed identities, requirements, entitlements, and hardened runtime.
4. Transactional install: build once from the root package, verify provenance, and publish atomically without launch or query.
5. Read-only runtime: prove one host, privacy, recovery, exact rollback, and no new query target.
6. Settings: enable only the sealed fixed main-System-Settings action after attended checks.
7. Keep Awake: add and prove the public resident IOPM assertion boundary and ownership recovery.
8. Display mutation: prove the resident Keep/Revert lease, readback, rollback, loss recovery, and hardware matrices.
9. BetterDisplay: keep the production allow-list empty until licensing, version, schema, capability, privacy, readback, and rollback gates pass.
10. Window manager and final UI: prove one manager, exact Spaces behavior, accessibility, masking, physical input, wake, restart, and one panel owner.

Source import alone does not advance a signing, install, runtime, display-write, Settings, Keep Awake, BetterDisplay, window-manager, or release gate. It is not permission to deploy or activate any artifact.
