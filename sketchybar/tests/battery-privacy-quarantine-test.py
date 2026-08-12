#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ITEM = (ROOT / "items/battery.lua").read_text()
PYTHON_HELPER = (ROOT / "scripts/battery-state.py").read_text()
SWIFT_HELPER = (ROOT / "scripts/battery-state.swift").read_text()
HARDWARE_PYTHON = (ROOT / "scripts/battery-hardware-state.py").read_text()
HARDWARE_SWIFT = (ROOT / "scripts/battery-hardware.swift").read_text()
STATUS = (ROOT / "items/status.lua").read_text()


def check(condition, message):
    if not condition:
        raise SystemExit(message)


check('settings.config_dir .. "/scripts/battery-state.py"' in ITEM,
      "battery item does not use the closed public helper")
check('settings.config_dir .. "/scripts/battery-hardware-state.py"' in ITEM,
      "battery item does not use the closed hardware helper")
check('popup.field(item, token, "condition", "Condition"' in ITEM,
      "reviewed public battery condition is missing")
check('popup.field(item, token, "cycles", "Cycles"' in ITEM,
      "reviewed reconciled battery cycle count is missing")
check('popup.field(item, token, "low_power", "Low Power Mode"' in ITEM,
      "reviewed ProcessInfo Low Power state is missing")

hardware_start = ITEM.index("local function build_hardware(token)")
hardware_end = ITEM.index("\nlocal function open_system_settings", hardware_start)
hardware_build = ITEM[hardware_start:hardware_end]
for required in (
    '"Raw current capacity"', '"Raw maximum capacity"',
    '"Raw design capacity"', '"Nominal capacity"',
    '"Raw maximum / design"', '"Signed battery current"',
    '"Battery voltage"', '"Battery temperature"',
    '"Adapter watts"', '"Adapter current"',
):
    check(required in hardware_build,
          "reviewed battery hardware label is missing: " + required)
for forbidden in (
    'popup.graph(item, token, "charge_graph"',
    'popup.section(item, token, "history_heading"',
    'popup.field(item, token, "health", "Health"',
    'popup.field(item, token, "maximum_capacity"',
    '"Hardware cycle count"', '"Serial number"', '"Manufacturer"',
    '"Battery model"', '"Battery name"', '"Process"',
):
    check(forbidden not in ITEM,
          "unreviewed battery popup concept remains: " + forbidden)
for forbidden in ("popup.link", "popup.choice", "popup.action", "popup.slider", "shell.exec"):
    check(forbidden not in hardware_build,
          "battery hardware detail exposes an operation: " + forbidden)

# The public helper remains limited to documented IOPowerSources and IOPM facts.
for forbidden in (
    "kIOPSNameKey", "kIOPSPowerSourceIDKey", "kIOPSTransportTypeKey",
    "kIOPSVendorIDKey", "kIOPSProductIDKey", "kIOPSVendorDataKey",
    "kIOPSHardwareSerialNumberKey", "kIOPSVoltageKey", "kIOPSCurrentKey",
    "kIOPSTemperatureKey", "kIOPSDesignCapacityKey", "kIOPSNominalCapacityKey",
    "kIOPSPowerAdapterWattsKey", "kIOPSPowerAdapterCurrentKey",
    "IOPSCopyExternalPowerAdapterDetails", "IORegistryEntry", "IOServiceMatching",
):
    check(forbidden not in SWIFT_HELPER,
          "unreviewed public battery field or API is present: " + forbidden)

# The separate popup-only helper has a fixed read allowlist and no identity surface.
for required in (
    'IOServiceMatching("AppleSmartBattery")',
    "IORegistryEntryCreateCFProperty", '"AppleRawCurrentCapacity"',
    '"AppleRawMaxCapacity"', '"DesignCapacity"', '"NominalChargeCapacity"',
    '"CycleCount"', '"Amperage"', '"Voltage"', '"Temperature"',
    "IOPSCopyExternalPowerAdapterDetails", "kIOPSPowerAdapterWattsKey",
    "kIOPSPowerAdapterCurrentKey",
):
    check(required in HARDWARE_SWIFT,
          "reviewed battery hardware read is missing: " + required)
for forbidden in (
    "SerialNumber", "Manufacturer", "Product", "FamilyCode", "AdapterID",
    "IORegistryEntryGetPath", "IORegistryEntryCreateCFProperties",
    "IORegistryEntrySetCFProperty", "IORegistryEntrySetCFProperties",
    "IOServiceOpen", "IOConnectCall", "ChargerData", "NotChargingReason",
    "Process(", "NSTask", "TB1T", "TB2T", "SMC.shared",
):
    check(forbidden not in HARDWARE_SWIFT,
          "battery hardware helper exposes an unreviewed surface: " + forbidden)

for source, label in (
    (PYTHON_HELPER, "public"), (HARDWARE_PYTHON, "hardware"),
):
    for forbidden in ("plistlib", '"/usr/sbin/ioreg"'):
        check(forbidden not in source,
              "unsafe %s battery Python query remains: %s" % (label, forbidden))
check("AppleSmartBattery" not in PYTHON_HELPER,
      "public Python battery helper contains a private query")

check('let schema = "battery_state_v1"' in SWIFT_HELPER,
      "closed public battery schema is missing")
check('encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]' in SWIFT_HELPER,
      "public battery helper output is not deterministic")
check('TOP_LEVEL_KEYS = {' in PYTHON_HELPER and 'set(value) != TOP_LEVEL_KEYS' in PYTHON_HELPER,
      "public Python boundary does not reject extra output keys")
check('TOP_LEVEL_KEYS = {' in HARDWARE_PYTHON and 'set(value) != TOP_LEVEL_KEYS' in HARDWARE_PYTHON,
      "hardware Python boundary does not reject extra output keys")
check('"/System/Applications/System Settings.app"' in ITEM,
      "battery action is not sealed to the main System Settings application")
check("settings.links.battery" not in ITEM,
      "battery action retains a pane URL")

for value in ("BATTERY_PERCENTAGE", "BATTERY_STATE", "BATTERY_REMAINING", "BATTERY_TIME_TO_FULL"):
    check(value not in STATUS, "combined status retains battery data")

print("Battery public and hardware detail privacy surfaces passed")
