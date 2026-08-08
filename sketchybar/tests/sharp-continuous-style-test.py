#!/usr/bin/env python3
import ast
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1]).resolve()

def fail(message):
    raise SystemExit(message)

def runtime_lua_files():
    values = [path for path in root.glob("*.lua") if path.is_file()]
    for directory in (root / "items", root / "lib"):
        values.extend(path for path in directory.rglob("*.lua") if path.is_file())
    return sorted(set(values))

for path in runtime_lua_files() + [root / "sketchybarrc"]:
    text = path.read_text()
    for match in re.finditer(r"corner_radius\s*=\s*(-?\d+(?:\.\d+)?)", text):
        if float(match.group(1)) != 0:
            fail(f"Rounded SketchyBar surface remains: {path.relative_to(root)}")
    for match in re.finditer(r"blur_radius\s*=\s*(-?\d+(?:\.\d+)?)", text):
        if float(match.group(1)) != 0:
            fail(f"SketchyBar blur remains: {path.relative_to(root)}")
    if re.search(r"shadow\s*=\s*true", text):
        fail(f"Enabled SketchyBar shadow remains: {path.relative_to(root)}")
    for match in re.finditer(r"shadow\s*=\s*{([^{}]*)}", text, re.DOTALL):
        if not re.search(r"drawing\s*=\s*false", match.group(1)):
            fail(f"SketchyBar shadow table does not fail closed: {path.relative_to(root)}")

colors_text = (root / "colors.lua").read_text()
required_colors = {
    "right_event": 0x242932,
    "right_date": 0x303744,
    "right_system": 0x3B4352,
    "right_hover": 0x4C566A,
    "primary": 0xE7EAED,
    "muted": 0xC5CBD3,
    "accent": 0xD8DEE9,
    "warning": 0xFFCC80,
    "critical": 0xFFC1C1,
}
for name, value in required_colors.items():
    literal = f"{name} = 0xff{value:06x}"
    if literal not in colors_text:
        fail(f"Missing continuous palette token: {literal}")
if "M.hover = M.right_hover" not in colors_text:
    fail("Hover alias is not pinned to the continuous palette")

def channel(value):
    value /= 255
    return value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4

def luminance(value):
    return 0.2126 * channel((value >> 16) & 0xFF) + 0.7152 * channel((value >> 8) & 0xFF) + 0.0722 * channel(value & 0xFF)

def contrast(first, second):
    low, high = sorted((luminance(first), luminance(second)))
    return (high + 0.05) / (low + 0.05)

for foreground_name in ("primary", "muted", "accent", "warning", "critical"):
    for background_name in ("right_event", "right_date", "right_system", "right_hover"):
        if contrast(required_colors[foreground_name], required_colors[background_name]) < 4.5:
            fail(f"Small foreground contrast below 4.5:1: {foreground_name} on {background_name}")

calendar = (root / "items/calendar.lua").read_text()
if "calendar.gap.next" in calendar or "calendar.gap.system" in calendar:
    fail("Calendar/system continuity still uses a spacer item")
for literal in (
    "color = colors.right_event",
    "color = colors.right_date",
    "border_width = 0",
    "idle_surface = colors.right_event",
    "idle_surface = colors.right_date",
    'width = "dynamic"',
    'icon_width = "dynamic"',
    "calendar_model.bounded_event_title",
):
    if literal not in calendar:
        fail(f"Missing sharp calendar contract: {literal}")

items_init = (root / "items/init.lua").read_text()
for literal in ("color = colors.right_system", "corner_radius = 0", "border_width = 0", '"release.probe"'):
    if literal not in items_init:
        fail(f"Missing sharp system contract: {literal}")

for name in ("audio.lua", "microphone.lua", "battery.lua", "connectivity.lua", "status.lua"):
    text = (root / "items" / name).read_text()
    if "settings.icon_width" in text:
        fail(f"System control icon is not centered in its 28-point cell: {name}")

hover = (root / "lib/hover.lua").read_text()
for literal in ("colors.hover", "function M.foreground", "colors.right_hover"):
    if literal not in hover:
        fail(f"Missing centralized hover contract: {literal}")
if "value(options.hover_border, colors.accent)" in hover:
    fail("Hover adds an accent outline")
popup = (root / "lib/popup.lua").read_text()
if "hover.set_popup_open(host, is_open)" not in popup or "state.popup_open" not in hover:
    fail("Open popup host does not use the centralized active continuous reducer")
if "background = { color = colors.hover }" not in (root / "items/workspaces.lua").read_text():
    fail("Workspace updates do not preserve active hover fill")

runtime_probe = root / "tests/calendar-bar-runtime-shape.py"
tree = ast.parse(runtime_probe.read_text(), filename=str(runtime_probe))
query_names = None
for node in tree.body:
    if isinstance(node, ast.Assign) and any(isinstance(target, ast.Name) and target.id == "QUERIED_ITEMS" for target in node.targets):
        query_names = ast.literal_eval(node.value)
expected_queries = (
    "calendar",
    "calendar.event.bracket",
    "calendar.date.bracket",
    "system.bracket",
    "release.probe",
)
if query_names != expected_queries:
    fail("Runtime probe query allow-list changed")
for node in ast.walk(tree):
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "query":
        if len(node.args) != 1 or not isinstance(node.args[0], ast.Name) or node.args[0].id != "name":
            fail("Runtime probe bypasses its structural query allow-list")

smoke = (root / "scripts/smoke-config.sh").read_text()
live_gate = 'if [ "$require_live_shape" = 1 ]; then'
if smoke.count(live_gate) != 1 or smoke.index(live_gate) > smoke.index("--query"):
    fail("Offline smoke can query a stale live configuration")
if "--query" in smoke[:smoke.index(live_gate)]:
    fail("Offline smoke performs a live query before the explicit gate")
smoke_queries = tuple(re.findall(r"--query ([a-z.]+)", smoke))
if smoke_queries != (
    "calendar.event.bracket", "calendar.date.bracket", "system.bracket",
    "calendar", "release.probe",
):
    fail("Smoke live query allow-list or order changed")

print("SketchyBar sharp continuous style contract passed")
