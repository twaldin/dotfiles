# Install and lifecycle design only

No installer, launch agent, socket, persistent file, or service mutation is included. This document defines a future integration gate; it does not execute it.

## Source pin and build

A future repository copy must pin a reviewed source manifest. Build the universal or target-native artifact from that exact manifest with both supported SDK checks. The install input must be a regular file from the fixed build output and must pass the reviewed architecture, ownership, mode, public-link, string, privacy, and hash gates.

## Transaction outline

A future installer must:

1. open each parent and target with no-follow rules from one fixed install root;
2. reject links, non-regular inputs, unexpected owner, mode, architecture, or hash;
3. copy to a same-directory temporary regular file with fixed owner and mode;
4. flush file content and its directory;
5. verify the installed candidate again by descriptor;
6. replace the target atomically only after all checks pass;
7. keep one exact prior hash as a rollback candidate;
8. flush the target directory after replacement;
9. recover interrupted temporary or prior files by exact hash, never by newest-file selection; and
10. report only fixed status enums and hashes, not sampled power values.

There is no install implementation here because this delivery is source-only and must not mutate the host.

## Popup lifecycle

1. The host creates one `PowerDetailAgent` and observation driver in its graphical session.
2. Opening the popup calls `beginPopup()`. The returned generation is required for all reads.
3. The first document performs one independent full read. A second request in the same unchanged generation can use the single cached document.
4. Source, Low Power, load advisory, wake, screen, session, or heartbeat callbacks ignore payloads, invalidate the cache, and coalesce one new full sample. If public source-notification creation fails, the driver reports `observation_unavailable` and keeps the independent observers and 60-second polling backstop active.
5. Wake causes the same complete refresh as other invalidations. It also records only `did_wake`.
6. Closing calls `closePopup()`, clears document and JSON caches, rejects the old generation, and stops extra popup work.
7. Stopping the graphical host calls `PublicPowerObservationDriver.stop()` before release.

System and session transitions exist only inside the current popup generation. Events received while closed are ignored, and begin/close reset both transition fields to unknown. There are no timestamps, durable history, or logs.

## Settings lifecycle

`SystemSettingsLaunchCommand.main` has no public initializer or variable target. It resolves only bundle identifier `com.apple.systempreferences` with `NSWorkspace.urlForApplication(withBundleIdentifier:)` and calls `openApplication(at:configuration:completionHandler:)` once. Success means only that the main application opened. It does not prove a pane. The synthetic gate injects a fake opener and never calls AppKit launch.

## Rollback and recovery scope

Reads and Settings launch do not change power state. Rollback is not applicable to reads or opening the main application. Direct power, sleep, display-sleep, lock, charging, schedule, and energy-mode writers do not exist in this source. Keep Awake is outside this component.
