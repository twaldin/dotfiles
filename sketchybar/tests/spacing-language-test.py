#!/usr/bin/env python3
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
settings = (ROOT / "settings.lua").read_text()
required_tokens = "item = 4, group = 4, segment = 4, edge = 8, icon_label = 2"
if settings.count(required_tokens) != 1:
    raise SystemExit("shared spacing token set changed")
controls = ["connectivity.lua", "audio.lua", "microphone.lua", "display.lua"]
for name in controls:
    source = (ROOT / "items" / name).read_text()
    if source.count("padding_left = settings.spacing.item / 2") < 1 or source.count("padding_right = settings.spacing.item / 2") < 1:
        raise SystemExit(f"{name} lacks symmetric shared item padding")
battery = (ROOT / "items/battery.lua").read_text()
status = (ROOT / "items/status.lua").read_text()
spaces = (ROOT / "items/workspaces.lua").read_text()
front = (ROOT / "items/front_window.lua").read_text()
calendar = (ROOT / "items/calendar.lua").read_text()
if any(token not in battery for token in ("padding_left = settings.spacing.item / 2", "padding_right = settings.spacing.item / 2")):
    raise SystemExit("battery lacks symmetric shared item padding")
if status.count("settings.spacing.item / 2") < 2 or status.count("settings.spacing.icon_label / 2") < 2:
    raise SystemExit("stats do not separate outer and icon/value spacing")
if spaces.count("settings.spacing.item / 2") < 2 or "(24 + settings.spacing.item) * count" not in spaces:
    raise SystemExit("workspace visual and modeled gutters differ")
if front.count("settings.spacing.group / 2") < 2:
    raise SystemExit("front-window group boundary is asymmetric")
if "content_gap = settings.spacing.item" not in (ROOT / "lib/calendar_bar_layout.lua").read_text():
    raise SystemExit("Calendar text segments do not use the shared item gap")
if calendar.count("padding_left = 0") < 1 or calendar.count("padding_right = 0") < 1:
    raise SystemExit("Calendar retains an exceptional exterior gap")
if "calendar_date_width = 148" not in settings:
    raise SystemExit("date surface no longer preserves the shared eight-point content edge")
print("Shared item, group, segment, edge, and icon/value spacing contract passed")
