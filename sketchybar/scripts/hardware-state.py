#!/usr/bin/python3
"""Emit bounded, identifier-free private hardware telemetry for SketchyBar."""
import hashlib
import json
import math
import os
import pathlib
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

STATS_APP = pathlib.Path("/Applications/Stats.app")
STATS_INFO = STATS_APP / "Contents/Info.plist"
STATS_SMC = STATS_APP / "Contents/Resources/smc"
STATS_VERSION = ("3.0.10", "832")
STATS_TEAM = "RP2S87B72W"
STATS_SMC_SHA256 = "5a924e98212ff85635a2db5778d417a182fcaca338bc1fe41dcf61571f5e8a0d"
HARDWARE_DIRECTORY = pathlib.Path(os.path.expanduser("~/.local/share/sketchybar-hardware"))
HARDWARE_BINARY = HARDWARE_DIRECTORY / "hardware-metrics"
HARDWARE_MARKER = HARDWARE_DIRECTORY / "SOURCE_SHA256"
SCRIPT_DIRECTORY = pathlib.Path(__file__).resolve().parent
SWIFT_SOURCE = SCRIPT_DIRECTORY / "hardware-metrics.swift"
BRIDGE_SOURCE = SCRIPT_DIRECTORY / "hardware-metrics-bridge.h"
ENV = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": os.path.expanduser("~"),
       "LANG": "C", "LC_ALL": "C"}
MAX_OUTPUT = 131072
VALUE_PATTERN = re.compile(r"^\[([^\]]{4})\]\s+(-?[0-9]+(?:\.[0-9]+)?)\s*$")
FAN_PATTERN = re.compile(
    r"^(\d+): [^\n]{1,80}\nActual speed: (-?[0-9]+(?:\.[0-9]+)?)\n"
    r"Minimal speed: (-?[0-9]+(?:\.[0-9]+)?)\nMaximum speed: (-?[0-9]+(?:\.[0-9]+)?)\n"
    r"Target speed: (-?[0-9]+(?:\.[0-9]+)?)\nMode: (automatic|manual)$", re.MULTILINE)

TEMPERATURE_KEYS = {
    "m1": {
        "cpu": ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"],
        "gpu": ["Tg05", "Tg0D", "Tg0L", "Tg0T"],
    },
    "m2": {
        "cpu": ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"],
        "gpu": ["Tg0f", "Tg0j"],
    },
    "m3": {
        "cpu": ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"],
        "gpu": ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"],
    },
    "m4": {
        "cpu": ["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"],
        "gpu": ["Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"],
    },
    "m5": {
        "cpu": ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"],
        "gpu": ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"],
    },
    "intel": {
        "cpu": [f"TC{i}{suffix}" for i in range(10) for suffix in ("c", "C")],
        "gpu": [],
    },
}


def _run(arguments, timeout):
    try:
        result = subprocess.run(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, env=ENV, timeout=timeout, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0 or len(result.stdout) > MAX_OUTPUT or len(result.stderr) > MAX_OUTPUT:
        return None
    try:
        return result.stdout.decode("utf-8", "strict")
    except UnicodeDecodeError:
        return None


def _run_silent(arguments, timeout):
    try:
        result = subprocess.run(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, env=ENV, timeout=timeout, check=False)
    except (OSError, subprocess.SubprocessError):
        return False
    return result.returncode == 0 and result.stdout == b"" and result.stderr == b""


def _safe_path(path, kind, modes, owners, links=None):
    try:
        info = path.lstat()
    except OSError:
        return False
    if stat.S_ISLNK(info.st_mode) or info.st_uid not in owners or stat.S_IMODE(info.st_mode) not in modes:
        return False
    if kind == "file" and not stat.S_ISREG(info.st_mode):
        return False
    if kind == "directory" and not stat.S_ISDIR(info.st_mode):
        return False
    return links is None or info.st_nlink in links


def _hash(path):
    descriptor = -1
    digest = hashlib.sha256()
    try:
        descriptor = os.open(
            path, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NONBLOCK", 0))
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode):
            return None
        while True:
            block = os.read(descriptor, 65536)
            if not block:
                return digest.hexdigest()
            digest.update(block)
    except OSError:
        return None
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _approved_stats_copy():
    runtime_base = os.environ.get("TMPDIR", "")
    if not os.path.isabs(runtime_base):
        return None
    runtime = pathlib.Path(os.path.realpath(runtime_base))
    if not _safe_path(runtime, "directory", {0o700}, {os.getuid()}):
        return None
    destination = None
    output_descriptor = -1
    source_descriptor = -1
    try:
        output_descriptor, raw = tempfile.mkstemp(prefix=".stats-smc-exec.", dir=runtime)
        destination = pathlib.Path(raw)
        os.fchmod(output_descriptor, 0o500)
        source_descriptor = os.open(
            STATS_SMC, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NONBLOCK", 0))
        opened = os.fstat(source_descriptor)
        current = STATS_SMC.lstat()
        if (not stat.S_ISREG(opened.st_mode) or opened.st_uid not in {0, os.getuid()}
                or opened.st_nlink != 1 or stat.S_IMODE(opened.st_mode) != 0o755
                or (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino)):
            raise OSError("Stats SMC source is unsafe")
        digest = hashlib.sha256()
        while True:
            block = os.read(source_descriptor, 65536)
            if not block:
                break
            digest.update(block)
            offset = 0
            while offset < len(block):
                offset += os.write(output_descriptor, block[offset:])
        os.fsync(output_descriptor)
        if digest.hexdigest() != STATS_SMC_SHA256:
            raise OSError("Stats SMC checksum changed")
        return destination
    except OSError:
        return None
    finally:
        if source_descriptor >= 0:
            os.close(source_descriptor)
        if output_descriptor >= 0:
            os.close(output_descriptor)
        if destination is not None and _hash(destination) != STATS_SMC_SHA256:
            try:
                destination.unlink()
            except OSError:
                pass


def _stats_trusted():
    uid = os.getuid()
    owners = {0, uid}
    if not (_safe_path(STATS_APP, "directory", {0o755}, owners)
            and _safe_path(STATS_APP / "Contents", "directory", {0o755}, owners)
            and _safe_path(STATS_SMC, "file", {0o755}, owners, {1})
            and _hash(STATS_SMC) == STATS_SMC_SHA256):
        return None
    descriptor = -1
    try:
        descriptor = os.open(
            STATS_INFO, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NONBLOCK", 0))
        opened = os.fstat(descriptor)
        current = STATS_INFO.lstat()
        if (not stat.S_ISREG(opened.st_mode) or opened.st_uid not in owners
                or opened.st_nlink != 1 or stat.S_IMODE(opened.st_mode) != 0o644
                or opened.st_size > 1024 * 1024
                or (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino)):
            return None
        chunks = []
        remaining = 1024 * 1024 + 1
        while remaining > 0:
            chunk = os.read(descriptor, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        if remaining == 0:
            return None
        info = plistlib.loads(b"".join(chunks))
    except (OSError, plistlib.InvalidFileException):
        return None
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if (info.get("CFBundleIdentifier") != "eu.exelban.Stats"
            or (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")) != STATS_VERSION):
        return None
    verify = _run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=0", str(STATS_APP)], 15)
    # codesign writes detail to stderr, so perform the bounded check separately.
    try:
        signed = subprocess.run(
            ["/usr/bin/codesign", "--display", "--verbose=4", str(STATS_APP)],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
            env=ENV, timeout=8, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    if (verify is None or signed.returncode != 0 or len(signed.stderr) > MAX_OUTPUT
            or ("TeamIdentifier=" + STATS_TEAM).encode() not in signed.stderr
            or b"Identifier=eu.exelban.Stats" not in signed.stderr):
        return None
    return _approved_stats_copy()


def _marker_values():
    # The release fingerprint is checked before installation. This marker binds
    # the installed helper to exact reviewed sources and build properties inside
    # the existing same-user SketchyBar trust boundary.
    uid = os.getuid()
    if not (_safe_path(HARDWARE_DIRECTORY, "directory", {0o700}, {uid})
            and pathlib.Path(os.path.realpath(HARDWARE_DIRECTORY)) == HARDWARE_DIRECTORY
            and _safe_path(HARDWARE_BINARY, "file", {0o755}, {uid}, {1})
            and _safe_path(HARDWARE_MARKER, "file", {0o644}, {uid}, {1})):
        return None
    swift_hash = _hash(SWIFT_SOURCE)
    bridge_hash = _hash(BRIDGE_SOURCE)
    binary_hash = _hash(HARDWARE_BINARY)
    if any(value is None or not re.fullmatch(r"[0-9a-f]{64}", value)
           for value in (swift_hash, bridge_hash, binary_hash)):
        return None
    expected = (
        "version=2\nswift_sha256=" + swift_hash +
        "\nbridge_sha256=" + bridge_hash +
        "\ntarget=arm64-apple-macosx15.0\nbuild_mode=-O\nbinary_sha256=" +
        binary_hash + "\n"
    ).encode("ascii")
    descriptor = -1
    try:
        descriptor = os.open(
            HARDWARE_MARKER, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
            | getattr(os, "O_CLOEXEC", 0))
        opened = os.fstat(descriptor)
        current = HARDWARE_MARKER.lstat()
        if ((opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino)
                or opened.st_nlink != 1 or stat.S_IMODE(opened.st_mode) != 0o644):
            return None
        marker = os.read(descriptor, 513)
        execution = _native_execution_copy(binary_hash)
        if execution is None:
            return None
        try:
            architecture = subprocess.run(
                ["/usr/bin/lipo", "-archs", str(execution)],
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                timeout=5, check=False)
        finally:
            try:
                execution.unlink()
            except OSError:
                pass
    except (OSError, subprocess.SubprocessError):
        return None
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if (marker != expected or architecture.returncode != 0 or architecture.stdout != b"arm64\n"
            or _hash(HARDWARE_BINARY) != binary_hash):
        return None
    return {
        "version": "2", "swift_sha256": swift_hash, "bridge_sha256": bridge_hash,
        "target": "arm64-apple-macosx15.0", "build_mode": "-O", "binary_sha256": binary_hash,
    }


def _native_execution_copy(expected_hash):
    runtime_base = os.environ.get("TMPDIR", "")
    if not os.path.isabs(runtime_base):
        return None
    runtime_base = pathlib.Path(os.path.realpath(runtime_base))
    if not _safe_path(runtime_base, "directory", {0o700}, {os.getuid()}):
        return None
    temporary = None
    descriptor = -1
    source_descriptor = -1
    try:
        descriptor, raw = tempfile.mkstemp(prefix=".hardware-exec.", dir=runtime_base)
        temporary = pathlib.Path(raw)
        os.fchmod(descriptor, 0o500)
        source_descriptor = os.open(
            HARDWARE_BINARY, os.O_RDONLY | os.O_NOFOLLOW
            | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NONBLOCK", 0))
        opened = os.fstat(source_descriptor)
        if (not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.getuid()
                or opened.st_nlink != 1 or stat.S_IMODE(opened.st_mode) != 0o755):
            raise OSError("hardware execution source is unsafe")
        while True:
            chunk = os.read(source_descriptor, 65536)
            if not chunk:
                break
            offset = 0
            while offset < len(chunk):
                offset += os.write(descriptor, chunk[offset:])
        os.fsync(descriptor)
        os.close(source_descriptor)
        source_descriptor = -1
        os.close(descriptor)
        descriptor = -1
        return temporary if _hash(temporary) == expected_hash else None
    except OSError:
        return None
    finally:
        if source_descriptor >= 0:
            os.close(source_descriptor)
        if descriptor >= 0:
            os.close(descriptor)
        if temporary is not None and _hash(temporary) != expected_hash:
            try:
                temporary.unlink()
            except OSError:
                pass


def _execute_native(arguments, expected_hash):
    execution = _native_execution_copy(expected_hash)
    if execution is None:
        return None
    try:
        if arguments == ["--self-test"]:
            return "" if _run_silent([str(execution), "--self-test"], 4) else None
        return _run([str(execution), *arguments], 4)
    finally:
        try:
            execution.unlink()
        except OSError:
            pass


def _native_state():
    marker = _marker_values()
    if marker is None:
        return None
    binary_hash = marker["binary_sha256"]
    if _execute_native(["--self-test"], binary_hash) is None:
        return None
    output = _execute_native(["state"], binary_hash)
    after = _marker_values()
    if after is None or after["binary_sha256"] != binary_hash:
        return None
    if output is None or len(output.encode()) > 16384:
        return None
    try:
        value = json.loads(output)
    except (json.JSONDecodeError, UnicodeError):
        return None
    if not isinstance(value, dict) or set(value) != {"schema", "gpu", "power", "frequency"}:
        return None
    if value.get("schema") != "native_hardware_metrics_v1":
        return None
    shapes = {
        "gpu": {"utilization_pct", "renderer_pct", "tiler_pct"},
        "power": {"cpu_w", "gpu_w", "ane_w", "ram_w"},
        "frequency": {"average_mhz", "efficiency_mhz", "performance_mhz", "super_mhz"},
    }
    bounds = {"utilization_pct": (0, 100), "renderer_pct": (0, 100), "tiler_pct": (0, 100),
              "cpu_w": (0, 1000), "gpu_w": (0, 1000), "ane_w": (0, 1000), "ram_w": (0, 1000),
              "average_mhz": (1, 10000), "efficiency_mhz": (1, 10000),
              "performance_mhz": (1, 10000), "super_mhz": (1, 10000)}
    for section, keys in shapes.items():
        obj = value.get(section)
        if not isinstance(obj, dict) or set(obj) != keys:
            return None
        for key, number in obj.items():
            if number is not None and (isinstance(number, bool) or not isinstance(number, (int, float))
                                       or not math.isfinite(number) or not bounds[key][0] <= number <= bounds[key][1]):
                return None
    return value


def _platform():
    output = _run(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"], 2)
    if output is None or len(output) > 128:
        return "intel"
    match = re.search(r"\bM([1-5])\b", output)
    return "m" + match.group(1) if match else "intel"


def _smc_values(execution, arguments):
    output = _run([str(execution)] + arguments, 4)
    if output is None:
        return None
    values = {}
    for line in output.splitlines():
        match = VALUE_PATTERN.fullmatch(line)
        if not match:
            continue
        number = float(match.group(2))
        if math.isfinite(number):
            values[match.group(1)] = number
    return values


def _temperature_state(values, platform):
    keys = TEMPERATURE_KEYS.get(platform, TEMPERATURE_KEYS["intel"])
    result = {}
    for group in ("cpu", "gpu"):
        samples = [values[key] for key in keys[group] if key in values and 0 < values[key] < 130]
        result[group + "_temp_c"] = max(samples) if samples else None
        result[group + "_sensor_count"] = len(samples)
    return result


def _fan_state(execution):
    output = _run([str(execution), "fans"], 3)
    if output is None or len(output) > 16384:
        return None
    count_match = re.search(r"^Number of fans: ([0-9]+(?:\.0+)?)$", output, re.MULTILINE)
    if not count_match:
        return None
    count = int(float(count_match.group(1)))
    if not 0 <= count <= 8:
        return None
    fans = []
    for match in FAN_PATTERN.finditer(output):
        index = int(match.group(1))
        numbers = [float(match.group(i)) for i in range(2, 6)]
        actual, minimum, maximum, target = numbers
        if (index != len(fans) or not all(math.isfinite(value) and 0 <= value <= 30000 for value in numbers)
                or minimum > maximum or not minimum <= target <= maximum):
            return None
        fans.append({"index": index + 1, "rpm": actual, "min_rpm": minimum,
                     "max_rpm": maximum, "target_rpm": target, "mode": match.group(6)})
    return fans if len(fans) == count else None


def _power_mode():
    custom = _run(["/usr/bin/pmset", "-g", "custom"], 3)
    source_output = _run(["/usr/bin/pmset", "-g", "ps"], 3)
    capabilities = _run(["/usr/bin/pmset", "-g", "cap"], 3)
    if (custom is None or source_output is None or capabilities is None
            or len(custom) > 65536 or len(source_output) > 16384 or len(capabilities) > 16384):
        return None
    source_match = re.search(r"Now drawing from '([^']{1,32})'", source_output)
    if not source_match:
        return None
    source_name = source_match.group(1)
    source = {"AC Power": "ac", "Battery Power": "battery", "UPS Power": "ups"}.get(source_name)
    if source is None:
        return None
    headings = {"Battery Power": "battery", "AC Power": "ac", "UPS Power": "ups"}
    profiles = {}
    current = None
    for line in custom.splitlines():
        heading = re.fullmatch(r"([^:]{1,32}):", line.strip())
        if heading and heading.group(1) in headings:
            current = headings[heading.group(1)]
            profiles[current] = {}
            continue
        field = re.fullmatch(r"\s*(lowpowermode|highpowermode|powermode)\s+([0-2])\s*", line)
        if current and field:
            profiles[current][field.group(1)] = int(field.group(2))
    fields = profiles.get(source)
    if not fields or ("powermode" not in fields and "lowpowermode" not in fields):
        return None
    supported = ["automatic"]
    capability_names = set(re.findall(r"^\s*(lowpowermode|highpowermode)\s*$", capabilities, re.MULTILINE))
    if "lowpowermode" in capability_names:
        supported.append("low")
    if "highpowermode" in capability_names:
        supported.append("high")
    if "powermode" in fields:
        mode = {0: "automatic", 1: "low", 2: "high"}.get(fields["powermode"])
        if mode is None:
            return None
    else:
        mode = "low" if fields["lowpowermode"] == 1 else ("high" if fields.get("highpowermode") == 1 else "automatic")
    if mode not in supported:
        return None
    return {"source": source, "mode": mode, "supported": supported}


def collect():
    candidate = _stats_trusted()
    stats_execution = candidate if isinstance(candidate, pathlib.Path) else None
    try:
        with ThreadPoolExecutor(max_workers=4) as pool:
            native_future = pool.submit(_native_state)
            power_future = pool.submit(_power_mode)
            temperatures_future = (pool.submit(_smc_values, stats_execution, ["list", "-t"])
                                   if stats_execution is not None else None)
            fans_future = (pool.submit(_fan_state, stats_execution)
                           if stats_execution is not None else None)
            native = native_future.result()
            power_mode = power_future.result()
            values = temperatures_future.result() if temperatures_future else None
            fans = fans_future.result() if fans_future else None
    finally:
        if stats_execution is not None:
            try:
                stats_execution.unlink()
            except OSError:
                values = None
                fans = None
    temperatures = _temperature_state(values, _platform()) if values is not None else {
        "cpu_temp_c": None, "cpu_sensor_count": 0, "gpu_temp_c": None, "gpu_sensor_count": 0}
    return {
        "schema": "hardware_state_v1",
        "smc_available": values is not None and fans is not None,
        "native_available": native is not None,
        "temperatures": temperatures,
        "fans": fans if fans is not None else [],
        "gpu": native["gpu"] if native else {"utilization_pct": None, "renderer_pct": None, "tiler_pct": None},
        "power": native["power"] if native else {"cpu_w": None, "gpu_w": None, "ane_w": None, "ram_w": None},
        "frequency": native["frequency"] if native else {"average_mhz": None, "efficiency_mhz": None,
                                                          "performance_mhz": None, "super_mhz": None},
        "power_mode": power_mode,
    }


def main():
    if sys.argv != [sys.argv[0]]:
        return 64
    try:
        value = collect()
        encoded = json.dumps(value, separators=(",", ":"), allow_nan=False)
    except (OSError, ValueError, TypeError):
        return 1
    if len(encoded.encode()) > 16384:
        return 1
    print(encoded)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
