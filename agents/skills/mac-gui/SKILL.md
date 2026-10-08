---
name: mac-gui
description: GUI testing, launching, placing, capturing or showing Mac windows. Use before opening a test window or when Tim asks to see one; default to the headless guest, with guarded host-only exceptions.
---

GUI tests default to the headless `agent-gui` guest on **twaldin-home**. The pilot proved Calculator/TextEdit launch, AX interaction, screenshots and promptless headless reboots (`~/cos/efforts/agent-tools/handoff.md`). Use the host only for a concrete guest limitation: a host-only app/license, hardware integration, or GPU-bound work such as Roblox Studio; the pilot did not establish GPU/performance equivalence. A busy guest is not a host exception. Check `hostname`; run the guest recipe on home. Keep test windows off Tim's Spaces and issue no host GUI input.

## Guest: claim → boot → fresh session → stop

The parent owns the whole batch and delegates to one GUI worker at a time; workers neither acquire/release ownership nor boot/stop it. Use the same directory across worktrees/harnesses. The queue has multiple slots, so it is not a guest lock.

1. **Claim atomically**, before any guest use:
   ```sh
   mkdir "$HOME/.cache/agent-gui.owner"
   ```
   Continue only on exit 0; write your agent/session ID to `~/.cache/agent-gui.owner/owner`. A collision means wait for the owner: no boot, tool call or stop. Keep the directory until every worker exits and teardown is confirmed. A crashed owner leaves a fail-closed lock; ask meta to recover it after checking the owner/workers are gone. Never steal it by age/PID or remove another owner's marker.
2. **Require stopped, then boot through the queue**. If stopped is not confirmed, retain the claim and ask meta; do not adopt/stop an unknown user's VM.
   ```sh
   set -e -o pipefail
   env LUME_UPDATE_CHECK=false ~/.local/bin/lume get agent-gui --format json | jq -e 'length == 1 and .[0].status == "stopped"'
   ~/.local/bin/machine-ok-queue run --agent meta -- env LUME_UPDATE_CHECK=false ~/.local/bin/lume run agent-gui --detach --display none --vnc disabled
   ```
3. **Wait for SSH and the signed GUI driver**, not just Lume's running state:
   ```sh
   set -o pipefail
   ready=0
   for attempt in {1..60}; do
     if ssh -F "$HOME/.config/agent-gui/ssh_config" -T agent-gui /Users/lume/.local/bin/cua-driver permissions status --json | jq -e '.accessibility and .screen_recording and .source.attribution == "driver-daemon"'; then
       ready=1; break
     fi
     sleep 2
   done
   test "$ready" = 1
   ```
   Proceed only on success. Timeout/boot failure goes to teardown, not host input or permission changes. Stage only the task files over this pinned SSH connection; host paths are not guest paths.
4. **Start a fresh headless OMP after readiness.** A session started while stopped warns that `computer-guest` is unavailable; booting does not itself refresh that session. Ordinary task subagents borrow the parent's MCP manager, so spawning one is not a fresh-discovery guarantee. Use the proven `omp -p` route:
   ```sh
   TASK='Call computer-guest list_windows with {} and report the actual result.'
   ~/.local/bin/machine-ok-queue run --agent meta -- env OMP_MCP_REQUIRE_READY=1 omp -p --no-session --no-title --max-time 10m "The parent owns agent-gui. Use computer-guest only for GUI work; do not claim/release ownership, boot/stop the VM, or use host GUI input. Finish all workers and tool calls before exiting. $TASK" </dev/null
   ```
   Replace `TASK` with the real GUI assignment and readback criteria. Keep stdin closed: a non-TTY open pipe can make print mode wait before startup. This new process discovers the retained machine-local MCP entry; `OMP_MCP_REQUIRE_READY=1` fails before the prompt if a configured server is unavailable. In Code Mode, read `xd://mcp__computer_guest_list_windows`, then write JSON `{}` to that device; other guest tools use the same presentation. Wait for OMP to exit before stopping. The parent need not gain the tools itself.
5. **After your boot attempt, teardown on success, error or cancellation**, once all guest work has ended:
   ```sh
   set -e -o pipefail
   ~/.local/bin/machine-ok-queue run --agent meta -- env LUME_UPDATE_CHECK=false ~/.local/bin/lume stop agent-gui
   env LUME_UPDATE_CHECK=false ~/.local/bin/lume get agent-gui --format json | jq -e 'length == 1 and .[0].status == "stopped"'
   ```
   Only after both succeed, remove your exact `~/.cache/agent-gui.owner/owner` file and `rmdir ~/.cache/agent-gui.owner`. Failed teardown retains ownership for meta to recover. Keep the MCP entry; its warning while stopped is expected. No viewer, daemon or new CLI is needed: atomic `mkdir` plus fail-closed recovery serializes the full lifecycle.

## Host exceptions: every Mac

- Launch without focus (`open -g`); quit apps you opened when testing ends. Do not operate Tim's windows or send host mouse/keyboard input.
- Move only your window by explicit id: `yabai -m window <id> --space <n>`. Unqualified yabai moves Tim's focused window. Verify the id first; any backstop rule must match only your launched window, never an app name alone.
- Capture by id with `screencapture -x -o -l <windowid>`. Hidden Spaces can throttle rendering: Chromium/Electron needs `--disable-backgrounding-occluded-windows`; timing-sensitive runs verify their own cadence.
- When Tim asks to see your result, move its window to the Space he names or an empty built-in-display Space, never his focused Space; tell him its number and leave it for him. If none is empty, ask. Sticky-only Spaces count as empty.
- Virtual screens cost WindowServer/ColorSync work. Never create one casually; `betterdisplaycli discard` must name exactly one screen (`--name=<screen>`). Get its display id with `betterdisplaycli get --name=<screen> --identifiers`, then its Spaces with `yabai -m query --displays`.

## twaldin-home: guarded host-only work

- Agent Spaces: 6 roblox, 7 canvas, 8 Minecraft labs; Tim uses 1–4. Use `gui-launch --space <6|7|8|display:CanvasTest> [--guard-seconds N] -- <open args | executable>` for host-only test launches. Read `gui-launch --help` for the current guard contract/events/exit codes. It never quits the app.
- For a LaunchServices child outside the launched process tree, use `--attach-exe <path> --attach-argv <needle>`; never adopt by app name/bundle id. Guard the full test lifetime, then SIGTERM at teardown. Treat `reverted` and `owner-query-timeout` as failures even on exit 0; exit 1 means Tim's screen was disturbed.
- The guard reverts focus theft, not prevents it. New windows may be born on Tim's viewed Space. If a host-only run cannot stay off his Spaces, defer it to meta rather than treating repair as permission. Apple/sandboxed apps do not inherit the launch token; use a nonsandboxed third-party app or built probe.
- Call yabai at `/Users/twaldin/Applications/Yabai.app/Contents/MacOS/yabai`; the `launchctl asuser` capture wrapper breaks its socket.
- `CanvasTest` is the only virtual screen. Book it with the sky-lead pane; the machine shepherd alone manages screens. Put it on its target Space before launch and leave other displays' Spaces unchanged while the guard runs.

## twaldin-work: host-only placement

- `yabai` and `betterdisplaycli` are on PATH (`/opt/homebrew/bin`). No Space map is set up; use a Space Tim isn't viewing and tell him which.
- When a hidden Space isn't enough, create at most one screen per pane and reuse it for every run: `betterdisplaycli create --type=VirtualScreen --virtualScreenName=Agent-<pane> --useResolutionList=on --resolutionList=1512x982 --virtualScreenHiDPI=on`, then `betterdisplaycli set --name=Agent-<pane> --connected=on --placement=<X>x<Y>`. When the pane's work is finished, discard it with `betterdisplaycli discard --name=Agent-<pane>`.
