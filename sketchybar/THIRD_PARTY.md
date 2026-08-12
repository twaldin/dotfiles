# Third-party software and references

No third-party executable or implementation source is vendored here.
The three source subtrees under `native/` are frozen first-party prototypes. Their internal directory names record an immutable fan-in boundary, not third-party ownership. They are not built or installed.
`lib/unicode_grapheme_ranges.lua` contains generated range data derived from the
Unicode Character Database under the Unicode Data Files and Software License.
`install-deps.sh` builds the first-party public stats, CoreAudio, read-only hardware, and narrow BetterDisplay transaction helpers, then installs dependencies and one Lua binary module into their normal user or Homebrew locations. The Lua implementation is independently written. The hardware helper uses unsupported Apple IOAccelerator and IOReport schemas; no Stats implementation source is copied into it.

## Pinned or required dependencies

| Dependency | Pin used here | License | Purpose / source |
| --- | --- | --- | --- |
| SbarLua | commit `dba9cc421b868c918d5c23c408544a28aadf2f2f` | GPL-3.0 | Installed binary module: <https://github.com/FelixKratz/SbarLua> |
| Lua | live Homebrew formula input; must remain 5.5.x and pass the post-install smoke gate | MIT | Runtime and SbarLua ABI: <https://www.lua.org/license.html> |
| icalBuddy | live Homebrew formula input; post-install smoke required | MIT | Calendar command API: <https://hasseg.org/icalBuddy/> |
| BetterDisplay | installed signed app version 4.2.3 build 48120; executable SHA-256 `b7507a7d367af7ca3119e8bf0d10342a6e5b2cea497f43c9f14d32bd560894c4`; exact signature/version/hash gate | Vendor license | Display reads and reviewed local DNC control protocol: <https://github.com/waydabber/BetterDisplay/wiki/Integration-features,-CLI> |
| Stats | installed signed app version 3.0.10 build 832; team `RP2S87B72W`; bundled `smc` SHA-256 `5a924e98212ff85635a2db5778d417a182fcaca338bc1fe41dcf61571f5e8a0d` | MIT | Fixed read-only temperature and fan commands from the external bundled CLI; exact source tag <https://github.com/exelban/stats/tree/64a34fa34c29d71de19af0868475e23cef7aaf81> |
| Yabai | installed signed app version 7.1.25 at `$HOME/Applications/Yabai.app`; exact-version smoke gate | MIT | Native Space/window queries and focus actions: <https://github.com/koekeishiya/yabai> |
| JetBrains Mono Nerd Font | existing user font | SIL OFL 1.1 plus Nerd Fonts notices | Monochrome glyphs: <https://www.nerdfonts.com/> |
| sketchybar-app-font | release `v2.0.71`; Lua SHA-256 `adbdd97d5137846babb2584de701f341541402bb2e1478d1ae031e07cc5e060c`; TTF SHA-256 `e015c40fbe95d85763b633eae54f7b8e1ded83cffbc15aff40b8b8f89717a0b1` | CC0-1.0 | App ligatures and lookup map installed outside the repository: <https://github.com/kvndrsslr/sketchybar-app-font/releases/tag/v2.0.71> |
| Unicode Character Database | 17.0.0; GraphemeBreakProperty SHA-256 `d6b51d1d2ae5c33b451b7ed994b48f1f4dc62b2272a5831e7fd418514a6bae89`; emoji-data SHA-256 `2cb2bb9455cda83e8481541ecf5b6dfda66a3bb89efa3fa7c5297eccf607b72b`; DerivedCoreProperties SHA-256 `24c7fed1195c482faaefd5c1e7eb821c5ee1fb6de07ecdbaa64b56a99da22c08`; license SHA-256 `e7a93b009565cfce55919a381437ac4db883e9da2126fa28b91d12732bc53d96` | Unicode-DFS-2016 | Vendored source data and generated grapheme ranges: <https://www.unicode.org/Public/17.0.0/ucd/auxiliary/GraphemeBreakProperty.txt>, <https://www.unicode.org/Public/17.0.0/ucd/emoji/emoji-data.txt>, <https://www.unicode.org/Public/17.0.0/ucd/DerivedCoreProperties.txt>, and <https://www.unicode.org/license.txt> |



This release supports Apple-silicon Tahoe hosts only and requires Homebrew at
`/opt/homebrew`. The system-controls release candidate targets exactly
`arm64-apple-macosx15.0`; its thin architecture is verified before candidate self-tests and publication.

SbarLua, the generated Unicode 17.0.0 ranges, and the checksum-pinned font
assets are reproducibly frozen. Lua and icalBuddy intentionally resolve from live Homebrew formulae. BetterDisplay and Yabai are existing external applications and are not installed by this repository. Their exact signed versions are checked by the release gates.
A Homebrew update invalidates the prior runtime proof. `install-deps.sh` resolves and publishes the live inputs, then requires the complete offline smoke gate to pass before it reports success. Lua and luac must remain in the supported 5.5.x line.

## Public API and prior-art references

- SketchyBar configuration, events, components, sliders, graphs, popups, and
  querying: <https://felixkratz.github.io/SketchyBar/>
- Stats 3.0.10 popup layouts and private telemetry behavior were reviewed at exact tag commit
  <https://github.com/exelban/stats/tree/64a34fa34c29d71de19af0868475e23cef7aaf81>.
  No Stats source or binary is vendored. The configuration executes only the exact
  signed external bundled `smc` binary with fixed read commands. Stats exposes no
  robust general local metrics bus: its LevelDB, app-group snapshots, preferences,
  cloud credentials, remote controls, XPC helper, and all SMC write commands are excluded.
  SketchyBar aliases are visual captures rather than interactive status items, and
  current macOS 26 alias limitations are tracked at
  <https://github.com/FelixKratz/SketchyBar/issues/738#issuecomment-3332084641>
  and <https://github.com/FelixKratz/SketchyBar/issues/738#issuecomment-4674820526>.
- The first-party hardware helper was independently written from observed Apple system contracts. Private API behavior was checked against pinned Stats source and the Apple-owned `/usr/bin/powermetrics`; private schemas remain unsupported and can break after an OS update. Stats frequency code cites MIT StatsBar, but no StatsBar source is copied here.
- The read-only private battery-detail contract was checked against `Modules/Battery/readers.swift` at the pinned Stats commit (SHA-256 `cc0da3c3231b093881dff78da8f702b52de988dcebce9a6c9b8cf2ae31029c1a`). No Stats source is copied; ambiguous charging fields are omitted.
- Public memory-pressure behavior was reviewed against exact Stats 3.0.10 `Modules/RAM/readers.swift` (SHA-256 `b08e7db0a98d973bcfcdef3a7da1e90c1dda4c86ed7eddd00e8d3e09a45e267b`). Public Data backing-device I/O behavior was reviewed against exact Stats 3.0.10 `Modules/Disk/readers.swift` (SHA-256 `93ca2674b5cf813a4dc434234e74f43dfed04048fe811ab31632cfa68fabea2a`). Network-counter behavior uses the separately listed exact Net reader hash. Only behavior was reviewed. No Stats source was copied.
- Connectivity capability parity was checked against exact Stats 3.0.10 `Modules/Net/readers.swift` (SHA-256 `16116b5113fe7d4d824e2c8fc2b6abab40d050d8ebe3c16426ae48d04eb04584`) and `Modules/Bluetooth/readers.swift` (SHA-256 `de119bbb51236ab5df8a5fa7c8dc3e00d6ddf23c36116a0b42a1c8ccd2c14bc3`). The first-party implementation uses the same public CoreWLAN/IOBluetooth and fixed Apple tool capabilities through an independent closed privacy boundary. It does not copy Stats code or read Stats caches, preferences, app-group data, CoreBluetooth UUIDs, or remote services.
- SbarLua public wrapper API and upstream examples:
  <https://github.com/FelixKratz/SbarLua>
- Visual-only workspace/app-strip reference supplied by the user:
  <https://github.com/ut0mt8/dotfiles/tree/main/sketchybar>. No source or icon
  map was copied from it; the repository publishes no detected license.
- Visual-only square continuous-block reference supplied by the user:
  <https://github.com/ssate/dotfiles>. No source, script, icon, or asset was
  copied from it; the repository publishes no detected license.
- Official community plugin and configuration indexes were reviewed as prior
  art, not vendored: <https://github.com/FelixKratz/SketchyBar/discussions/12>
  and <https://github.com/FelixKratz/SketchyBar/discussions/47>.
- Apple public CoreWLAN, IOBluetooth, CoreAudio, IOPowerSources, IOPM battery,
  Metal, CoreGraphics, AppKit, ColorSync, CoreLocation, CoreWLAN, IOBluetooth,
  ProcessInfo, and `networksetup`/`system_profiler`/`ioreg`/`pmset`/`open`
  interfaces. The foreground network-name permission request follows Apple’s
  `CLLocationManager.requestWhenInUseAuthorization()` contract and required
  `NSLocationWhenInUseUsageDescription`/macOS `NSLocationUsageDescription` keys:
  <https://developer.apple.com/documentation/corelocation/cllocationmanager/requestwheninuseauthorization()>
  and <https://developer.apple.com/documentation/corelocation/requesting-authorization-to-use-location-services>.
  Apple’s Access Wi-Fi Information entitlement documentation lists only iOS,
  iPadOS, and visionOS, so the macOS helper does not claim or add that entitlement:
  <https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.wifi-info>.
- BetterDisplay documented CLI integration:
  <https://github.com/waydabber/BetterDisplay/wiki/Integration-features,-CLI>. The write helper uses the installed app's reviewed local DNC protocol only for brightness, hardware contrast, volume, and mute. DNC is an unauthenticated local broadcast bus; correlation and post-write readback reduce accidental races but do not authenticate another process in the same login context.

No Linkarzu/Rocky source, unlicensed icon map, GPL dotfile source, private
Control Center alias, Notification Center database, or deprecated
`media_change` event is copied or used.
