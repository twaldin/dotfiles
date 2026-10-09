---
name: mac-gui
description: GUI testing, launching, placing, capturing or showing Mac windows. Read before any computer-guest tool use or opening a test window, and when Tim asks to see one.
---

On **twaldin-home**, GUI tests default to headless `agent-gui`. Host exceptions: host-only apps/licenses or hardware, GPU/timing work such as Roblox Studio, measurements of the host itself (WindowServer/ColorSync/CanvasTest), or showing a host-only app Tim requests. Other hosts have no retained guest; use their isolated test placement below. A busy guest is not a host exception. Keep test windows off Tim's Spaces; no host GUI input.

## Guest on twaldin-home

Only the CLI's delegated worker calls `computer-guest` tools, even if another session already has them. Include file staging in the task: the worker runs `scp -F ~/.config/agent-gui/ssh_config <host-file> agent-gui:<guest-path>` after boot, and saves requested screenshots to host paths it prints. Host paths are not guest paths.

```sh
machine-ok-queue run -- agent-gui run -- 'Call computer-guest list_windows with {} and report the actual result.'
```

Replace the task with the GUI assignment and readback criteria. Use a background job or a tool timeout of at least 20 minutes plus queue wait; wait for its exit status. `agent-gui --help` / `agent-gui run --help` is the command contract.

The CLI waits at most 30 seconds for a kernel-held lease (`--lock-wait` changes that), then reports recorded owners confirmed by `lsof` (not waiters) and exits 75. On 75, keep other work moving and retry later; report repeated 75 or failures with their output to your lead or Tim (subagents in their result). It recovers an orphaned VM, boots headless, waits for the signed driver, checks ColorSync K=0, starts fresh `omp -p` with closed stdin and prints its final answer. A dedicated keeper retains the lease until OMP exits, with its own 660s deadline; OMP and shell children never inherit it. The holder terminates the keeper's remaining process group before direct teardown and lease release. Never delete the lock file or bypass the CLI.

The retained MCP entry may warn at session start while stopped. The fresh worker discovers it after boot and requires MCP readiness; an ordinary task subagent does not guarantee rediscovery. Show its saved host screenshots, not a viewer. The pilot's host-state brackets were rollout evidence; ongoing runs check log access and post-boot K=0 over four periods (~20 seconds).

## Host exceptions: every Mac

- Launch without focus (`open -g`); quit apps you opened when testing ends. Do not operate Tim's windows or send host mouse/keyboard input.
- Move only your window by explicit id: `yabai -m window <id> --space <n>`. Unqualified yabai moves Tim's focused window. Verify the id first; any backstop rule must match only your launched window, never an app name alone.
- Capture by id with `screencapture -x -o -l <windowid>`. Hidden Spaces can throttle rendering: Chromium/Electron needs `--disable-backgrounding-occluded-windows`; timing-sensitive runs verify their own cadence.
- When Tim asks to see a host-only result, tell him its agent Space; keep the window there rather than moving it onto his Spaces. Show guest screenshots on the board instead.
- Virtual screens cost WindowServer/ColorSync work. Never create one casually; `betterdisplaycli discard` must name exactly one screen (`--name=<screen>`). Get its display id with `betterdisplaycli get --name=<screen> --identifiers`, then its Spaces with `yabai -m query --displays`.

## twaldin-home: guarded host-only work

- Agent Spaces: 6 roblox, 7 canvas, 8 Minecraft labs; Tim uses 1–4. Use `gui-launch --space <6|7|8|display:CanvasTest> [--guard-seconds N] -- <open args | executable>` for host-only test launches. Read `gui-launch --help` for the current guard contract/events/exit codes. It never quits the app.
- For a LaunchServices child outside the launched process tree, use `--attach-exe <path> --attach-argv <needle>`; never adopt by app name/bundle id. Guard the full test lifetime, then SIGTERM at teardown. Use `gui-launch --help` for event interpretation and exit codes; exit 1 means its check failed.
- The guard reverts focus theft, not prevents it. Brief flashes while new windows open on Tim's viewed Space are allowed during guarded runs. Exposure duration is diagnostic, not a check failure. Windows must reach their placement, leave none on Tim's screen or Spaces at the guard's end, and get clean teardown. Keep Tim's Space unchanged and send no input to his apps. If a host-only run cannot meet those checks, report the limitation to your lead or Tim rather than treating repair as permission. Apple/sandboxed apps do not inherit the launch token; use a nonsandboxed third-party app or built probe.
- Call yabai at `/Users/twaldin/Applications/Yabai.app/Contents/MacOS/yabai`; the `launchctl asuser` capture wrapper breaks its socket.
- `CanvasTest` is the only virtual screen. Your lead or Tim manages screens; put it on its target Space before launch and leave other displays' Spaces unchanged while the guard runs.

## twaldin-work: host-only placement

- `yabai` and `betterdisplaycli` are on PATH (`/opt/homebrew/bin`). No Space map is set up; use a Space Tim isn't viewing and tell him which.
- When a hidden Space isn't enough, create at most one screen per pane and reuse it for every run: `betterdisplaycli create --type=VirtualScreen --virtualScreenName=Agent-<pane> --useResolutionList=on --resolutionList=1512x982 --virtualScreenHiDPI=on`, then `betterdisplaycli set --name=Agent-<pane> --connected=on --placement=<X>x<Y>`. When the pane's work is finished, discard it with `betterdisplaycli discard --name=Agent-<pane>`.
