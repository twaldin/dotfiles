#!/usr/bin/python3
import hashlib
import hmac
import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import stat
import subprocess
import sys
import tempfile
import time
import unicodedata
from xml.parsers.expat import ExpatError

NETWORKSETUP = "/usr/sbin/networksetup"
SYSTEM_PROFILER = "/usr/sbin/system_profiler"
IOREG = "/usr/sbin/ioreg"
PMSET = "/usr/bin/pmset"
OPEN = "/usr/bin/open"
CODESIGN = "/usr/bin/codesign"
SYSTEM_CONTROLS = os.path.expanduser("~/.local/share/sketchybar-controls/system-controls")
NATIVE_SOURCE = Path(__file__).with_suffix(".swift")
NATIVE_EXECUTABLE = "ConnectivityName"
NATIVE_BUNDLE_ID = "local.sketchybar.ConnectivityName"
BLUETOOTH_PUBLIC_LIMIT = 12
BLUETOOTH_PROFILES = {
    "A2DP sink", "A2DP source", "AVRCP", "AVRCP target", "File transfer",
    "Hands-free", "Hands-free gateway", "Headset", "Headset gateway", "HID",
    "Network access", "OBEX", "PAN",
}
BLUETOOTH_TYPES = {
    "Audio device", "Blood pressure monitor", "Camera", "Car audio",
    "Computer", "Controller", "Desktop computer", "Digital pen", "Display",
    "Game", "Gamepad", "Glucose meter", "Hands-free audio",
    "Handheld computer", "Headphones", "Headset", "Health device",
    "Heart-rate monitor", "Imaging device", "Joystick", "Keyboard",
    "Keyboard and pointing device", "Laptop", "Microphone",
    "Network access point", "Peripheral", "Phone", "Pointing device",
    "Printer", "Pulse oximeter", "Remote control", "Robot", "Scale",
    "Scanner", "Server computer", "Smartphone", "Speaker", "Tablet",
    "Thermometer", "Toy", "Vehicle", "Watch", "Wearable",
    "Wearable computer",
}
NAME_AUTHORIZATIONS = {
    "authorized", "denied", "not_determined", "restricted", "services_disabled",
}
WIFI_ASSOCIATIONS = {
    "associated", "host_ap", "ibss", "link_unverified", "not_associated", "unknown",
}
WIFI_MODES = {"station", "none", "ibss", "host_ap", "unknown"}
WIFI_SECURITIES = {
    "none", "wep", "wpa_personal", "wpa_personal_mixed", "wpa2_personal",
    "personal", "dynamic_wep", "wpa_enterprise", "wpa_enterprise_mixed",
    "wpa2_enterprise", "enterprise", "wpa3_personal", "wpa3_enterprise",
    "wpa3_transition", "owe", "owe_transition", "unknown",
}
WIFI_DETAIL_KEYS = {
    "schema", "ok", "interface", "radio", "association", "mode",
    "service_active", "ssid", "ssid_visibility", "bssid", "rssi", "noise",
    "transmit_rate_mbps", "security",
}
WIFI_PUBLIC_DETAIL_KEYS = WIFI_DETAIL_KEYS.difference({"interface", "radio", "bssid"})
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


def _native_paths(bundle):
    contents = bundle / "Contents"
    return contents, contents / "MacOS" / NATIVE_EXECUTABLE, contents / "Info.plist"


def _valid_native_bundle(bundle, digest):
    try:
        bundle_info = os.lstat(bundle)
        contents, executable, info_path = _native_paths(bundle)
        contents_info = os.lstat(contents)
        executable_info = os.lstat(executable)
        plist_info = os.lstat(info_path)
        document = plistlib.loads(info_path.read_bytes())
    except (FileNotFoundError, OSError, ValueError, plistlib.InvalidFileException):
        return False
    if bundle.name != "connectivity-name-" + digest + ".app":
        return False
    if any(stat.S_ISLNK(value.st_mode) or value.st_uid != os.getuid()
           for value in (bundle_info, contents_info, executable_info, plist_info)):
        return False
    if (not stat.S_ISDIR(bundle_info.st_mode) or not stat.S_ISDIR(contents_info.st_mode)
            or not stat.S_ISREG(executable_info.st_mode)
            or not stat.S_ISREG(plist_info.st_mode)
            or executable_info.st_nlink != 1 or plist_info.st_nlink != 1
            or stat.S_IMODE(bundle_info.st_mode) != 0o700
            or stat.S_IMODE(contents_info.st_mode) != 0o700
            or stat.S_IMODE(executable_info.st_mode) != 0o700
            or stat.S_IMODE(plist_info.st_mode) not in {0o600, 0o644}):
        return False
    expected = {
        "CFBundleDisplayName": "SketchyBar Network Name",
        "CFBundleExecutable": NATIVE_EXECUTABLE,
        "CFBundleIdentifier": NATIVE_BUNDLE_ID,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "SketchyBar Network Name",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "NSLocationUsageDescription": (
            "SketchyBar uses location authorization only because macOS requires it "
            "to show the associated Wi-Fi network name."
        ),
        "NSLocationWhenInUseUsageDescription": (
            "SketchyBar uses location authorization only because macOS requires it "
            "to show the associated Wi-Fi network name."
        ),
        "NSPrincipalClass": "NSApplication",
    }
    if document != expected:
        return False
    checked = subprocess.run(
        [CODESIGN, "--verify", "--strict", str(bundle)],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL, timeout=8, check=False,
    )
    return checked.returncode == 0


def compiled_native_bundle():
    source_bytes = NATIVE_SOURCE.read_bytes()
    digest = hashlib.sha256(source_bytes).hexdigest()
    _secure_runtime()
    bundle = Path(RUNTIME) / ("connectivity-name-" + digest + ".app")
    lock_path = os.path.join(RUNTIME, ".native-build.lock")
    descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600):
            raise OSError("unsafe native helper build lock")
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        if bundle.exists() or bundle.is_symlink():
            if not _valid_native_bundle(bundle, digest):
                raise OSError("unsafe cached connectivity helper")
            return bundle
        candidate = Path(tempfile.mkdtemp(prefix=".connectivity-name-", dir=RUNTIME))
        os.chmod(candidate, 0o700)
        try:
            contents, executable, info_path = _native_paths(candidate)
            executable.parent.mkdir(parents=True, mode=0o700)
            os.chmod(contents, 0o700)
            os.chmod(executable.parent, 0o700)
            document = {
                "CFBundleDisplayName": "SketchyBar Network Name",
                "CFBundleExecutable": NATIVE_EXECUTABLE,
                "CFBundleIdentifier": NATIVE_BUNDLE_ID,
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleName": "SketchyBar Network Name",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1",
                "NSLocationUsageDescription": (
                    "SketchyBar uses location authorization only because macOS requires it "
                    "to show the associated Wi-Fi network name."
                ),
                "NSLocationWhenInUseUsageDescription": (
                    "SketchyBar uses location authorization only because macOS requires it "
                    "to show the associated Wi-Fi network name."
                ),
                "NSPrincipalClass": "NSApplication",
            }
            info_path.write_bytes(plistlib.dumps(document, fmt=plistlib.FMT_BINARY,
                                                  sort_keys=True))
            os.chmod(info_path, 0o600)
            compiled = subprocess.run(
                ["/usr/bin/xcrun", "swiftc", "-parse-as-library", "-O",
                 "-warnings-as-errors", str(NATIVE_SOURCE),
                 "-framework", "AppKit", "-framework", "CoreLocation",
                 "-framework", "CoreWLAN", "-framework", "IOBluetooth",
                 "-o", str(executable)],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, timeout=60, check=False,
            )
            if compiled.returncode != 0:
                raise OSError("connectivity helper compilation failed")
            os.chmod(executable, 0o700)
            signed = subprocess.run(
                [CODESIGN, "--force", "--sign", "-", "--identifier",
                 NATIVE_BUNDLE_ID, str(candidate)],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, timeout=15, check=False,
            )
            if signed.returncode != 0:
                raise OSError("connectivity helper signing failed")
            os.replace(candidate, bundle)
            if not _valid_native_bundle(bundle, digest):
                raise OSError("unsafe installed connectivity helper")
            return bundle
        finally:
            if candidate.exists():
                import shutil
                shutil.rmtree(candidate)
    finally:
        os.close(descriptor)


def native_document(command, timeout=8):
    bundle = compiled_native_bundle()
    _, executable, _ = _native_paths(bundle)
    return json_document([str(executable), command], timeout=timeout)


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


def json_document(arguments, timeout=8):
    result = run(arguments, timeout=timeout)
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


def bounded_wifi_number(value, minimum, maximum, integer=False):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    if integer and not isinstance(value, int):
        return False
    return minimum <= value <= maximum


def valid_wifi_details(value):
    if not isinstance(value, dict) or set(value) != WIFI_DETAIL_KEYS:
        return False
    if value["schema"] != 1 or value["ok"] is not True:
        return False
    interface = value["interface"]
    bssid = value["bssid"]
    ssid = value["ssid"]
    if (interface is not None
            and (not isinstance(interface, str) or not re.fullmatch(r"en\d+", interface))):
        return False
    if bssid is not None and canonical_address(bssid) != bssid:
        return False
    if value["radio"] not in {"on", "unknown"}:
        return False
    if value["association"] not in WIFI_ASSOCIATIONS or value["mode"] not in WIFI_MODES:
        return False
    if value["security"] not in WIFI_SECURITIES:
        return False
    if value["ssid_visibility"] not in {"visible", "redacted_or_unavailable"}:
        return False
    if ssid is not None and (not isinstance(ssid, str) or len(ssid.encode("utf-8")) > 1024):
        return False
    if (value["ssid_visibility"] == "visible") != (isinstance(ssid, str) and bool(ssid)):
        return False
    if value["association"] != "associated" and ssid is not None:
        return False
    if value["service_active"] is not None and not isinstance(value["service_active"], bool):
        return False
    for name in ("rssi", "noise"):
        number = value[name]
        if number is not None and not bounded_wifi_number(number, -200, -1, integer=True):
            return False
    rate = value["transmit_rate_mbps"]
    if rate is not None and not bounded_wifi_number(rate, 0.001, 100000):
        return False
    expected_mode = {"ibss": "ibss", "host_ap": "host_ap"}.get(value["association"])
    if expected_mode and value["mode"] != expected_mode:
        return False
    if value["association"] in {"associated", "link_unverified"} and value["mode"] != "station":
        return False
    return True


def wifi_details():
    value = json_document([SYSTEM_CONTROLS, "wifi", "state"])
    if isinstance(value, dict) and set(value) == WIFI_PUBLIC_DETAIL_KEYS:
        value = dict(value, interface=None, radio="on", bssid=None)
    return value if valid_wifi_details(value) else {}


def safe_network_name(value):
    if not isinstance(value, str):
        return None
    name = clean(value)
    compact = compact_hex(name)
    if (not name or name == "<redacted>" or canonical_address(name)
            or (len(compact) == 12 and len(name) <= 17)):
        return None
    return name


def wifi_profiler_details():
    result = run([SYSTEM_PROFILER, "SPAirPortDataType", "-json"], timeout=15)
    if result.returncode != 0 or len(result.stdout) > 1048576:
        return {}
    try:
        document = json.loads(result.stdout)
    except json.JSONDecodeError:
        return {}
    roots = document.get("SPAirPortDataType") if isinstance(document, dict) else None
    if not isinstance(roots, list) or len(roots) > 16:
        return {}
    candidates = []
    channel_pattern = re.compile(r"^(\d{1,3}) \((2|5|6)GHz, (20|40|80|160)MHz\)$")
    for root in roots:
        if not isinstance(root, dict):
            continue
        interfaces = root.get("spairport_airport_interfaces", [])
        if not isinstance(interfaces, list) or len(interfaces) > 64:
            continue
        for interface in interfaces:
            if not isinstance(interface, dict):
                continue
            current = interface.get("spairport_current_network_information")
            if not isinstance(current, dict) or len(current) > 32:
                continue
            network_type = current.get("spairport_network_type")
            if network_type != "spairport_network_type_station":
                continue
            value = {"ssid": safe_network_name(current.get("_name")),
                     "phy": None, "mcs": None, "channel": None,
                     "band": None, "channel_width": None}
            phy = current.get("spairport_network_phymode")
            if phy in {"802.11a", "802.11ac", "802.11b", "802.11be",
                       "802.11g", "802.11n", "802.11ax"}:
                value["phy"] = phy
            mcs = current.get("spairport_network_mcs")
            if isinstance(mcs, int) and not isinstance(mcs, bool) and 0 <= mcs <= 15:
                value["mcs"] = mcs
            raw_channel = current.get("spairport_network_channel")
            match = channel_pattern.fullmatch(raw_channel) if isinstance(raw_channel, str) else None
            if match:
                channel = int(match.group(1))
                if 1 <= channel <= 233:
                    value["channel"] = channel
                    value["band"] = match.group(2) + " GHz"
                    value["channel_width"] = match.group(3) + " MHz"
            if any(value[field] is not None
                   for field in ("ssid", "phy", "mcs", "channel")):
                candidates.append(value)
    return candidates[0] if len(candidates) == 1 else {}


def wifi_name_details():
    empty = {"authorization": "unavailable", "ssid": None, "phy": None,
             "channel": None, "band": None, "channel_width": None}
    try:
        value = native_document("wifi")
    except (OSError, subprocess.SubprocessError, ValueError):
        return empty
    expected = {"schema", "ok", "authorization", "ssid", "phy", "channel",
                "band", "channel_width", "country_code"}
    if (not value or set(value) != expected
            or value["authorization"] not in NAME_AUTHORIZATIONS
            or (value["ssid"] is not None and not isinstance(value["ssid"], str))
            or value["phy"] not in {None, "802.11a", "802.11ac", "802.11b",
                                    "802.11be", "802.11g", "802.11n", "802.11ax"}
            or (value["channel"] is not None
                and (isinstance(value["channel"], bool)
                     or not isinstance(value["channel"], int)
                     or not 1 <= value["channel"] <= 233))
            or value["band"] not in {None, "2 GHz", "5 GHz", "6 GHz"}
            or value["channel_width"] not in {None, "20 MHz", "40 MHz", "80 MHz", "160 MHz"}
            or (value["country_code"] is not None
                and (not isinstance(value["country_code"], str)
                     or not re.fullmatch(r"[A-Z]{2}", value["country_code"])))):
        return empty
    return {"authorization": value["authorization"],
            "ssid": safe_network_name(value["ssid"]), "phy": value["phy"],
            "channel": value["channel"], "band": value["band"],
            "channel_width": value["channel_width"]}

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
    if details.get("interface") not in {None, interface}:
        details = {}
    reported_association = details.get("association")
    associated = reported_association == "associated"
    visible = details.get("ssid_visibility") == "visible"
    forbidden_bssid = canonical_address(details.get("bssid"))
    def eligible_name(value):
        name = safe_network_name(value)
        if (name and forbidden_bssid
                and forbidden_bssid.replace(":", "") in compact_hex(name)):
            return None
        return name
    ssid = eligible_name(details.get("ssid")) if associated and visible else None
    profiler = (wifi_profiler_details()
                if reported_association in {"associated", "link_unverified"} else {})
    if reported_association == "link_unverified" and profiler:
        associated = True
    ssid = ssid or eligible_name(profiler.get("ssid"))
    native_name = {}
    if associated and (not ssid or (profiler and (not profiler.get("phy")
                                                    or not profiler.get("channel")))):
        native_name = wifi_name_details()
        ssid = ssid or eligible_name(native_name.get("ssid"))
    name_permission = ("not_required" if ssid
                       else native_name.get("authorization", "unavailable"))
    def number(name):
        value = details.get(name)
        return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None
    state = {
        "interface_key": opaque_handle("wifi", interface),
        "power": enabled,
        "ssid": ssid,
        "name_available": ssid is not None,
        "association": ("associated" if associated else
                        clean(reported_association or ("unknown" if enabled else "radio_off"))),
        "mode": clean(details.get("mode") or "unknown"),
        "security": clean(details.get("security") or "unknown"),
        "rssi": number("rssi"),
        "noise": number("noise"),
        "rate": number("transmit_rate_mbps"),
        "service_active": details.get("service_active") if isinstance(details.get("service_active"), bool) else None,
    }
    if associated and not ssid:
        state["name_permission"] = name_permission
    optional = {
        "phy": profiler.get("phy") or native_name.get("phy"),
        "mcs": profiler.get("mcs"),
        "channel": profiler.get("channel") or native_name.get("channel"),
        "band": profiler.get("band") or native_name.get("band"),
        "channel_width": (profiler.get("channel_width")
                          or native_name.get("channel_width")),
    }
    state.update({key: value for key, value in optional.items() if value is not None})
    return state

def bluetooth_power():
    value = json_document([SYSTEM_CONTROLS, "bluetooth", "state"])
    if not value or set(value) != {"schema", "ok", "power"}:
        return None
    return state_word(value.get("power"))


def system_control_bluetooth_devices():
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
        if (not address or address in seen or not isinstance(value["name"], str)
                or not isinstance(value["connected"], bool)):
            return None
        seen.add(address)
        devices.append({
            "_address": address, "key": opaque_handle("bluetooth", address),
            "name": clean(value["name"] or "Bluetooth device"),
            "connected": value["connected"], "paired": True, "rssi": None,
            "type": None, "profiles": [], "battery": [],
        })
    return devices


def native_bluetooth_devices():
    value = native_document("bluetooth")
    if not value or set(value) != {"schema", "ok", "devices"}:
        return None
    raw = value["devices"]
    if not isinstance(raw, list) or len(raw) > 512:
        return None
    devices = []
    seen = set()
    expected = {"address", "name", "connected", "paired", "rssi", "type", "profiles"}
    for item in raw:
        if not isinstance(item, dict) or set(item) != expected:
            return None
        address = canonical_address(item["address"])
        rssi = item["rssi"]
        device_type = item["type"]
        profiles = item["profiles"]
        if (not address or address in seen or not isinstance(item["name"], str)
                or not isinstance(item["connected"], bool)
                or item["paired"] is not True
                or (rssi is not None and (isinstance(rssi, bool)
                                          or not isinstance(rssi, int)
                                          or not -127 <= rssi <= -1))
                or (device_type is not None and device_type not in BLUETOOTH_TYPES)
                or not isinstance(profiles, list) or len(profiles) > len(BLUETOOTH_PROFILES)
                or any(profile not in BLUETOOTH_PROFILES for profile in profiles)
                or len(set(profiles)) != len(profiles)):
            return None
        seen.add(address)
        devices.append({
            "_address": address,
            "key": opaque_handle("bluetooth", address),
            "name": clean(item["name"] or "Bluetooth device"),
            "connected": item["connected"],
            "paired": True,
            "rssi": rssi,
            "type": device_type,
            "profiles": profiles,
            "battery": [],
        })
    return devices


def battery_percentage(value):
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        number = value
    elif isinstance(value, str):
        match = re.fullmatch(r"\s*(\d{1,3})(?:\.0+)?\s*%?\s*", value)
        number = int(match.group(1)) if match else -1
    else:
        return None
    if isinstance(number, float) and not number.is_integer():
        return None
    return int(number) if 0 <= number <= 100 else None


def bluetooth_profiler_facts():
    result = run([SYSTEM_PROFILER, "SPBluetoothDataType", "-json"], timeout=15)
    if result.returncode != 0 or len(result.stdout) > 1048576:
        return {}
    try:
        document = json.loads(result.stdout)
    except json.JSONDecodeError:
        return {}
    roots = document.get("SPBluetoothDataType") if isinstance(document, dict) else None
    if not isinstance(roots, list) or len(roots) > 16:
        return {}
    facts = {}
    battery_keys = {
        "device_batteryLevelCase": "case",
        "device_batteryLevelLeft": "left",
        "device_batteryLevelRight": "right",
        "Left Battery Level": "left",
        "Right Battery Level": "right",
        "device_batteryLevelMain": "main",
    }
    type_words = {
        "audio": "Audio device", "camera": "Camera", "computer": "Computer",
        "gamepad": "Gamepad", "headphones": "Headphones", "headset": "Headset",
        "keyboard": "Keyboard", "mouse": "Pointing device", "phone": "Phone",
        "pointing": "Pointing device", "printer": "Printer", "remote": "Remote control",
        "speaker": "Speaker", "tablet": "Tablet", "trackpad": "Pointing device",
        "watch": "Watch",
    }
    for root in roots:
        if not isinstance(root, dict):
            continue
        for group_name in ("device_connected", "device_not_connected"):
            groups = root.get(group_name, [])
            if not isinstance(groups, list) or len(groups) > 512:
                continue
            for group in groups:
                if not isinstance(group, dict) or len(group) > 512:
                    continue
                for properties in group.values():
                    if not isinstance(properties, dict):
                        continue
                    address = canonical_address(properties.get("device_address"))
                    if not address:
                        continue
                    fact = facts.setdefault(address, {"battery": {}, "type": None})
                    for key, component in battery_keys.items():
                        percentage = battery_percentage(properties.get(key))
                        if percentage is not None and component not in fact["battery"]:
                            fact["battery"][component] = percentage
                    raw_type = properties.get("device_minorType")
                    if isinstance(raw_type, str) and fact["type"] is None:
                        lowered = clean(raw_type).lower()
                        matches = [label for word, label in type_words.items()
                                   if re.search(r"(?:^|[^a-z])" + re.escape(word)
                                                + r"(?:$|[^a-z])", lowered)]
                        if len(set(matches)) == 1:
                            fact["type"] = matches[0]
    return facts


def address_value(value):
    if isinstance(value, bytes):
        if len(value) == 6:
            return ":".join(f"{byte:02x}" for byte in value)
        try:
            value = value.decode("ascii")
        except UnicodeDecodeError:
            return None
    if not isinstance(value, str):
        return None
    compact = value.lower()
    if re.fullmatch(r"[0-9a-f]{12}", compact):
        return ":".join(compact[index:index + 2] for index in range(0, 12, 2))
    return canonical_address(value)


def bluetooth_ioreg_batteries():
    result = run([IOREG, "-a", "-r", "-c", "AppleDeviceManagementHIDEventService"],
                 timeout=10)
    if result.returncode != 0 or len(result.stdout) > 1048576:
        return {}
    try:
        values = plistlib.loads(result.stdout.encode("utf-8"))
    except (ValueError, plistlib.InvalidFileException, UnicodeError, ExpatError):
        return {}
    if not isinstance(values, list) or len(values) > 512:
        return {}
    batteries = {}
    for value in values:
        if not isinstance(value, dict) or value.get("BluetoothDevice") is not True:
            continue
        addresses = {address_value(value.get(key))
                     for key in ("DeviceAddress", "SerialNumber", "BD_ADDR")}
        addresses.discard(None)
        if len(addresses) != 1:
            continue
        percentage = battery_percentage(value.get("BatteryPercent"))
        if percentage is not None:
            batteries[next(iter(addresses))] = {"main": percentage}
    return batteries


def bluetooth_pmset_batteries():
    result = run([PMSET, "-g", "accps", "-xml"], timeout=10)
    if result.returncode != 0 or len(result.stdout) > 1048576:
        return {}
    batteries = {}
    chunks = ["<?xml" + chunk for chunk in result.stdout.split("<?xml") if chunk.strip()]
    if len(chunks) > 512:
        return {}
    component_names = {"case": "case", "left": "left", "right": "right",
                       "combined": "main", "main": "main"}
    for chunk in chunks:
        try:
            value = plistlib.loads(chunk.encode("utf-8"))
        except (ValueError, plistlib.InvalidFileException, UnicodeError, ExpatError):
            continue
        if not isinstance(value, dict):
            continue
        address = address_value(value.get("Accessory Identifier"))
        percentage = battery_percentage(value.get("Current Capacity"))
        if not address or percentage is None:
            continue
        raw_part = value.get("Part Identifier", "main")
        component = component_names.get(str(raw_part).lower())
        if component:
            batteries.setdefault(address, {})[component] = percentage
    return batteries


def paired_devices():
    try:
        devices = native_bluetooth_devices()
    except (OSError, subprocess.SubprocessError, ValueError):
        devices = None
    if devices is None:
        devices = system_control_bluetooth_devices()
    if devices is None:
        return None
    profiler = bluetooth_profiler_facts()
    ioreg_batteries = bluetooth_ioreg_batteries()
    pmset_batteries = bluetooth_pmset_batteries()
    for device in devices:
        address = device["_address"]
        profile_fact = profiler.get(address, {})
        if device["type"] is None and profile_fact.get("type") in BLUETOOTH_TYPES:
            device["type"] = profile_fact["type"]
        combined = {}
        for source in (profile_fact.get("battery", {}),
                       ioreg_batteries.get(address, {}),
                       pmset_batteries.get(address, {})):
            for component, percentage in source.items():
                if component in {"case", "left", "main", "right"}:
                    combined.setdefault(component, percentage)
        device["battery"] = [
            {"component": component, "percent": combined[component]}
            for component in ("main", "left", "right", "case") if component in combined
        ]
    compact_addresses = tuple(device["_address"].replace(":", "") for device in devices)
    for device in devices:
        name_hex = compact_hex(device["name"])
        if any(address in name_hex for address in compact_addresses):
            device["name"] = "Bluetooth device"
    devices.sort(key=lambda value: (not value["connected"], value["name"].lower(), value["key"]))
    return devices

def public_bluetooth_state(enabled, devices):
    inventory_available = devices is not None
    total_count = len(devices) if inventory_available else None
    return {
        "power": enabled,
        "inventory_available": inventory_available,
        "total_count": total_count,
        "truncated": (total_count > BLUETOOTH_PUBLIC_LIMIT
                      if total_count is not None else False),
        "devices": [
            {"key": device["key"], "name": device["name"],
             "connected": device["connected"], "paired": device.get("paired", True),
             "rssi": device.get("rssi"), "type": device.get("type"),
             "profiles": device.get("profiles", []), "battery": device.get("battery", [])}
            for device in (devices or [])[:BLUETOOTH_PUBLIC_LIMIT]
        ],
    }


def bluetooth_state():
    enabled = bluetooth_power()
    if enabled is None:
        return None
    devices = paired_devices()
    return public_bluetooth_state(enabled, devices)


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
            return public_bluetooth_state(True, devices)
        if attempt + 1 < attempts:
            time.sleep(delay)
    return None


def emit(value):
    print(json.dumps(value, separators=(",", ":"), sort_keys=True))
    return 0


def authorize_wifi_name():
    before = wifi_state()
    if not before or before["association"] != "associated" or before["name_available"]:
        return emit(before) if before else 1
    permission = before["name_permission"]
    if permission == "not_determined":
        bundle = compiled_native_bundle()
        requested = run([OPEN, "-W", "-n", str(bundle), "--args", "request"],
                        timeout=140)
        if requested.returncode != 0:
            return 1
    elif permission in {"denied", "restricted", "services_disabled"}:
        opened = run([OPEN, "-a", "System Settings"])
        if opened.returncode != 0:
            return 1
    value = wifi_state()
    return emit(value) if value else 1


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
    if arguments == ["wifi", "authorize-name"]:
        return authorize_wifi_name()
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
