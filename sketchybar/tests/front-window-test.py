#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "items/front_window.lua").read_text()

required = (
    'require("lib.icons")', 'require("lib.window_pages")',
    'yabai-windows.sh", "current"', 'yabai-windows.sh", "all"',
    'focus-window.sh", tostring(id)', 'front_app_switched',
    'icon = { string = glyph or "", drawing = glyph ~= nil }',
    'background = { drawing = false',
)
if not all(value in SOURCE for value in required):
    raise SystemExit("front-window app and focus behavior is incomplete")
if 'local row_glyph = glyph or "󰖯"' not in SOURCE or 'drawing = true, string = row_glyph' not in SOURCE:
    raise SystemExit("window rows must keep one visible icon lane")
if SOURCE.count("idle_background = false") < 2:
    raise SystemExit("front-window idle background must stay hidden")
if SOURCE.count('app_name, title = "Desktop", ""') != 1:
    raise SystemExit("front-window Desktop fallback must be initialization-only")
refresh = SOURCE[SOURCE.index("local function refresh_title"):SOURCE.index("item:subscribe", SOURCE.index("local function refresh_title"))]
if 'app_name, title = "Desktop", ""' in refresh:
    raise SystemExit("front-window refresh causes Desktop flicker")
for forbidden in ("Native privacy view", "Provider unavailable", "idle_background = true"):
    if forbidden in SOURCE:
        raise SystemExit(f"front-window fallback remains: {forbidden}")
print("Front-window icon, focus, and idle-style source test passed")
