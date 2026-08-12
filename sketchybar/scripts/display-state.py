#!/usr/bin/python3
import hashlib
import hmac
import json
import math
import os
import plistlib
import re
import secrets
import stat
import subprocess
import sys
import tempfile
import time

BETTERDISPLAY = "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"
BETTERDISPLAY_APP = "/Applications/BetterDisplay.app"
BETTERDISPLAY_INFO = BETTERDISPLAY_APP + "/Contents/Info.plist"
APPROVED_VERSION = ("4.2.3", "48120")
APPROVED_EXECUTABLE_SHA256 = "b7507a7d367af7ca3119e8bf0d10342a6e5b2cea497f43c9f14d32bd560894c4"
CONTROL_DIR = os.path.expanduser("~/.local/share/sketchybar-display")
CONTROL_BINARY = CONTROL_DIR + "/betterdisplay-control"
CONTROL_MARKER = CONTROL_DIR + "/SOURCE_SHA256"
CONTROL_SOURCE = os.path.join(os.path.dirname(__file__), "betterdisplay-control.swift")
MAP_DIRECTORY_NAME = "sketchybar-display-state-v1"
MAP_FILE_NAME = "target-map.json"
ENV = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": os.path.expanduser("~"), "LANG": "C", "LC_ALL": "C"}
UUID_PATTERN = re.compile(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
MARKER_PATTERN = re.compile(r"-?[0-9]{1,12},-?[0-9]{1,12}")
HANDLE_PATTERN = re.compile(r"v1_[0-9a-f]{32}_[0-9a-f]{64}")
HASH_PATTERN = re.compile(r"[0-9a-f]{64}")
NUMERIC_OPERATIONS = {"brightness": "brightness", "hardware_contrast": "contrast", "volume": "volume"}
OPERATIONS = set(NUMERIC_OPERATIONS) | {"mute"}
NATIVE_STATUSES = {
    "applied": 0,
    "artifact_rejected": 69,
    "conflict": 65,
    "invalid_request": 65,
    "out_of_range": 65,
    "recovery_failed": 70,
    "restored": 70,
    "unavailable": 69,
}
NORMALIZED_TOLERANCE = 0.010001


def run(arguments, timeout=8, capture_stderr=False):
    try:
        return subprocess.run(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE if capture_stderr else subprocess.DEVNULL,
                              text=True, timeout=timeout, env=ENV, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return subprocess.CompletedProcess(arguments, 1, "", "")


def _betterdisplay_run(arguments, timeout=8):
    if not exact_artifact():
        return subprocess.CompletedProcess(arguments, 1, "", "")
    result = run([BETTERDISPLAY, *arguments], timeout=timeout)
    if not exact_artifact():
        return subprocess.CompletedProcess(arguments, 1, "", "")
    return result


def feature(name):
    result = _betterdisplay_run(["get", "-displayWithMouse", "-" + name])
    value = result.stdout.strip()
    if result.returncode != 0 or not value or len(value) > 16384 or "\n" in value:
        return None
    return value


def feature_list(name, limit=65536):
    result = _betterdisplay_run(["get", "-displayWithMouse", "-" + name], timeout=12)
    value = result.stdout.strip()
    if result.returncode != 0 or not value or len(value) > limit:
        return None
    return value


def fraction(value):
    if not isinstance(value, str):
        return None
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)%?", value.strip())
    if not match:
        return None
    number = float(match.group(1))
    if value.strip().endswith("%"):
        number /= 100
    if not math.isfinite(number) or number < 0 or number > 1:
        return None
    return number


def boolean(value):
    if value in {"on", "true"}:
        return True
    if value in {"off", "false"}:
        return False
    return None


VARIABLE_REFRESH_RATES = {"ProMotion", "Variable", "Adaptive"}
FIXED_REFRESH_PATTERN = r"[0-9]+(?:\.[0-9]{1,2})?"
VARIABLE_REFRESH_PATTERN = FIXED_REFRESH_PATTERN + r"-" + FIXED_REFRESH_PATTERN + r"Hz"
REFRESH_PATTERN = (
    r"(?:" + FIXED_REFRESH_PATTERN + r"Hz|" + VARIABLE_REFRESH_PATTERN
    + r"|ProMotion|Variable|Adaptive)"
)


def refresh_rate(value):
    if not isinstance(value, str):
        return None
    value = value.strip()
    match = re.fullmatch(r"(" + FIXED_REFRESH_PATTERN + r")Hz", value)
    if match:
        number = float(match.group(1))
        return number if math.isfinite(number) and 1 <= number <= 1000 else None
    if value in VARIABLE_REFRESH_RATES:
        return value
    match = re.fullmatch(
        r"(" + FIXED_REFRESH_PATTERN + r")-(" + FIXED_REFRESH_PATTERN + r")Hz", value
    )
    if not match:
        return None
    minimum, maximum = float(match.group(1)), float(match.group(2))
    return value if (1 <= minimum < maximum <= 1000) else None


def same_refresh_rate(first, second):
    return type(first) is type(second) and first == second


def refresh_sort_key(value):
    return (0, value) if type(value) is float else (1, value)


def resolution(value):
    match = re.fullmatch(r"([0-9]{3,5})x([0-9]{3,5})", value or "")
    if not match:
        return None
    width, height = int(match.group(1)), int(match.group(2))
    return value if 320 <= width <= 32768 and 200 <= height <= 32768 else None


def integer(value, minimum, maximum):
    if not re.fullmatch(r"[0-9]+", value or ""):
        return None
    number = int(value)
    return number if minimum <= number <= maximum else None


MODE_PATTERN = re.compile(
    r"^(\d+) - (\d{3,5})x(\d{3,5})( HiDPI)? "
    r"(" + REFRESH_PATTERN + r") (\d{1,2})bpc(?: (.*))?$"
)
MODE_NUMBER_PREFIX_PATTERN = re.compile(r"^(\d+) - ")


def parse_modes(output, current_number, current_rate):
    modes = []
    current_line_rejected = False
    for line in (output or "").splitlines():
        text = line.strip()
        prefix = MODE_NUMBER_PREFIX_PATTERN.match(text)
        is_current_number = prefix is not None and int(prefix.group(1)) == current_number
        match = MODE_PATTERN.fullmatch(text)
        if not match or "Unsafe" in (match.group(7) or ""):
            current_line_rejected = current_line_rejected or is_current_number
            continue
        number, width, height = int(match.group(1)), int(match.group(2)), int(match.group(3))
        rate, depth = refresh_rate(match.group(5)), int(match.group(6))
        flags = set((match.group(7) or "").split())
        if (number > 4096 or rate is None or not 1 <= depth <= 64
                or not (320 <= width <= 32768 and 200 <= height <= 32768)):
            current_line_rejected = current_line_rejected or is_current_number
            continue
        modes.append({
            "number": number, "resolution": f"{width}x{height}",
            "width": width, "height": height, "hi_dpi": match.group(4) is not None,
            "refresh_rate": rate, "color_depth": depth,
            "current": number == current_number or "Current" in flags,
            "default": "Default" in flags, "native": "Native" in flags,
        })
    if current_line_rejected or not any(mode["number"] == current_number for mode in modes):
        return []
    chosen = []

    def add(mode):
        if mode and all(item["number"] != mode["number"] for item in chosen):
            chosen.append(mode)
    for mode in modes:
        if mode["current"] or mode["default"]:
            add(mode)
    native = [mode for mode in modes if mode["native"]]
    add(next((mode for mode in native if mode["hi_dpi"]
              and same_refresh_rate(mode["refresh_rate"], current_rate)), None))
    add(next((mode for mode in native if not mode["hi_dpi"]
              and same_refresh_rate(mode["refresh_rate"], current_rate)), None))
    chosen.sort(key=lambda mode: (
        mode["width"] * mode["height"], refresh_sort_key(mode["refresh_rate"]), mode["number"]
    ))
    retained = chosen[:10]
    current = next(mode for mode in chosen if mode["number"] == current_number)
    if all(mode["number"] != current_number for mode in retained):
        retained[-1] = current
        retained.sort(key=lambda mode: (
            mode["width"] * mode["height"], refresh_sort_key(mode["refresh_rate"]), mode["number"]
        ))
    return retained


def trusted_bundle():
    verified = run(["/usr/bin/codesign", "--verify", "--deep", "--strict", BETTERDISPLAY_APP])
    if verified.returncode != 0:
        return False
    detail = run(["/usr/bin/codesign", "-d", "--verbose=4", BETTERDISPLAY_APP], capture_stderr=True)
    if detail.returncode != 0 or len(detail.stderr) > 65536:
        return False
    fields = {}
    for line in detail.stderr.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            if key in {"Identifier", "TeamIdentifier"} and key not in fields:
                fields[key] = value
    return fields == {
        "Identifier": "pro.betterdisplay.BetterDisplay",
        "TeamIdentifier": "299YSU96J7",
    }


def exact_version():
    data = _read_safe_file(BETTERDISPLAY_INFO, 0o644, 1024 * 1024)
    if data is None:
        return False
    try:
        info = plistlib.loads(data)
    except plistlib.InvalidFileException:
        return False
    return (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")) == APPROVED_VERSION


def one_running_instance():
    result = run(["/bin/ps", "-axo", "ppid=,comm="])
    if result.returncode != 0 or len(result.stdout) > 1024 * 1024:
        return False
    app_instances = 0
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 1)
        if (len(fields) == 2 and fields[0] == "1"
                and fields[1] == BETTERDISPLAY):
            app_instances += 1
    return app_instances == 1


def target_marker():
    result = _betterdisplay_run(["get", "-displayWithMouse", "-identifier=tagID"])
    value = result.stdout.strip()
    return value if result.returncode == 0 and MARKER_PATTERN.fullmatch(value) else None


def target_uuid():
    result = _betterdisplay_run(["get", "-displayWithMouse", "-identifier=UUID"])
    value = result.stdout.strip()
    return value if result.returncode == 0 and UUID_PATTERN.fullmatch(value) else None


def snapshot():
    initial_uuid, initial_marker = target_uuid(), target_marker()
    if initial_uuid is None or initial_marker is None:
        return None
    current_resolution = resolution(feature("resolution"))
    current_rate = refresh_rate(feature("refreshRate"))
    current_mode = integer(feature("displayModeNumber"), 0, 4096)
    brightness = fraction(feature("brightness"))
    if not current_resolution or current_rate is None or current_mode is None or brightness is None:
        return None
    volume = fraction(feature("volume"))
    contrast = fraction(feature("hardwareContrast"))
    muted = boolean(feature("mute"))
    depth = integer(feature("colorDepth"), 1, 64)
    modes = parse_modes(feature_list("displayModeList"), current_mode, current_rate)
    value = {
        "schema": 3, "ok": True,
        "brightness": round(brightness * 100),
        "volume": round(volume * 100) if volume is not None else None,
        "contrast": round(contrast * 100) if contrast is not None else None,
        "mute": muted,
        "resolution": current_resolution,
        "refresh_rate": current_rate,
        "hi_dpi": boolean(feature("hiDPI")),
        "main": boolean(feature("main")),
        "color_depth": depth,
        "mode_number": current_mode,
        "modes": modes,
        "_normalized": {
            "brightness": brightness, "hardware_contrast": contrast,
            "volume": volume, "mute": muted,
        },
        "_target_uuid": initial_uuid,
        "_target_marker": initial_marker,
    }
    final_uuid, final_marker = target_uuid(), target_marker()
    return value if (final_uuid, final_marker) == (initial_uuid, initial_marker) else None


def exact_artifact():
    return _sha256_safe_file(BETTERDISPLAY, 0o755) == APPROVED_EXECUTABLE_SHA256


def _valid_snapshot_analog(value):
    normalized = value.get("_normalized") if isinstance(value, dict) else None
    if (not isinstance(value, dict)
            or not {"brightness", "contrast", "volume", "mute", "_normalized"}.issubset(value)
            or not isinstance(normalized, dict)
            or set(normalized) != {"brightness", "hardware_contrast", "volume", "mute"}):
        return False
    for normalized_key, public_key in (
        ("brightness", "brightness"),
        ("hardware_contrast", "contrast"),
        ("volume", "volume"),
    ):
        number = normalized[normalized_key]
        if number is not None and (type(number) is not float
                                   or not math.isfinite(number) or not 0 <= number <= 1):
            return False
        expected = round(number * 100) if number is not None else None
        if value.get(public_key) != expected:
            return False
    muted = normalized["mute"]
    return ((muted is None or type(muted) is bool)
            and value.get("mute") is muted)


def snapshots_match(first, second):
    if not _valid_snapshot_analog(first) or not _valid_snapshot_analog(second):
        return False
    analog_public = {"brightness", "contrast", "volume", "mute", "_normalized"}
    first_discrete = {key: value for key, value in first.items() if key not in analog_public}
    second_discrete = {key: value for key, value in second.items() if key not in analog_public}
    if first_discrete != second_discrete:
        return False
    first_normalized, second_normalized = first["_normalized"], second["_normalized"]
    if first_normalized["mute"] is not second_normalized["mute"]:
        return False
    for key in ("brightness", "hardware_contrast", "volume"):
        first_value, second_value = first_normalized[key], second_normalized[key]
        if first_value is None or second_value is None:
            if first_value is not second_value:
                return False
        elif abs(first_value - second_value) > NORMALIZED_TOLERANCE:
            return False
    return True


def stable_snapshot(expected_uuid=None):
    if (not os.access(BETTERDISPLAY, os.X_OK) or not trusted_bundle()
            or not exact_version() or not exact_artifact() or not one_running_instance()):
        return None
    first = snapshot()
    if first is None or (expected_uuid is not None and first["_target_uuid"] != expected_uuid):
        return None
    time.sleep(0.12)
    second = snapshot()
    if (not snapshots_match(first, second)
            or (expected_uuid is not None and second["_target_uuid"] != expected_uuid)):
        return None
    return second


def _mode(status):
    return stat.S_IMODE(status.st_mode)


def _safe_directory_status(status, mode):
    return stat.S_ISDIR(status.st_mode) and status.st_uid == os.getuid() and _mode(status) == mode


def _safe_file_status(status, mode):
    return (stat.S_ISREG(status.st_mode) and status.st_uid == os.getuid()
            and status.st_nlink == 1 and _mode(status) == mode)


def _read_safe_file(path, mode, limit):
    flags = (os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
             | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    try:
        descriptor = os.open(path, flags)
    except OSError:
        return None
    try:
        opened = os.fstat(descriptor)
        current = os.lstat(path)
        if (not _safe_file_status(opened, mode)
                or not _safe_file_status(current, mode)
                or (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino)):
            return None
        chunks, total = [], 0
        while True:
            chunk = os.read(descriptor, min(65536, limit + 1 - total))
            if not chunk:
                return b"".join(chunks)
            chunks.append(chunk)
            total += len(chunk)
            if total > limit:
                return None
    except OSError:
        return None
    finally:
        os.close(descriptor)


def _sha256_safe_file(path, mode, limit=512 * 1024 * 1024):
    data = _read_safe_file(path, mode, limit)
    return hashlib.sha256(data).hexdigest() if data is not None else None


def _approved_execution_copy(path, expected_hash):
    directory = _runtime_directory(True)
    if directory is None:
        return None
    descriptor = None
    raw = None
    source_descriptor = None
    try:
        descriptor, raw = tempfile.mkstemp(prefix=".display-control-exec.", dir=directory)
        os.fchmod(descriptor, 0o500)
        source_descriptor = os.open(
            path, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
        opened = os.fstat(source_descriptor)
        if (not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.getuid()
                or opened.st_nlink != 1 or stat.S_IMODE(opened.st_mode) != 0o755):
            raise OSError("display control execution source is unsafe")
        while True:
            chunk = os.read(source_descriptor, 65536)
            if not chunk:
                break
            offset = 0
            while offset < len(chunk):
                offset += os.write(descriptor, chunk[offset:])
        os.fsync(descriptor)
        os.close(source_descriptor)
        source_descriptor = None
        os.close(descriptor)
        descriptor = None
        copied = _sha256_safe_file(raw, 0o500)
        return raw if copied == expected_hash else None
    except OSError:
        return None
    finally:
        if source_descriptor is not None:
            os.close(source_descriptor)
        if descriptor is not None:
            os.close(descriptor)
        if raw is not None and (not os.path.exists(raw) or _sha256_safe_file(raw, 0o500) != expected_hash):
            try:
                os.unlink(raw)
            except OSError:
                pass


def _checked_control(arguments, expected_hash, input_data=None, timeout=18):
    execution = _approved_execution_copy(CONTROL_BINARY, expected_hash)
    if execution is None:
        return None
    try:
        return subprocess.run(
            [execution, *arguments], input=input_data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=timeout, env=ENV, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    finally:
        try:
            os.unlink(execution)
        except OSError:
            pass


def _approved_helper_hash():
    try:
        directory_status = os.lstat(CONTROL_DIR)
        if not _safe_directory_status(directory_status, 0o700):
            return None
        if os.path.realpath(CONTROL_DIR) != os.path.normpath(CONTROL_DIR):
            return None
        marker = _read_safe_file(CONTROL_MARKER, 0o644, 256)
        binary_hash = _sha256_safe_file(CONTROL_BINARY, 0o755)
        source_hash = _sha256_safe_file(CONTROL_SOURCE, 0o644, 2 * 1024 * 1024)
    except OSError:
        return None
    if marker is None or binary_hash is None or source_hash is None:
        return None
    expected = (b"version=2\nsource_sha256=" + source_hash.encode("ascii")
                + b"\ntarget=arm64-apple-macosx15.0\nbuild_mode=-O\nbinary_sha256="
                + binary_hash.encode("ascii") + b"\n")
    if marker != expected:
        return None
    execution = _approved_execution_copy(CONTROL_BINARY, binary_hash)
    if execution is None:
        return None
    try:
        architecture = subprocess.run(
            ["/usr/bin/lipo", "-archs", execution],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            env=ENV, timeout=5, check=False)
        self_test = subprocess.run(
            [execution, "--self-test"], input=b"", stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, env=ENV, timeout=5, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    finally:
        try:
            os.unlink(execution)
        except OSError:
            pass
    if (architecture.returncode != 0 or architecture.stdout != b"arm64\n"
            or self_test.returncode != 0
            or self_test.stdout != b'{"status":"self_test_passed"}\n'
            or self_test.stderr != b""):
        return None
    if (_read_safe_file(CONTROL_MARKER, 0o644, 256) != expected
            or _sha256_safe_file(CONTROL_BINARY, 0o755) != binary_hash
            or _sha256_safe_file(CONTROL_SOURCE, 0o644, 2 * 1024 * 1024) != source_hash):
        return None
    return binary_hash


def approved_helper():
    return _approved_helper_hash() is not None


def _runtime_directory(create):
    base_input = os.environ.get("TMPDIR", "")
    if not os.path.isabs(base_input):
        return None
    base_input = os.path.normpath(base_input)
    try:
        input_status = os.lstat(base_input)
        if not _safe_directory_status(input_status, 0o700):
            return None
        base = os.path.realpath(base_input)
        child = os.path.join(base, MAP_DIRECTORY_NAME)
        base_status = os.lstat(base)
        if not _safe_directory_status(base_status, 0o700):
            return None
        base_fd = os.open(base, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
                          | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
        try:
            try:
                child_status = os.stat(MAP_DIRECTORY_NAME, dir_fd=base_fd, follow_symlinks=False)
            except FileNotFoundError:
                if not create:
                    return None
                os.mkdir(MAP_DIRECTORY_NAME, 0o700, dir_fd=base_fd)
                child_status = os.stat(MAP_DIRECTORY_NAME, dir_fd=base_fd, follow_symlinks=False)
            if not _safe_directory_status(child_status, 0o700):
                return None
        finally:
            os.close(base_fd)
        if os.path.realpath(child) != child:
            return None
        return child
    except OSError:
        return None


def _canonical_json(value):
    return json.dumps(value, separators=(",", ":"), sort_keys=True).encode("utf-8")


def _map_mac(key, nonce, target, marker):
    message = _canonical_json({"nonce": nonce, "target_uuid": target, "target_marker": marker})
    return hmac.new(key, message, hashlib.sha256).hexdigest()


def store_target(target, marker):
    if not UUID_PATTERN.fullmatch(target) or not MARKER_PATTERN.fullmatch(marker):
        return None
    directory = _runtime_directory(True)
    if directory is None:
        return None
    map_path = os.path.join(directory, MAP_FILE_NAME)
    try:
        existing = os.lstat(map_path)
    except FileNotFoundError:
        existing = None
    except OSError:
        return None
    if existing is not None and not _safe_file_status(existing, 0o600):
        return None
    if existing is not None:
        data = _read_safe_file(map_path, 0o600, 2048)
        if data is None:
            return None
        try:
            document = json.loads(data)
        except (UnicodeDecodeError, json.JSONDecodeError):
            document = None
        if (isinstance(document, dict)
                and set(document) == {"handle", "hmac_key", "target_marker", "target_uuid", "version"}
                and type(document.get("version")) is int and document["version"] == 1
                and type(document.get("handle")) is str
                and HANDLE_PATTERN.fullmatch(document["handle"])
                and document.get("target_uuid") == target
                and document.get("target_marker") == marker
                and resolve_target(document["handle"]) == target):
            return document["handle"]
    key = secrets.token_bytes(32)
    nonce = secrets.token_hex(16)
    digest = _map_mac(key, nonce, target, marker)
    handle = "v1_" + nonce + "_" + digest
    document = {
        "handle": handle,
        "hmac_key": key.hex(),
        "target_marker": marker,
        "target_uuid": target,
        "version": 1,
    }
    payload = _canonical_json(document)
    temporary = ".target-map." + secrets.token_hex(16)
    directory_fd = None
    descriptor = None
    try:
        directory_fd = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
                               | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                             | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
                             0o600, dir_fd=directory_fd)
        offset = 0
        while offset < len(payload):
            offset += os.write(descriptor, payload[offset:])
        os.fsync(descriptor)
        if not _safe_file_status(os.fstat(descriptor), 0o600):
            return None
        os.close(descriptor)
        descriptor = None
        os.replace(temporary, MAP_FILE_NAME, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
        os.fsync(directory_fd)
        final_status = os.stat(MAP_FILE_NAME, dir_fd=directory_fd, follow_symlinks=False)
        return handle if _safe_file_status(final_status, 0o600) else None
    except OSError:
        return None
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if directory_fd is not None:
            try:
                os.unlink(temporary, dir_fd=directory_fd)
            except OSError:
                pass
            os.close(directory_fd)


def resolve_target(handle):
    if not isinstance(handle, str) or not HANDLE_PATTERN.fullmatch(handle):
        return None
    directory = _runtime_directory(False)
    if directory is None:
        return None
    data = _read_safe_file(os.path.join(directory, MAP_FILE_NAME), 0o600, 2048)
    if data is None:
        return None
    try:
        document = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    if (not isinstance(document, dict)
            or set(document) != {"handle", "hmac_key", "target_marker", "target_uuid", "version"}
            or type(document.get("version")) is not int or document["version"] != 1
            or type(document.get("handle")) is not str
            or type(document.get("hmac_key")) is not str
            or type(document.get("target_marker")) is not str
            or type(document.get("target_uuid")) is not str
            or document["handle"] != handle
            or not re.fullmatch(r"[0-9a-f]{64}", document["hmac_key"])
            or not MARKER_PATTERN.fullmatch(document["target_marker"])
            or not UUID_PATTERN.fullmatch(document["target_uuid"])
            or _canonical_json(document) != data):
        return None
    nonce = handle.split("_", 2)[1]
    try:
        key = bytes.fromhex(document["hmac_key"])
    except ValueError:
        return None
    expected = "v1_" + nonce + "_" + _map_mac(
        key, nonce, document["target_uuid"], document["target_marker"]
    )
    if not hmac.compare_digest(expected, handle):
        return None
    return document["target_uuid"]


def publish(snapshot_value, action_status=None, approved_control=False):
    public = {key: value for key, value in snapshot_value.items() if not key.startswith("_")}
    capabilities = {
        "brightness": True,
        "hardware_contrast": snapshot_value["_normalized"]["hardware_contrast"] is not None,
        "volume": snapshot_value["_normalized"]["volume"] is not None,
        "mute": type(snapshot_value["_normalized"]["mute"]) is bool,
    }
    if approved_control or approved_helper():
        handle = store_target(snapshot_value["_target_uuid"], snapshot_value["_target_marker"])
        if handle is not None:
            public["target_handle"] = handle
            public["controls"] = capabilities
    if action_status is not None:
        public["status"] = action_status
    return public


def state():
    value = stable_snapshot()
    return publish(value) if value else None


def _native_process(arguments, input_data=None, timeout=18):
    return subprocess.run(arguments, input=input_data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          timeout=timeout, env=ENV, check=False)


def _self_test_passes():
    try:
        result = _native_process([CONTROL_BINARY, "--self-test"], b"", 5)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return (result.returncode == 0 and result.stdout == b'{"status":"self_test_passed"}\n'
            and result.stderr == b"")


def _normalized_argument(value):
    if not isinstance(value, str) or not re.fullmatch(r"(?:0|1|0\.[0-9]{1,6})", value):
        return None
    number = float(value)
    if not math.isfinite(number) or not 0 <= number <= 1:
        return None
    return int(number) if value in {"0", "1"} else number


def _action_values(operation, expected_text, desired_text):
    if operation not in OPERATIONS:
        return None
    if operation == "mute":
        if expected_text not in {"on", "off"} or desired_text not in {"on", "off"}:
            return None
        return expected_text == "on", desired_text == "on"
    expected = _normalized_argument(expected_text)
    desired = _normalized_argument(desired_text)
    return (expected, desired) if expected is not None and desired is not None else None


def _native_status(result):
    if result.stderr != b"" or len(result.stdout) > 64:
        return None
    for status, returncode in NATIVE_STATUSES.items():
        if result.returncode == returncode and result.stdout == ('{"status":"' + status + '"}\n').encode("ascii"):
            return status
    return None


def _desired_confirmed(snapshot_value, operation, desired):
    current = snapshot_value["_normalized"].get(operation)
    if operation == "mute":
        return type(current) is bool and current is desired
    return (type(current) is float and type(desired) in {int, float}
            and math.isfinite(current) and math.isfinite(desired)
            and abs(current - desired) <= NORMALIZED_TOLERANCE)


def action(operation, expected_text, desired_text, handle):
    values = _action_values(operation, expected_text, desired_text)
    if values is None or not isinstance(handle, str) or not HANDLE_PATTERN.fullmatch(handle):
        return "invalid_request", None, 64
    expected, desired = values
    target = resolve_target(handle)
    approved_hash = _approved_helper_hash() if target is not None else None
    if target is None or approved_hash is None:
        return "control_unavailable", None, 69
    request = {
        "desired": desired,
        "expected": expected,
        "operation": operation,
        "target_uuid": target,
    }
    input_data = _canonical_json(request)
    try:
        result = _checked_control(["transaction"], approved_hash, input_data, 18)
    except (OSError, subprocess.TimeoutExpired):
        return "control_unavailable", None, 69
    if result is None:
        return "control_unavailable", None, 69
    status = _native_status(result)
    if status is None:
        return "native_invalid", None, 70
    if status != "applied":
        return status, None, result.returncode
    refreshed = stable_snapshot(expected_uuid=target)
    if refreshed is None or not _desired_confirmed(refreshed, operation, desired):
        return "post_write_unavailable", None, 70
    return "applied", publish(
        refreshed, action_status="applied", approved_control=True), 0


def emit(value):
    print(json.dumps(value, separators=(",", ":"), sort_keys=True))
    return 0


def emit_error(status):
    emit({"ok": False, "schema": 3, "status": status})


def main(arguments):
    if arguments == ["state"]:
        value = state()
        return emit(value) if value else 1
    if len(arguments) == 5 and arguments[0] == "action":
        status, value, code = action(arguments[1], arguments[2], arguments[3], arguments[4])
        if value is not None:
            emit(value)
        else:
            emit_error(status)
        return code
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
