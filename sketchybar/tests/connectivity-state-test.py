#!/usr/bin/python3
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "scripts/connectivity-state.py"
NATIVE_SOURCE = ROOT / "scripts/connectivity-state.swift"


def check(value, message):
    if not value:
        raise SystemExit(message)


def load_helper():
    specification = importlib.util.spec_from_file_location("connectivity_state_fixtures", SOURCE)
    check(specification is not None and specification.loader is not None,
          "connectivity helper import is unavailable")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def result(stdout="", returncode=0):
    return SimpleNamespace(stdout=stdout, stderr="", returncode=returncode)


def public_strings(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True)


def native_inventory(devices):
    return {"schema": 1, "ok": True, "devices": devices}


check(SOURCE.is_file() and NATIVE_SOURCE.is_file(),
      "connectivity helper sources are missing")
source_text = SOURCE.read_text() + NATIVE_SOURCE.read_text()
check("assert " not in source_text and "assert(" not in source_text,
      "connectivity helpers must not depend on optimizable assertions")
check("os.environ.get(\"CONNECTIVITY" not in source_text
      and "ProcessInfo.processInfo.environment" not in source_text,
      "connectivity helpers must not have a production environment fault seam")

module = load_helper()
real_paired_devices = module.paired_devices
real_wifi_profiler_details = module.wifi_profiler_details
module.session_secret = lambda: b"f" * 32
module.wifi_interface = lambda: "en7"

profiler_document = {
    "SPAirPortDataType": [{
        "spairport_airport_interfaces": [{
            "spairport_current_network_information": {
                "_name": "Current Fixture", "spairport_network_type": "spairport_network_type_station",
                "spairport_network_channel": "69 (6GHz, 160MHz)",
                "spairport_network_mcs": 12, "spairport_network_phymode": "802.11ax",
            },
            "spairport_other_local_wireless_networks": [{"_name": "Neighbor must stay private"}],
        }]
    }, {
        "spairport_airport_interfaces": [{
            "spairport_current_network_information": {
                "spairport_network_type": "spairport_network_type_station",
            }
        }]
    }]
}
module.run = lambda argv, timeout=8, input_text=None: result(json.dumps(profiler_document))
profiler = real_wifi_profiler_details()
check(profiler == {
          "ssid": "Current Fixture", "phy": "802.11ax", "mcs": 12,
          "channel": 69, "band": "6 GHz", "channel_width": "160 MHz",
      } and "Neighbor" not in public_strings(profiler),
      "Wi-Fi profiler must accept only one detailed fixed current-network node")
profiler_document["SPAirPortDataType"][0]["spairport_airport_interfaces"][0]["spairport_current_network_information"]["_name"] = "aa:bb:cc:dd:ee:ff"
module.run = lambda argv, timeout=8, input_text=None: result(json.dumps(profiler_document))
check(real_wifi_profiler_details()["ssid"] is None,
      "address-shaped profiler network name must fail the public privacy boundary")

valid_wifi_contract = {
    "schema": 1, "ok": True, "interface": "en7", "radio": "on",
    "association": "associated", "mode": "station", "service_active": True,
    "ssid": None, "ssid_visibility": "redacted_or_unavailable", "bssid": None,
    "rssi": -48, "noise": -92, "transmit_rate_mbps": 1200,
    "security": "wpa3_personal",
}
check(module.valid_wifi_details(valid_wifi_contract),
      "closed Wi-Fi detail fixture was rejected")
for key, hostile in (("association", "associated-en7"), ("security", "serial-like-secret"),
                     ("rssi", -500), ("transmit_rate_mbps", 100001),
                     ("service_active", "yes")):
    candidate = dict(valid_wifi_contract)
    candidate[key] = hostile
    check(not module.valid_wifi_details(candidate),
          "drifted Wi-Fi detail value escaped validation: " + key)

module.wifi_profiler_details = lambda: {}
module.wifi_name_details = lambda: {
    "authorization": "not_determined", "ssid": None, "phy": None,
    "channel": None, "band": None, "channel_width": None,
}
wifi_key = module.opaque_handle("wifi", "en7")

module.run = lambda argv, timeout=8, input_text=None: result("Wi-Fi Power (en7): On\n")
module.wifi_details = lambda: dict(valid_wifi_contract, interface="en8")
module.wifi_profiler_details = lambda: check(
    False, "mismatched Wi-Fi interface details must not reach the profiler fallback")
mismatched_interface = module.wifi_state()
check(mismatched_interface is not None
      and mismatched_interface["association"] == "unknown"
      and mismatched_interface["mode"] == "unknown"
      and mismatched_interface["rssi"] is None
      and mismatched_interface.get("phy") is None,
      "Wi-Fi state mixed details from a different controllable interface")
module.wifi_profiler_details = lambda: {}

association_cases = (
    ("associated", "station"),
    ("link_unverified", "station"),
    ("not_associated", "station"),
    ("ibss", "ibss"),
    ("host_ap", "host_ap"),
    ("unknown", "unknown"),
)
for association, mode in association_cases:
    module.run = lambda argv, timeout=8, input_text=None: result("Wi-Fi Power (en7): On\n")
    module.wifi_details = lambda association=association, mode=mode: {
        "association": association,
        "mode": mode,
        "service_active": association != "unknown",
        "ssid_visibility": "visible",
        "ssid": "Fixture" if association == "associated" else None,
        "security": "wpa3_personal" if association == "associated" else "unknown",
        "rssi": -51 if association == "associated" else None,
        "noise": -93 if association == "associated" else None,
        "transmit_rate_mbps": 866 if association == "associated" else None,
    }
    state = module.wifi_state()
    check(state is not None and state["association"] == association
          and state["mode"] == mode
          and state["service_active"] is (association != "unknown")
          and state["interface_key"] == wifi_key,
          "Wi-Fi association, mode, or service fixture changed: " + association)
    check(state.get("name_permission") is None,
          "visible or inapplicable Wi-Fi name must not add a permission gate: " + association)
    check("en7" not in public_strings(state),
          "raw Wi-Fi interface entered public state")

module.run = lambda argv, timeout=8, input_text=None: result("Wi-Fi Power (en7): Off\n")
module.wifi_details = lambda: check(False, "radio-off Wi-Fi state must not query link details")
off_wifi = module.wifi_state()
check(off_wifi is not None and off_wifi["power"] is False
      and off_wifi["association"] == "radio_off" and off_wifi["mode"] == "unknown"
      and off_wifi["service_active"] is None and off_wifi["rssi"] is None
      and off_wifi["noise"] is None and off_wifi.get("name_permission") is None,
      "radio-off Wi-Fi association fixture changed")

module.run = lambda argv, timeout=8, input_text=None: result("Wi-Fi Power (en7): On\n")
module.wifi_details = lambda: {
    "association": "associated", "mode": "station", "service_active": True,
    "ssid_visibility": "redacted_or_unavailable", "ssid": None,
    "security": "wpa2_personal", "rssi": -47, "noise": None,
    "transmit_rate_mbps": 400,
}
module.wifi_name_details = lambda: {
    "authorization": "not_determined", "ssid": None, "phy": "802.11ax",
    "channel": 69, "band": "6 GHz", "channel_width": "160 MHz",
}
rssi_only = module.wifi_state()
check(rssi_only["rssi"] == -47 and rssi_only["noise"] is None
      and rssi_only["association"] == "associated"
      and rssi_only["name_permission"] == "not_determined",
      "RSSI-only associated Wi-Fi evidence or permission state was not preserved")
module.wifi_details = lambda: {
    "association": "associated", "mode": "station", "service_active": True,
    "ssid_visibility": "redacted_or_unavailable", "ssid": None,
    "security": "wpa2_personal", "rssi": None, "noise": -96,
    "transmit_rate_mbps": 400,
}
noise_only = module.wifi_state()
check(noise_only["rssi"] is None and noise_only["noise"] == -96,
      "noise-only Wi-Fi evidence was not preserved independently")
module.wifi_name_details = lambda: {
    "authorization": "authorized", "ssid": "Authorized Fixture", "phy": "802.11ax",
    "channel": 69, "band": "6 GHz", "channel_width": "160 MHz",
}
authorized_name = module.wifi_state()
check(authorized_name["ssid"] == "Authorized Fixture"
      and authorized_name["name_available"] is True
      and authorized_name.get("name_permission") is None
      and authorized_name["phy"] == "802.11ax"
      and authorized_name["channel"] == 69
      and authorized_name["band"] == "6 GHz"
      and authorized_name["channel_width"] == "160 MHz",
      "authorized helper name or link facts were not read back into associated Wi-Fi state")

module.wifi_details = lambda: {
    "schema": 1, "ok": True, "interface": None, "radio": "on",
    "association": "associated", "mode": "station", "service_active": True,
    "ssid": None, "ssid_visibility": "redacted_or_unavailable", "bssid": None,
    "rssi": -50, "noise": -90, "transmit_rate_mbps": 600,
    "security": "wpa3_personal",
}
module.wifi_profiler_details = lambda: {
    "ssid": "Profiler Fixture", "phy": "802.11be", "mcs": 13,
    "channel": 37, "band": "6 GHz", "channel_width": "80 MHz",
}
module.wifi_name_details = lambda: check(False, "complete profiler facts must avoid a helper read")
profiler_name = module.wifi_state()
check(profiler_name["ssid"] == "Profiler Fixture"
      and profiler_name.get("name_permission") is None
      and profiler_name["phy"] == "802.11be" and profiler_name["mcs"] == 13
      and profiler_name["channel"] == 37 and profiler_name["band"] == "6 GHz"
      and profiler_name["channel_width"] == "80 MHz",
      "normalized public-helper state did not retain fixed current-network profiler facts")
module.wifi_details = lambda: {
    "schema": 1, "ok": True, "interface": None, "radio": "on",
    "association": "link_unverified", "mode": "station", "service_active": True,
    "ssid": None, "ssid_visibility": "redacted_or_unavailable", "bssid": None,
    "rssi": None, "noise": None, "transmit_rate_mbps": None,
    "security": "unknown",
}
profiler_proved_link = module.wifi_state()
check(profiler_proved_link["association"] == "associated"
      and profiler_proved_link["ssid"] == "Profiler Fixture"
      and profiler_proved_link["phy"] == "802.11be"
      and profiler_proved_link["channel"] == 37,
      "fixed current-network profiler evidence did not resolve an unverified station link")
module.wifi_profiler_details = lambda: {}

request_reads = iter((
    {"association": "associated", "name_available": False,
     "name_permission": "not_determined"},
    {"association": "associated", "name_available": True,
     "name_permission": "not_required", "ssid": "Readback"},
))
module.wifi_state = lambda: next(request_reads)
module.compiled_native_bundle = lambda: Path("/private/connectivity-name.app")
authorization_commands = []
module.run = lambda argv, timeout=8, input_text=None: (
    authorization_commands.append((argv, timeout)) or result())
emitted = []
module.emit = lambda value: emitted.append(value) or 0
check(module.authorize_wifi_name() == 0
      and authorization_commands == [([
          module.OPEN, "-W", "-n", "/private/connectivity-name.app", "--args", "request"
      ], 140)]
      and emitted[-1]["ssid"] == "Readback",
      "network-name authorization must request in the foreground and emit exact readback")

denied_reads = iter((
    {"association": "associated", "name_available": False,
     "name_permission": "denied"},
    {"association": "associated", "name_available": False,
     "name_permission": "denied"},
))
module.wifi_state = lambda: next(denied_reads)
authorization_commands.clear()
check(module.authorize_wifi_name() == 0
      and authorization_commands == [([module.OPEN, "-a", "System Settings"], 8)]
      and emitted[-1]["name_permission"] == "denied",
      "denied network-name action must open System Settings and emit current readback")

addresses = ["02:00:00:%02x:%02x:%02x" %
             (index // 65536, (index // 256) % 256, index % 256)
             for index in range(14)]
raw_devices = [
    {"address": address, "name": "Fixture %02d" % index,
     "connected": index % 3 == 0, "paired": True,
     "rssi": -40 - index if index % 3 == 0 else None,
     "type": "Headphones" if index == 0 else None,
     "profiles": ["A2DP sink"] if index == 0 else []}
    for index, address in enumerate(addresses)
]
module.native_document = lambda command, timeout=8: native_inventory(raw_devices)
module.bluetooth_profiler_facts = lambda: {
    addresses[0]: {"type": "Headset", "battery": {"left": 81, "right": 79}}
}
module.bluetooth_ioreg_batteries = lambda: {addresses[0]: {"main": 80}}
module.bluetooth_pmset_batteries = lambda: {addresses[0]: {"case": 60}}
private_inventory = module.paired_devices()
check(private_inventory is not None and len(private_inventory) == 14,
      "valid Bluetooth inventory above the public limit was rejected")
first = next(device for device in private_inventory if device["_address"] == addresses[0])
check(first["paired"] is True and first["connected"] is True and first["rssi"] == -40
      and first["type"] == "Headphones" and first["profiles"] == ["A2DP sink"]
      and first["battery"] == [
          {"component": "main", "percent": 80},
          {"component": "left", "percent": 81},
          {"component": "right", "percent": 79},
          {"component": "case", "percent": 60},
      ], "Bluetooth paired, connection, RSSI, type, profile, or battery merge changed")
module.bluetooth_power = lambda: True
module.paired_devices = lambda: private_inventory
public_state = module.bluetooth_state()
expected_keys = {"power", "inventory_available", "total_count", "truncated", "devices"}
expected_device_keys = {
    "key", "name", "connected", "paired", "rssi", "type", "profiles", "battery",
}
check(set(public_state) == expected_keys
      and public_state["inventory_available"] is True
      and public_state["total_count"] == 14
      and public_state["truncated"] is True
      and len(public_state["devices"]) == module.BLUETOOTH_PUBLIC_LIMIT,
      "truncated Bluetooth public schema or exact total changed")
check(all(set(device) == expected_device_keys for device in public_state["devices"]),
      "Bluetooth device public schema is not closed")
serialized = public_strings(public_state)
check(all(address not in serialized and address.replace(":", "") not in serialized
          for address in addresses),
      "raw Bluetooth address entered public state")
check(all(module.HANDLE_PATTERN.fullmatch(device["key"])
          for device in public_state["devices"]),
      "Bluetooth state did not publish session handles only")

module.paired_devices = lambda: []
empty_state = module.bluetooth_state()
check(empty_state == {
          "power": True, "inventory_available": True, "total_count": 0,
          "truncated": False, "devices": [],
      }, "proved-zero Bluetooth inventory changed")

module.bluetooth_power = lambda: True
module.paired_devices = lambda: None
unavailable_state = module.bluetooth_state()
check(unavailable_state == {
          "power": True, "inventory_available": False, "total_count": None,
          "truncated": False, "devices": [],
      }, "known-on Bluetooth state must preserve power when inventory cannot be read")

inventory_called = []
module.bluetooth_power = lambda: False
module.paired_devices = lambda: inventory_called.append(True) or []
off_state = module.bluetooth_state()
check(off_state == {
          "power": False, "inventory_available": True, "total_count": 0,
          "truncated": False, "devices": [],
      } and inventory_called,
      "radio-off Bluetooth state must still use the available paired inventory")

module.native_document = lambda command, timeout=8: native_inventory(raw_devices * 37)
check(module.native_bluetooth_devices() is None,
      "Bluetooth inventory above the private validation limit must fail closed")
module.native_document = lambda command, timeout=8: native_inventory([
    {**raw_devices[0], "paired": False}
])
check(module.native_bluetooth_devices() is None,
      "a contradictory non-paired entry in paired inventory must fail closed")

hostile_address = "aa:bb:cc:dd:ee:ff"
module.bluetooth_profiler_facts = lambda: {}
module.bluetooth_ioreg_batteries = lambda: {}
module.bluetooth_pmset_batteries = lambda: {}
for hostile_name in (
    "Headset " + hostile_address,
    "Headset aabbccddeeff",
    "Headset aabb.ccdd.eeff",
    "Headset aa:bb:cc:\u200bdd:ee:ff",
):
    module.native_document = lambda command, timeout=8, name=hostile_name: native_inventory([{
        "address": hostile_address, "name": name, "connected": False,
        "paired": True, "rssi": None, "type": "Headset", "profiles": [],
    }])
    hostile = real_paired_devices()
    check(hostile is not None and hostile[0]["name"] == "Bluetooth device",
          "hostile Bluetooth address-bearing name escaped redaction")

module.session_secret = lambda: b"a" * 32
first_handle = module.opaque_handle("bluetooth", hostile_address)
module.session_secret = lambda: b"b" * 32
second_handle = module.opaque_handle("bluetooth", hostile_address)
check(first_handle != second_handle and hostile_address not in first_handle + second_handle,
      "Bluetooth handles must rotate with the private session secret")

module.session_secret = lambda: b"c" * 32
device_key = module.opaque_handle("bluetooth", hostile_address)
private_before = [{"_address": hostile_address, "key": device_key,
                   "name": "Headset", "connected": False, "paired": True,
                   "rssi": None, "type": "Headset", "profiles": [], "battery": []}]
private_after = [{**private_before[0], "connected": True, "rssi": -48,
                  "profiles": ["Hands-free"],
                  "battery": [{"component": "main", "percent": 75}]}]
reads = iter((private_before, private_after))
module.bluetooth_power = lambda: True
module.paired_devices = lambda: next(reads)
module.time.sleep = lambda _seconds: None
confirmed = module.confirm_bluetooth_device(device_key, True, attempts=2, delay=0)
check(set(confirmed) == expected_keys and confirmed["total_count"] == 1
      and confirmed["truncated"] is False
      and confirmed["devices"] == [{
          "key": device_key, "name": "Headset", "connected": True,
          "paired": True, "rssi": -48, "type": "Headset",
          "profiles": ["Hands-free"],
          "battery": [{"component": "main", "percent": 75}],
      }]
      and hostile_address not in public_strings(confirmed),
      "Bluetooth action readback did not preserve rich facts or private boundary")

check(module.address_value("aa:bb:cc:dd:ee:ff") == "aa:bb:cc:dd:ee:ff"
      and module.address_value("AA-BB-CC-DD-EE-FF") == "aa:bb:cc:dd:ee:ff"
      and module.address_value("AABBCCDDEEFF") == "aa:bb:cc:dd:ee:ff"
      and module.address_value(bytes.fromhex("aabbccddeeff")) == "aa:bb:cc:dd:ee:ff"
      and module.address_value("aabbccddee") is None
      and module.address_value("serial-aabbccddeeff") is None,
      "private Bluetooth address canonicalization changed")

check(module.battery_percentage("81%") == 81
      and module.battery_percentage(0) == 0
      and module.battery_percentage(100.0) == 100
      and module.battery_percentage(True) is None
      and module.battery_percentage(101) is None
      and module.battery_percentage("serial-81") is None,
      "Bluetooth battery percentage validation changed")

print("Connectivity permission, association, rich Bluetooth, limit, and privacy fixtures passed")
