# SketchyBar operations

The Home deployment uses SketchyBar 2.24.0 from `/opt/homebrew/bin/sketchybar` and Lua 5.5.x. The configuration is `/Users/twaldin/.config/sketchybar`.

## Layout

The left side contains Spaces, the front window, Wi-Fi, Bluetooth, Display, sound output, microphone input, and battery. The device controls stay left of the notch.

Spaces require the signed Yabai 7.1.25 app at `$HOME/Applications/Yabai.app`. This personal layout requires exactly nine global Spaces. They must have indices 1 through 9, and all must be on display 1. If the Yabai query or topology fails, all nine Space cells turn orange. App ligatures clear, and the cells have no focus or hover affordance. Scrolling fails closed. Each click on an orange cell opens or rebuilds one bounded diagnostic popup anchored to Space 1. The popup reports the query or topology failure. It repeats the exact app version, path, Space count, indices, and display requirement. It has one real action that opens the official Yabai setup guide. It does not show a focus control.

The right side contains CPU, GPU, RAM, NET, SSD, TMP, and then Calendar at the far-right edge. The six metric items are independent. Each item has its own popup. TMP always shows the highest recognized CPU and GPU temperatures in fixed order, for example `C73 G61`; a truly absent source uses its own em dash, so complete absence is `C— G—`. A failed refresh can keep the last accepted pair for at most 20 seconds. The fixed 72-point TMP host uses a compact value face for three-digit readings, fits the full accepted `C130 G130` range, and takes exactly 24 points from the Calendar event surface. The right cluster stays at `5 × (48 + 4) + (72 + 4) + 164 + 148 = 648` points. SketchyBar 2.24.0 has no separate item accessibility-label property, so the visible compact label keeps explicit `C` and `G` semantics. Calendar is static and display-only. Its provider requests only title and date/time plus a transient UID for stable sorting. It does not request notes, location, or URL, and it does not open Calendar or meeting URLs.

## Popups and controls

Left-click an item to open or close its popup.

- CPU and RAM show 120-sample graphs, sections, and aggregate details. CPU also shows neutral logical-core activity, uptime, highest recognized CPU temperature, cluster-weighted frequency, and CPU power. The popups do not collect process or application identity.
- GPU shows measured device, renderer, and tiler utilization, a 120-sample graph, highest recognized GPU temperature, GPU power, and public Metal capability facts.
- NET shows a 120-sample, fixed logarithmic throughput graph, separate current download and upload rates, and provider-session download and upload totals. The session totals are measured lower bounds. They start with each provider instance, stay monotonic for that instance, and do not infer traffic during read gaps, sleep, route changes, or counter resets.
- SSD shows used, free, and total Data-volume capacity. It also shows a 120-sample read-plus-write history and separate read, write, and combined rates for the Data backing device. These are backing-target rates, not APFS per-volume accounting. If the target is shared, the values include I/O from the System volume or other APFS volumes. Invalid gaps are not inferred.
- TMP shows public thermal and memory-pressure states, the active source-scoped power mode, recognized CPU/GPU temperatures, CPU/GPU/ANE/memory power, and bounded fan RPM/mode/target/range telemetry. Fan and power writes remain visibly inert until the privileged owner is approved and installed.
- Wi-Fi shows supported CoreWLAN association, service/mode, independent signal and noise values, transmit rate, security, PHY, MCS, channel, band, and channel width plus an explicit desired-state radio action. An associated network stays visibly associated when macOS redacts its name. A populated name is accepted only from CoreWLAN or the fixed current-network node in Apple `system_profiler`; neighboring network names are never parsed. The helper replaces the raw interface with a session-bound opaque handle before Lua or an action argument receives it.
- Bluetooth distinguishes unavailable inventory from proved zero and reports bounded, proved truncation. Every retained device shows explicit paired and connected state. Public IOBluetooth supplies exact RSSI, device class, cached service-profile facts, and actions; fixed Apple `system_profiler`, `ioreg`, and `pmset` fields add address-correlated battery components when present. A missing battery, RSSI, type, or profile is omitted instead of labeled unknown. Connect and disconnect use stale-state preflight and readback. Adapter power remains read-only.
- Sound output and microphone show verified CoreAudio state. A nonzero `warning_count` means only that one or more non-fatal audio facts could not be read or published; both popups use that exact broad statement and do not claim a device was omitted. Their sliders, mute controls, and eligible device actions bind the exact displayed device and render only confirmed readback state. The bar requests a selected-microphone refresh every two seconds. This fixed cadence is a deliberate privacy-indicator exception to the power-aware hardware-metrics cadence: a slower idle cadence could delay the first indication after capture starts. A 40-read measurement after the input-first/global-fallback implementation on this host used about 90 ms of wall time and 58 ms of aggregate CPU time per request, which is about 2.9% of one CPU core at the two-second cadence. A busy read or write coalesces one immediate follow-up refresh instead of dropping the freshness request. If work is still busy at the next two-second tick, the prior active or idle mark and text are hidden immediately while the last confirmed device, mute, volume, and default facts remain. The native state read has a two-second deadline. A normal transition is visible after the next request; a stalled transaction cannot leave a visible active or idle claim past the next tick plus small launch and scheduling overhead. Before an active-use query, the native owner proves that the selected device has input streams and has no output streams. It queries the public `kAudioDevicePropertyDeviceIsRunningSomewhere` UInt32 Boolean at input scope first. Only when `AudioObjectHasProperty` is false at input scope does it query the global device scope for driver compatibility. A present input-scoped property always takes precedence. This precedence trusts the selected driver’s input-scoped value without a second-scope corroboration. A malformed value, wrong size, or read error at the chosen scope omits use state and never causes another-scope read. Output-only and duplex devices never reach either query. Confirmed active use adds a solid dot and the semantic recording color; confirmed idle adds an open circle. An absent use value has neither mark, so it is not shown as proof of idle. A confirmed device whose mute and use values are both absent has a separate unclaimed slate rendering; it does not look the same as a missing device. The popup heading and state row give visible active or idle text. The hidden bar label keeps the same semantic text only as a `sketchybar --query` diagnostic. A failed refresh immediately clears the active-use claim while it retains the last confirmed device facts. This device/microphone active state has no process attribution or history. If neither scope has the property, or the chosen read errors or is malformed, the active-use row and text are absent; the UI makes no unknown or unavailable use claim.
- Battery keeps public IOPowerSources as the basic-state owner. It renders charge and time only when the public facts form a consistent state. It never renders a qualitative Health row. One Cycles row uses the exact public or popup-only hardware count. It stays absent while either read is pending, uses the available exact count if the other read fails, and makes no claim when proved counts conflict. Hardware detail uses explicit Raw current capacity, Raw maximum capacity, Raw design capacity, Nominal capacity, and Raw maximum / design labels, plus signed current, voltage, and temperature. A successful read with no renderable facts says that no battery hardware readings were reported. Adapter watts/current appear only when the attached-adapter dictionary proves each value; detached numeric rows are absent. With the popup open, a wake or power-source event retires in-flight public and hardware reads and hides their prior popup facts until fresh reads complete. In both the open and closed cases, the bar keeps its last accepted percentage until the replacement public read completes or its 70-second deadline expires; an expired read changes the bar to an em dash. Every public and hardware read has the same 70-second deadline. Public state refreshes about every 30 seconds. Popup-only hardware state refreshes every fourth routine tick, about every 120 seconds, only while that popup generation stays open. These recurring pending windows briefly remove the Cycles row and, during a hardware read, the Hardware readings section. A failed or expired public transport retries at the next approximately 30-second tick. A failed or expired hardware transport retries at the next approximately 120-second popup-open tick. Failure copy says that automatic retry continues and that reopening retries now; the fixed main-System-Settings Battery handoff remains. The popup exposes no identity, history, or operation-looking hardware control and does not claim Apple Maximum Capacity or infer health from a raw ratio.
- Display requires exactly one launchd-parented BetterDisplay app instance, then uses exact-version, exact-artifact, stable-target, double-confirmed reads. Extra CLI clients do not count as app instances. If the app-instance or another read gate fails, the current state is unavailable. An opaque target handle remains stable across reads while its UUID and tag marker are unchanged; a target change, missing map, or safe corrupt map rotates the handle and revokes the prior value. Fixed numeric refresh rates remain numeric. The closed variable-refresh set is `ProMotion`, `Variable`, `Adaptive`, or an ascending `min-maxHz` range from 1 through 1000 Hz. An unrecognized active refresh value fails the state read closed. An invalid or missing current mode omits the complete optional mode list; invalid non-current modes are omitted. A readable brightness value is required for Display state. Brightness actions and any reported hardware-contrast, display-volume, or explicit mute on/off actions use a fresh expected-state check, one bounded write, independent readback, and one verified best-effort restore. The target is the display under the pointer when each read starts. Because the bar is on all displays, the always-visible item uses a neutral `Display confirmed` label instead of repeating one display’s values on every bar. Opening the popup first shows a neutral header and a fixed pointer-target confirmation state with no controls. It reserves the normal popup area and keeps the BetterDisplay and System Settings handoffs visible. Controls appear only after that fresh exact-target read completes. A 15-second UI deadline changes a stalled confirmation to unavailable and rejects its late result. Brightness stays visible after confirmation; unsupported contrast and display-audio rows and actions are omitted. An unproved role uses an em dash. Raw display identifiers remain in an owner-only runtime map and native stdin. Rotation, HDR, mirror, power, disconnect, and connection controls are absent because Pro is unavailable or rollback is not reliable.

Stat, connectivity, sound, microphone, battery, Display, and front-window popups contain explicit app or fixed main-System-Settings handoffs. The label names the section to select manually; no private pane URL is used. Right-click remains a shortcut. A Wi-Fi power change or Bluetooth device action can interrupt connectivity. Bluetooth adapter power stays in System Settings. Calendar remains display-only and does not open Calendar or meeting URLs.

## Metrics and native helpers

`install-deps.sh` builds and installs:

- `$HOME/.local/share/sketchybar-provider/sketchybar-public-stats` for CPU, RAM, the strict current memory-pressure state, primary-IPv4-route network rates and provider-session totals, Data-volume capacity, Data backing-device I/O rates, GPU capability, and public system-condition events.
- `$HOME/.local/share/sketchybar-controls/system-controls` for public IOBluetooth reads/device actions and verified CoreAudio reads/writes.
- `$HOME/.local/share/sketchybar-hardware/hardware-metrics` for identifier-free IOAccelerator and IOReport utilization, power, and frequency reads.
- `$HOME/.local/share/sketchybar-display/betterdisplay-control` for a narrow BetterDisplay DNC display transaction with correlated response, readback, and restore.

The hardware and BetterDisplay control sources are exact-hash checked before the complete smoke gate, copied into private hash-checked snapshots, and compiled only from those snapshots after the gate passes. Each binary and its exact semantic source marker publish as one locked transaction; any marker, identity, hash, self-test, live-state, or post-publication failure restores the complete prior pair. The hardware helper is installed in an owner-only directory, self-tested with exact silent output, and validated through a closed JSON contract. The connectivity Swift source is hash-bound, compiled into an owner-only per-user app bundle on first use, ad-hoc signed with its fixed bundle identifier, and strict-signature checked before every use. Its Info.plist contains only the exact location usage text needed for macOS network-name authorization. Both Battery Swift helpers are source-hash-bound and compiled into private per-user caches on first use. The hardware-detail helper reads a strict allowlist from the private AppleSmartBattery registry contract and sanitizes every result before Lua receives it. The BetterDisplay helper has the same source/binary publication boundary and validates the exact installed signed vendor artifact before every transaction. DNC is an unauthenticated local broadcast bus, so correlation does not protect against a malicious process in the same login context; its output is advisory under that threat.

`native/` is a source-only, non-built, non-installed fan-in of three frozen first-party prototypes. It is inert at runtime. `native/APPROVED-ARTIFACTS.tsv` is its approval receipt, and the offline smoke gate verifies it with `tests/native-approved-artifacts-test.py`.

Within the current macOS user-session trust boundary, every incoming `system_metrics_v3` event is rejected before UI mutation unless its complete v3-only schema, producer identity, monotonic sequence, 15-second freshness, finite Lua-exact numeric ranges, independent rate/total validity, and cross-field relations pass `lib/stats_contract.lua`. The consumer does not accept a `system_metrics_v2` event. This v3-only rule applies to the metrics domain; the independent `system_cpu_detail_v1` and `system_battery_v2` auxiliary contracts stay unchanged. A lower valid network session total from the same provider instance is rejected. A new producer clears that monotonic floor, all metric histories, and the old producer identity. An invalid network-rate or SSD-I/O sample clears its rate history. This is event-contract validation, not sender authentication: SketchyBar custom events can be triggered by any process already running as the same user, and a same-user-writable nonce file would not change that boundary.

The public provider remains unprivileged, read-only, and limited to public frameworks. It uses the Stats-default primary IPv4 route with 64-bit route counters and the exact bounded Stats digit-count parent rule for the Data backing target. It publishes no interface name or index, BSD name, volume or media identity, registry name or ID, raw lifetime counter, or process identity. The named pressure sysctl and the `Statistics`, `Bytes (Read)`, and `Bytes (Write)` registry strings are unsupported compatibility contracts. If one changes, only that domain becomes unavailable; the provider does not scan more registry data, call a command, use a private fallback, or guess. No root, helper, entitlement, Full Disk Access, Accessibility, Screen Recording, Location, packet capture, raw disk access, or network-capture permission is used. A separate read-only helper uses private, unsupported IOAccelerator and IOReport schemas and fails closed when its closed capability contract changes. Hardware samples run every 2 seconds only while a CPU/GPU/TMP popup is visible, every 5 seconds on normal AC idle state, and every 15 seconds on battery or Low Power Mode. One transport failure can retain a visibly delayed sample for at most 20 seconds; a valid explicit-unavailable result clears the affected values immediately. No sample history is written to disk.

Battery uses public IOPowerSources and IOPM battery-cycle APIs through a closed first-party helper. Wi-Fi uses `networksetup` for explicit bounded power writes, CoreWLAN for richer reads, and only the fixed current-network `system_profiler` node as a name/PHY/channel fallback. If the associated name stays redacted, “Allow network name · Location” foregrounds the signed helper and calls Core Location’s documented When In Use request. The callback reads the complete Wi-Fi state again. A prior denial, restriction, or disabled Location Services instead opens the main System Settings app and returns the still-current permission state; it never claims a grant. No private Settings URL is used. Bluetooth power, pairing, exact RSSI, cached profiles, inventory, and connection actions use first-party public IOBluetooth. Fixed read-only Apple profiler, HID registry, and accessory-power outputs are address-correlated inside the Python helper. Raw addresses and identifiers never reach Lua, public JSON, action argv, logs, or persistent state; the first-party native read contract returns addresses only to Python for private correlation, and a connect or disconnect sends the selected address only through the bounded native stdin contract. No Control Center cache, Bluetooth preference cache, CoreBluetooth UUID, third-party controller, scan, or persistent history is used.

Stats.app 3.0.10 has no robust general local integration bus. Its preferences, widget app-group data, LevelDB cache, cloud credentials, and privileged XPC helper are not used. The exact signed Stats 3.0.10 build 832 bundled `smc` executable is used only with fixed read commands for temperature and fan telemetry after bundle, team, version, and executable-hash validation. Its write commands and privileged helper are never called. SketchyBar aliases remain pixel captures and do not forward clicks.

## Install and reload

Run the first-party dependency and deployment transaction:

```sh
sketchybar/install-deps.sh
```

`install-deps.sh` completes the full offline smoke gate before it calls `scripts/sketchybar-launch-agent.py`. The installer accepts no path, fixture, or environment override. It validates the reviewed closed plist contract, the source and destination files, the per-user `LaunchAgents` directory, and private launch logs. It then replaces only `~/Library/LaunchAgents/homebrew.mxcl.sketchybar.plist`, boots out the prior loaded job when present, bootstraps the reviewed plist, and reads back the exact live program, configuration argument, and private log paths. Output is a closed identifier-free verdict. Every `launchctl` call has a timeout and its raw output stays private.

The transaction takes a fresh destination and loaded-state preflight before mutation. For a loaded prior job, the on-disk plist must match one of two closed formula-derived schemas: the reviewed configured service or the original unconfigured Homebrew service. Its observable program, arguments, and log paths must also match the live job before bootout, so the rollback source is recoverable. A transaction failure atomically restores the exact prior plist bytes, mode, presence, and loaded or unloaded state, then reads back the restored observable program, arguments, log paths, and a stable running process state. A first install failure restores an absent destination and an unloaded job. The success readback also requires the exact plist path, a stable running process, and an accepted last-exit state; the process identifier is validated privately and is never printed.

A separate fixed `rollback incomplete` verdict and exit 2 means an operating-system failure prevented that restoration. Stop and inspect the owner, type, link count, and mode of the per-user plist and log paths before another attempt. For this personal deployment, recovery is to boot out the label if it is still loaded, remove only the validated real single-link per-user plist, and rerun `install-deps.sh`. A normal fixed `installation failed` verdict and exit 1 made no unreported partial success. Do not use `brew services restart sketchybar`: the formula-generated service has no `--config` argument and can load a hidden default 25-point bar with no items.

The reviewed plist is based on the Homebrew formula service and uses `/opt/homebrew/opt/sketchybar/bin/sketchybar` with the exact `--config /Users/twaldin/.config/sketchybar/sketchybarrc` arguments. It retains the formula session types, interactive process type, keep-alive behavior, `LANG`, and bounded service `PATH`. It omits `Umask` and `ThrottleInterval` because either key makes `launchctl bootstrap` fail with EIO on the supported macOS 26.2 host.

The launchd stdout/stderr directory is `~/Library/Logs/sketchybar`. The installer creates or validates it as an owner-only mode-0700 real directory and precreates both single-link regular log files as mode 0600. Lua/provider logs and helper session maps are separate mode-0600 files in validated mode-0700 per-user directories below macOS `TMPDIR`.

Before the deployment transaction commits, the installer performs a bounded content-free bar query. It requires drawing on, height 36, and the exact reviewed 29-item list, including the six CPU, GPU, RAM, NET, SSD, and TMP stat hosts. A mismatch restores the prior plist and loaded state. `install-deps.sh` repeats the same check as a postcondition. Neither check prints the query response.

The privileged fan/power owner is a separate reviewed payload. `install-deps.sh` does not install it. The offline smoke gate builds and tests it only in a private `TMPDIR` scratch directory. It does not load a daemon or write fan or power state. Run its isolated gate with:

```sh
sketchybar/privileged/fan-power-owner/scripts/verify.sh
```

After explicit approval, the exact attended install command is:

```sh
/usr/bin/sudo -- /bin/sh -ceu '
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
umask 077
source=/Users/twaldin/dotfiles/sketchybar/privileged/fan-power-owner/install.sh
expected=bc386b90e07830791a9f155be6a33bf3e65cfd4b09d09f63f61c4482d0ac0205
[ -f "$source" ] && [ ! -L "$source" ]
[ "$(/usr/bin/stat -f "%Su %HT %Lp %l" "$source")" = "twaldin Regular File 755 1" ]
[ "$(/usr/bin/shasum -a 256 "$source" | /usr/bin/cut -d" " -f1)" = "$expected" ]
work=$(/usr/bin/mktemp -d /private/var/tmp/fan-power-owner-bootstrap.XXXXXX)
trap "/bin/rm -rf $work" EXIT HUP INT TERM
[ "$(/usr/bin/stat -f "%u %g %HT %Lp" "$work")" = "0 0 Directory 700" ]
bootstrap_code=aW1wb3J0IG9zLHN0YXQsc3lzCnMsZCxuPXN5cy5hcmd2WzFdLHN5cy5hcmd2WzJdLGludChzeXMuYXJndlszXSkKYz1beCBmb3IgeCBpbiBzLnNwbGl0KG9zLnNlcCkgaWYgeF0KZj1vcy5vcGVuKG9zLnNlcCxvcy5PX1JET05MWXxvcy5PX0RJUkVDVE9SWXxvcy5PX0NMT0VYRUMpCnRyeToKIGZvciB4IGluIGNbOi0xXToKICBxPW9zLm9wZW4oeCxvcy5PX1JET05MWXxvcy5PX0RJUkVDVE9SWXxvcy5PX05PRk9MTE9XfG9zLk9fQ0xPRVhFQyxkaXJfZmQ9Zik7b3MuY2xvc2UoZik7Zj1xCiBpPW9zLm9wZW4oY1stMV0sb3MuT19SRE9OTFl8b3MuT19OT0ZPTExPV3xvcy5PX0NMT0VYRUN8b3MuT19OT05CTE9DSyxkaXJfZmQ9ZikKZmluYWxseTogb3MuY2xvc2UoZikKdD1vcy5mc3RhdChpKQppZiBub3Qgc3RhdC5TX0lTUkVHKHQuc3RfbW9kZSkgb3IgdC5zdF9ubGluayE9MSBvciB0LnN0X3NpemUhPW4gb3IgdC5zdF9tb2RlJjBvMDIyOiBvcy5jbG9zZShpKTtyYWlzZSBTeXN0ZW1FeGl0KDEpCm89b3Mub3BlbihkLG9zLk9fV1JPTkxZfG9zLk9fQ1JFQVR8b3MuT19FWENMfG9zLk9fTk9GT0xMT1d8b3MuT19DTE9FWEVDLDBvNTAwKQp0cnk6CiB3aGlsZSBuOgogIGI9b3MucmVhZChpLG1pbihuLDY1NTM2KSkKICBpZiBub3QgYjogcmFpc2UgU3lzdGVtRXhpdCgxKQogIG4tPWxlbihiKQogIHdoaWxlIGI6CiAgIHo9b3Mud3JpdGUobyxiKQogICBpZiB6PDE6IHJhaXNlIFN5c3RlbUV4aXQoMSkKICAgYj1iW3o6XQogaWYgb3MucmVhZChpLDEpOiByYWlzZSBTeXN0ZW1FeGl0KDEpCmZpbmFsbHk6IG9zLmNsb3NlKGkpO29zLmNsb3NlKG8pCg==
/usr/bin/python3 -I -S -c "$(/usr/bin/printf %s "$bootstrap_code" | /usr/bin/base64 -D)" \
  "$source" "$work/install.sh" 24307
[ "$(/usr/bin/shasum -a 256 "$work/install.sh" | /usr/bin/cut -d" " -f1)" = "$expected" ]
exec "$work/install.sh" "$@"
' fan-power-owner-bootstrap install --target-user twaldin --manifest-sha256 08d951629b2d5c75c543bc9c559c827470cf772e3e14516a6b837aeefd6f3bfd
```

The fixed attended root-shell argument hash-binds and executes a root-owned installer copy before the lifecycle lock, root-owned source snapshot, embedded client CDHash, installed signatures and immutable flags, authenticated status, and rollback proof must all pass. A normal exit 1 proved restoration. Exit 2 means rollback or lifecycle-lock cleanup is incomplete. Stop and use `privileged/fan-power-owner/README.md`; do not retry. No agent ran the attended command.

The exact attended safe-uninstall command is:

```sh
/usr/bin/sudo -- /bin/sh -ceu '
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
umask 077
source=/Users/twaldin/dotfiles/sketchybar/privileged/fan-power-owner/install.sh
expected=bc386b90e07830791a9f155be6a33bf3e65cfd4b09d09f63f61c4482d0ac0205
[ -f "$source" ] && [ ! -L "$source" ]
[ "$(/usr/bin/stat -f "%Su %HT %Lp %l" "$source")" = "twaldin Regular File 755 1" ]
[ "$(/usr/bin/shasum -a 256 "$source" | /usr/bin/cut -d" " -f1)" = "$expected" ]
work=$(/usr/bin/mktemp -d /private/var/tmp/fan-power-owner-bootstrap.XXXXXX)
trap "/bin/rm -rf $work" EXIT HUP INT TERM
[ "$(/usr/bin/stat -f "%u %g %HT %Lp" "$work")" = "0 0 Directory 700" ]
bootstrap_code=aW1wb3J0IG9zLHN0YXQsc3lzCnMsZCxuPXN5cy5hcmd2WzFdLHN5cy5hcmd2WzJdLGludChzeXMuYXJndlszXSkKYz1beCBmb3IgeCBpbiBzLnNwbGl0KG9zLnNlcCkgaWYgeF0KZj1vcy5vcGVuKG9zLnNlcCxvcy5PX1JET05MWXxvcy5PX0RJUkVDVE9SWXxvcy5PX0NMT0VYRUMpCnRyeToKIGZvciB4IGluIGNbOi0xXToKICBxPW9zLm9wZW4oeCxvcy5PX1JET05MWXxvcy5PX0RJUkVDVE9SWXxvcy5PX05PRk9MTE9XfG9zLk9fQ0xPRVhFQyxkaXJfZmQ9Zik7b3MuY2xvc2UoZik7Zj1xCiBpPW9zLm9wZW4oY1stMV0sb3MuT19SRE9OTFl8b3MuT19OT0ZPTExPV3xvcy5PX0NMT0VYRUN8b3MuT19OT05CTE9DSyxkaXJfZmQ9ZikKZmluYWxseTogb3MuY2xvc2UoZikKdD1vcy5mc3RhdChpKQppZiBub3Qgc3RhdC5TX0lTUkVHKHQuc3RfbW9kZSkgb3IgdC5zdF9ubGluayE9MSBvciB0LnN0X3NpemUhPW4gb3IgdC5zdF9tb2RlJjBvMDIyOiBvcy5jbG9zZShpKTtyYWlzZSBTeXN0ZW1FeGl0KDEpCm89b3Mub3BlbihkLG9zLk9fV1JPTkxZfG9zLk9fQ1JFQVR8b3MuT19FWENMfG9zLk9fTk9GT0xMT1d8b3MuT19DTE9FWEVDLDBvNTAwKQp0cnk6CiB3aGlsZSBuOgogIGI9b3MucmVhZChpLG1pbihuLDY1NTM2KSkKICBpZiBub3QgYjogcmFpc2UgU3lzdGVtRXhpdCgxKQogIG4tPWxlbihiKQogIHdoaWxlIGI6CiAgIHo9b3Mud3JpdGUobyxiKQogICBpZiB6PDE6IHJhaXNlIFN5c3RlbUV4aXQoMSkKICAgYj1iW3o6XQogaWYgb3MucmVhZChpLDEpOiByYWlzZSBTeXN0ZW1FeGl0KDEpCmZpbmFsbHk6IG9zLmNsb3NlKGkpO29zLmNsb3NlKG8pCg==
/usr/bin/python3 -I -S -c "$(/usr/bin/printf %s "$bootstrap_code" | /usr/bin/base64 -D)" \
  "$source" "$work/install.sh" 24307
[ "$(/usr/bin/shasum -a 256 "$work/install.sh" | /usr/bin/cut -d" " -f1)" = "$expected" ]
exec "$work/install.sh" "$@"
' fan-power-owner-bootstrap uninstall --target-user twaldin --manifest-sha256 08d951629b2d5c75c543bc9c559c827470cf772e3e14516a6b837aeefd6f3bfd
```

Uninstall removes nothing until the same installed release proves all fans are Automatic. It then verifies those exact hashes, signatures, immutable flags, socket, and loaded state again under the lifecycle lock before removal.

To run only the reviewed deployment transaction after an already-passed gate:

```sh
sketchybar/scripts/sketchybar-launch-agent.py
```

To stop the job:

```sh
/bin/launchctl bootout gui/$(/usr/bin/id -u)/homebrew.mxcl.sketchybar
```

A nonempty absolute macOS `TMPDIR` with a canonical, owner-owned mode-0700 directory is a hard requirement for the `sketchybarrc`, `provider-launch.sh`, `install-deps.sh`, and `smoke-config.sh` shell entrypoints. For these entrypoints, exit 64 means that `TMPDIR` is missing or is not absolute. Exit 73 means that its directory cannot be resolved or fails the ownership or mode check. Before runtime logs exist, a launch wrapper writes only this generic error to the private launchd stderr file above; it never prints the path. The audio, battery, and connectivity Python helpers instead fail closed with exit 1 and no diagnostic for an unsafe temporary-directory boundary.

## Verification

Run the complete offline configuration gate:

```sh
sketchybar/scripts/smoke-config.sh
```

Then run the anonymous live microphone active-use schema check. It confirms only that the selected input exposes the exact public Boolean schema through the input-first/global-fallback read path. It does not check whether the value changes with capture, and it prints only a fixed verdict with no device or process identity:

```sh
/usr/bin/python3 sketchybar/tests/system-controls-test.py sketchybar/scripts/system-controls.swift --live-active-schema
```

Then reload the bar and physically test each popup, enabled slider, toggle, device choice, Space action, and front-window action. During attended acceptance, start a real microphone capture and confirm that the dot glyph, recording color, semantic state, and popup row change to active. Stop capture and confirm that all four return to idle within the bounded refresh transaction. This is an observation step only; do not use synthetic input. For Display, test brightness and each optional control that is present, confirm its readback, confirm unsupported contrast and audio controls are absent, and confirm mode, refresh-rate, rotation, HDR, mirror, power, and layout actions are absent. Click a real macOS Notification Center notification and confirm that its overlay stays outside the Yabai BSP tree. Visual and click acceptance is attended. Do not use synthetic input for final acceptance.

Complete Wi-Fi scan/join sheets, Bluetooth discovery/pairing sheets, keyboard navigation, VoiceOver, and popup scrolling require a full signed native AppKit owner. This host currently has no Developer ID identity, so the release uses explicit fixed-app System Settings handoffs for those flows. The narrower ad-hoc-signed network-name helper owns only its documented foreground Core Location request and readback; it does not scan, join, track location, or retain the name.
