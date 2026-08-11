# Third-party software and references

No third-party executable or implementation source is vendored here.
The three source subtrees under `native/` are frozen first-party prototypes. Their internal directory names record an immutable fan-in boundary, not third-party ownership. They are not built or installed.
`lib/unicode_grapheme_ranges.lua` contains generated range data derived from the
Unicode Character Database under the Unicode Data Files and Software License.
`install-deps.sh` builds the first-party public stats and CoreAudio helpers, then installs dependencies and one Lua binary module into their normal user or Homebrew locations. The Lua implementation is independently written against public APIs.

## Pinned or required dependencies

| Dependency | Pin used here | License | Purpose / source |
| --- | --- | --- | --- |
| SbarLua | commit `dba9cc421b868c918d5c23c408544a28aadf2f2f` | GPL-3.0 | Installed binary module: <https://github.com/FelixKratz/SbarLua> |
| Lua | live Homebrew formula input; must remain 5.5.x and pass the post-install smoke gate | MIT | Runtime and SbarLua ABI: <https://www.lua.org/license.html> |
| icalBuddy | live Homebrew formula input; post-install smoke required | MIT | Calendar command API: <https://hasseg.org/icalBuddy/> |
| BetterDisplay | installed signed app version 4.2.3 build 48120; exact-version read gate | Vendor license | Read-only display integration through the documented bundled CLI: <https://github.com/waydabber/BetterDisplay/wiki/Integration-features,-CLI> |
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
- Stats 3.0.10 popup layouts were reviewed as MIT-licensed visual prior art:
  <https://github.com/exelban/stats/tree/v3.0.10>. No Stats source or binary is
  vendored. Stats exposes no documented local metrics API used by this configuration.
  SketchyBar aliases are visual captures rather than interactive status items, and
  current macOS 26 alias limitations are tracked at
  <https://github.com/FelixKratz/SketchyBar/issues/738#issuecomment-3332084641>
  and <https://github.com/FelixKratz/SketchyBar/issues/738#issuecomment-4674820526>.
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
  Metal, CoreGraphics, AppKit, ColorSync, ProcessInfo, and `networksetup`/`open`
  interfaces.
- BetterDisplay documented CLI integration:
  <https://github.com/waydabber/BetterDisplay/wiki/Integration-features,-CLI>.

No Linkarzu/Rocky source, unlicensed icon map, GPL dotfile source, private
Control Center alias, Notification Center database, or deprecated
`media_change` event is copied or used.
