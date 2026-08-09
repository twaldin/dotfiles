# SketchyBar operations

The Home deployment uses SketchyBar 2.24.0 from `/opt/homebrew/bin/sketchybar` and Lua 5.5.1. The configuration is `/Users/twaldin/.config/sketchybar`.

Calendar surfaces are static. They show the clock and next-event status, but they do not open Calendar, meeting URLs, or the removed native panel.

## Replace the existing Homebrew service

Stop the existing `homebrew.mxcl.sketchybar` job before installing this plist. Never load a second label.

## Start

```sh
/bin/launchctl bootstrap gui/$(/usr/bin/id -u) ~/Library/LaunchAgents/homebrew.mxcl.sketchybar.plist
```

## Reload

```sh
/opt/homebrew/bin/sketchybar --reload
```

## Stop

```sh
/bin/launchctl bootout gui/$(/usr/bin/id -u)/homebrew.mxcl.sketchybar
```

Logs are private files in `~/Library/Logs/sketchybar`.
