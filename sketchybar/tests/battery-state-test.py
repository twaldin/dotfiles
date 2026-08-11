#!/usr/bin/env python3
import contextlib
import copy
import importlib.util
import io
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
PYTHON_SOURCE = ROOT / "scripts/battery-state.py"
SWIFT_SOURCE = ROOT / "scripts/battery-state.swift"
spec = importlib.util.spec_from_file_location("battery_state", PYTHON_SOURCE)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def check(condition, message):
    if not condition:
        raise SystemExit(message)


PYTHON_TEXT = PYTHON_SOURCE.read_text()
for required in (
    'RUNTIME_PARENT_INPUT = os.environ.get("TMPDIR", "")',
    'os.path.realpath(RUNTIME_PARENT_INPUT)',
    'stat.S_IMODE(parent.st_mode) != 0o700',
):
    check(required in PYTHON_TEXT, "battery per-user TMPDIR contract is missing: " + required)
check('/tmp/sketchybar-battery-state-' not in PYTHON_TEXT,
      "battery helper cache must not use the shared temporary namespace")


with tempfile.TemporaryDirectory(prefix="battery-tmpdir-test.") as raw:
    base = Path(raw).resolve()
    base.chmod(0o700)
    original_parent, original_cache = module.RUNTIME_PARENT, module.CACHE_ROOT
    try:
        module.RUNTIME_PARENT = str(base)
        module.CACHE_ROOT = base / ("sketchybar-battery-state-" + str(os.getuid()))
        cache = module._secure_cache_directory()
        check(cache.is_dir() and stat.S_IMODE(cache.stat().st_mode) == 0o700,
              "valid per-user TMPDIR must create a private battery cache")
        digest = hashlib.sha256(PYTHON_SOURCE.with_suffix(".swift").read_bytes()).hexdigest()
        tampered = cache / ("battery-state-" + digest)
        tampered.write_bytes(b"tampered")
        tampered.chmod(0o755)
        try:
            module.compiled_helper()
            check(False, "weak cached battery helper was reused")
        except OSError:
            pass

        weak = base / "weak"
        weak.mkdir(mode=0o755)
        weak.chmod(0o755)
        module.RUNTIME_PARENT = str(weak)
        module.CACHE_ROOT = weak / ("sketchybar-battery-state-" + str(os.getuid()))
        try:
            module._secure_cache_directory()
            check(False, "weak battery TMPDIR parent was accepted")
        except OSError:
            pass
    finally:
        module.RUNTIME_PARENT, module.CACHE_ROOT = original_parent, original_cache

helper_python = [sys.executable] + (["-O"] if not __debug__ else [])
for environment in (
    {key: value for key, value in os.environ.items() if key != "TMPDIR"},
    dict(os.environ, TMPDIR="relative-battery-tmp"),
):
    rejected = subprocess.run(
        helper_python + [str(PYTHON_SOURCE)], env=environment,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=10)
    check(rejected.returncode != 0 and rejected.stdout == "" and rejected.stderr == "",
          "unsafe battery TMPDIR must fail silently")


def compile_and_test_swift():
    with tempfile.TemporaryDirectory(prefix="battery-state-test-") as directory:
        directory = Path(directory)
        common = [
            "/usr/bin/xcrun", "swiftc", "-parse-as-library", "-warnings-as-errors",
            "-D", "BATTERY_STATE_TESTING", str(SWIFT_SOURCE), "-framework", "IOKit",
        ]
        for name, optimization in (("debug", []), ("optimized", ["-O"])):
            binary = directory / name
            result = subprocess.run(
                common + optimization + ["-o", str(binary)],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            check(result.returncode == 0, "Swift battery helper %s build failed" % name)
            result = subprocess.run(
                [str(binary), "--self-test"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            check(result.returncode == 0 and not result.stdout,
                  "Swift battery helper %s synthetic self-test failed" % name)

        release = directory / "release"
        result = subprocess.run(
            [
                "/usr/bin/xcrun", "swiftc", "-parse-as-library", "-O",
                "-warnings-as-errors", str(SWIFT_SOURCE), "-framework", "IOKit",
                "-o", str(release),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        check(result.returncode == 0, "Swift battery helper release build failed")


def document():
    return {
        "schema": "battery_state_v1",
        "inventory": "present",
        "percent": {"state": "value", "value": 50.0},
        "source": "ac",
        "charge": "charging",
        "time": {"state": "minutes", "minutes": 30},
        "health": "good",
        "condition": "no_reported_condition",
        "cycles": {"state": "value", "value": 42},
        "low_power": "on",
    }


def execute(payload, returncode=0):
    encoded = json.dumps(payload).encode("utf-8") if payload is not None else b""
    original = module.subprocess.run
    module.subprocess.run = lambda *arguments, **keywords: SimpleNamespace(
        returncode=returncode,
        stdout=encoded,
    )
    stream = io.StringIO()
    try:
        with contextlib.redirect_stdout(stream):
            code = module.main("/synthetic/battery-state")
    finally:
        module.subprocess.run = original
    return code, json.loads(stream.getvalue()) if stream.getvalue() else None


compile_and_test_swift()

valid = document()
code, value = execute(valid)
check(code == 0 and value == valid, "valid public battery contract was rejected")

for inventory in ("absent", "ambiguous", "malformed", "unsupported_type_present", "unavailable"):
    candidate = document()
    candidate.update({
        "inventory": inventory,
        "percent": {"state": "unavailable", "value": None},
        "charge": "unavailable",
        "time": {"state": "unavailable", "minutes": None},
        "health": "unavailable",
        "condition": "unavailable",
        "cycles": {"state": "unavailable", "value": None},
    })
    code, value = execute(candidate)
    check(code == 0 and value["inventory"] == inventory,
          "battery %s inventory state was not preserved" % inventory)

candidate = document()
candidate["source"] = "offline"
check(execute(candidate)[0] == 1, "undocumented active-source value was accepted")
candidate = document()
candidate["percent"] = {"state": "value", "value": True}
check(execute(candidate)[0] == 1, "Boolean battery percentage was accepted")
candidate = document()
candidate["cycles"] = {"state": "value", "value": True}
check(execute(candidate)[0] == 1, "Boolean battery cycle count was accepted")
candidate = document()
candidate["time"] = {"state": "not_applicable", "minutes": None}
check(execute(candidate)[0] == 1, "contradictory charging time was accepted")
candidate = document()
candidate["hardware_name"] = "private"
check(execute(candidate)[0] == 1, "unexpected battery output key was accepted")
check(execute(None, returncode=1)[0] == 1, "battery helper failure was accepted")

python_source = PYTHON_SOURCE.read_text()
swift_source = SWIFT_SOURCE.read_text()
for forbidden in ("ioreg", "AppleSmartBattery", "IOServiceMatching", "IORegistryEntry"):
    check(forbidden not in python_source and forbidden not in swift_source,
          "private battery query remains: %s" % forbidden)
for required in (
    "IOPSCopyPowerSourcesInfo", "IOPSCopyPowerSourcesList",
    "IOPSGetPowerSourceDescription", "kIOPSTypeKey", "kIOPSCurrentCapacityKey",
    "kIOPSBatteryHealthConditionKey", "kIOPMACPowerKey", "kIOPMBatteryPowerKey",
    "kIOPMUPSPowerKey", "IOPMCopyBatteryInfo", "kIOBatteryCycleCountKey",
    "ProcessInfo.processInfo.isLowPowerModeEnabled",
):
    check(required in swift_source, "reviewed public battery read is missing: %s" % required)

item_source = (ROOT / "items/battery.lua").read_text()
ordered_rows = (
    'popup.section(item, token, "status_heading", "Status")',
    'popup.field(item, token, "inventory", "Internal battery"',
    'popup.field(item, token, "charge", "Charge"',
    'popup.field(item, token, "source", "Source"',
    'popup.field(item, token, "remaining"',
    'popup.field(item, token, "low_power", "Low Power Mode"',
    'popup.section(item, token, "health_heading", "Health")',
    'popup.field(item, token, "health", "Health"',
    'popup.field(item, token, "condition", "Condition"',
    'popup.field(item, token, "cycles", "Cycles"',
    'popup.section(item, token, "settings_heading", "Open")',
)
positions = [item_source.find(row) for row in ordered_rows]
check(all(position >= 0 for position in positions) and positions == sorted(positions),
      "battery popup hierarchy is incomplete or out of order")
check('output.schema == "battery_state_v1"' in item_source,
      "battery item does not require the closed public contract")
check('"/System/Applications/System Settings.app"' in item_source,
      "battery action does not target the main System Settings application")
check("settings.links.battery" not in item_source,
      "battery action retains a settings-pane claim")
print("Battery public state contract passed")
