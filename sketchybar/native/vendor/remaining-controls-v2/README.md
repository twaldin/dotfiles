# Remaining Controls v2 source-only prototype

This isolated prototype binds these approved inputs:

- gap audit SHA-256: `43899240514ebf3c81ca46b4197f39d351c94d10134cbb97129a63ab6d8a7146`
- audit rereview SHA-256: `dd20dfdfe4389fd2b7d04e596f49d3625f481ca95ecccbae1ae7205aaf35aefc`
- implementation initial cross-harness review SHA-256: `661ecc77605995a6510d49f1e50f06931910fe05bf8c3edbcdcebf8d7b6b5067`
- implementation seven-issue cross-harness rereview SHA-256: `c03b21dbccad8c8ae0237a65d4bddb40b55238c9a4844804ab1c4ea06364b5e0`

The first two hashes are the binding approved audit contract. The latter two are implementation reviews whose seven lifecycle/mutation findings are repaired and regression-tested.

It is not installed or integrated. Its only executable product is an isolated offline self-test runner. That runner uses only fake AppKit, CoreGraphics, power, Keep Awake, and yabai boundaries. The package does not query live state or perform a live mutation when it is built or tested.

## Implemented contracts

- Media has fixed public-unavailable rows. There is no private media provider or media command path.
- Window content and native identities stay in the native coordinator. Public inventory uses fixed local slots and anonymous capability state. Every supported action has a new strict preflight, one vendor action, and a separate strict readback. Send-and-follow has conditional exact rollback and truthful partial/uncertain results.
- The global window-manager gate covers panel and key actions. Display preview blocks the gate until terminal readback. View invalidation never releases an in-flight operation.
- Focus, Do Not Disturb identity, built-in Control Center state/actions, Lock Screen, global Appearance, Night Shift, True Tone, brightness, and Stage Manager are fixed non-actionable, accessibility-disabled rows.
- The 13 System Settings enum keys all resolve and launch the same sealed main application resource. No key controls a pane. Primary launch uses the fixed file URL. The only fallback is the fixed path as the sole argument to `/usr/bin/open`.
- System Sleep and Display Sleep have read-only capability/aggregate coordinators and permanently disabled instruction rows. No writer protocol or runner exists. All Shortcut slots are nil and rejected; the two sleep slots are permanently reserved.
- Display reads require two equal online-display snapshots. A write requires exactly two online displays, full restorable state, no remote or sharing session, app-only preview, separate readback, a resident lease, and WM exclusion. Keep uses one session transaction and verifies the session after the app-only lease ends. Revert, owner death, and crash use app-only reversion plus exact readback. Undo is invalidated by any full-snapshot mismatch or lifecycle event.

## Safety boundary

`RemainingControlsCore` is pure coordination logic. `RemainingControlsMacBoundaries` contains only public AppKit, CoreGraphics, Foundation, and Security references. It has no initialization side effects. No executable target wires it to a UI. The CoreGraphics adapter is for a dedicated resident preview owner only; the owner must exit immediately after ending its app-only lease. The yabai interface is deliberately an injected native boundary. No operating-system window identity is accepted from or returned to Lua, a query document, stdout, logs, or helper argv.

The fake suite contains 58 scenario functions and 578 assertions. Run the offline gate with `scripts/test.sh`. It uses isolated scratch directories and removes them on exit.
