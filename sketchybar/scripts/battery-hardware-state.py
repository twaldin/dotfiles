#!/usr/bin/python3
"""Emit a bounded, identifier-free battery hardware snapshot."""
import hashlib
import json
import math
import os
from pathlib import Path
import pwd
import stat
import subprocess
import sys
import tempfile


SOURCE = Path(__file__).with_name("battery-hardware.swift")
TOP_LEVEL_KEYS = {"schema", "capacities", "cycle_count", "electrical", "adapter"}
CAPACITY_KEYS = {
    "raw_current_mah", "raw_maximum_mah", "maximum_mah", "design_mah", "nominal_mah",
    "maximum_to_design_ratio",
}
ELECTRICAL_KEYS = {"signed_current_ma", "voltage_v", "temperature_c"}
ADAPTER_KEYS = {"watts", "current_ma"}
RUNTIME_PARENT_INPUT = os.environ.get("TMPDIR", "")
RUNTIME_PARENT = (os.path.realpath(RUNTIME_PARENT_INPUT)
                  if os.path.isabs(RUNTIME_PARENT_INPUT) else "")
CACHE_ROOT = (Path(RUNTIME_PARENT) / ("sketchybar-battery-hardware-" + str(os.getuid()))
              if RUNTIME_PARENT else None)
try:
    ACCOUNT_HOME = pwd.getpwuid(os.getuid()).pw_dir
except KeyError:
    ACCOUNT_HOME = "/"
SAFE_ENV = {
    "HOME": ACCOUNT_HOME,
    "LANG": "C",
    "LC_ALL": "C",
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "TMPDIR": RUNTIME_PARENT,
}
MAX_HELPER_OUTPUT = 4096
MAX_PUBLIC_OUTPUT = 2048


def _secure_cache_directory():
    if CACHE_ROOT is None or not RUNTIME_PARENT or CACHE_ROOT.parent != Path(RUNTIME_PARENT):
        raise OSError("unsafe battery hardware helper cache")
    parent = os.lstat(RUNTIME_PARENT)
    if (not stat.S_ISDIR(parent.st_mode) or stat.S_ISLNK(parent.st_mode)
            or parent.st_uid != os.getuid()
            or stat.S_IMODE(parent.st_mode) != 0o700
            or os.path.realpath(RUNTIME_PARENT) != RUNTIME_PARENT):
        raise OSError("unsafe battery hardware helper cache parent")
    try:
        os.mkdir(str(CACHE_ROOT), 0o700)
    except FileExistsError:
        pass
    details = os.lstat(str(CACHE_ROOT))
    if (not stat.S_ISDIR(details.st_mode) or stat.S_ISLNK(details.st_mode)
            or details.st_uid != os.getuid()
            or stat.S_IMODE(details.st_mode) != 0o700):
        raise OSError("unsafe battery hardware helper cache")
    return CACHE_ROOT


def _valid_binary(path):
    try:
        details = os.lstat(str(path))
    except FileNotFoundError:
        return False
    return (stat.S_ISREG(details.st_mode) and not stat.S_ISLNK(details.st_mode)
            and details.st_uid == os.getuid() and details.st_nlink == 1
            and stat.S_IMODE(details.st_mode) == 0o700)


def compiled_helper():
    digest = hashlib.sha256(SOURCE.read_bytes()).hexdigest()
    directory = _secure_cache_directory()
    target = directory / ("battery-hardware-" + digest)
    if target.exists() or target.is_symlink():
        if not _valid_binary(target):
            raise OSError("unsafe cached battery hardware helper")
        return target

    descriptor, candidate_name = tempfile.mkstemp(
        prefix=".battery-hardware.", dir=str(directory)
    )
    os.close(descriptor)
    candidate = Path(candidate_name)
    try:
        result = subprocess.run(
            [
                "/usr/bin/xcrun", "swiftc", "-parse-as-library", "-O",
                "-warnings-as-errors", str(SOURCE), "-framework", "IOKit",
                "-o", str(candidate),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=SAFE_ENV,
            timeout=60,
            check=False,
        )
        if result.returncode != 0:
            raise OSError("battery hardware helper compilation failed")
        os.chmod(str(candidate), 0o700)
        if not _valid_binary(candidate):
            raise OSError("unsafe battery hardware helper candidate")
        os.replace(str(candidate), str(target))
        if not _valid_binary(target):
            raise OSError("unsafe installed battery hardware helper")
        return target
    finally:
        try:
            candidate.unlink()
        except FileNotFoundError:
            pass


def _integer_or_none(value, minimum, maximum):
    return (value is None
            or (isinstance(value, int) and not isinstance(value, bool)
                and minimum <= value <= maximum))


def _number_or_none(value, minimum, maximum):
    return (value is None
            or (isinstance(value, (int, float)) and not isinstance(value, bool)
                and math.isfinite(value) and minimum <= value <= maximum))


def valid_contract(value):
    if not isinstance(value, dict) or set(value) != TOP_LEVEL_KEYS:
        return False
    if value["schema"] != "battery_hardware_v1":
        return False
    capacities = value["capacities"]
    electrical = value["electrical"]
    adapter = value["adapter"]
    if not isinstance(capacities, dict) or set(capacities) != CAPACITY_KEYS:
        return False
    if not isinstance(electrical, dict) or set(electrical) != ELECTRICAL_KEYS:
        return False
    if not isinstance(adapter, dict) or set(adapter) != ADAPTER_KEYS:
        return False

    if not _integer_or_none(capacities["raw_current_mah"], 0, 1_000_000):
        return False
    for key in ("raw_maximum_mah", "maximum_mah", "design_mah", "nominal_mah"):
        if not _integer_or_none(capacities[key], 1, 1_000_000):
            return False
    if not _integer_or_none(value["cycle_count"], 0, 10_000_000):
        return False
    if not _integer_or_none(electrical["signed_current_ma"], -1_000_000, 1_000_000):
        return False
    if not _number_or_none(electrical["voltage_v"], 1, 100):
        return False
    if not _number_or_none(electrical["temperature_c"], -50, 150):
        return False
    if not _integer_or_none(adapter["watts"], 1, 1_000):
        return False
    if not _integer_or_none(adapter["current_ma"], 1, 100_000):
        return False

    ratio = capacities["maximum_to_design_ratio"]
    maximum = capacities["maximum_mah"]
    design = capacities["design_mah"]
    if maximum is None or design is None:
        return ratio is None
    if not _number_or_none(ratio, 0, 4) or ratio is None:
        return False
    expected = maximum / design
    return math.isclose(ratio, expected, rel_tol=1e-12, abs_tol=1e-12)


def main():
    if sys.argv != [sys.argv[0]]:
        return 64
    try:
        helper = compiled_helper()
        result = subprocess.run(
            [str(helper)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=SAFE_ENV,
            timeout=3,
            check=False,
        )
        if result.returncode != 0 or len(result.stdout) > MAX_HELPER_OUTPUT:
            return 1
        value = json.loads(result.stdout)
        if not valid_contract(value):
            return 1
        encoded = json.dumps(
            value, separators=(",", ":"), sort_keys=True, allow_nan=False
        )
        if len(encoded.encode("utf-8")) > MAX_PUBLIC_OUTPUT:
            return 1
        print(encoded)
        return 0
    except (OSError, ValueError, TypeError, json.JSONDecodeError,
            subprocess.SubprocessError):
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
