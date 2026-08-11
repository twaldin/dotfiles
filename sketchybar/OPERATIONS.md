# SketchyBar operations

The Home deployment uses SketchyBar 2.24.0 from `/opt/homebrew/bin/sketchybar` and Lua 5.5.x. The configuration is `/Users/twaldin/.config/sketchybar`.

## Layout

The left side contains Spaces, the front window, Wi-Fi, Bluetooth, Display, sound output, microphone input, and battery. The device controls stay left of the notch.

Spaces require the signed Yabai 7.1.25 app at `$HOME/Applications/Yabai.app`. This personal layout requires exactly nine global Spaces numbered 1 through 9 on display 1. If that topology is unavailable, all nine Space cells turn orange, app ligatures clear, and click/scroll actions fail closed.

The right side contains CPU, GPU, RAM, NET, SSD, TMP, and then Calendar at the far-right edge. The six metric items are independent. Each item has its own popup. Calendar is static and display-only. Its provider requests only title and date/time plus a transient UID for stable sorting. It does not request notes, location, or URL, and it does not open Calendar or meeting URLs.

## Popups and controls

Left-click an item to open or close its popup.

- CPU and RAM show a live meter, a 120-sample graph, sections, and public aggregate details. CPU also shows neutral logical-core activity and uptime. The popups do not collect process or application identity.
- GPU shows public Metal capability facts. It does not claim a utilization percentage because the supported public API does not provide one.
- NET shows a 120-sample, fixed logarithmic throughput graph and separate download and upload values.
- SSD shows used, free, and total Data-volume capacity. It does not attribute block-device I/O to the APFS Data volume.
- TMP shows the public macOS thermal state, memory pressure, and Low Power Mode. It does not invent numeric temperatures or fan telemetry.
- Wi-Fi shows supported CoreWLAN association, signal, noise, transmit rate, and security details plus an explicit desired-state radio action. The helper replaces the raw interface with a session-bound opaque handle before Lua or an action argument receives it.
- Bluetooth shows paired devices and public adapter state. Connect and disconnect use public IOBluetooth with stale-state preflight and readback. Adapter power remains read-only.
- Sound output and microphone show verified CoreAudio state. Their sliders, mute controls, and eligible device actions bind the exact displayed device and render only confirmed readback state.
- Battery uses public IOPowerSources facts. It shows percentage, source, charge state, remaining time, categorical condition, cycle count, and Low Power Mode. It does not expose history, identity, temperature, electrical measurements, watts, or a fabricated health percentage.
- Display uses exact-version, stable-target, double-confirmed BetterDisplay reads. Display mutations remain disabled until a resident preview-and-rollback guard is approved.

Stat, connectivity, sound, microphone, battery, Display, and front-window popups contain explicit app or fixed main-System-Settings handoffs. The label names the section to select manually; no private pane URL is used. Right-click remains a shortcut. A Wi-Fi power change or Bluetooth device action can interrupt connectivity. Bluetooth adapter power stays in System Settings. Calendar remains display-only and does not open Calendar or meeting URLs.

## Metrics and native helpers

`install-deps.sh` builds and installs:

- `$HOME/.local/share/sketchybar-provider/sketchybar-public-stats` for CPU, RAM, network, Data-volume capacity, GPU capability, and public system-condition events.
- `$HOME/.local/share/sketchybar-controls/system-controls` for public IOBluetooth reads/device actions and verified CoreAudio reads/writes.

The Battery Swift helper is checksum-bound and compiled into a private per-user cache on first use. BetterDisplay remains an external, signed, exact-version read dependency.

`native/` is a source-only, non-built, non-installed fan-in of three frozen first-party prototypes. It is inert at runtime. `native/APPROVED-ARTIFACTS.tsv` is its approval receipt, and the offline smoke gate verifies it with `tests/native-approved-artifacts-test.py`.

Within the current macOS user-session trust boundary, every incoming `system_metrics_v2` event is rejected before UI mutation unless its complete schema, producer identity, monotonic sequence, 15-second freshness, finite numeric ranges, and cross-field relations pass `lib/stats_contract.lua`. A new producer clears all metric histories and retires the old producer identity. Unavailable domains clear their stale histories. This is event-contract validation, not sender authentication: SketchyBar custom events can be triggered by any process already running as the same user, and a same-user-writable nonce file would not change that boundary.

The provider uses documented public frameworks and publishes no GPU utilization or numeric sensor claim. Battery uses public IOPowerSources and IOPM battery-cycle APIs through a closed first-party helper. Wi-Fi uses `networksetup` for explicit bounded power writes and CoreWLAN for richer reads. Bluetooth adapter state, paired-device inventory, and device connection actions all use first-party public IOBluetooth. No Bluetooth third-party controller is required.

Stats.app 3.0.10 was reviewed as visual prior art. It has no documented local metrics API, URL scheme, or service for SketchyBar. SketchyBar aliases are pixel captures, do not forward clicks, and cannot anchor the real Stats popup. On macOS 26, Stats items are also absent from SketchyBar's supported menu-bar capture layer. This configuration therefore keeps first-party SketchyBar items and uses explicit Activity Monitor, Disk Utility, Storage Settings, or Stats app launches. It does not scrape Stats state, automate its UI, or call its private helper.

## Install and reload

Stop the existing `homebrew.mxcl.sketchybar` job before installing this plist. Never load a second label.

```sh
sketchybar/install-deps.sh
/opt/homebrew/bin/sketchybar --reload
```

To start the job:

```sh
/bin/launchctl bootstrap gui/$(/usr/bin/id -u) ~/Library/LaunchAgents/homebrew.mxcl.sketchybar.plist
```

To stop the job:

```sh
/bin/launchctl bootout gui/$(/usr/bin/id -u)/homebrew.mxcl.sketchybar
```

The launchd stdout/stderr files are in `~/Library/Logs/sketchybar`, which `install-deps.sh` creates as an owner-only mode-0700 directory; the plist umask creates log files as mode 0600. Lua/provider logs and helper session maps are separate mode-0600 files in validated mode-0700 per-user directories below macOS `TMPDIR`.

A nonempty absolute macOS `TMPDIR` with a canonical, owner-owned mode-0700 directory is a hard requirement for the `sketchybarrc`, `provider-launch.sh`, `install-deps.sh`, and `smoke-config.sh` shell entrypoints. For these entrypoints, exit 64 means that `TMPDIR` is missing or is not absolute. Exit 73 means that its directory cannot be resolved or fails the ownership or mode check. Before runtime logs exist, a launch wrapper writes only this generic error to the private launchd stderr file above; it never prints the path. The audio, battery, and connectivity Python helpers instead fail closed with exit 1 and no diagnostic for an unsafe temporary-directory boundary.

## Verification

Run the complete offline configuration gate:

```sh
sketchybar/scripts/smoke-config.sh
```

Then reload the bar and physically test each popup, enabled slider, toggle, device choice, Space action, and front-window action. Click a real macOS Notification Center notification and confirm that its overlay stays outside the Yabai BSP tree. Display meters are read-only. Visual and click acceptance is attended. Do not use synthetic input for final acceptance.

Complete Wi-Fi scan/join sheets, Bluetooth discovery/pairing sheets, keyboard navigation, VoiceOver, and popup scrolling require a signed native AppKit owner. This host currently has no valid code-signing identity, so the release uses explicit fixed-app System Settings handoffs instead of an unsigned or synthetic substitute.
