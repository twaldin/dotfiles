#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
BATTERY = (ROOT / "items/battery.lua").read_text()
STATUS = (ROOT / "items/status.lua").read_text()


def check(value: bool, message: str) -> None:
    if not value:
        raise SystemExit(message)


def battery_is_quarantined(source: str) -> bool:
    forbidden = (
        "lib.shell", "sbar.exec", "system_stats", "power_source_change",
        "system_profiler", "SPPowerDataType", "x-apple.systempreferences",
        "BATTERY_PERCENTAGE", "BATTERY_STATE", "BATTERY_REMAINING",
        "BATTERY_TIME_TO_FULL", "right_click", "left_click", "click_script",
        "mouse.clicked", "shell.open",
    )
    required = (
        "State  Unavailable",
        "Charge / source  Public v2 pending",
        "Time estimates  Public v2 pending",
        "Health / capacity  Detail pending",
        "Cycles / electrical  Detail pending",
        "Adapter  Detail provider pending",
        "Low Power  Unavailable",
        "Energy modes  Manage in Settings",
        "Charge controls  Settings only",
        "Usage history  Settings only",
        "Keep Awake  Public provider pending",
        "Sleep actions  Apple menu / Settings",
        "Lock state / action  Unavailable",
        "Settings  Sealed launcher unavailable",
    )
    strings = re.findall(r'string = "([^"]*)"', source)
    return (
        not any(value in source for value in forbidden)
        and all(value in source for value in required)
        and all(len(value) <= 38 for value in strings)
    )


def status_is_quarantined(source: str) -> bool:
    forbidden = (
        "battery", "BATTERY_PERCENTAGE", "BATTERY_STATE", "BATTERY_REMAINING",
        "BATTERY_TIME_TO_FULL", "power_source_change", "BAT %", "BAT  ",
    )
    return not any(value.lower() in source.lower() for value in forbidden)


check(battery_is_quarantined(BATTERY), "battery privacy quarantine is incomplete")
check(status_is_quarantined(STATUS), "combined status retains battery data")
check(not status_is_quarantined(STATUS + "\nlocal battery = env.BATTERY_STATE"),
      "status battery-state mutation was not detected")
check(not status_is_quarantined(STATUS + "\n-- power_source_change BATTERY_REMAINING"),
      "status battery-time/event mutation was not detected")
check(not status_is_quarantined(STATUS + "\n-- BAT  50%"),
      "status battery-render mutation was not detected")
check(not battery_is_quarantined(BATTERY + "\n-- system_profiler"),
      "live detail mutation was not detected")
check(not battery_is_quarantined(BATTERY.replace("Low Power  Unavailable", "Low Power  Off")),
      "false Low Power mutation was not detected")
check(not battery_is_quarantined(BATTERY + "\nsbar.exec({ \"/usr/bin/true\" })"),
      "sleep writer mutation was not detected")
print("Battery privacy quarantine source test passed")
