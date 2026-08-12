#!/usr/bin/python3
import hashlib
import json
import math
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile


SOURCE = Path(__file__).with_suffix(".swift")
INVENTORY_STATES = {
    "present", "absent", "ambiguous", "malformed", "unavailable",
    "unsupported_type_present",
}
SOURCES = {"ac", "battery", "ups", "offline", "unknown"}
CHARGE_STATES = {
    "finishing_charge", "charging", "charged", "empty", "discharging",
    "not_charging", "offline", "unknown", "unavailable",
}
TIME_STATES = {"minutes", "calculating", "not_applicable", "unavailable"}
HEALTH_STATES = {"good", "fair", "poor", "unknown", "unavailable"}
CONDITION_STATES = {
    "check_battery", "permanent_battery_failure", "no_reported_condition",
    "unknown", "unavailable",
}
LOW_POWER_STATES = {"on", "off_or_unsupported"}
TOP_LEVEL_KEYS = {
    "schema", "inventory", "percent", "source", "charge", "time",
    "health", "condition", "cycles", "low_power",
}
RUNTIME_PARENT_INPUT = os.environ.get("TMPDIR", "")
RUNTIME_PARENT = (os.path.realpath(RUNTIME_PARENT_INPUT)
                  if os.path.isabs(RUNTIME_PARENT_INPUT) else "")
CACHE_ROOT = (Path(RUNTIME_PARENT) / ("sketchybar-battery-state-" + str(os.getuid()))
              if RUNTIME_PARENT else None)


def _secure_cache_directory():
    if CACHE_ROOT is None or not RUNTIME_PARENT or CACHE_ROOT.parent != Path(RUNTIME_PARENT):
        raise OSError("unsafe battery helper cache")
    parent = os.lstat(RUNTIME_PARENT)
    if (not stat.S_ISDIR(parent.st_mode) or stat.S_ISLNK(parent.st_mode)
            or parent.st_uid != os.getuid()
            or stat.S_IMODE(parent.st_mode) != 0o700
            or os.path.realpath(RUNTIME_PARENT) != RUNTIME_PARENT):
        raise OSError("unsafe battery helper cache parent")
    path = CACHE_ROOT
    try:
        os.mkdir(str(path), 0o700)
    except FileExistsError:
        pass
    details = os.lstat(str(path))
    if (not stat.S_ISDIR(details.st_mode) or stat.S_ISLNK(details.st_mode)
            or details.st_uid != os.getuid()
            or stat.S_IMODE(details.st_mode) != 0o700):
        raise OSError("unsafe battery helper cache")
    return path


def _valid_binary(path):
    try:
        details = os.lstat(str(path))
    except FileNotFoundError:
        return False
    return (stat.S_ISREG(details.st_mode) and not stat.S_ISLNK(details.st_mode)
            and details.st_uid == os.getuid() and details.st_nlink == 1
            and stat.S_IMODE(details.st_mode) == 0o700)


def compiled_helper():
    source_bytes = SOURCE.read_bytes()
    digest = hashlib.sha256(source_bytes).hexdigest()
    directory = _secure_cache_directory()
    target = directory / ("battery-state-" + digest)
    if target.exists() or target.is_symlink():
        if not _valid_binary(target):
            raise OSError("unsafe cached battery helper")
        return target

    descriptor, candidate_name = tempfile.mkstemp(prefix=".battery-state.", dir=str(directory))
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
            timeout=60,
            check=False,
        )
        if result.returncode != 0:
            raise OSError("battery helper compilation failed")
        os.chmod(str(candidate), 0o700)
        if not _valid_binary(candidate):
            raise OSError("unsafe battery helper candidate")
        os.replace(str(candidate), str(target))
        if not _valid_binary(target):
            raise OSError("unsafe installed battery helper")
        return target
    finally:
        try:
            candidate.unlink()
        except FileNotFoundError:
            pass


def _closed_value(value, number_type, minimum, maximum):
    if not isinstance(value, dict) or set(value) != {"state", "value"}:
        return False
    if value["state"] == "unavailable":
        return value["value"] is None
    raw = value["value"]
    if value["state"] != "value" or isinstance(raw, bool) or not isinstance(raw, number_type):
        return False
    if isinstance(raw, float) and not math.isfinite(raw):
        return False
    return minimum <= raw <= maximum


def valid_contract(value):
    if not isinstance(value, dict) or set(value) != TOP_LEVEL_KEYS:
        return False
    if value["schema"] != "battery_state_v1":
        return False
    if value["inventory"] not in INVENTORY_STATES:
        return False
    if value["source"] not in SOURCES or value["charge"] not in CHARGE_STATES:
        return False
    if value["health"] not in HEALTH_STATES or value["condition"] not in CONDITION_STATES:
        return False
    if value["low_power"] not in LOW_POWER_STATES:
        return False
    if not _closed_value(value["percent"], (int, float), 0, 100):
        return False
    if not _closed_value(value["cycles"], int, 0, 9_007_199_254_740_991):
        return False

    remaining = value["time"]
    if not isinstance(remaining, dict) or set(remaining) != {"state", "minutes"}:
        return False
    if remaining["state"] not in TIME_STATES:
        return False
    minutes = remaining["minutes"]
    if remaining["state"] == "minutes":
        if isinstance(minutes, bool) or not isinstance(minutes, int) or not 0 <= minutes <= 2_147_483_647:
            return False
    elif minutes is not None:
        return False

    if value["inventory"] != "present":
        if (value["percent"]["state"] != "unavailable"
                or value["charge"] != "unavailable"
                or value["time"]["state"] != "unavailable"
                or value["health"] != "unavailable"
                or value["condition"] != "unavailable"
                or value["cycles"]["state"] != "unavailable"):
            return False
    if value["charge"] in {"charging", "finishing_charge", "discharging", "empty"}:
        if value["time"]["state"] == "not_applicable":
            return False
    if value["charge"] in {"charged", "not_charging", "offline"}:
        if value["time"]["state"] != "not_applicable":
            return False
    if value["charge"] in {"unknown", "unavailable"}:
        if value["time"]["state"] != "unavailable":
            return False
    return True


def main(helper_path=None):
    try:
        helper = Path(helper_path) if helper_path is not None else compiled_helper()
        result = subprocess.run(
            [str(helper)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=3,
            check=False,
        )
        if result.returncode != 0 or len(result.stdout) > 4096:
            return 1
        value = json.loads(result.stdout)
        if not valid_contract(value):
            return 1
    except (OSError, ValueError, json.JSONDecodeError, subprocess.TimeoutExpired):
        return 1
    print(json.dumps(value, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
