# SketchyBar operations

## Install and reload

This release supports Apple-silicon Tahoe hosts only and requires the reviewed
Homebrew prefix at `/opt/homebrew`. Installation rejects other architectures
before dependency changes. The native helper target is exactly
`arm64-apple-macosx15.0`; its thin architecture is checked with public
`lipo -archs` before self-test or publication.

Run dependency setup manually. It never runs during a bar reload.

```sh
~/.config/sketchybar/install-deps.sh
~/.config/sketchybar/scripts/smoke-config.sh
sketchybar --reload
SKETCHYBAR_REQUIRE_LIVE_SHAPE=1 ~/.config/sketchybar/scripts/smoke-config.sh
```

The first smoke is the complete offline gate. Reload happens only after it is
green. The required live invocation then repeats that gate and verifies the
newly loaded source fingerprint plus content-redacted geometry; it cannot pass
against the prior configuration. Hotload can satisfy the same fingerprint, but
the final release procedure uses the explicit reload shown above. Offline
installer validation leaves `SKETCHYBAR_REQUIRE_LIVE_SHAPE` unset because no
live bar is required.

The native source is immutable at SHA-256
`e695b4a98f69436fbcc22f83750ca683a98fc1d5057e7858bb92b4417603afb3`.
The installer rejects a different repository source before any Homebrew
mutation or compilation. The prior exact implementation approval applies only
to its predecessor and is not reused for this interaction revision. Current
source requires its own direct and cross-harness reviews, complete offline
native gate, and attended physical interaction acceptance.

The calendar SF Symbol navigation contract fixture is immutable at SHA-256
`3b7119c0d6d7bf98ccdeac7bfc8ea7e22fc78892c0f8b661d095cff0cb12bc04`. The standalone smoke and direct offline gates verify it
before Swift compilation. The offline gate compiles arm64 debug and optimized
binaries and runs the same self-test in both. It also retains both anonymous
same-host render pairs before it checks byte determinism, so a failure remains
diagnosable. This check does not claim identical pixels across different hosts.

`install-deps.sh` runs that full offline smoke gate after every dependency
installation and fails the install if the gate fails. Lua, icalBuddy, blueutil, and media-control are intentionally live Homebrew formula
inputs, not reproducibly frozen artifacts. Any Homebrew update invalidates the
prior runtime proof until the full gate passes again. Lua and luac are accepted
only from the supported 5.5.x line. The reproducibly frozen inputs are SbarLua,
stats provider 0.8.2, and the checksum-pinned font assets described below.

`install-deps.sh` installs and Brew-pins `stats_provider` 0.8.2 from the
vendored formula captured at upstream tap commit
`57f2b989bddd3f365d51db84cdd806c948cef8e8`. The installer verifies the
formula SHA-256, securely publishes it into a local no-git frozen Homebrew tap,
and installs that fully qualified formula, so later upstream tap releases cannot
change a clean install. Every run installs or reinstalls that formula and then
validates the resolved Cellar path, version, architecture-specific executable
SHA-256, and Brew pin; a preexisting version-matching executable is not accepted.
It also installs checksum-pinned
`sketchybar-app-font` v2.0.71 assets. SbarLua is built once at commit
`dba9cc421b868c918d5c23c408544a28aadf2f2f` under
`~/.local/share/sketchybar_lua`. Checksum-pinned assets validate their canonical
owned parents and existing files, then publish verified 0644 same-directory
staging files atomically. SbarLua builds into an owned staging HOME; its
single-link 0755 module and 0600 provenance marker publish as a rollback-safe,
file-and-directory-fsynced pair inside a canonical owned directory with no
group/other write. The marker records both the pinned commit and exact installed
module SHA-256; every wrapper start validates both against the same no-follow
module inode before Lua loads it. Same-directory
hard-link backups restore exact prior bytes, modes, device, and inode if marker
publication fails or a handled `SIGHUP`, `SIGINT`, or `SIGTERM` interrupts the
pair update; stages and backup names are removed. `SIGKILL` cannot be handled,
so a mismatched pair fails closed until the next installer recovery. For migration,
the wrapper accepts the prior one-line marker only when both its exact pinned
commit and the separately pinned approved legacy module SHA-256 match. New
two-line markers bind their own module SHA-256. The calendar helper uses a canonical owned directory with no group/other write
and validates single-link 0755/0644 live and staging files. Its exact bounded v2
marker binds the source SHA-256, `arm64-apple-macosx15.0` target, `-O` build mode,
and installed binary SHA-256. An existing helper is executed for self-test only
after no-follow marker/binary identity, hash, and exact arm64 `lipo` validation;
legacy, wrong-binary, or wrong-architecture state rebuilds without execution. It
is compiled into an owned same-directory temporary, must pass its native self-test,
and is then installed with atomic binary and provenance-marker renames. Every
transaction holds the stable owned single-link 0600 `lockf` lock before it
inspects recovery state; a concurrent writer returns temporary failure without
normalizing the active writer's namespace. Candidate files and rollback backup
entries are fsynced before live mutation; the destination directory is fsynced after pair publication, rollback restoration, and backup/stage cleanup. SIGKILL or power loss can retain the owned 0700 `.calendar-install-transaction` namespace. Its fixed 0600 manifest records the publication phase, pair presence, and exact prior plus candidate device/inode identities. After the next build and self-test, the locked transaction validates the complete namespace. It idempotently restores the recorded prior pair for every incomplete phase, or retains the already durable new pair for `pair-published`, before it removes recovery state. Only then can it make and fsync a fresh manifested backup snapshot and publish another pair. Missing, extra, unsafe, or identity-mismatched recovery state fails closed unchanged; unrelated main-directory lookalikes are never touched. Same-directory hard-link backups restore the exact prior binary and marker if a detected post-binary marker commit fails. Startup and EXIT rollback create new hard links without consuming the recovery links; a crash at any restore or cleanup point remains idempotently recoverable. An owned canonical empty fixed namespace is normalized as cleanup residue before new state. The lock path is revalidated against the held descriptor before recovery, destructive rollback steps, and each publication phase. Candidate paths are revalidated by exact identity before and after publication and are removed on failure only if they still identify the recorded staging files. Calendar rollback ignores additional handled signals until exact pair restoration and cleanup finish. A failed build or self-test does not overwrite the installed helper. Reloads do not download or compile anything.

## Resting bar and controls

The resting bar uses a fully transparent, non-topmost base. `_HIHideMenuBar=1`
keeps native menu content out of that layer. Sharp graphite blocks remain above
the base for selection, grouping, hover, and popups. Bar items and SketchyBar
popups use zero corner radius; all shadows and blur remain disabled.

- Left: every available primary-display native Space with case-insensitive app ligatures, then a
  fixed 100-point focused-app block. A `front_app_switched` event invalidates
  stale state, then a topology-guarded Yabai query confirms the focused app and
  full window/app list before content is rendered. The center stays empty on every display.
- Right: a touching sequence of square color levels on every configured display.
  The intrinsic next-event block is bounded at 256 points and touches the fixed
  116-point date/time anchor, which touches the fixed 168-point six-cell system
  block: system activity, battery, microphone, audio, Bluetooth, and Wi-Fi.
  Event/date/system use progressively lighter graphite-blue fills. Every system
  cell remains 28 points and its Nerd Font glyph is centered in that full cell.
  Hover changes only the local fill and foreground; it never changes geometry
  or adds an outline. Amber/red warning states keep their semantic foreground.
  An open popup host uses the same active fill instead of cutting a dark hole
  through the continuous block. CPU/memory and live graphs remain out of this
  release slice; the separate-domain stats redesign follows as its own slice.
- Selection and normal data use graphite, neutral gray, and off-white. Amber and
  red are reserved for genuine warning/critical state.

Interactions:

- Space left click focuses through Yabai; scroll cycles native Spaces only when
  Yabai is available. App slots share a 340-point strip fairly. Without Yabai,
  both click and scroll focus are intentionally disabled because macOS has no
  safe public numeric Space-focus API. The fallback is the static guarded
  `1..9` primary-Space visual invariant used by the shipped Yabai/Hyper setup;
  it is not live enumeration and exposes no actions or app ligatures. Window
  data is queried only after the exact Yabai Space invariant is accepted. It does not read the
  undocumented Spaces plist or sum separate-monitor Spaces. Yabai actions are
  enabled only when its primary `display == 1` indices sort to the exact global
  sequence `1..9`; any subset or non-1-based result fails back to static mode.
  The final focus helper independently rechecks that same snapshot before every
  action. Numeric clicks remain valid while an external Space is focused;
  relative scroll requires one focused primary Space and computes bounded 1↔9
  wrap targets instead of passing raw `prev` or `next`.
- Focused-app hover keeps its 100-point width. Left click opens the window panel
  only through the exact primary 1..9 topology guard. Rows show detailed titles;
  the final helper brackets two matching bounded stable records for the requested
  window with three exact-topology checks immediately before it focuses a
  validated numeric ID. A topology change after the final check and before the
  Yabai focus syscall is the unavoidable limit of Yabai's nontransactional API;
  the helper does not use an unbounded recheck loop. The flat
  popup paginates deterministically at ten windows per page, so every sorted
  primary or external window remains reachable without an irreversible cap.
  Exact primary Spaces 1..9 gate service validity, but the list intentionally includes
  and focuses current windows on external displays with higher Space indices.
  Window content is held transiently and emitted only after a second
  exact-topology check.
- The next-event preview opens a safe meeting URL when one is available, with
  one Calendar fallback. A left click on date/time queries only SketchyBar's
  public per-display item rectangles and opens or toggles the native AppKit
  calendar panel at the exact clicked 116×32 rect. Non-left date clicks do
  nothing. Wi-Fi, Bluetooth, audio, microphone, battery, and system activity
  open purpose-built panels. The date panel includes a rendered month grid and
  agenda. Network/system use compact metric grids and section hierarchy, not a
  graph or a flat undifferentiated list. Every panel uses one continuous outer
  surface: only its top header has a resting fill; secondary headings and rows
  are flat, and only the active action-row hover receives a temporary fill.
- One popup exists globally. Same-host click closes it; another host replaces it.
  A 130 ms grace covers the pointer crossing between host and panel. Display
  changes, wake, reload, and leaving both dismiss it.
- Action rows have a centralized fixed-geometry hover state. Passive metrics do
  not look clickable. One bar hover exists globally and prior state resets before
  the next surface appears.
- Right click opens Wi-Fi, Bluetooth, Sound, or Battery settings where
  applicable. Calendar event and date/time group right and middle clicks are no-ops.
- Audio changes require explicit popup actions; scrolling the bar item does not
  mutate state. The Audio and Microphone panels expose true mute, capability-aware
  level sliders, and device selectors. A muted device keeps its confirmed stored
  level visible for restore context while the mute state remains explicit.
- Bluetooth cache invalidates when the light connected-device fingerprint
  changes. VPN recognizes NetworkExtension connections, split `utun` tunnels,
  and a running Tailscale tunnel.

Refresh policy:

- Native Space/window/front-app events are primary; enabled five-second Space and
  focused-window reconciliation is only a safety net.
- Wi-Fi state and network counters reconcile every five seconds. An open network panel updates live and refreshes VPN
  every eight seconds; its extra loop stops on close.
- Bluetooth and audio/microphone bar state use 30-second fallbacks plus events
  where macOS provides them. Open audio or microphone panels reconcile input
  every five seconds. Slow Bluetooth `system_profiler` runs on intent with a
  60-second cache invalidated by the light fingerprint.
- `system_stats` pushes CPU/RAM/disk/battery/uptime every three seconds. An open
  system panel updates on those events and refreshes only processes/VPN every
  eight seconds; its extra loop stops on close.
- Calendar text updates every 30 seconds; the bounded next-event preview uses one
  generation-guarded `icalBuddy` query every 60 seconds. The installed exact
  JetBrains Mono Nerd Font faces and SketchyBar CoreText dynamic widths allocate
  8-point outer edges and an 8-point internal gap. Only printable ASCII and the
  trusted calendar glyph use the verified 5.4-point narrow advance. Each
  non-ASCII scalar reserves 24 points, except a scan-verified 64-point outlier tier.
  A complete sanitizer-reachable CoreText glyph-path and typographic-advance
  scan must prove both tiers against the installed 9-point face and its public
  fallback cascade. Generated,
  checksum-pinned Unicode 17 properties ensure that the selector never cuts
  combining, joined emoji, regional-pair, Hangul conjoining, or grouped
  unknown-script sequences. A complete title remains unchanged when it fits; a
  bounded title ends with a visible ellipsis. Native font-oracle fixtures cover
  ASCII, CJK, emoji, decomposed marks, Hangul, Indic, Cyrillic, Greek, and
  hostile fallback text including U+FDFD.
  The actual event block never exceeds 256 points, and event plus the 116-point
  date anchor never exceeds 372 points. The countdown remains left-aligned.
  `settings.calendar_show_titles` defaults to `true` for this personal setup, so
  the resting bar exposes event titles to anyone who can see the display or a
  screen share. Set it to `false` for generic `Upcoming event` text. Rich agenda
  and battery-health helpers run only on intent. Data-volume capacity refreshes
  about every five minutes.

## Lifecycle and diagnostics

Lua callback errors stay at `${TMPDIR:-/tmp}/sketchybar-lua-$UID/lua.log`.
The wrapper requires an owned, non-symlink 0700 per-user Lua runtime and execs
through the same `O_NOFOLLOW`/same-inode helper into an owned, single-link 0600
regular log.
Each verified Lua exec safely resets only that private descriptor; the wrapper
uses no shell log redirection.
All external UI strings pass through the shared bounded UTF-8 display sanitizer. It rejects invalid UTF-8, every current Unicode format scalar, variation selectors, tag/default-invisible controls, surrogates, private-use code points, and Unicode noncharacters before calendar, window, media, network, VPN, device, or popup text reaches SketchyBar.

Provider output stays in the owned 0700 per-user runtime directory at
`${TMPDIR:-/tmp}/sketchybar-stats-provider-$UID/provider.log`; it is an owned,
non-symlink 0600 regular file opened with `O_NOFOLLOW`. Each verified provider
exec safely resets that owned descriptor to bound growth; diagnostic append mode
never truncates or follows an unsafe path. The provider PID, pre-fork launch intent,
and launcher lock are in the same runtime directory. The launcher fsyncs the
owned intent before fork. The child first claims and fsyncs that same intent inode with its own PID,
then atomically publishes its PID before exact provider exec and removes/fsyncs
the intent. A later launcher never removes pending intent. It waits briefly and then fails
closed while any intent remains, whether its recorded owner is live or dead. A
true crash before child claim therefore needs attended removal after process
verification; this deliberate wedge prevents a second fork under scheduler
uncertainty. PID publication refuses to overwrite a different live PID and
uses an exclusive `O_NOFOLLOW` 0600 temporary, full write and sync, atomic
replacement, and final same-inode validation. A
crash-owned fixed temporary is recovered only when it is an owned, non-symlink,
single-link 0600 regular file; unsafe temporary paths remain unchanged and fail
closed. The launcher builds a complete owned 0700 unique staging directory with one
no-follow, exclusive, fsynced 0600 owner record, fsyncs the stage, and uses macOS
`renameatx_np(RENAME_EXCL)` to publish the whole `launcher.lock` directory without
an empty visible state. Owner cleanup and confirmed-dead recovery revalidate the directory and record,
then use the same no-replace primitive to move the complete lock to the fixed
quarantine. After revalidation, a second no-replace rename detaches that complete
quarantine to a unique cleanup directory and fsyncs the runtime before entry
removal. Crashes during deletion therefore leave only invisible unique complete
or empty cleanup residue, never a blocking empty fixed quarantine. Incomplete
unique stages and detached cleanup residue are invisible to lock acquisition;
any replacement or occupied or malformed fixed quarantine safely wedges. Only a
validated live lock holder, validated live quarantine holder, or exclusive-publish
`EEXIST` winner that revalidates as an exact safe live lock returns contention
status 75 and becomes a no-op success. Unsafe, dead, malformed, or unrecoverable
states return nonzero and append one generic diagnostic to the private provider
log. The launcher preserves every existing recorded holder
independent of relative, absolute, default, or explicit invocation spelling. PID
reuse can safely wedge the launcher until manual cleanup, but cannot permit
concurrent launch. It migrates prior owned PID metadata, verifies the full expected provider
command, and fails closed if an owned process does not stop. It never uses
`killall` or `pkill`.

Useful checks:

```sh
sketchybar --query bar
sketchybar --query space.1
sketchybar --query front_window
sketchybar --query status
ps -axo pid=,command= | grep -E '[l]ua .*/sketchybar/bootstrap.lua|[s]tats_provider'
df -k /System/Volumes/Data
```

The network sampler detects the default route; it never assumes `en0`. Rates
use an atomic previous tuple, real elapsed time, nonnegative deltas, and a
fixed logarithmic 100 MiB/s scale. The Data-volume sample uses
`df /System/Volumes/Data`. Slow callbacks are generation guarded and coalesced.

## Permissions and manual checks

- `icalBuddy` can request Calendar access. Without it, the panel shows
  `Calendar permission required`. The configuration does not read Calendar
  files directly.
- Tahoe can redact SSID from `networksetup`/`ipconfig` even when Wi-Fi has a
  valid route. The panel then shows `—`. Location Services for the process that
  starts SketchyBar can expose it; do not grant broader file access.
- Yabai supplies window lists, app-to-Space mapping, and focus. Until its real
  Cellar binary has Accessibility permission, the service is running, and its
  primary topology is exactly 1..9, the bar correctly shows static Space numbers
  and `Window list needs Yabai` without querying or exposing window content.
- No item uses a private Control Center alias. Screen Recording, Full Disk
  Access, and scripting additions are not required.
- The native calendar launch uses public SketchyBar bounding rectangles and
  public CoreGraphics/AppKit display geometry. The helper selects an exact
  mapped rect only while the pointer is still inside it; a moved-pointer abort
  does nothing and preserves focus. It does not use global Accessibility,
  state-report files, hard-coded production display geometry, or synthetic HID.
  A left-click toggle remains visible when the pointer moves. Escape, a second
  date click, an outside physical mouse-down, screen change, wake, or an event
  action closes it explicitly. Accessory-app deactivation alone never closes it.
  Production validates its exact frame, four-point gap, display inset, and
  one-window contract after ordering; a failed contract closes without opening
  an unrelated Calendar window.
- Pointer automation is currently blocked because `osascript` lacks Assistive
  Access (`-25211`). Before activation on a deployment host, a human must check
  VoiceOver, Full Keyboard Access, focus rings, Increase Contrast, pointer
  dismissal, safe-link actions, multi-display anchoring, hover, scroll,
  popup-boundary crossing, and slider drag at each display scale. Calendar and
  Accessibility permission prompts are attended gates; do not reset TCC.
- Popup rows are scoped to the active display. Resting controls return to all
  displays after the popup closes.

## Rollback

The prior shell configuration is at:

`~/.local/share/sketchybar-rollback/shell-config-before-sbarlua-20260806T1545`

Stop SketchyBar, restore that directory into `~/.config/sketchybar`, and start
SketchyBar again. The backup is outside this repository.
