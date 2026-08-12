#!/usr/bin/python3
import hashlib
import importlib.util
import json
import os
import pathlib
import stat
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "scripts/hardware-state.py"
spec = importlib.util.spec_from_file_location("hardware_state", SOURCE)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def require(value, message):
    if not value:
        raise AssertionError(message)


# Exact CLI is closed and failures are silent.
result = subprocess.run([str(SOURCE), "extra"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        text=True, timeout=5, check=False)
require(result.returncode == 64 and result.stdout == "" and result.stderr == "", "extra argument must fail silently with 64")

# Platform-specific maxima use only the reviewed semantic key table.
values = {"Te05": 42.5, "Tp01": 70.25, "Tg1U": 61.75, "TC0c": 99.0,
          "Tp05": float("nan"), "Tg1k": 131.0}
state = module._temperature_state(values, "m4")
require(state == {"cpu_temp_c": 70.25, "cpu_sensor_count": 2,
                  "gpu_temp_c": 61.75, "gpu_sensor_count": 1}, "M4 temperature selection changed")
require(module._temperature_state({"TC0c": 51.0, "TC1C": 52.0}, "intel")["cpu_temp_c"] == 52.0,
        "Intel core expansion changed")

# Fan parser is closed, ordered, finite, and range checked.
fan_output = """Number of fans: 2.0

0: Fan #0
Actual speed: 2500.5
Minimal speed: 2000.0
Maximum speed: 7000.0
Target speed: 2501.0
Mode: automatic

1: Fan #1
Actual speed: 2600.0
Minimal speed: 2000.0
Maximum speed: 7000.0
Target speed: 2600.0
Mode: manual
"""
original_run = module._run
module._run = lambda arguments, timeout: fan_output
fans = module._fan_state(module.STATS_SMC)
require(len(fans) == 2 and fans[0]["index"] == 1 and fans[1]["mode"] == "manual", "fan parser rejected valid state")
module._run = lambda arguments, timeout: fan_output.replace("Target speed: 2501.0", "Target speed: 9000.0")
require(module._fan_state(module.STATS_SMC) is None, "out-of-range fan target was accepted")
module._run = original_run

# macOS 26 consolidated and legacy power-mode schemas are both strict.
new_custom = """Battery Power:
 powermode 1
AC Power:
 powermode 2
"""
legacy_custom = """Battery Power:
 lowpowermode 1
AC Power:
 lowpowermode 0
 highpowermode 0
"""
def fake_power(arguments, timeout):
    if arguments[-2:] == ["-g", "custom"]:
        return fake_power.custom
    if arguments[-2:] == ["-g", "ps"]:
        return "Now drawing from 'AC Power'\n"
    if arguments[-2:] == ["-g", "cap"]:
        return "Capabilities for AC Power:\n lowpowermode\n highpowermode\n"
    return None
fake_power.custom = new_custom
module._run = fake_power
require(module._power_mode() == {"source": "ac", "mode": "high", "supported": ["automatic", "low", "high"]},
        "consolidated power mode changed")
fake_power.custom = new_custom.replace("powermode 2", "powermode 0")
require(module._power_mode()["mode"] == "automatic", "automatic power-mode mapping changed")
fake_power.custom = new_custom.replace("powermode 2", "powermode 1")
require(module._power_mode()["mode"] == "low", "low power-mode mapping changed")
fake_power.custom = legacy_custom
require(module._power_mode() == {"source": "ac", "mode": "automatic", "supported": ["automatic", "low", "high"]},
        "legacy power mode changed")
fake_power.custom = new_custom.replace("powermode 2", "powermode 9")
require(module._power_mode() is None, "unknown power mode was accepted")
module._run = original_run

# Native JSON rejects extra keys, non-finite data, and out-of-range data.
native = {
    "schema": "native_hardware_metrics_v1",
    "gpu": {"utilization_pct": 25.0, "renderer_pct": None, "tiler_pct": None},
    "power": {"cpu_w": 10.0, "gpu_w": 2.0, "ane_w": 0.0, "ram_w": 1.0},
    "frequency": {"average_mhz": 2500.0, "efficiency_mhz": 1500.0,
                  "performance_mhz": 3500.0, "super_mhz": None},
}
original_marker_values = module._marker_values
original_execute_native = module._execute_native
module._marker_values = lambda: {"binary_sha256": "0" * 64}
module._run_silent = lambda arguments, timeout: True
module._run = lambda arguments, timeout: json.dumps(native, allow_nan=True)
module._execute_native = lambda arguments, expected_hash: "" if arguments == ["--self-test"] else json.dumps(native, allow_nan=True)
require(module._native_state() == native, "valid native state was rejected")
module._execute_native = lambda arguments, expected_hash: None if arguments == ["--self-test"] else json.dumps(native, allow_nan=True)
require(module._native_state() is None, "native helper with a noncanonical self-test was accepted")
module._execute_native = lambda arguments, expected_hash: "" if arguments == ["--self-test"] else json.dumps(native, allow_nan=True)
native["gpu"]["utilization_pct"] = 101.0
require(module._native_state() is None, "out-of-range GPU utilization was accepted")
native["gpu"]["utilization_pct"] = float("nan")
require(module._native_state() is None, "non-finite GPU utilization was accepted")
native["gpu"]["utilization_pct"] = 25.0
native["raw_identifier"] = "forbidden"
require(module._native_state() is None, "extra native key was accepted")
module._run = original_run

# The real output is bounded, closed, and contains no raw SMC keys or platform identity.
module._marker_values = original_marker_values
module._execute_native = original_execute_native
original_native_paths = (
    module.HARDWARE_DIRECTORY, module.HARDWARE_BINARY, module.HARDWARE_MARKER,
    module.SWIFT_SOURCE, module.BRIDGE_SOURCE,
)
with tempfile.TemporaryDirectory(prefix="hardware-marker-test.") as raw:
    base = pathlib.Path(raw).resolve()
    directory = base / "runtime"
    directory.mkdir(mode=0o700)
    swift_source = base / "hardware-metrics.swift"
    bridge_source = base / "hardware-metrics-bridge.h"
    swift_source.write_text("reviewed swift source\n")
    bridge_source.write_text("reviewed bridge source\n")
    binary_source = base / "fixture.swift"
    binary_source.write_text(
        'import Darwin\n@main struct Main { static func main() { exit(0) } }\n')
    binary = directory / "hardware-metrics"
    compiled = subprocess.run(
        ["/usr/bin/xcrun", "swiftc", "-target", "arm64-apple-macosx15.0",
         "-parse-as-library", "-O", str(binary_source), "-o", str(binary)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        timeout=60, check=False)
    require(compiled.returncode == 0, "hardware marker fixture compile failed")
    os.chmod(binary, 0o755)
    marker = directory / "SOURCE_SHA256"

    def marker_value():
        return (
            "version=2\nswift_sha256=" + hashlib.sha256(swift_source.read_bytes()).hexdigest()
            + "\nbridge_sha256=" + hashlib.sha256(bridge_source.read_bytes()).hexdigest()
            + "\ntarget=arm64-apple-macosx15.0\nbuild_mode=-O\nbinary_sha256="
            + hashlib.sha256(binary.read_bytes()).hexdigest() + "\n"
        )

    marker.write_text(marker_value())
    os.chmod(marker, 0o644)
    module.HARDWARE_DIRECTORY, module.HARDWARE_BINARY = directory, binary
    module.HARDWARE_MARKER, module.SWIFT_SOURCE = marker, swift_source
    module.BRIDGE_SOURCE = bridge_source
    require(module._marker_values() is not None, "exact hardware v2 marker was rejected")
    marker.write_text("\n".join(reversed(marker_value().splitlines())) + "\n")
    require(module._marker_values() is None, "reordered hardware marker was accepted")
    marker.write_text(marker_value())
    os.chmod(marker, 0o600)
    require(module._marker_values() is None, "wrong-mode hardware marker was accepted")
    os.chmod(marker, 0o644)
    wrong_arch_source = base / "wrong-arch.swift"
    wrong_arch_source.write_text(binary_source.read_text())
    wrong_arch = base / "wrong-arch"
    compiled = subprocess.run(
        ["/usr/bin/xcrun", "swiftc", "-target", "x86_64-apple-macosx15.0",
         "-parse-as-library", "-O", str(wrong_arch_source), "-o", str(wrong_arch)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        timeout=60, check=False)
    require(compiled.returncode == 0, "wrong-architecture hardware fixture compile failed")
    binary.write_bytes(wrong_arch.read_bytes())
    os.chmod(binary, 0o755)
    marker.write_text(marker_value())
    require(module._marker_values() is None, "wrong-architecture hardware helper was accepted")
    correct_arch = base / "correct-arch"
    compiled = subprocess.run(
        ["/usr/bin/xcrun", "swiftc", "-target", "arm64-apple-macosx15.0",
         "-parse-as-library", "-O", str(wrong_arch_source), "-o", str(correct_arch)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        timeout=60, check=False)
    require(compiled.returncode == 0, "correct-architecture hardware fixture compile failed")
    binary.write_bytes(correct_arch.read_bytes())
    os.chmod(binary, 0o755)
    approved_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
    execution = module._native_execution_copy(approved_hash)
    binary.write_bytes(wrong_arch.read_bytes())
    os.chmod(binary, 0o755)
    require(execution is not None and hashlib.sha256(execution.read_bytes()).hexdigest() == approved_hash,
            "hardware execution copy did not bind approved bytes across a path swap")
    execution.unlink()
    fifo = base / "hardware-fifo"
    os.mkfifo(fifo, 0o755)
    module.HARDWARE_BINARY = fifo
    started = time.monotonic()
    require(module._native_execution_copy(approved_hash) is None,
            "hardware execution copy accepted a FIFO")
    require(time.monotonic() - started < 1,
            "hardware execution copy did not reject a FIFO without blocking")
    started = time.monotonic()
    require(module._marker_values() is None, "hardware approval accepted a FIFO")
    require(time.monotonic() - started < 1,
            "hardware approval did not reject a FIFO without blocking")
module.HARDWARE_DIRECTORY, module.HARDWARE_BINARY, module.HARDWARE_MARKER, module.SWIFT_SOURCE, module.BRIDGE_SOURCE = original_native_paths

result = subprocess.run([str(SOURCE)], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        text=True, timeout=12, check=False)
require(result.returncode == 0 and result.stderr == "" and len(result.stdout.encode()) <= 16384,
        "live hardware state failed")
value = json.loads(result.stdout)
require(set(value) == {"schema", "smc_available", "native_available", "temperatures", "fans",
                       "gpu", "power", "frequency", "power_mode"}, "top-level schema changed")
require(value["schema"] == "hardware_state_v1", "hardware schema changed")
public = result.stdout.lower()
for forbidden in ("applesmc", "ioreport", "ioaccelerator", "machdep", "brand_string", "rp2s87b72w",
                  "tp01", "tg1u", "serial", "model identifier", "device id"):
    require(forbidden not in public, "private implementation or identifier leaked")

source = SOURCE.read_text()
for forbidden in ("os.environ.get(\"SKETCHYBAR_TEST", "--test-fixtures", " fan ", "writeKey", " set "):
    require(forbidden not in source, "production test or write seam found")

with tempfile.TemporaryDirectory() as temporary:
    stats_source = pathlib.Path(temporary) / "smc"
    stats_source.write_bytes(b"approved Stats helper")
    stats_source.chmod(0o755)
    stats_replacement = pathlib.Path(temporary) / "replacement"
    stats_replacement.write_bytes(b"replacement Stats helper")
    stats_replacement.chmod(0o755)
    original_stats_smc = module.STATS_SMC
    original_stats_hash = module.STATS_SMC_SHA256
    module.STATS_SMC = stats_source
    module.STATS_SMC_SHA256 = hashlib.sha256(stats_source.read_bytes()).hexdigest()
    execution = module._approved_stats_copy()
    os.replace(stats_replacement, stats_source)
    require(execution is not None
            and hashlib.sha256(execution.read_bytes()).hexdigest() == module.STATS_SMC_SHA256,
            "Stats execution copy did not bind approved bytes across a path replacement")
    execution.unlink()
    module.STATS_SMC = original_stats_smc
    module.STATS_SMC_SHA256 = original_stats_hash

with tempfile.TemporaryDirectory() as temporary:
    stats_info_fifo = pathlib.Path(temporary) / "Info.plist"
    os.mkfifo(stats_info_fifo, 0o644)
    original_stats_info = module.STATS_INFO
    original_safe_path = module._safe_path
    original_hash = module._hash
    module.STATS_INFO = stats_info_fifo
    module._safe_path = lambda *arguments, **keywords: True
    module._hash = lambda path: module.STATS_SMC_SHA256
    started = time.monotonic()
    require(not module._stats_trusted(), "Stats version approval accepted a FIFO")
    require(time.monotonic() - started < 1,
            "Stats version approval did not reject a FIFO without blocking")
    module.STATS_INFO = original_stats_info
    module._safe_path = original_safe_path
    module._hash = original_hash

original_stats_trusted = module._stats_trusted
original_smc_values = module._smc_values
original_fan_state = module._fan_state
smc_invocations = []
module._stats_trusted = lambda: False
module._smc_values = lambda *arguments: smc_invocations.append("temperatures")
module._fan_state = lambda *arguments: smc_invocations.append("fans")
failed_stats_state = module.collect()
require(not smc_invocations and failed_stats_state["smc_available"] is False,
        "failed Stats approval reached the SMC execution path")
module._stats_trusted = original_stats_trusted
module._smc_values = original_smc_values
module._fan_state = original_fan_state

print("Hardware state tests passed")
