# AeroSpace rollback operations

## Role

AeroSpace 0.21.3-Beta is an inactive rollback for the primary yabai/skhd
workflow. Its linked config remains valid, but `start-at-login` is false.
AeroSpace and yabai must never run together.

AeroSpace uses virtual workspaces inside one native macOS Space. The primary
workflow instead uses yabai BSP trees across nine native Spaces. Do not mix the
two workspace models during normal use.

## Fallback keys

The fallback matches the primary chord ownership where possible:

| Keys | Action |
| --- | --- |
| Hyper-H/J/K/L or Hyper-arrows | Focus the adjacent window |
| Option-Shift-H/J/K/L or Option-Shift-arrows | Move the focused node |
| Hyper-1...9 | Focus AeroSpace workspace 1...9 |
| Option-Shift-1...9 | Move the focused node to workspace 1...9 and follow it |
| Option-Tab | Focus the recent workspace |
| Option-Return | Toggle AeroSpace fullscreen |
| Option-Backtick | Toggle floating or tiling |
| Option-minus/equal | Resize |
| Option-0 | Balance sizes |
| Option-Slash | Select the tiles layout |
| Option-Shift-Semicolon | Enter service mode |

Option-Left/Right remain available for native word movement. Raycast keeps
non-conflicting Hyper application shortcuts. Clear Raycast Window Management
shortcuts that duplicate this table.

## Activate the rollback

Use the repository fail-closed rollback command:

```sh
./yabai/activate-aerospace-rollback.sh
```

The script unloads and disables skhd before yabai. It opens AeroSpace only
after process inspection proves that both primary processes are absent. It
aborts on an inspection error.

Then verify the fallback:

```sh
aerospace reload-config
aerospace list-windows --all
```

If either primary process remains, do not open AeroSpace.

## Return to yabai

Quit AeroSpace normally, then use the guarded primary activation:

```sh
osascript -e 'tell application id "bobko.aerospace" to quit'
./yabai/activate-yabai.sh
```

The activation script fails closed if AeroSpace is still active. It verifies
the final yabai BSP config before it starts skhd.

## Bar behavior

The final SketchyBar is driven by native/yabai Space data. If AeroSpace is
activated as a rollback, the bar can show reduced fallback data, but it must not
start a second bar or a second workspace layer. SketchyBar owns its own service.
AeroSpace only emits events.

The native macOS menu bar stays on automatic hide. Do not restart Dock, Finder,
SystemUIServer, or unrelated applications as part of a WM rollback.

## Static validation

```sh
taplo check aerospace/aerospace.toml
```

The rollback config has 8-point inner gaps and 10-point content padding. On the
built-in display, the 32-point bar already changes the usable frame and the
10-point top gap produces `y=42`. Other displays use an explicit 42-point top
value for the same 32-plus-10 geometry. Service mode can reconstruct a flat
tile tree. The rollback remains installed until the primary workflow and bar
receive final acceptance.

## Sources

- [AeroSpace guide](https://nikitabobko.github.io/AeroSpace/guide)
- [AeroSpace commands](https://nikitabobko.github.io/AeroSpace/commands)
- [AeroSpace SketchyBar integration](https://nikitabobko.github.io/AeroSpace/goodies#show-aerospace-workspaces-in-sketchybar)
