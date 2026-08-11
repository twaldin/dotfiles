#!/usr/bin/env python3
from pathlib import Path
import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
ITEM = (ROOT / "items/connectivity.lua").read_text()
HELPER = (ROOT / "scripts/connectivity-state.py").read_text()
NATIVE = (ROOT / "scripts/system-controls.swift").read_text()

def check(value, message):
    if not value: raise SystemExit(message)

for value in (
    '"session", "begin"', '"wifi", "state"',
    '"wifi", "set", desired, expected, captured_interface',
    '"bluetooth", "state"', 'captured.key, expected',
    'captured.connected and "disconnect" or "connect"',
    'popup.action', 'popup.on_click', 'network_connect', 'Paired devices',
):
    check(value in ITEM, f"connectivity item contract missing: {value}")
for forbidden in ('captured.address', 'wifi_state.interface)', 'tostring(wifi_state.interface)'):
    check(forbidden not in ITEM, f"raw connectivity identifier reached Lua: {forbidden}")

for value in (
    'RUNTIME_PARENT_INPUT = os.environ.get("TMPDIR", "")',
    'os.path.realpath(RUNTIME_PARENT_INPUT)',
    'stat.S_IMODE(parent.st_mode) != 0o700',
):
    check(value in HELPER, f"connectivity per-user TMPDIR contract missing: {value}")
check('/tmp/sketchybar-connectivity-' not in HELPER,
      "connectivity runtime must not use the shared temporary namespace")

for value in (
    'NETWORKSETUP = "/usr/sbin/networksetup"',
    'SYSTEM_CONTROLS = os.path.expanduser("~/.local/share/sketchybar-controls/system-controls")',
    'run([SYSTEM_CONTROLS, "bluetooth", "inventory"])',
    'input_text=json.dumps({"address": captured["_address"], "expected": old}',
    'opaque_handle("wifi", interface)', 'opaque_handle("bluetooth", address)',
    'confirm_wifi_power(', 'confirm_bluetooth_device(', 'time.sleep(delay)',
    'before["power"] is not old', 'captured["connected"] is not old',
):
    check(value in HELPER, f"connectivity helper contract missing: {value}")
for value in ('shell=True', 'osascript', '--unpair', 'setairportnetwork', 'password', '"›"', '"--power"'):
    check(value not in HELPER and value not in ITEM, f"forbidden connectivity surface present: {value}")
for value in (
    'IOBluetoothHostController.default()', 'kBluetoothHCIPowerStateON',
    'IOBluetoothDevice.pairedDevices()', 'device.openConnection()', 'device.closeConnection()',
    'BluetoothInventoryDocument', 'arguments == ["bluetooth", "inventory"]',
    'FileHandle.standardInput', 'Set(object.keys) == Set(["address", "expected"])',
):
    check(value in NATIVE, f"public Bluetooth contract missing: {value}")
check('devices.sort(key=lambda value: (not value["connected"], value["name"].lower(), value["key"]))' in HELPER,
      "connected Bluetooth devices must sort first without an address tiebreaker")

spec = importlib.util.spec_from_file_location("connectivity_state", ROOT / "scripts/connectivity-state.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

helper_path = ROOT / "scripts/connectivity-state.py"
python = [sys.executable] + (["-O"] if not __debug__ else [])
def run_helper(environment, arguments=("session", "begin")):
    return subprocess.run(
        python + [str(helper_path), *arguments], env=environment,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=10)

with tempfile.TemporaryDirectory(prefix="connectivity-tmpdir-test.") as raw:
    base = Path(raw).resolve()
    base.chmod(0o700)
    valid_environment = dict(os.environ, TMPDIR=str(base))
    valid = run_helper(valid_environment)
    runtime = base / ("sketchybar-connectivity-" + str(os.getuid()))
    secret = runtime / "session-secret"
    check(valid.returncode == 0 and valid.stderr == "" and runtime.is_dir()
          and secret.is_file() and stat.S_IMODE(runtime.stat().st_mode) == 0o700
          and stat.S_IMODE(secret.stat().st_mode) == 0o600
          and secret.stat().st_nlink == 1,
          "valid per-user TMPDIR must create private connectivity state")

    weak_parent = base / "weak"
    weak_parent.mkdir(mode=0o755)
    weak_parent.chmod(0o755)
    invalid_environments = [dict(os.environ, TMPDIR=str(weak_parent)),
                            dict(os.environ, TMPDIR="relative-connectivity-tmp")]
    missing_environment = dict(os.environ)
    missing_environment.pop("TMPDIR", None)
    invalid_environments.append(missing_environment)
    invalid_commands = [
        ("session", "begin"),
        ("wifi", "state"),
        ("bluetooth", "state"),
        ("wifi", "set", "on", "off", "0" * 64),
    ]
    for environment in invalid_environments:
        for arguments in invalid_commands:
            rejected = run_helper(environment, arguments)
            check(rejected.returncode != 0 and rejected.stdout == "" and rejected.stderr == "",
                  "every connectivity command must reject unsafe TMPDIR silently")

module.session_secret = lambda: b"s" * 32
wifi_key = module.opaque_handle("wifi", "en0")
address = "00:11:22:33:44:55"
device_key = module.opaque_handle("bluetooth", address)
commands = []
def result(stdout="", returncode=0):
    return SimpleNamespace(stdout=stdout, stderr="", returncode=returncode)
def fake_run(argv, timeout=8, input_text=None):
    commands.append((tuple(argv), input_text))
    if argv[1:] == ["-listallhardwareports"]:
        return result("Hardware Port: Wi-Fi\nDevice: en0\nEthernet Address: redacted\n")
    if argv[1:] == ["-getairportpower", "en0"]:
        return result("Wi-Fi Power (en0): On\n")
    if argv[1:] == ["wifi", "state"]:
        return result(json.dumps({
            "schema": 1, "ok": True, "association": "associated", "ssid_visibility": "visible",
            "ssid": "Example", "mode": "station", "security": "wpa3_personal",
            "rssi": -48, "noise": -92, "transmit_rate_mbps": 1200, "service_active": True,
        }))
    raise AssertionError(argv)
module.run = fake_run
state = module.wifi_state()
check(state == {
    "interface_key": wifi_key, "power": True, "ssid": "Example", "name_available": True,
    "association": "associated", "mode": "station", "security": "wpa3_personal",
    "rssi": -48, "noise": -92, "rate": 1200, "service_active": True,
}, f"rich private-target Wi-Fi fixture changed: {state!r}")
check("en0" not in json.dumps(state), "raw Wi-Fi interface escaped the helper")

sleeps = []
module.time.sleep = lambda seconds: sleeps.append(seconds)
wifi_reads = iter((
    {"interface_key": wifi_key, "power": False},
    {"interface_key": wifi_key, "power": False},
    {"interface_key": wifi_key, "power": True},
))
module.wifi_state = lambda: next(wifi_reads)
check(module.confirm_wifi_power(wifi_key, True, attempts=3, delay=0.01) == {"interface_key": wifi_key, "power": True} and len(sleeps) == 2,
      "Wi-Fi confirmation does not tolerate asynchronous state propagation")

writes = []
module.emit = lambda value: 0
module.wifi_interface = lambda: "en0"
module.run = lambda argv, timeout=8, input_text=None: (writes.append((tuple(argv), input_text)) or result())
module.wifi_state = lambda: {"interface_key": wifi_key, "power": True}
check(module.set_wifi("on", "off", wifi_key) == 75 and not writes,
      "stale Wi-Fi control wrote before rejecting the old state")
wrong_key = "0" * 64
check(module.set_wifi("on", "off", wrong_key) == 75 and not writes,
      "changed Wi-Fi target wrote before rejection")
module.wifi_state = lambda: {"interface_key": wifi_key, "power": False}
module.confirm_wifi_power = lambda key, target: {"interface_key": key, "power": target}
check(module.set_wifi("on", "off", wifi_key) == 0,
      "explicit Wi-Fi desired/expected action changed")
check(writes == [((module.NETWORKSETUP, "-setairportpower", "en0", "on"), None)],
      "Wi-Fi internal target changed")

for hostile_name in (
    "Headset " + address,
    "Headset 001122334455",
    "Headset 0011.2233.4455",
    "Headset 00:11:22:​33:44:55",
):
    module.run = lambda argv, timeout=8, input_text=None, name=hostile_name: result(json.dumps({"schema": 1, "ok": True, "devices": [
        {"address": address, "name": name, "connected": False}
    ]}))
    private_name_fixture = module.paired_devices()
    check(private_name_fixture and private_name_fixture[0]["name"] == "Bluetooth device",
          "Bluetooth identifier leaked through a rendered device name")
    check(private_name_fixture[0]["key"] == device_key, "Bluetooth opaque key changed")
module.run = lambda argv, timeout=8, input_text=None: result(json.dumps({"schema": 1, "ok": True, "devices": [
    {"address": address, "name": "Head‮set", "connected": False}
]}))
sanitary_name_fixture = module.paired_devices()
check(sanitary_name_fixture and "‮" not in sanitary_name_fixture[0]["name"],
      "Bluetooth bidi control leaked through a rendered device name")
writes.clear()
module.run = lambda argv, timeout=8, input_text=None: (writes.append((tuple(argv), input_text)) or result())
real_confirm_bluetooth = module.confirm_bluetooth_device
module.bluetooth_power = lambda: True
module.paired_devices = lambda: [{"_address": address, "key": device_key, "name": "Headset", "connected": True}]
check(module.set_bluetooth_device("connect", device_key, "off") == 75 and not writes,
      "stale Bluetooth baseband state wrote before rejection")
module.paired_devices = lambda: []
check(module.set_bluetooth_device("disconnect", device_key, "on") == 75 and not writes,
      "unpaired captured Bluetooth target wrote before rejection")
module.paired_devices = lambda: [{"_address": address, "key": device_key, "name": "Headset", "connected": True}]
module.confirm_bluetooth_device = lambda key, target: {"power": True, "devices": [{"key": key, "name": "Headset", "connected": target}]}
check(module.set_bluetooth_device("disconnect", device_key, "on") == 0,
      "Bluetooth exact-target action did not confirm")
check(writes and writes[0][0] == (module.SYSTEM_CONTROLS, "bluetooth", "disconnect"),
      "Bluetooth action is not owned by the public first-party helper")
check(address not in " ".join(writes[0][0]) and json.loads(writes[0][1]) == {"address": address, "expected": True},
      "Bluetooth address reached argv or private stdin contract changed")
check(module.set_bluetooth_device("connect", address, "off") == 64,
      "raw Bluetooth target was accepted from Lua")

sleeps.clear()
bluetooth_reads = iter((
    [{"_address": address, "key": device_key, "name": "Headset", "connected": False}],
    [{"_address": address, "key": device_key, "name": "Headset", "connected": True}],
))
module.bluetooth_power = lambda: True
module.paired_devices = lambda: next(bluetooth_reads)
confirmed = real_confirm_bluetooth(device_key, True, attempts=2, delay=0.01)
check(confirmed and confirmed["devices"][0].get("_address") is None and len(sleeps) == 1,
      "Bluetooth confirmation leaks identity or misses asynchronous propagation")
print("Opaque-target expected-state Wi-Fi and public IOBluetooth control contracts passed")
