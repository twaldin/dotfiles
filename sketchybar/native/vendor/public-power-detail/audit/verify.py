#!/usr/bin/env python3
"""Offline source, public-link, string, privacy, and no-live-exec gate."""
from __future__ import annotations

import argparse
import hashlib
import pathlib
import re
import subprocess
import sys

EXPECTED_AUDIT_SHA256 = "76274bc15a50f2e86673ea8bafc7145753f391117a8f9c60de7daf977816090b"
ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Sources" / "PublicPowerDetail"
TEST = ROOT / "Tests" / "PublicPowerDetailTests" / "PublicPowerDetailTests.swift"

# Pieces keep forbidden spellings out of the audit binary's own string table.
def joined(*parts: str) -> str:
    return "".join(parts)

SOURCE_DENY = [
    joined("IO", "Registry"),
    joined("io", "reg"),
    joined("system", "_profiler"),
    joined("sp", "power", "_"),
    joined("pm", "set"),
    joined("lib", "proc"),
    joined("KERN_", "PROC", "ARGS2"),
    joined("x-apple.", "systempreferences"),
    joined("/usr/bin/", "shortcuts"),
    joined("IOPM", "Sleep", "System"),
    joined("IOPM", "Assertion"),
    joined("NSSelector", "FromString"),
    joined("Selector", "("),
    joined("User", "Defaults"),
    joined("CF", "Preferences"),
    joined("dl", "open"),
    joined("dls", "ym"),
    joined("sudo"),
    joined("/bin/", "sh"),
    joined("/bin/", "zsh"),
]

IDENTITY_DENY = [
    joined("Serial", "Number"),
    joined("Vendor", " ID"),
    joined("Product", " ID"),
    joined("Transport", " Type"),
    joined("User", "Name"),
    joined("User", "ID"),
    joined("Source", "ID"),
    joined("Display", " Identifier"),
    joined("Process", "ID"),
    joined("time", "stamp"),
]

RUNTIME_GENERIC = {joined("dl", "open"), joined("dls", "ym")}
BINARY_DENY = [value for value in SOURCE_DENY + IDENTITY_DENY if value not in RUNTIME_GENERIC]
LINK_DENY = [value for value in SOURCE_DENY if value not in RUNTIME_GENERIC]
REQUIRED_LINK_SYMBOLS = [
    "IOPSCopyPowerSourcesInfo",
    "IOPSCopyPowerSourcesList",
    "IOPSGetPowerSourceDescription",
    "IOPSGetProvidingPowerSourceType",
    "IOPSGetTimeRemainingEstimate",
    "IOPSGetBatteryWarningLevel",
    "IOPSCopyExternalPowerAdapterDetails",
    "IOPMCopyBatteryInfo",
    "IOGetSystemLoadAdvisory",
    "IOCopySystemLoadAdvisoryDetailed",
    "IOPMFindPowerManagement",
    "IOPMGetAggressiveness",
    "IOPMSleepEnabled",
    "IOPMCopyScheduledPowerEvents",
    "CGGetOnlineDisplayList",
    "CGDisplayIsAsleep",
    "CGDisplayIsActive",
    "IOPSNotificationCreateRunLoopSource",
]

EXPECTED_POWER_KEYS = {
    "Type", "Is Present", "Current Capacity", "Max Capacity",
    "Power Source State", "Is Charging", "Is Charged",
    "Is Finishing Charge", "Time to Empty", "Time to Full Charge",
    "BatteryHealth", "BatteryHealthCondition", "Internal Failure",
    "BatteryFailureModes", "DesignCapacity", "NominalCapacity",
    "Max Error", "Voltage", "Current", "Temperature",
}


def fail(message: str) -> None:
    print(f"audit: fail: {message}", file=sys.stderr)
    raise SystemExit(1)


def source_text() -> str:
    files = sorted(SOURCE.glob("*.swift"))
    if not files:
        fail("no Swift source")
    return "\n".join(path.read_text(encoding="utf-8") for path in files)


def verify_binding_audit(path: pathlib.Path) -> None:
    if not path.is_file():
        fail("binding audit is missing")
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != EXPECTED_AUDIT_SHA256:
        fail("binding audit digest mismatch")


def verify_source() -> None:
    text = source_text()
    lowered = text.lower()
    for value in SOURCE_DENY:
        if value.lower() in lowered:
            fail("forbidden production source token")
    for value in IDENTITY_DENY:
        if value.lower() in lowered:
            fail("identity-bearing production token")
    if "@main" in text:
        fail("production library has an executable entry point")
    if re.search(r"\bProcess\s*\(", text):
        fail("production process execution exists")
    if ".standardOutput" in text or ".standardError" in text:
        fail("production subprocess stream exists")
    if "perform(" in text or "performSelector" in text:
        fail("dynamic selector call exists")
    if "as? Bool" in text or "as? Int" in text or " as NSNumber" in text:
        fail("coercing Foundation bridge exists")
    if "CFGetTypeID" not in text or "CFNumberIsFloatType" not in text:
        fail("strict CF bridge proof is missing")
    if "case offOrUnsupported" not in text:
        fail("Low Power ambiguity enum is missing")
    if "notAttachedOrUnavailable" not in text:
        fail("adapter ambiguity sentinel is missing")
    if "dictionaries.count == 1" not in text:
        fail("cycle cardinality is not exact")
    if "current_active_value" not in text:
        fail("active timer meaning is missing")

    darwin = (SOURCE / "DarwinPublicBindings.swift").read_text(encoding="utf-8")
    keys = set(re.findall(r'case \.[A-Za-z]+: return "([^"]+)"', darwin))
    if keys != EXPECTED_POWER_KEYS:
        fail("power-source fixed key allowlist changed")
    if "watts:" not in darwin or 'key: "Watts"' not in darwin:
        fail("adapter public watts key is missing")

    contract = (SOURCE / "Contract.swift").read_text(encoding="utf-8")
    for prohibited_claim in [joined("battery", "Wattage"), joined("thermal", "Danger")]:
        if prohibited_claim.lower() in contract.lower():
            fail("unsupported output claim exists")


def verify_no_live_test_path() -> None:
    text = TEST.read_text(encoding="utf-8")
    live_constructors = [
        joined("Darwin", "PublicPowerBindings", "("),
        joined("Darwin", "SystemSettingsApplicationOpener", "("),
        joined("Darwin", "PublicPowerObservationBackend", "("),
    ]
    for value in live_constructors:
        if value in text:
            fail("synthetic test constructs a live adapter")
    if "FakeBindings" not in text or "FakeSettingsOpener" not in text:
        fail("synthetic injection proof is missing")


def command_output(argv: list[str]) -> bytes:
    completed = subprocess.run(argv, check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if completed.returncode != 0:
        fail("inspection tool failed")
    return completed.stdout


def verify_binary(binary: pathlib.Path) -> None:
    if not binary.is_file():
        fail("link audit binary is missing")
    undefined = command_output(["nm", "-u", str(binary)]).decode("utf-8", errors="replace")
    for symbol in REQUIRED_LINK_SYMBOLS:
        if symbol not in undefined:
            fail("required reviewed public link symbol is missing")
    for value in LINK_DENY:
        if value in undefined:
            fail("forbidden linked symbol exists")

    strings = command_output(["strings", str(binary)]).decode("utf-8", errors="replace").lower()
    for value in BINARY_DENY:
        if value.lower() in strings:
            fail("forbidden or identity-bearing production binary string exists")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binding-audit", type=pathlib.Path, required=True)
    parser.add_argument("--binary", type=pathlib.Path)
    args = parser.parse_args()
    verify_binding_audit(args.binding_audit)
    verify_source()
    verify_no_live_test_path()
    if args.binary is not None:
        verify_binary(args.binary)
    print("audit: pass")


if __name__ == "__main__":
    main()
