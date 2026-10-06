---
name: mac-gui
description: Launch, place, capture or show GUI windows on Tim's Macs (Spaces, yabai, BetterDisplay, screencapture). Use before opening any app window for testing, moving or capturing one, or when Tim asks to see one.
---

Test windows never go on the Space Tim is using. Check which host you are on (`hostname`), then follow its section.

## Every Mac

- Launch with `open -g` (no focus) and never focus a test window.
- Move windows by id, never by rule. A new window opens on the Space Tim is viewing, and no yabai rule can place it on another display's Space. Park it on an unviewed Space, check that `yabai -m query --windows --window <id>` finds it, then run `yabai -m window <id> --space <n>`. Without an id, yabai moves Tim's focused window.
- If you need a yabai rule as a backstop, scope it to the window you launched: match its title, or add the rule just before launch and remove it after. A rule on `app="Google Chrome"` alone also catches Tim's own windows.
- Capture a window with `screencapture -x -o -l <windowid>`. A window on a Space nobody views keeps rendering, but macOS reports it as occluded, and apps that honor that throttle themselves: Chromium/Electron (launch with `--disable-backgrounding-occluded-windows`), WebKit views, GLFW with vsync (60 fps cap) and unfocused Roblox Studio (about 15 fps). Runs whose results depend on frame timing check their own cadence before trusting a result.
- Every virtual display costs WindowServer work: each one present lets display changes start a ColorSync loop that stalls the desktop every few seconds until all virtual displays are gone. Never create one casually.
- `betterdisplaycli discard` always takes `--name=<screen>`. A bare `discard` destroys every virtual screen without asking.
- Find a screen's Space with `betterdisplaycli get --name=<screen> --identifiers` (its `displayID`), then `yabai -m query --displays` for that display's first Space.
- When Tim asks to see something, move the window to a Space he can view (virtual screens are headless). Use the Space he names. Otherwise pick an empty Space on the built-in display, move the window there and tell him its number. Never use the Space he is focused on, and ask only when no Space is empty. A sticky window (`is-sticky=true`, such as Superwhisper) shows up on every Space, so a Space holding only that is still empty. Afterwards the window is his; leave it there unless he says otherwise.
- Quit GUI apps you opened for testing (browsers, Blender, Prism Launcher, game clients, simulators) when the batch is done.

## twaldin-home

- Agent Spaces on the built-in display: 6 roblox, 7 canvas, 8 Minecraft labs. Tim keeps to Spaces 1-4. Spaces 6-8 float, so a window keeps its size and re-tiles nothing.
- Launch every GUI test app through `gui-launch --space <6|7|8|display:CanvasTest> [--guard-seconds N] -- <open args | executable>` (`gui-launch --help`). It opens the app with `open -g`. Until the guard ends, it re-activates Tim's app whenever the launched process tree takes focus, and moves each tree window to your Space by id. Then it exits 1 if a tree window is on Spaces 1-4, or if Tim's frontmost app or active display changed. To guard a whole session, set `--guard-seconds` to its length and send SIGTERM at teardown. It never quits what it launched.
- `gui-launch` reverts; it cannot prevent. macOS lets an app activate itself (a reverted probe held focus 57 ms, 2026-10-06), and it opens a new window on the Space Tim is viewing. When the thief's window sat on another display, the active display can stay there after the revert. The check reports that, and a click on his display clears it. Only a window born on another display that never activates stays off his screen entirely. Once the dummy HDMI display is connected, it is the zero-flash target.
- Call yabai at `/Users/twaldin/Applications/Yabai.app/Contents/MacOS/yabai`. There is no `yabai` on PATH, and the `launchctl asuser` wrapper needed for `screencapture` breaks yabai's socket.
- The only virtual screen is `CanvasTest`. Use it for measured runs pinned to it, and for work that fails on a hidden Space. Book it with the sky-lead pane. Never create, connect, disconnect or discard a screen yourself: send the request to the machine shepherd.

## twaldin-work

- `yabai` and `betterdisplaycli` are on PATH (`/opt/homebrew/bin`). No Space map is set up; use a Space Tim isn't viewing and tell him which.
- When a hidden Space isn't enough, create at most one screen per pane and reuse it for every run: `betterdisplaycli create --type=VirtualScreen --virtualScreenName=Agent-<pane> --useResolutionList=on --resolutionList=1512x982 --virtualScreenHiDPI=on`, then `betterdisplaycli set --name=Agent-<pane> --connected=on --placement=<X>x<Y>`. When the pane's work is finished, discard it with `betterdisplaycli discard --name=Agent-<pane>`.
