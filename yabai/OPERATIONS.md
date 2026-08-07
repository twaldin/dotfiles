# yabai basic-mode operations

This setup uses yabai 7.1.25 and skhd 0.3.9 from `asmvik/formulae`.
System Integrity Protection stays fully enabled. Do not install or load the
scripting addition. This configuration targets Apple-silicon macOS Tahoe. The
activation path requires Homebrew yabai at `/opt/homebrew/bin/yabai`, the Tahoe
system `jq` at `/usr/bin/jq`, and `/usr/libexec/PlistBuddy`; it fails before
cutover when one is absent.

## Ownership

- Karabiner changes Caps Lock into Hyper: Command-Control-Option-Shift.
- skhd owns the window and Space chords in the table below.
- Raycast keeps only non-conflicting Hyper application shortcuts.
- yabai manages recursive BSP trees on native macOS Spaces.
- AeroSpace is an installed rollback. It must not run with yabai.

Remove global shortcuts from Raycast **Window Management** actions. Do not
remove Raycast application shortcuts. macOS symbolic Hyper-1...4 shortcuts
must stay disabled because skhd owns Hyper-number.

## Keys

| Keys | Action |
| --- | --- |
| Hyper-H/J/K/L or Hyper-arrows | Focus the adjacent window |
| Option-Shift-H/J/K/L or Option-Shift-arrows | Move the focused BSP node |
| Hyper-1...9 | Focus native Space 1...9 |
| Option-Shift-1...9 | Send the window to native Space 1...9 and follow it |
| Option-Tab | Focus the recent window |
| Option-Return | Toggle yabai zoom fullscreen |
| Option-Backtick | Toggle floating |
| Option-0 | Balance the current BSP tree |
| Option-minus/equal | Shrink or grow the focused BSP pane by 0.05 |

Hyper already contains Shift. Hyper-Shift-1 is therefore the same physical
chord as Hyper-1. Option-Shift-number is the separate send chord.
Option-Left/Right remain available for native word movement. skhd owns
Option-Shift-Left/Right for window movement, so those two chords no longer
perform native word selection.

## Native Spaces

The primary yabai display (`display == 1`, the built-in display on the current
hosts) owns global Space indices 1 through 9. Create missing Spaces with the
Mission Control `add desktop` button. Basic-mode yabai cannot create or destroy
Spaces. It can focus an existing Space with its gesture fallback and can move a
window to an existing Space on this macOS version. External displays can own
additional Spaces, but activation fails unless the primary display still owns
exactly indices 1 through 9 because the keyboard map addresses those indices.

Check the live set:

```sh
yabai -m query --spaces | jq '.[] | {index, windows, "has-focus"}'
```

The bar must build its Space list from this query. It must not use AeroSpace
workspace data while yabai is active.

## macOS 26 Accessibility wrappers

macOS 26.1 and 26.2 have an Apple-confirmed bug for standalone command-line
Accessibility clients. This repo builds normal app bundles at fixed paths:

```sh
./yabai/install-accessibility-wrappers.sh
```

Add these apps in **System Settings > Privacy & Security > Accessibility**:

- `~/Applications/Yabai.app`
- `~/Applications/skhd.app`

The launch agents run the matching `Contents/MacOS` paths. Approval for the
Homebrew paths does not approve these wrapper executables.

The wrappers use ad-hoc signatures. Their paths and bundle IDs are stable, but
their code requirements are not stable after a binary or `Info.plist` change.
After every yabai or skhd upgrade:

1. Stop and disable both services.
2. Confirm that no `yabai` or `skhd` process is active.
3. Run the wrapper installer.
4. Remove stale Accessibility rows if macOS does not match the new code.
5. Add and enable both wrapper apps again.
6. Verify both signatures.
7. Start yabai and verify its socket before you start skhd.

The installer derives the installed versions, builds and verifies both apps
before replacement, and restores both old apps if the pair replacement fails.
It refuses to replace a running wrapper.

## Launch agents

The repository owns the two launch-agent definitions:

```sh
ln -sfn "$PWD/yabai/launch-agents/com.asmvik.yabai.plist"   "$HOME/Library/LaunchAgents/com.asmvik.yabai.plist"
ln -sfn "$PWD/yabai/launch-agents/com.koekeishiya.skhd.plist"   "$HOME/Library/LaunchAgents/com.koekeishiya.skhd.plist"
```

They use a fixed system PATH. They restart a crash, but they do not restart a
normal permission failure. The checked-in wrapper and log paths use the macOS
short name `twaldin`. For another account, replace those absolute values in
both plists before linking them, then run `plutil -lint` on both files. The
activation script rejects wrapper or log paths that do not match the current
account.

Use the fail-closed activation script for a controlled start:

```sh
./yabai/activate-yabai.sh
```

It refuses to start if AeroSpace, yabai, or skhd is active or if either launch
agent is already loaded. It verifies both wrapper signatures and plists, starts
yabai first, waits for the final BSP config, and only then starts skhd. If a
cutover step fails, it disables both primary jobs and restores AeroSpace only
after safe process inspection proves that yabai and skhd are absent.

A first app-bundle launch can take several seconds. The socket can answer
before `yabairc` finishes, so the script verifies both the query and final
config values.

Reload the hotkey file without restarting:

```sh
skhd -r
```

Logs:

```sh
tail -n 100 "/tmp/yabai_$USER.err.log"
tail -n 100 "/tmp/skhd_$USER.err.log"
```

## Geometry

SketchyBar occupies the top 32 points. yabai reserves it with
`external_bar all:32:0`, then applies 10-point outer padding and 8-point window
gaps. On the built-in 1512-by-982 display, the managed origin is `x=10, y=42`.
Window animation duration is explicitly `0.0`, so Screen Recording permission
is not required.

The default root split is 0.55. Discord has an application minimum width near
800 points. yabai cannot discover or override application minimum sizes. Put
large applications on separate Spaces or use a compatible tree. Do not balance
a hand-adjusted tree unless equal ratios are wanted.

Raycast and System Settings are unmanaged overlays. Native macOS window shadows
stay enabled. Forced shadow control is outside basic mode.

## Durable rollback to AeroSpace

Use the fail-closed rollback script:

```sh
./yabai/activate-aerospace-rollback.sh
```

It unloads and disables skhd before yabai. It opens AeroSpace only after
process inspection proves that both primary processes are absent. It aborts on
an inspection error instead of treating that error as a safe state.

For a full security rollback, also remove both wrapper rows from Accessibility
and remove the wrapper apps if they will not be evaluated again. Keep
AeroSpace `start-at-login` false during yabai evaluation. Never run both window
managers.

## Basic-mode boundary

Do not run `yabai --load-sa`. Whole-Space creation, destruction, reordering,
and direct switching need the scripting addition. Forced shadows, opacity,
sticky windows, custom layers, and nonzero yabai animations are also outside
this setup.

## Validation status

On the Work host, the wrapper workaround and the window-manager runtime were
live-proven on 2026-08-06 before the account-path guard was added. AeroSpace is
stopped. Wrapper-backed yabai and skhd are active, and the yabai socket answers
queries. Historical key automation supplied smoke coverage for Hyper focus and Space
navigation before the current no-synthetic-HID rule. It is not acceptance
proof. Nine native Spaces exist. Option-Shift-number distributed live windows
across native Spaces. The live config reports BSP layout, split ratio 0.55,
10-point padding, 8-point gaps, a 32-point external bar, and zero animation.
Each host still needs attended physical-key verification before skhd or its
hotkeys are accepted.

The account-path guard has passed ShellCheck, shell syntax checks, plist lint,
and exact read-only comparisons against the current Work plists. It was not
invoked because the active services must not be disturbed. When it is actually
run on a new host, a successful guarded activation is expected to verify the
account-specific plist values, wrapper signatures, yabai socket, final yabai
configuration, and process survival. It does not prove skhd Accessibility
approval or hotkey registration:
`skhd` can remain alive when those controls do not work. After activation, use
physical keys to verify directional focus, Space focus, and send-and-follow.
Exercise rollback separately under attended conditions; do not use synthetic
HID or treat process presence as keyboard proof.

Remaining manual checks are physical-key feel, Raycast Window Management
shortcut cleanup, guarded rollback on the Home host, and final SketchyBar
visual and interaction acceptance.
