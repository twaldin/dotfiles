#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
FRONT = (ROOT / "items/front_window.lua").read_text()
SPACES = (ROOT / "items/workspaces.lua").read_text()


def check(value: bool, message: str) -> None:
    if not value:
        raise SystemExit(message)


def front_is_quarantined(source: str) -> bool:
    forbidden = (
        "lib.shell", "lib.icons", "lib.window_pages", "settings.paths.yabai",
        "yabai-windows.sh", "focus-window.sh", "front_app_switched", "sbar.exec",
        "exec_quiet", "popup.action", "popup.on_click", "mouse.clicked",
        "window.app", "window.title", "window.id", "has-focus",
    )
    required = (
        "App / title  Native privacy view", "Window list  Native privacy view",
        "Focus window  Provider unavailable", "Move / swap / resize  Unavailable",
        "Close / minimize / zoom  Unavailable", "Space / display actions  Unavailable",
    )
    strings = re.findall(r'string = "([^"]*)"', source)
    return (
        not any(value in source for value in forbidden)
        and all(value in source for value in required)
        and all(len(value) <= 38 for value in strings)
        and source.count("width = 100") == 1
    )


def spaces_are_quarantined(source: str) -> bool:
    forbidden = (
        "lib.shell", "lib.icons", "settings.paths.yabai", "yabai-windows.sh",
        "focus-space.sh", "sbar.exec", "mouse.clicked", "mouse.scrolled",
        "front_app_switched", "window.app", "window.title", "has-focus",
    )
    return (
        not any(value in source for value in forbidden)
        and "for index = 1, 9 do" in source
        and source.count("width = 24") == 2
        and "label = { drawing = false }" in source
        and 'item:subscribe("space_change"' in source
    )


check(front_is_quarantined(FRONT), "front-window privacy quarantine is incomplete")
check(spaces_are_quarantined(SPACES), "workspace privacy quarantine is incomplete")
check(not front_is_quarantined(FRONT + "\nsbar.exec({ \"yabai\" })"),
      "front-window command mutation was not detected")
check(not front_is_quarantined(FRONT.replace(
    "App / title  Native privacy view", "App / title  Private title")),
    "front-window identity mutation was not detected")
check(not spaces_are_quarantined(SPACES + "\nitem:subscribe(\"mouse.clicked\", function() end)"),
      "workspace action mutation was not detected")
check(not spaces_are_quarantined(SPACES + "\nlocal app = window.app"),
      "workspace app-identity mutation was not detected")
check(not spaces_are_quarantined(SPACES.replace("width = 24", "width = 44", 1)),
      "workspace geometry mutation was not detected")
print("Window and workspace privacy quarantine source test passed")
