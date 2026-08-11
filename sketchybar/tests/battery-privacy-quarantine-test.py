#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ITEM = (ROOT / "items/battery.lua").read_text()
PYTHON_HELPER = (ROOT / "scripts/battery-state.py").read_text()
SWIFT_HELPER = (ROOT / "scripts/battery-state.swift").read_text()
STATUS = (ROOT / "items/status.lua").read_text()


def check(condition, message):
    if not condition:
        raise SystemExit(message)


check('settings.config_dir .. "/scripts/battery-state.py"' in ITEM,
      "battery item does not use the closed helper")
check('popup.field(item, token, "condition", "Condition"' in ITEM,
      "reviewed public battery condition is missing")
check('popup.field(item, token, "cycles", "Cycles"' in ITEM,
      "reviewed public battery cycle count is missing")
check('popup.field(item, token, "low_power", "Low Power Mode"' in ITEM,
      "reviewed ProcessInfo Low Power state is missing")

for forbidden in (
    'popup.graph(item, token, "charge_graph"',
    'popup.section(item, token, "history_heading"',
    'popup.field(item, token, "power", "Power"',
    'popup.field(item, token, "temperature", "Temperature"',
    'popup.field(item, token, "electrical", "Voltage / current"',
    'state.health and (tostring(state.health) .. "%")',
):
    check(forbidden not in ITEM, "unsafe battery popup surface remains: %s" % forbidden)

for forbidden in (
    "kIOPSNameKey", "kIOPSPowerSourceIDKey", "kIOPSTransportTypeKey",
    "kIOPSVendorIDKey", "kIOPSProductIDKey", "kIOPSVendorDataKey",
    "kIOPSHardwareSerialNumberKey", "kIOPSVoltageKey", "kIOPSCurrentKey",
    "kIOPSTemperatureKey", "kIOPSDesignCapacityKey", "kIOPSNominalCapacityKey",
    "kIOPSPowerAdapterWattsKey", "kIOPSPowerAdapterCurrentKey",
    "IOPSCopyExternalPowerAdapterDetails", "IORegistryEntry", "IOServiceMatching",
):
    check(forbidden not in SWIFT_HELPER,
          "unreviewed battery field or API is present: %s" % forbidden)

for forbidden in ("plistlib", '"/usr/sbin/ioreg"', "AppleSmartBattery"):
    check(forbidden not in PYTHON_HELPER,
          "unsafe Python battery query remains: %s" % forbidden)

check('let schema = "battery_state_v1"' in SWIFT_HELPER,
      "closed battery schema is missing")
check('encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]' in SWIFT_HELPER,
      "battery helper output is not deterministic")
check('TOP_LEVEL_KEYS = {' in PYTHON_HELPER and 'set(value) != TOP_LEVEL_KEYS' in PYTHON_HELPER,
      "Python boundary does not reject extra output keys")
check('"/System/Applications/System Settings.app"' in ITEM,
      "battery action is not sealed to the main System Settings application")
check("settings.links.battery" not in ITEM,
      "battery action retains a pane URL")

for value in ("BATTERY_PERCENTAGE", "BATTERY_STATE", "BATTERY_REMAINING", "BATTERY_TIME_TO_FULL"):
    check(value not in STATUS, "combined status retains battery data")

print("Battery public detail privacy surface passed")
