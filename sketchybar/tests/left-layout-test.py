#!/usr/bin/env python3
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
settings = (ROOT / "settings.lua").read_text()
front = (ROOT / "items/front_window.lua").read_text()
workspaces = (ROOT / "items/workspaces.lua").read_text()
items = (ROOT / "items/init.lua").read_text()
installer = (ROOT / "install-deps.sh").read_text()

required = (
    "M.spaces_width_limit = M.left_layout.limit",
    "M.left_layout.front_width - M.spacing.group",
    "(M.left_layout.control_width + M.spacing.item) * M.left_layout.control_count",
    "M.left_layout.battery_width - M.spacing.item",
)
if not all(value in settings for value in required) or "M.control_width = M.left_layout.control_width" not in settings or "M.battery_width = M.left_layout.battery_width" not in settings:
    raise SystemExit("left-island geometry is not derived from one budget")
if "settings.spaces_width_limit" not in workspaces or workspaces.count("settings.spacing.item / 2") < 2:
    raise SystemExit("workspace sizing does not use the derived width")
if "width = settings.battery_width" not in (ROOT / "items/battery.lua").read_text():
    raise SystemExit("battery width does not use the left-island budget")
if front.count("settings.left_layout.front_width") < 2:
    raise SystemExit("front-window creation and updates do not share the width budget")
if ("local function label_metrics(" not in front or front.count("label_metrics(") < 3
        or "math.floor(width / 7)" not in front):
    raise SystemExit("front-window label bound is not derived from the width budget")
combined = settings + front + workspaces
if "q_layout" in combined:
    raise SystemExit("inert q_layout state remains")
if 'require("items.media")' in items or "media-control" in installer:
    raise SystemExit("dead Media surface or dependency remains")
print("Left-island derived geometry and Media retirement passed")
