#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONNECTIVITY = (ROOT / "items/connectivity.lua").read_text()
STATUS = (ROOT / "items/status.lua").read_text()
ITEM_SOURCES = "\n".join(path.read_text() for path in sorted((ROOT / "items").glob("*.lua")))


def check(value: bool, message: str) -> None:
    if not value:
        raise SystemExit(message)


def connectivity_is_quarantined(source: str) -> bool:
    forbidden = (
        "lib.network", "lib.shell", "sbar.exec", "blueutil", "system_profiler",
        "network-sample", "vpn-state", "x-apple.systempreferences", ".ssid",
        ".address", ".interface", ".router", "device.name", "device.address",
    )
    required = (
        "Current  Native privacy view",
        "Known  Native privacy view",
        "Available  Native privacy view",
        "Hidden join  Native privacy view",
        "Power / Disconnect  No safe rollback",
        "Paired  Native privacy view",
        "Connected  Native privacy view",
        "New devices  Native privacy view",
        "Power / Unpair  No safe rollback",
        "Settings  Sealed launcher unavailable",
    )
    return not any(value in source for value in forbidden) and all(value in source for value in required)


def status_is_quarantined(source: str) -> bool:
    forbidden = (
        "lib.network", "top-processes.sh", "vpn-state.sh", "refresh_slow",
        "active.processes", "network.current", "processes[index]",
    )
    required = (
        "NET  Unavailable until public provider",
        "Unavailable — no approved public units",
        "VPN identity  Native privacy view",
    )
    allowed_exec = 'settings.config_dir .. "/scripts/data-disk.sh"'
    return (
        not any(value in source for value in forbidden)
        and all(value in source for value in required)
        and source.count("shell.exec") == 1
        and allowed_exec in source
    )


check(connectivity_is_quarantined(CONNECTIVITY), "connectivity privacy quarantine is incomplete")
check(status_is_quarantined(STATUS), "status privacy quarantine is incomplete")
check(not connectivity_is_quarantined(CONNECTIVITY + "\n-- system_profiler"),
      "connectivity mutation was not detected")
check(not connectivity_is_quarantined(CONNECTIVITY.replace(
    "Known  Native privacy view", "Known networks")),
    "missing Wi-Fi surface mutation was not detected")
check(not status_is_quarantined(STATUS + "\n-- top-processes.sh"),
      "status process mutation was not detected")
check(not status_is_quarantined(STATUS.replace(
    "Unavailable — no approved public units", "Unavailable")),
    "status reason mutation was not detected")
for forbidden in ("require(\"lib.network\")", "top-processes.sh", "vpn-state.sh",
                  "network-sample.sh", "SPBluetoothDataType", "blueutil"):
    check(forbidden not in ITEM_SOURCES, f"production item still references {forbidden}")
for forbidden_action in ("right_click", "left_click", "click_script", "shell.open",
                         "mouse.clicked"):
    check(forbidden_action not in CONNECTIVITY,
          f"quarantined connectivity still registers {forbidden_action}")
for retired in ("lib/network.lua", "scripts/network-sample.sh", "scripts/top-processes.sh",
                "scripts/vpn-state.sh"):
    check(not (ROOT / retired).exists(), f"retired privacy path remains: {retired}")
print("Privacy quarantine source test passed")
