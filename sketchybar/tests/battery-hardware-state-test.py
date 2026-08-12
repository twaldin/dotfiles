#!/usr/bin/python3
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import math
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[1]
PYTHON_SOURCE = ROOT / "scripts/battery-hardware-state.py"
SWIFT_SOURCE = ROOT / "scripts/battery-hardware.swift"
STATS_SOURCE_ROOT = Path("/private/tmp/stats-upstream")
STATS_COMMIT = "64a34fa34c29d71de19af0868475e23cef7aaf81"
STATS_READERS_SHA256 = "cc0da3c3231b093881dff78da8f702b52de988dcebce9a6c9b8cf2ae31029c1a"
spec = importlib.util.spec_from_file_location("battery_hardware_state", PYTHON_SOURCE)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def check(condition, message):
    if not condition:
        raise SystemExit(message)


def document():
    return {
        "schema": "battery_hardware_v1",
        "capacities": {
            "raw_current_mah": 4_000,
            "raw_maximum_mah": 8_000,
            "maximum_mah": 8_000,
            "design_mah": 10_000,
            "nominal_mah": 8_100,
            "maximum_to_design_ratio": 0.8,
        },
        "cycle_count": 42,
        "electrical": {
            "signed_current_ma": -1_250,
            "voltage_v": 12.345,
            "temperature_c": 30.25,
        },
        "adapter": {"watts": 96, "current_ma": 4_700},
    }


def execute(payload=None, returncode=0, raw=None):
    encoded = (raw if raw is not None else json.dumps(payload).encode("utf-8"))
    original_helper = module.compiled_helper
    original_run = module.subprocess.run
    original_argv = sys.argv
    module.compiled_helper = lambda: Path("/synthetic/battery-hardware")
    module.subprocess.run = lambda *arguments, **keywords: SimpleNamespace(
        returncode=returncode, stdout=encoded
    )
    sys.argv = [str(PYTHON_SOURCE)]
    stream = io.StringIO()
    try:
        with contextlib.redirect_stdout(stream):
            code = module.main()
    finally:
        sys.argv = original_argv
        module.compiled_helper = original_helper
        module.subprocess.run = original_run
    return code, json.loads(stream.getvalue()) if stream.getvalue() else None


def compile_and_test_swift():
    with tempfile.TemporaryDirectory(prefix="battery-hardware-swift-test.") as raw_directory:
        directory = Path(raw_directory)
        common = [
            "/usr/bin/xcrun", "swiftc", "-parse-as-library", "-warnings-as-errors",
            "-D", "BATTERY_HARDWARE_TESTING", str(SWIFT_SOURCE), "-framework", "IOKit",
        ]
        for name, optimization in (("normal", []), ("optimized", ["-O"])):
            binary = directory / name
            result = subprocess.run(
                common + optimization + ["-o", str(binary)],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            check(result.returncode == 0, "Swift battery hardware %s build failed" % name)
            result = subprocess.run(
                [str(binary), "--self-test"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            check(result.returncode == 0 and result.stdout == b"" and result.stderr == b"",
                  "Swift battery hardware %s self-test failed" % name)
            rejected = subprocess.run(
                [str(binary)],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            check(rejected.returncode == 64 and rejected.stdout == b"" and rejected.stderr == b"",
                  "Swift test binary accepted the production CLI")

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
        check(result.returncode == 0, "Swift battery hardware production build failed")
        rejected = subprocess.run(
            [str(release), "state"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        check(rejected.returncode == 64 and rejected.stdout == b"" and rejected.stderr == b"",
              "Swift battery hardware production CLI is not exact")
        live = subprocess.run(
            [str(release)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        check(live.returncode == 0 and live.stderr == b"" and len(live.stdout) <= 2049,
              "Swift battery hardware live read failed or was not bounded")
        try:
            live_value = json.loads(live.stdout)
        except (json.JSONDecodeError, UnicodeError):
            check(False, "Swift battery hardware live JSON was malformed")
        check(module.valid_contract(live_value), "Swift battery hardware live contract was invalid")
        return live_value, live.stdout


PYTHON_TEXT = PYTHON_SOURCE.read_text()
SWIFT_TEXT = SWIFT_SOURCE.read_text()

# The coordinator accepts only a real private per-user TMPDIR and a source-hash cache.
for required in (
    'RUNTIME_PARENT_INPUT = os.environ.get("TMPDIR", "")',
    "os.path.realpath(RUNTIME_PARENT_INPUT)",
    "stat.S_IMODE(parent.st_mode) != 0o700",
    "hashlib.sha256(SOURCE.read_bytes()).hexdigest()",
    '"battery-hardware-" + digest',
    '"DYLD_',
):
    if required == '"DYLD_':
        check(required not in PYTHON_TEXT, "hostile dynamic-loader environment was copied")
    else:
        check(required in PYTHON_TEXT, "battery hardware cache contract is missing: " + required)
check("/tmp/sketchybar-battery-hardware-" not in PYTHON_TEXT,
      "battery hardware cache uses the shared temporary namespace")
check("env=SAFE_ENV" in PYTHON_TEXT and "SAFE_ENV = {" in PYTHON_TEXT,
      "battery hardware subprocesses do not use a closed environment")

with tempfile.TemporaryDirectory(prefix="battery-hardware-tmpdir-test.") as raw_directory:
    base = Path(raw_directory).resolve()
    base.chmod(0o700)
    original_parent, original_cache = module.RUNTIME_PARENT, module.CACHE_ROOT
    try:
        module.RUNTIME_PARENT = str(base)
        module.CACHE_ROOT = base / ("sketchybar-battery-hardware-" + str(os.getuid()))
        cache = module._secure_cache_directory()
        check(cache.is_dir() and stat.S_IMODE(cache.stat().st_mode) == 0o700,
              "private TMPDIR did not create a private battery hardware cache")
        digest = hashlib.sha256(SWIFT_SOURCE.read_bytes()).hexdigest()
        tampered = cache / ("battery-hardware-" + digest)
        tampered.write_bytes(b"tampered")
        tampered.chmod(0o755)
        try:
            module.compiled_helper()
            check(False, "weak cached battery hardware helper was reused")
        except OSError:
            pass

        weak = base / "weak"
        weak.mkdir(mode=0o755)
        weak.chmod(0o755)
        module.RUNTIME_PARENT = str(weak)
        module.CACHE_ROOT = weak / ("sketchybar-battery-hardware-" + str(os.getuid()))
        try:
            module._secure_cache_directory()
            check(False, "weak battery hardware TMPDIR parent was accepted")
        except OSError:
            pass
    finally:
        module.RUNTIME_PARENT, module.CACHE_ROOT = original_parent, original_cache

helper_python = [sys.executable] + (["-O"] if not __debug__ else [])
for environment in (
    {key: value for key, value in os.environ.items() if key != "TMPDIR"},
    dict(os.environ, TMPDIR="relative-battery-hardware"),
):
    rejected = subprocess.run(
        helper_python + [str(PYTHON_SOURCE)],
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=10,
        check=False,
    )
    check(rejected.returncode == 1 and rejected.stdout == "" and rejected.stderr == "",
          "unsafe battery hardware TMPDIR did not fail silently")
rejected = subprocess.run(
    [str(PYTHON_SOURCE), "extra"],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    timeout=5,
    check=False,
)
check(rejected.returncode == 64 and rejected.stdout == "" and rejected.stderr == "",
      "battery hardware coordinator CLI is not exact and silent")

# The closed Python schema fails each field independently and rejects contradictions.
valid = document()
check(module.valid_contract(valid), "valid battery hardware contract was rejected")
code, value = execute(valid)
check(code == 0 and value == valid, "valid helper output was not preserved")

unavailable = document()
unavailable["capacities"] = {key: None for key in unavailable["capacities"]}
unavailable["cycle_count"] = None
unavailable["electrical"] = {key: None for key in unavailable["electrical"]}
unavailable["adapter"] = {key: None for key in unavailable["adapter"]}
check(module.valid_contract(unavailable), "all-unavailable closed contract was rejected")

mutations = []
for section, key in (
    ("capacities", "raw_current_mah"),
    ("capacities", "raw_maximum_mah"),
    ("capacities", "maximum_mah"),
    ("capacities", "design_mah"),
    ("capacities", "nominal_mah"),
    (None, "cycle_count"),
    ("electrical", "signed_current_ma"),
    ("adapter", "watts"),
    ("adapter", "current_ma"),
):
    candidate = document()
    (candidate if section is None else candidate[section])[key] = True
    mutations.append((candidate, "Boolean integer field was accepted: " + key))
for section, key, value in (
    ("capacities", "raw_current_mah", -1),
    ("capacities", "raw_maximum_mah", 0),
    ("capacities", "maximum_mah", 1_000_001),
    ("capacities", "design_mah", 1_000_001),
    ("capacities", "nominal_mah", 1.5),
    (None, "cycle_count", -1),
    ("electrical", "signed_current_ma", 1_000_001),
    ("electrical", "voltage_v", float("inf")),
    ("electrical", "temperature_c", float("nan")),
    ("adapter", "watts", 0),
    ("adapter", "current_ma", 100_001),
):
    candidate = document()
    (candidate if section is None else candidate[section])[key] = value
    mutations.append((candidate, "invalid hardware field was accepted: " + key))
for candidate, message in mutations:
    check(not module.valid_contract(candidate) and execute(candidate)[0] == 1, message)

candidate = document()
candidate["capacities"]["maximum_to_design_ratio"] = 0.9
check(not module.valid_contract(candidate), "false maximum/design ratio was accepted")
candidate = document()
candidate["capacities"]["maximum_mah"] = None
check(not module.valid_contract(candidate), "ratio without both operands was accepted")
candidate = document()
candidate["capacities"]["maximum_to_design_ratio"] = None
check(not module.valid_contract(candidate), "missing ratio with both operands was accepted")
for section in (None, "capacities", "electrical", "adapter"):
    candidate = document()
    target = candidate if section is None else candidate[section]
    target["source_name"] = "hostile identity"
    check(execute(candidate)[0] == 1, "unexpected key was accepted in " + (section or "root"))
check(execute(valid, returncode=1)[0] == 1, "failed native helper was accepted")
check(execute(raw=b"{" + b" " * 4096 + b"}")[0] == 1,
      "oversized native helper output was accepted")
check(execute(raw=b"\xff")[0] == 1, "invalid UTF-8 native helper output was accepted")

# Exact Stats v3.0.10 evidence is optional at test runtime but fixed when available.
if (STATS_SOURCE_ROOT / ".git").is_dir():
    result = subprocess.run(
        ["/usr/bin/git", "-C", str(STATS_SOURCE_ROOT), "show",
         STATS_COMMIT + ":Modules/Battery/readers.swift"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=10,
        check=False,
    )
    check(result.returncode == 0 and hashlib.sha256(result.stdout).hexdigest() == STATS_READERS_SHA256,
          "exact Stats v3.0.10 battery evidence changed")

# The native reader is fixed, read-only, single-service, and does not expose uncertain fields.
for required in (
    'IOServiceMatching("AppleSmartBattery")',
    "IOServiceGetMatchingServices", "IOIteratorNext", "second == 0",
    "IORegistryEntryCreateCFProperty",
    '"AppleRawCurrentCapacity"', '"AppleRawMaxCapacity"', '"MaxCapacity"',
    '"DesignCapacity"', '"NominalChargeCapacity"', '"FullChargeCapacity"',
    '"BatteryData"', '"CycleCount"', "ReadingBounds.effectiveMaximum(",
    "forARM: false", "legacyMaximum: 7_900",
    '"Amperage"', '"Voltage"', '"Temperature"',
    "IOPSCopyExternalPowerAdapterDetails", "kIOPSPowerAdapterWattsKey",
    "kIOPSPowerAdapterCurrentKey",
):
    check(required in SWIFT_TEXT, "reviewed battery hardware read is missing: " + required)
for forbidden in (
    "IORegistryEntryCreateCFProperties", "IORegistryEntrySetCFProperty",
    "IORegistryEntrySetCFProperties", "IOServiceOpen", "IOConnectCall",
    "ChargerData", "ChargingCurrent", "ChargingVoltage", "NotChargingReason",
    '"AdapterDetails"', "TB1T", "TB2T", "SMC.shared", "Process(", "NSTask",
    "SerialNumber", "Manufacturer", "Product", "FamilyCode", "AdapterID",
    "IORegistryEntryGetPath",
):
    check(forbidden not in SWIFT_TEXT, "forbidden battery hardware surface remains: " + forbidden)
check("CommandLine.arguments.count == 1" in SWIFT_TEXT,
      "production Swift battery hardware CLI is not exact")
check("BATTERY_HARDWARE_TESTING" in SWIFT_TEXT and "ProcessInfo.processInfo.environment" not in SWIFT_TEXT,
      "battery hardware helper has a production test seam")

compile_and_test_swift_result = compile_and_test_swift()
live_value, live_bytes = compile_and_test_swift_result

# The live public document contains only one fixed schema string and no identity/source text.
def strings(value):
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict):
        result = []
        for child in value.values():
            result.extend(strings(child))
        return result
    if isinstance(value, list):
        result = []
        for child in value:
            result.extend(strings(child))
        return result
    return []

check(strings(live_value) == ["battery_hardware_v1"],
      "live battery hardware output emitted an unknown string")
public_text = live_bytes.decode("utf-8", "strict").lower()
for forbidden in (
    "serial", "manufacturer", "model", "vendor", "product", "source_name",
    "registry", "process", "applesmartbattery", "familycode", "adapterid",
    "tb1t", "tb2t", "smc", "chargerdata", "notchargingreason", "path",
):
    check(forbidden not in public_text, "live battery output leaked: " + forbidden)

# Exercise the installed coordinator and report only anonymous capability booleans.
live = subprocess.run(
    [str(PYTHON_SOURCE)],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    timeout=70,
    check=False,
)
check(live.returncode == 0 and live.stderr == b"" and len(live.stdout) <= 2049,
      "live battery hardware coordinator failed or was not bounded")
try:
    coordinator_value = json.loads(live.stdout)
except (json.JSONDecodeError, UnicodeError):
    check(False, "live battery hardware coordinator emitted malformed JSON")
check(module.valid_contract(coordinator_value), "live coordinator contract was invalid")
helper = module.compiled_helper()
digest = hashlib.sha256(SWIFT_SOURCE.read_bytes()).hexdigest()
check(helper.name == "battery-hardware-" + digest and module._valid_binary(helper),
      "live coordinator did not use its private source-hash binary")

availability = {
    "raw_current_capacity": coordinator_value["capacities"]["raw_current_mah"] is not None,
    "raw_maximum_capacity": coordinator_value["capacities"]["raw_maximum_mah"] is not None,
    "maximum_capacity": coordinator_value["capacities"]["maximum_mah"] is not None,
    "design_capacity": coordinator_value["capacities"]["design_mah"] is not None,
    "nominal_capacity": coordinator_value["capacities"]["nominal_mah"] is not None,
    "maximum_to_design_ratio": coordinator_value["capacities"]["maximum_to_design_ratio"] is not None,
    "cycle_count": coordinator_value["cycle_count"] is not None,
    "signed_current": coordinator_value["electrical"]["signed_current_ma"] is not None,
    "voltage": coordinator_value["electrical"]["voltage_v"] is not None,
    "temperature": coordinator_value["electrical"]["temperature_c"] is not None,
    "adapter_watts": coordinator_value["adapter"]["watts"] is not None,
    "adapter_current": coordinator_value["adapter"]["current_ma"] is not None,
}
print("Battery hardware contract passed; live anonymous capabilities "
      + json.dumps(availability, separators=(",", ":"), sort_keys=True))
