#!/usr/bin/python3
import hashlib
import hmac
import json
import os
import re
import secrets
import stat
import subprocess
import sys
import time
import unicodedata

NETWORKSETUP = "/usr/sbin/networksetup"
SYSTEM_CONTROLS = os.path.expanduser("~/.local/share/sketchybar-controls/system-controls")
ENV = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": os.path.expanduser("~"), "LANG": "C", "LC_ALL": "C"}
ADDRESS_PATTERN = re.compile(r"[0-9a-f]{2}(?::[0-9a-f]{2}){5}")
HANDLE_PATTERN = re.compile(r"[0-9a-f]{64}")
RUNTIME_PARENT_INPUT = os.environ.get("TMPDIR", "")
RUNTIME_PARENT = (os.path.realpath(RUNTIME_PARENT_INPUT)
                  if os.path.isabs(RUNTIME_PARENT_INPUT) else "")
RUNTIME = (os.path.join(RUNTIME_PARENT, f"sketchybar-connectivity-{os.getuid()}")
           if RUNTIME_PARENT else "")
SECRET = os.path.join(RUNTIME, "session-secret") if RUNTIME else ""
REJECTED_SCALAR_RANGES = (
    (0x00AD, 0x00AD), (0x034F, 0x034F), (0x0600, 0x0605), (0x061C, 0x061D),
    (0x06DD, 0x06DD), (0x070F, 0x070F), (0x0890, 0x0891), (0x08E2, 0x08E2),
    (0x115F, 0x1160), (0x17B4, 0x17B5), (0x180B, 0x180F), (0x200B, 0x200F),
    (0x202A, 0x202E), (0x2060, 0x206F), (0x3164, 0x3164), (0xFE00, 0xFE0F),
    (0xFEFF, 0xFEFF), (0xFFA0, 0xFFA0), (0xFFF0, 0xFFFB), (0x110BD, 0x110BD),
    (0x110CD, 0x110CD), (0x13430, 0x13455), (0x1BCA0, 0x1BCA3),
    (0x1D173, 0x1D17A), (0xE0000, 0xE0FFF),
)


def _secure_runtime():
    if (not RUNTIME_PARENT or not RUNTIME
            or os.path.dirname(RUNTIME) != RUNTIME_PARENT
            or SECRET != os.path.join(RUNTIME, "session-secret")):
        raise OSError("unsafe connectivity runtime")
    parent = os.lstat(RUNTIME_PARENT)
    if (not stat.S_ISDIR(parent.st_mode) or stat.S_ISLNK(parent.st_mode)
            or parent.st_uid != os.getuid()
            or stat.S_IMODE(parent.st_mode) != 0o700
            or os.path.realpath(RUNTIME_PARENT) != RUNTIME_PARENT):
        raise OSError("unsafe connectivity runtime parent")
    try:
        os.mkdir(RUNTIME, 0o700)
    except FileExistsError:
        pass
    info = os.lstat(RUNTIME)
    if (not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode)
            or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700):
        raise OSError("unsafe connectivity runtime")


def _read_secret():
    _secure_runtime()
    descriptor = os.open(SECRET, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600
                or info.st_size != 32):
            raise OSError("unsafe connectivity secret")
        value = os.read(descriptor, 33)
        if len(value) != 32:
            raise OSError("malformed connectivity secret")
        return value
    finally:
        os.close(descriptor)


def _write_secret():
    _secure_runtime()
    candidate = os.path.join(RUNTIME, ".session-secret-" + secrets.token_hex(16))
    descriptor = os.open(candidate, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        value = secrets.token_bytes(32)
        if os.write(descriptor, value) != len(value):
            raise OSError("short connectivity secret write")
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    try:
        os.replace(candidate, SECRET)
    finally:
        try:
            os.unlink(candidate)
        except FileNotFoundError:
            pass
    return _read_secret()


def session_secret():
    try:
        return _read_secret()
    except FileNotFoundError:
        return _write_secret()


def opaque_handle(kind, value):
    return hmac.new(session_secret(), (kind + "\0" + value).encode("utf-8"), hashlib.sha256).hexdigest()


def begin_session():
    _write_secret()
    return {"schema": 1, "ok": True}


def run(arguments, timeout=8, input_text=None):
    return subprocess.run(arguments,
                          stdin=subprocess.DEVNULL if input_text is None else None,
                          input=input_text, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, text=True, timeout=timeout,
                          env=ENV, check=False)


def rejected_scalar(character):
    scalar = ord(character)
    category = unicodedata.category(character)
    if category in {"Cc", "Cf", "Zl", "Zp", "Co", "Cs"}:
        return True
    if any(start <= scalar <= end for start, end in REJECTED_SCALAR_RANGES):
        return True
    return 0xFDD0 <= scalar <= 0xFDEF or scalar & 0xFFFF in {0xFFFE, 0xFFFF}


def clean(value):
    accepted = []
    separator_pending = False
    for character in str(value):
        if rejected_scalar(character) or character.isspace():
            separator_pending = bool(accepted)
            continue
        if separator_pending:
            accepted.append(" ")
            separator_pending = False
        accepted.append(character)
    result = []
    byte_count = 0
    for character in accepted:
        encoded = len(character.encode("utf-8"))
        if len(result) >= 80 or byte_count + encoded > 256:
            break
        result.append(character)
        byte_count += encoded
    return "".join(result).strip()


def compact_hex(value):
    return "".join(character for character in value.lower() if character in "0123456789abcdef")


def state_word(value):
    return {"on": True, "off": False}.get(value)


def canonical_address(value):
    if not isinstance(value, str):
        return None
    address = value.lower().replace("-", ":")
    return address if ADDRESS_PATTERN.fullmatch(address) else None


def json_document(arguments):
    result = run(arguments)
    if result.returncode != 0 or len(result.stdout) > 65536:
        return None
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None
    if not isinstance(value, dict) or value.get("schema") != 1 or value.get("ok") is not True:
        return None
    return value


def wifi_interface():
    result = run([NETWORKSETUP, "-listallhardwareports"])
    if result.returncode != 0:
        return None
    blocks = result.stdout.split("\n\n")
    for block in blocks:
        if "Hardware Port: Wi-Fi" in block or "Hardware Port: AirPort" in block:
            match = re.search(r"^Device: (\S+)$", block, re.MULTILINE)
            if match and re.fullmatch(r"en\d+", match.group(1)):
                return match.group(1)
    return None


def wifi_details():
    return json_document([SYSTEM_CONTROLS, "wifi", "state"]) or {}


def wifi_state():
    interface = wifi_interface()
    if not interface:
        return None
    power = run([NETWORKSETUP, "-getairportpower", interface])
    if power.returncode != 0:
        return None
    line = power.stdout.rstrip()
    if not (line.endswith(": On") or line.endswith(": Off")):
        return None
    enabled = line.endswith(": On")
    details = wifi_details() if enabled else {}
    associated = details.get("association") == "associated"
    visible = details.get("ssid_visibility") == "visible"
    ssid = clean(details.get("ssid")) if associated and visible and details.get("ssid") else None
    def number(name):
        value = details.get(name)
        return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None
    return {
        "interface_key": opaque_handle("wifi", interface),
        "power": enabled,
        "ssid": ssid,
        "name_available": ssid is not None,
        "association": clean(details.get("association") or ("not_associated" if enabled else "radio_off")),
        "mode": clean(details.get("mode") or "unknown"),
        "security": clean(details.get("security") or "unknown"),
        "rssi": number("rssi"),
        "noise": number("noise"),
        "rate": number("transmit_rate_mbps"),
        "service_active": details.get("service_active") if isinstance(details.get("service_active"), bool) else None,
    }


def bluetooth_power():
    value = json_document([SYSTEM_CONTROLS, "bluetooth", "state"])
    if not value or set(value) != {"schema", "ok", "power"}:
        return None
    return state_word(value.get("power"))


def paired_devices():
    paired = run([SYSTEM_CONTROLS, "bluetooth", "inventory"])
    if paired.returncode != 0 or len(paired.stdout) > 262144:
        return None
    try:
        document = json.loads(paired.stdout)
    except json.JSONDecodeError:
        return None
    if (not isinstance(document, dict) or set(document) != {"schema", "ok", "devices"}
            or document["schema"] != 1 or document["ok"] is not True):
        return None
    raw = document["devices"]
    if not isinstance(raw, list) or len(raw) > 512:
        return None
    devices = []
    seen = set()
    for value in raw:
        if not isinstance(value, dict) or set(value) != {"address", "name", "connected"}:
            return None
        address = canonical_address(value["address"])
        connected = value["connected"]
        if not address or not isinstance(value["name"], str) or not isinstance(connected, bool) or address in seen:
            return None
        seen.add(address)
        devices.append({
            "_address": address,
            "key": opaque_handle("bluetooth", address),
            "name": clean(value.get("name") or "Bluetooth device"),
            "connected": connected,
        })
    compact_addresses = tuple(device["_address"].replace(":", "") for device in devices)
    for device in devices:
        name_hex = compact_hex(device["name"])
        if any(address in name_hex for address in compact_addresses):
            device["name"] = "Bluetooth device"
    devices.sort(key=lambda value: (not value["connected"], value["name"].lower(), value["key"]))
    return devices


def bluetooth_state():
    enabled = bluetooth_power()
    if enabled is None:
        return None
    devices = paired_devices() if enabled else []
    if devices is None:
        return None
    return {"power": enabled, "devices": [
        {"key": device["key"], "name": device["name"], "connected": device["connected"]}
        for device in devices[:12]
    ]}


def confirm_wifi_power(interface_key, target, attempts=12, delay=0.2):
    for attempt in range(attempts):
        value = wifi_state()
        if value and value["interface_key"] == interface_key and value["power"] is target:
            return value
        if attempt + 1 < attempts:
            time.sleep(delay)
    return None


def exact_device(devices, key):
    matches = [device for device in devices or [] if device["key"] == key]
    return matches[0] if len(matches) == 1 else None


def confirm_bluetooth_device(key, target, attempts=15, delay=0.2):
    for attempt in range(attempts):
        enabled = bluetooth_power()
        devices = paired_devices() if enabled is True else None
        confirmed = exact_device(devices, key)
        if confirmed and confirmed["connected"] is target:
            return {"power": True, "devices": [
                {"key": device["key"], "name": device["name"], "connected": device["connected"]}
                for device in devices[:12]
            ]}
        if attempt + 1 < attempts:
            time.sleep(delay)
    return None


def emit(value):
    print(json.dumps(value, separators=(",", ":"), sort_keys=True))
    return 0


def set_wifi(desired, expected, interface_key):
    target = state_word(desired)
    old = state_word(expected)
    if target is None or old is None or target is old or not HANDLE_PATTERN.fullmatch(interface_key):
        return 64
    interface = wifi_interface()
    if not interface or opaque_handle("wifi", interface) != interface_key:
        return 75
    before = wifi_state()
    if not before or before["interface_key"] != interface_key or before["power"] is not old:
        return 75
    changed = run([NETWORKSETUP, "-setairportpower", interface, desired])
    if changed.returncode != 0:
        return 1
    value = confirm_wifi_power(interface_key, target)
    return emit(value) if value else 75


def set_bluetooth_device(action, key, expected):
    target = {"connect": True, "disconnect": False}.get(action)
    old = state_word(expected)
    if target is None or old is None or target is old or not HANDLE_PATTERN.fullmatch(key):
        return 64
    if bluetooth_power() is not True:
        return 75
    devices = paired_devices()
    captured = exact_device(devices, key)
    if not captured or captured["connected"] is not old:
        return 75
    changed = run(
        [SYSTEM_CONTROLS, "bluetooth", action], timeout=15,
        input_text=json.dumps({"address": captured["_address"], "expected": old}, separators=(",", ":")),
    )
    if changed.returncode != 0:
        return 1
    value = confirm_bluetooth_device(key, target)
    return emit(value) if value else 75


def dispatch(arguments):
    _secure_runtime()
    if arguments == ["session", "begin"]:
        return emit(begin_session())
    if arguments == ["wifi", "state"]:
        value = wifi_state()
        return emit(value) if value else 1
    if len(arguments) == 5 and arguments[:2] == ["wifi", "set"]:
        return set_wifi(arguments[2], arguments[3], arguments[4])
    if arguments == ["bluetooth", "state"]:
        value = bluetooth_state()
        return emit(value) if value else 1
    if len(arguments) == 4 and arguments[0] == "bluetooth":
        return set_bluetooth_device(arguments[1], arguments[2], arguments[3])
    return 64


def main(arguments):
    try:
        return dispatch(arguments)
    except (OSError, subprocess.SubprocessError, ValueError, TypeError,
            KeyError, UnicodeError):
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
