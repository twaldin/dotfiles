# Third-party software and references

No third-party executable or implementation source is vendored here.
`lib/unicode_grapheme_ranges.lua` contains generated range data derived from the
Unicode Character Database under the Unicode Data Files and Software License.
`install-deps.sh` installs executables and one Lua binary module into their
normal user/Homebrew locations. The Lua implementation is independently written
against public APIs.

## Pinned or required dependencies

| Dependency | Pin used here | License | Purpose / source |
| --- | --- | --- | --- |
| SbarLua | commit `dba9cc421b868c918d5c23c408544a28aadf2f2f` | GPL-3.0 | Installed binary module: <https://github.com/FelixKratz/SbarLua> |
| sketchybar-system-stats | `0.8.2`; vendored arm64-only formula derived from tap commit `57f2b989bddd3f365d51db84cdd806c948cef8e8` with formula SHA-256 `639b236a164c049a98eab97265b8a3c333c5c5f39e7a95544302c89247715d55` | GPL-3.0-only | Installed provider: <https://github.com/joncrangle/sketchybar-system-stats> |
| Lua | live Homebrew formula input; must remain 5.5.x and pass the post-install smoke gate | MIT | Runtime and SbarLua ABI: <https://www.lua.org/license.html> |
| icalBuddy | live Homebrew formula input; post-install smoke required | MIT | Calendar command API: <https://hasseg.org/icalBuddy/> |
| blueutil | live Homebrew formula input; post-install smoke required | MIT | Bluetooth controller and connection state: <https://github.com/toy/blueutil> |
| media-control | live Homebrew formula input; post-install smoke required | BSD-3-Clause | Tahoe-compatible media metadata/control: <https://github.com/ungive/media-control> |
| gh | existing Homebrew install | MIT | Authenticated notification query: <https://github.com/cli/cli> |
| JetBrains Mono Nerd Font | existing user font | SIL OFL 1.1 plus Nerd Fonts notices | Monochrome glyphs: <https://www.nerdfonts.com/> |
| sketchybar-app-font | release `v2.0.71`; Lua SHA-256 `adbdd97d5137846babb2584de701f341541402bb2e1478d1ae031e07cc5e060c`; TTF SHA-256 `e015c40fbe95d85763b633eae54f7b8e1ded83cffbc15aff40b8b8f89717a0b1` | CC0-1.0 | App ligatures and lookup map installed outside the repository: <https://github.com/kvndrsslr/sketchybar-app-font/releases/tag/v2.0.71> |
| Unicode Character Database | 17.0.0; GraphemeBreakProperty SHA-256 `d6b51d1d2ae5c33b451b7ed994b48f1f4dc62b2272a5831e7fd418514a6bae89`; emoji-data SHA-256 `2cb2bb9455cda83e8481541ecf5b6dfda66a3bb89efa3fa7c5297eccf607b72b`; DerivedCoreProperties SHA-256 `24c7fed1195c482faaefd5c1e7eb821c5ee1fb6de07ecdbaa64b56a99da22c08`; license SHA-256 `e7a93b009565cfce55919a381437ac4db883e9da2126fa28b91d12732bc53d96` | Unicode-DFS-2016 | Vendored source data and generated grapheme ranges: <https://www.unicode.org/Public/17.0.0/ucd/auxiliary/GraphemeBreakProperty.txt>, <https://www.unicode.org/Public/17.0.0/ucd/emoji/emoji-data.txt>, <https://www.unicode.org/Public/17.0.0/ucd/DerivedCoreProperties.txt>, and <https://www.unicode.org/license.txt> |

The native calendar source is separately immutable at SHA-256
`e695b4a98f69436fbcc22f83750ca683a98fc1d5057e7858bb92b4417603afb3`.
The predecessor approval is not reused after this interaction revision. The
installer verifies the exact source before mutation; current direct,
cross-harness, complete offline native, and attended interaction gates remain
mandatory.

The dependency contract intentionally freezes stats provider 0.8.2. Upstream
also publishes 0.9.0, but this tree does not silently move to a later release:
the reviewed 0.8.2 formula, release archives, Apple-silicon installed binary hash, behavior, and rollback gates form one fixed release input. A
future version change requires a separate review and updated pinned hashes.

This release supports Apple-silicon Tahoe hosts only and requires Homebrew at
`/opt/homebrew`. The calendar helper target is exactly
`arm64-apple-macosx15.0`, and its thin architecture is checked before self-test.

SbarLua, stats provider 0.8.2, the generated Unicode 17.0.0 ranges, and the
checksum-pinned font assets are reproducibly frozen. Lua, icalBuddy, blueutil, and media-control intentionally resolve from live Homebrew formulae.
A Homebrew update invalidates the prior runtime proof. `install-deps.sh` accepts
those live inputs only after the complete offline smoke gate passes; Lua and
luac must also remain in the supported 5.5.x line.

## Public API and prior-art references

- SketchyBar configuration, events, components, sliders, graphs, popups, and
  querying: <https://felixkratz.github.io/SketchyBar/>
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
- Provider event variable contract:
  <https://github.com/joncrangle/sketchybar-system-stats#usage-with-sketchybar>
- macOS `networksetup`, `route`, `netstat`, `ipconfig`, `pmset`,
  `system_profiler`, `scutil`, `plutil`, and `open` command interfaces.

No Linkarzu/Rocky source, unlicensed icon map, GPL dotfile source, private
Control Center alias, Notification Center database, or deprecated
`media_change` event is copied or used.
