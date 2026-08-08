# Sealed launcher and lifecycle design

## Main System Settings launcher

The fixed destination is `/System/Applications/System Settings.app` with bundle identity `com.apple.systempreferences`. The boundary requires all of these facts before launch:

1. The literal, standardized, and symlink-resolved file paths are the fixed path.
2. The canonical path and the bundle resolver refer to the same filesystem resource identity.
3. The bundle metadata has the fixed identity.
4. Public Security validation satisfies the Apple anchor and fixed identifier requirement.

A semantic key changes only fixed local label and manual instruction text. The native primary call receives only the fixed canonical file URL. Only an unambiguous primary failure permits one fallback. The fallback executable and its only argument are fixed. No resolver result, bundle identifier, pane URL, event value, or configuration value becomes a launch destination. An ambiguous result does not retry. A late result cannot change a new view.

There is no Control Center resolver or launcher. Its programmatic rows stay disabled. The separate Settings action launches only the main Settings app and gives manual instructions.

## Native private window owner

One signed panel process owns native window records, complete private content, native identities, snapshot generations, UI slots, and operation tokens. The bar can request only a fixed panel-open action. Slot selection stays inside that process. The injected vendor boundary receives private typed commands in memory. Production integration must not translate a native identity into public argv, Lua, public query output, logs, or evidence. If a reviewed vendor transport cannot preserve that rule, target-by-identity actions remain disabled.

Wake, display change, manager cutover, reload, and panel replacement rotate the view generation and discard all slots. They do not release the domain mutation lock. A command callback must reach a terminal state and complete fresh readback before the lock is released. A late result may update only private recovery state and cannot update a new view.

## Resident display preview owner

A dedicated process captures the complete session snapshot twice. It applies one `forAppOnly` transaction and holds an app-local 15-second Keep/Revert lease. Its owner channel is inherited, fixed, and content-free. Escape, Revert, timeout, reconfiguration, topology loss, wake, reload, owner EOF, or helper failure ends the lease. Unexpected owner death or a crash automatically removes the app-only CoreGraphics configuration.

Keep repeats the full preflight, writes one identical session transaction, obtains two equal readbacks, ends the app-only lease, and obtains two more equal session readbacks. It never writes permanently. Revert ends the lease and accepts exact rollback only after two equal snapshots match the saved session. A mismatch is partial/manual-recovery truth. The process exits after terminal lease handling. A fresh owner does any post-exit readback needed after a crash.

Post-Keep Undo retains the saved and kept snapshots only inside the resident native owner. Any wake, reconfiguration callback, online-set change, native handle churn, display-services epoch change, remote/sharing transition, mode/origin/main/mirror mismatch, reload, or owner change destroys Undo. Undo performs no partial restore and never calls broad permanent restore.

The WM gate is externally blocked from preview preflight until final Keep/Revert readback. It stays blocked if a callback is pending. After termination, the exact native 1-through-9 Space invariant must be read again before a window action is enabled.

## Permanently unsupported writers

System Sleep, Display Sleep, and Lock Screen have no writer object, command metadata, confirmation path, deferred flag, or executable. Focus and built-in Control Center actions have no live boundary. Unsupported display and appearance rows have no action. Human approval cannot enable the two sleep actions.
