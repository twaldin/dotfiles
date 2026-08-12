#!/usr/bin/env python3
import contextlib
import copy
import importlib.util
import io
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
PYTHON_SOURCE = ROOT / "scripts/battery-state.py"
SWIFT_SOURCE = ROOT / "scripts/battery-state.swift"
spec = importlib.util.spec_from_file_location("battery_state", PYTHON_SOURCE)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def check(condition, message):
    if not condition:
        raise SystemExit(message)


PYTHON_TEXT = PYTHON_SOURCE.read_text()
for required in (
    'RUNTIME_PARENT_INPUT = os.environ.get("TMPDIR", "")',
    'os.path.realpath(RUNTIME_PARENT_INPUT)',
    'stat.S_IMODE(parent.st_mode) != 0o700',
):
    check(required in PYTHON_TEXT, "battery per-user TMPDIR contract is missing: " + required)
check('/tmp/sketchybar-battery-state-' not in PYTHON_TEXT,
      "battery helper cache must not use the shared temporary namespace")


with tempfile.TemporaryDirectory(prefix="battery-tmpdir-test.") as raw:
    base = Path(raw).resolve()
    base.chmod(0o700)
    original_parent, original_cache = module.RUNTIME_PARENT, module.CACHE_ROOT
    try:
        module.RUNTIME_PARENT = str(base)
        module.CACHE_ROOT = base / ("sketchybar-battery-state-" + str(os.getuid()))
        cache = module._secure_cache_directory()
        check(cache.is_dir() and stat.S_IMODE(cache.stat().st_mode) == 0o700,
              "valid per-user TMPDIR must create a private battery cache")
        digest = hashlib.sha256(PYTHON_SOURCE.with_suffix(".swift").read_bytes()).hexdigest()
        tampered = cache / ("battery-state-" + digest)
        tampered.write_bytes(b"tampered")
        tampered.chmod(0o755)
        try:
            module.compiled_helper()
            check(False, "weak cached battery helper was reused")
        except OSError:
            pass

        weak = base / "weak"
        weak.mkdir(mode=0o755)
        weak.chmod(0o755)
        module.RUNTIME_PARENT = str(weak)
        module.CACHE_ROOT = weak / ("sketchybar-battery-state-" + str(os.getuid()))
        try:
            module._secure_cache_directory()
            check(False, "weak battery TMPDIR parent was accepted")
        except OSError:
            pass
    finally:
        module.RUNTIME_PARENT, module.CACHE_ROOT = original_parent, original_cache

helper_python = [sys.executable] + (["-O"] if not __debug__ else [])
for environment in (
    {key: value for key, value in os.environ.items() if key != "TMPDIR"},
    dict(os.environ, TMPDIR="relative-battery-tmp"),
):
    rejected = subprocess.run(
        helper_python + [str(PYTHON_SOURCE)], env=environment,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=10)
    check(rejected.returncode != 0 and rejected.stdout == "" and rejected.stderr == "",
          "unsafe battery TMPDIR must fail silently")


def compile_and_test_swift():
    with tempfile.TemporaryDirectory(prefix="battery-state-test-") as directory:
        directory = Path(directory)
        common = [
            "/usr/bin/xcrun", "swiftc", "-parse-as-library", "-warnings-as-errors",
            "-D", "BATTERY_STATE_TESTING", str(SWIFT_SOURCE), "-framework", "IOKit",
        ]
        for name, optimization in (("debug", []), ("optimized", ["-O"])):
            binary = directory / name
            result = subprocess.run(
                common + optimization + ["-o", str(binary)],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            check(result.returncode == 0, "Swift battery helper %s build failed" % name)
            result = subprocess.run(
                [str(binary), "--self-test"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            check(result.returncode == 0 and not result.stdout,
                  "Swift battery helper %s synthetic self-test failed" % name)

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
        check(result.returncode == 0, "Swift battery helper release build failed")


def document():
    return {
        "schema": "battery_state_v1",
        "inventory": "present",
        "percent": {"state": "value", "value": 50.0},
        "source": "ac",
        "charge": "charging",
        "time": {"state": "minutes", "minutes": 30},
        "health": "good",
        "condition": "no_reported_condition",
        "cycles": {"state": "value", "value": 42},
        "low_power": "on",
    }


def execute(payload, returncode=0):
    encoded = json.dumps(payload).encode("utf-8") if payload is not None else b""
    original = module.subprocess.run
    module.subprocess.run = lambda *arguments, **keywords: SimpleNamespace(
        returncode=returncode,
        stdout=encoded,
    )
    stream = io.StringIO()
    try:
        with contextlib.redirect_stdout(stream):
            code = module.main("/synthetic/battery-state")
    finally:
        module.subprocess.run = original
    return code, json.loads(stream.getvalue()) if stream.getvalue() else None


compile_and_test_swift()

valid = document()
code, value = execute(valid)
check(code == 0 and value == valid, "valid public battery contract was rejected")

for inventory in ("absent", "ambiguous", "malformed", "unsupported_type_present", "unavailable"):
    candidate = document()
    candidate.update({
        "inventory": inventory,
        "percent": {"state": "unavailable", "value": None},
        "charge": "unavailable",
        "time": {"state": "unavailable", "minutes": None},
        "health": "unavailable",
        "condition": "unavailable",
        "cycles": {"state": "unavailable", "value": None},
    })
    code, value = execute(candidate)
    check(code == 0 and value["inventory"] == inventory,
          "battery %s inventory state was not preserved" % inventory)

candidate = document()
candidate.update({
    "source": "offline",
    "charge": "offline",
    "time": {"state": "not_applicable", "minutes": None},
})
code, value = execute(candidate)
check(code == 0 and value["source"] == "offline",
      "provider offline source was not preserved")
candidate = document()
candidate["percent"] = {"state": "value", "value": True}
check(execute(candidate)[0] == 1, "Boolean battery percentage was accepted")
candidate = document()
candidate["cycles"] = {"state": "value", "value": True}
check(execute(candidate)[0] == 1, "Boolean battery cycle count was accepted")
candidate = document()
candidate["time"] = {"state": "not_applicable", "minutes": None}
check(execute(candidate)[0] == 1, "contradictory charging time was accepted")
candidate = document()
candidate["hardware_name"] = "private"
check(execute(candidate)[0] == 1, "unexpected battery output key was accepted")
check(execute(None, returncode=1)[0] == 1, "battery helper failure was accepted")

python_source = PYTHON_SOURCE.read_text()
swift_source = SWIFT_SOURCE.read_text()
for forbidden in ("ioreg", "AppleSmartBattery", "IOServiceMatching", "IORegistryEntry"):
    check(forbidden not in python_source and forbidden not in swift_source,
          "private battery query remains: %s" % forbidden)
for required in (
    "IOPSCopyPowerSourcesInfo", "IOPSCopyPowerSourcesList",
    "IOPSGetPowerSourceDescription", "kIOPSTypeKey", "kIOPSCurrentCapacityKey",
    "kIOPSBatteryHealthConditionKey", "kIOPMACPowerKey", "kIOPMBatteryPowerKey",
    "kIOPMUPSPowerKey", "IOPMCopyBatteryInfo", "kIOBatteryCycleCountKey",
    "ProcessInfo.processInfo.isLowPowerModeEnabled",
):
    check(required in swift_source, "reviewed public battery read is missing: %s" % required)

live = subprocess.run(
    [str(PYTHON_SOURCE)],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    timeout=70,
    check=False,
)
check(live.returncode == 0 and live.stderr == b"" and len(live.stdout) <= 4097,
      "live public battery coordinator failed or was not bounded and silent")
try:
    live_value = json.loads(live.stdout)
except (json.JSONDecodeError, UnicodeError):
    check(False, "live public battery coordinator emitted malformed JSON")
check(module.valid_contract(live_value), "live public battery contract was invalid")
live_text = live.stdout.decode("utf-8", "strict").lower()
for forbidden in (
    "serial", "manufacturer", "model", "vendor", "product", "source_name",
    "registry", "process", "applesmartbattery", "familycode", "adapterid",
    "name", "path", "ioreg",
):
    check(forbidden not in live_text, "live public battery output leaked identity metadata")

item_source = (ROOT / "items/battery.lua").read_text()
build_start = item_source.index("local function build(token)")
failure_end = item_source.index("\n  local percent =", build_start)
build_end = item_source.index("\nlocal function rebuild()", build_start)
build_source = item_source[failure_end:build_end]
ordered_rows = (
    'popup.section(item, token, "status_heading", "Status")',
    'popup.field(item, token, "inventory", "Internal battery"',
    'popup.field(item, token, "charge", "Charge"',
    'popup.field(item, token, "source", "Source"',
    'popup.field(item, token, "remaining"',
    'popup.field(item, token, "low_power", "Low Power Mode"',
    "build_health(token)",
    "build_hardware(token)",
    'popup.section(item, token, "settings_heading", "Open")',
)
positions = [build_source.find(row) for row in ordered_rows]
check(all(position >= 0 for position in positions) and positions == sorted(positions),
      "battery popup hierarchy is incomplete or out of order")
check('output.schema == "battery_state_v1"' in item_source,
      "battery item does not require the closed public contract")
check('offline = "Offline"' in item_source,
      "battery item does not render the provider offline source")
failure_branch = item_source[build_start:failure_end]
check('"Status read failed. Retrying automatically; reopen to retry now."' in failure_branch
      and 'popup.section(item, token, "settings_heading", "Open")' in failure_branch
      and 'popup.link(item, token, "settings", "Open System Settings · select Battery", open_system_settings)' in failure_branch,
      "battery data failure must explain retry and retain its Settings recovery action")
check('"/System/Applications/System Settings.app"' in item_source,
      "battery action does not target the main System Settings application")
check("settings.links.battery" not in item_source,
      "battery action retains a settings-pane claim")

health_build_start = item_source.index("local function build_health(token)")
health_build_end = item_source.index("\nlocal function build_hardware", health_build_start)
health_build = item_source[health_build_start:health_build_end]
check("health_labels" not in item_source
      and 'popup.field(item, token, "health", "Health"' not in health_build,
      "battery popup must not make a qualitative health claim")
check('if state_loading or hardware_loading then return nil end' in item_source
      and 'if count ~= nil then popup.field(item, token, "cycles", "Cycles"' in health_build,
      "the single battery cycle row is not gated on hardware reconciliation")
check('public_count ~= nil and hardware_count ~= nil and public_count ~= hardware_count' in item_source,
      "contradictory public and hardware cycle counts are not suppressed")

hardware_build_start = item_source.index("local function build_hardware(token)")
hardware_build_end = item_source.index("\nlocal function open_system_settings", hardware_build_start)
hardware_build = item_source[hardware_build_start:hardware_build_end]
for required in (
    'popup.section(item, token, "hardware_heading", "Hardware readings")',
    '"Hardware read failed. Retrying automatically; reopen to retry now."',
    '"No battery hardware readings were reported."',
    '"Raw current capacity"', '"Raw maximum capacity"', '"Raw design capacity"',
    '"Nominal capacity"', '"Raw maximum / design"',
    '"Signed battery current"', '"Battery voltage"', '"Battery temperature"',
    '"Adapter watts"', '"Adapter current"',
    "if adapter.watts ~= nil then", "if adapter.current_ma ~= nil then",
):
    check(required in hardware_build, "battery hardware rendering is missing: " + required)
for forbidden in (
    '"Maximum capacity"', '"Hardware cycle count"', '"Reading battery hardware…"',
    "popup.link", "popup.choice", "popup.action", "popup.slider", "shell.exec",
):
    check(forbidden not in hardware_build,
          "battery hardware detail retains a misleading, duplicate, or interactive surface: " + forbidden)
check('value.schema ~= "battery_hardware_v1"' in item_source
      and 'settings.config_dir .. "/scripts/battery-hardware-state.py"' in item_source,
      "battery item does not validate and invoke the closed hardware helper")
check('hardware_requests[token]' in item_source
      and 'hardware_request_versions[token] ~= version' in item_source
      and 'hardware_requests[token] = nil' in item_source
      and 'replace_pending' in item_source
      and 'hardware_in_flight' not in item_source
      and 'hardware_pending_token' not in item_source,
      "a stale hardware request can gate or replace a current popup generation")
check('state_request_version ~= version' in item_source
      and 'state_in_flight and not replace_pending' in item_source
      and item_source.count('sbar.delay(request_timeout_seconds, function()') == 2
      and 'request_timeout_seconds = 70' in item_source,
      "battery public/hardware reads lack replacement semantics or bounded deadlines")
check('hardware_refresh_routines = 4' in item_source
      and 'hardware_routine_ticks >= hardware_refresh_routines' in item_source,
      "battery hardware does not use a reduced popup-only cadence")
routine_start = item_source.index('item:subscribe("routine", function()')
routine_end = item_source.index('\nitem:subscribe("system_woke"', routine_start)
routine = item_source[routine_start:routine_end]
check('if active and popup.is_current(item, active) then' in routine
      and 'hardware = nil' in routine
      and 'refresh_hardware(active, false, true)' in routine,
      "battery hardware routine read is not restricted to the open popup")
popup_start = item_source.index("popup.bind(item, {")
popup_end = item_source.index('\nitem:subscribe("routine"', popup_start)
popup_binding = item_source[popup_start:popup_end]
check('refresh(true, true)' in popup_binding
      and 'refresh_hardware(token, false, true)' in popup_binding
      and 'hardware = nil' in popup_binding
      and 'hardware_loading = false' in popup_binding
      and 'hardware_requests = {}' in popup_binding
      and 'hardware_request_versions = {}' in popup_binding,
      "battery hardware is not fetched on open and cleared on close")
check(item_source.count('settings.config_dir .. "/scripts/battery-state.py"') == 1
      and 'item:subscribe("system_woke", refresh_power_facts)' in item_source
      and 'item:subscribe("power_source_change", refresh_power_facts)' in item_source,
      "battery public helper is no longer the owner of basic state")
power_start = item_source.index("local function refresh_power_facts()")
power_end = item_source.index('\nitem:subscribe("system_woke"', power_start)
power_source_change = item_source[power_start:power_end]
check("refresh(true, true)" in power_source_change
      and "state = nil" in power_source_change
      and "hardware = nil" in power_source_change
      and "rebuild()" in power_source_change
      and "refresh_hardware(active, true, true)" in power_source_change,
      "wake or power-source change can retain stale battery hardware facts")
check('build_hardware(token)' in failure_branch,
      "battery hardware detail disappears when public battery state fails")


def lua_literal(value):
    if value is None:
        return "nil"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, str):
        return json.dumps(value)
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, dict):
        return "{" + ",".join(
            "[" + json.dumps(str(key)) + "]=" + lua_literal(child)
            for key, child in value.items()
        ) + "}"
    raise TypeError("unsupported Lua fixture value")


def render_popup(public_value, hardware_value, public_code=0, hardware_code=0,
                 delay_public=False, delay_hardware=False,
                 drop_public=False, drop_hardware=False,
                 expire_requests=False, power_change_before_public=False,
                 stale_public_value=None, routine_ticks=0, all_snapshots=False):
    lua = r'''
local public_value = PUBLIC_VALUE
local hardware_value = HARDWARE_VALUE
local stale_public_value = STALE_PUBLIC_VALUE
local delay_public = DELAY_PUBLIC
local delay_hardware = DELAY_HARDWARE
local drop_public = DROP_PUBLIC
local drop_hardware = DROP_HARDWARE
local expire_requests = EXPIRE_REQUESTS
local power_change_before_public = POWER_CHANGE_BEFORE_PUBLIC
local routine_ticks = ROUTINE_TICKS
local public_call_count = 0
local hardware_call_count = 0
local pending_public = {}
local pending_hardware = nil
local deadline_callbacks = {}
local rows = {}
local popup_options = nil
local function add(kind, label, value)
  rows[#rows + 1] = { kind, tostring(label or ""), tostring(value or "") }
end
package.preload["colors"] = function()
  return { muted = 1, surface2 = 2, red = 3, primary = 4, green = 5,
    blue = 6, warning = 7, transparent = 8 }
end
package.preload["settings"] = function()
  return { battery_width = 60, spacing = { item = 4 }, surface_height = 24,
    type = { bar_control = "", bar_battery = "" }, config_dir = "/synthetic" }
end
package.preload["lib.hover"] = function()
  return { foreground = function(_, color) return color end, bind = function() end }
end
package.preload["lib.shell"] = function()
  return { exec = function(arguments, callback)
    if not callback then return end
    if string.find(arguments[1], "battery-hardware-state.py", 1, true) then
      hardware_call_count = hardware_call_count + 1
      if drop_hardware then return
      elseif delay_hardware then pending_hardware = callback
      else callback(hardware_value, HARDWARE_CODE) end
    elseif string.find(arguments[1], "battery-state.py", 1, true) then
      public_call_count = public_call_count + 1
      if drop_public then return
      elseif delay_public then pending_public[#pending_public + 1] = callback
      else callback(public_value, PUBLIC_CODE) end
    else
      error("unexpected helper")
    end
  end }
end
package.preload["lib.popup"] = function()
  local popup = {}
  function popup.header(_, _, title, chip) add("header", title, chip) end
  function popup.section(_, _, _, title) add("section", title, "") end
  function popup.field(_, _, _, label, value) add("field", label, value) end
  function popup.note(_, _, _, text) add("note", text, "") end
  function popup.link(_, _, _, text) add("link", text, "") end
  function popup.meter() end
  function popup.bind(_, options) popup_options = options end
  function popup.is_current(_, token) return token == 1 end
  function popup.rebuild(_, token, builder)
    rows = {}
    builder(token)
  end
  return popup
end
local subscriptions = {}
local item = { name = "battery" }
function item:set() end
function item:subscribe(event, callback) subscriptions[event] = callback end
sbar = {
  add = function() return item end,
  delay = function(_, callback) deadline_callbacks[#deadline_callbacks + 1] = callback end,
}
dofile(ITEM_PATH)
local function emit_snapshot()
  print("BATTERY_SNAPSHOT")
  for _, row in ipairs(rows) do print(table.concat(row, "\t")) end
end
popup_options.build(1)
emit_snapshot()
if pending_hardware then
  pending_hardware(hardware_value, HARDWARE_CODE)
  emit_snapshot()
end
if power_change_before_public then
  subscriptions["power_source_change"]()
  emit_snapshot()
  if #pending_public < 3 then error("power event did not replace public request") end
  pending_public[#pending_public - 1](stale_public_value, 0)
  emit_snapshot()
  pending_public[#pending_public](public_value, PUBLIC_CODE)
  emit_snapshot()
  pending_public[1](stale_public_value, 0)
  emit_snapshot()
elseif #pending_public > 0 then
  pending_public[#pending_public](public_value, PUBLIC_CODE)
  emit_snapshot()
  if #pending_public > 1 then
    pending_public[1](public_value, PUBLIC_CODE)
    emit_snapshot()
  end
end
if routine_ticks > 0 then
  for _ = 1, routine_ticks do subscriptions["routine"]() end
  if public_call_count < 2 or (routine_ticks >= 4 and hardware_call_count < 2) then
    error("routine did not retry failed Battery reads")
  end
  emit_snapshot()
end
if expire_requests then
  for _, deadline in ipairs(deadline_callbacks) do deadline() end
  emit_snapshot()
end
'''
    replacements = {
        "STALE_PUBLIC_VALUE": lua_literal(stale_public_value if stale_public_value is not None else public_value),
        "PUBLIC_VALUE": lua_literal(public_value),
        "HARDWARE_VALUE": lua_literal(hardware_value),
        "DELAY_PUBLIC": "true" if delay_public else "false",
        "DELAY_HARDWARE": "true" if delay_hardware else "false",
        "DROP_PUBLIC": "true" if drop_public else "false",
        "DROP_HARDWARE": "true" if drop_hardware else "false",
        "EXPIRE_REQUESTS": "true" if expire_requests else "false",
        "POWER_CHANGE_BEFORE_PUBLIC": "true" if power_change_before_public else "false",
        "ROUTINE_TICKS": str(routine_ticks),
        "PUBLIC_CODE": str(public_code),
        "HARDWARE_CODE": str(hardware_code),
        "ITEM_PATH": json.dumps(str(ROOT / "items/battery.lua")),
    }
    for key, value in replacements.items():
        lua = lua.replace(key, value)
    with tempfile.TemporaryDirectory(prefix="battery-popup-test.") as directory:
        script = Path(directory) / "popup.lua"
        script.write_text(lua)
        result = subprocess.run(
            ["/opt/homebrew/bin/lua", str(script)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=10,
            check=False,
        )
    check(result.returncode == 0,
          "battery popup Lua fixture failed: " + result.stderr.strip())
    snapshots = []
    rendered = None
    for line in result.stdout.splitlines():
        if line == "BATTERY_SNAPSHOT":
            rendered = []
            snapshots.append(rendered)
            continue
        parts = line.split("\t")
        check(rendered is not None and len(parts) == 3,
              "battery popup fixture emitted an invalid row")
        rendered.append(tuple(parts))
    check(snapshots, "battery popup fixture emitted no snapshots")
    return snapshots if all_snapshots else snapshots[-1]


def exercise_hardware_generation_race(public_value, stale_hardware, current_hardware):
    lua = r'''
local public_value = PUBLIC_VALUE
local stale_hardware = STALE_HARDWARE
local current_hardware = CURRENT_HARDWARE
local hardware_callbacks = {}
local deadline_callbacks = {}
local popup_options = nil
local current_token = nil
local rebuild_count = 0
local rows = {}
local function add(kind, label, value)
  rows[#rows + 1] = { kind, tostring(label or ""), tostring(value or "") }
end
package.preload["colors"] = function()
  return { muted = 1, surface2 = 2, red = 3, primary = 4, green = 5,
    blue = 6, warning = 7, transparent = 8 }
end
package.preload["settings"] = function()
  return { battery_width = 60, spacing = { item = 4 }, surface_height = 24,
    type = { bar_control = "", bar_battery = "" }, config_dir = "/synthetic" }
end
package.preload["lib.hover"] = function()
  return { foreground = function(_, color) return color end, bind = function() end }
end
package.preload["lib.shell"] = function()
  return { exec = function(arguments, callback)
    if not callback then return end
    if string.find(arguments[1], "battery-hardware-state.py", 1, true) then
      hardware_callbacks[#hardware_callbacks + 1] = callback
    elseif string.find(arguments[1], "battery-state.py", 1, true) then
      callback(public_value, 0)
    else
      error("unexpected helper")
    end
  end }
end
package.preload["lib.popup"] = function()
  local popup = {}
  function popup.header(_, _, title, chip) add("header", title, chip) end
  function popup.section(_, _, _, title) add("section", title, "") end
  function popup.field(_, _, _, label, value) add("field", label, value) end
  function popup.note(_, _, _, text) add("note", text, "") end
  function popup.link(_, _, _, text) add("link", text, "") end
  function popup.meter() end
  function popup.bind(_, options) popup_options = options end
  function popup.is_current(_, token) return token == current_token end
  function popup.rebuild(_, token, builder)
    if token ~= current_token then return false end
    rebuild_count = rebuild_count + 1
    rows = {}
    builder(token)
    return true
  end
  return popup
end
local subscriptions = {}
local item = { name = "battery" }
function item:set() end
function item:subscribe(event, callback) subscriptions[event] = callback end
sbar = {
  add = function() return item end,
  delay = function(_, callback) deadline_callbacks[#deadline_callbacks + 1] = callback end,
}
dofile(ITEM_PATH)

current_token = 1
rows = {}
popup_options.build(1)
if #hardware_callbacks ~= 1 then error("first generation did not start one read") end
popup_options.on_close()
current_token = nil

current_token = 2
rows = {}
popup_options.build(2)
if #hardware_callbacks ~= 2 then error("second generation was gated by stale read") end
local function field_values(label)
  local values = {}
  for _, row in ipairs(rows) do
    if row[1] == "field" and row[2] == label then values[#values + 1] = row[3] end
  end
  return values
end
local function cycle_values() return field_values("Cycles") end
hardware_callbacks[2](current_hardware, 0)
local current_cycles = cycle_values()
if #current_cycles ~= 1 or current_cycles[1] ~= "202" then
  error("current generation did not accept its initial read")
end
for _ = 1, 3 do subscriptions["routine"]() end
if #hardware_callbacks ~= 2 then error("hardware routine cadence refreshed too early") end
subscriptions["routine"]()
if #hardware_callbacks ~= 3 then error("hardware routine cadence did not refresh") end
if #cycle_values() ~= 0
    or #field_values("Signed battery current") ~= 0
    or #field_values("Battery voltage") ~= 0
    or #field_values("Battery temperature") ~= 0 then
  error("routine reconciliation retained stale hardware facts")
end
if not subscriptions["power_source_change"] then error("power-source subscription is missing") end
subscriptions["power_source_change"]()
if #hardware_callbacks ~= 4 then error("power change was gated by its stale same-generation read") end
local before_same_generation_stale = rebuild_count
hardware_callbacks[3](stale_hardware, 0)
if rebuild_count ~= before_same_generation_stale or #cycle_values() ~= 0 then
  error("pre-power-change read replaced the retired hardware state")
end
hardware_callbacks[4](current_hardware, 0)
current_cycles = cycle_values()
if #current_cycles ~= 1 or current_cycles[1] ~= "202" then
  error("current generation did not accept its post-power-change read")
end
local before_stale_generation = rebuild_count
hardware_callbacks[1](stale_hardware, 0)
local after_stale_cycles = cycle_values()
if rebuild_count ~= before_stale_generation
    or #after_stale_cycles ~= 1 or after_stale_cycles[1] ~= "202" then
  error("stale popup generation replaced current hardware")
end
print("Battery hardware generation race passed")
'''
    replacements = {
        "PUBLIC_VALUE": lua_literal(public_value),
        "STALE_HARDWARE": lua_literal(stale_hardware),
        "CURRENT_HARDWARE": lua_literal(current_hardware),
        "ITEM_PATH": json.dumps(str(ROOT / "items/battery.lua")),
    }
    for key, value in replacements.items():
        lua = lua.replace(key, value)
    with tempfile.TemporaryDirectory(prefix="battery-generation-test.") as directory:
        script = Path(directory) / "generation.lua"
        script.write_text(lua)
        result = subprocess.run(
            ["/opt/homebrew/bin/lua", str(script)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=10,
            check=False,
        )
    check(result.returncode == 0
          and result.stdout == "Battery hardware generation race passed\n"
          and result.stderr == "",
          "battery hardware generation fixture failed")


def fields(rows):
    return [(label, value) for kind, label, value in rows if kind == "field"]


def values_for(rows, label):
    return [value for candidate, value in fields(rows) if candidate == label]


live_hardware_result = subprocess.run(
    [str(ROOT / "scripts/battery-hardware-state.py")],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    timeout=70,
    check=False,
)
check(live_hardware_result.returncode == 0
      and live_hardware_result.stderr == b""
      and len(live_hardware_result.stdout) <= 2049,
      "live battery hardware coordinator failed or was not bounded and silent")
try:
    live_hardware_value = json.loads(live_hardware_result.stdout)
except (json.JSONDecodeError, UnicodeError):
    check(False, "live battery hardware coordinator emitted malformed JSON")
actual_live_rows = render_popup(live_value, live_hardware_value)
actual_live_fields = fields(actual_live_rows)
check(not any(value in {"Unknown", "Unavailable", "—"}
              for _, value in actual_live_fields)
      and values_for(actual_live_rows, "Health") == []
      and len(values_for(actual_live_rows, "Cycles")) <= 1,
      "actual live battery popup contains a placeholder, health claim, or duplicate cycles")
actual_adapter = live_hardware_value["adapter"]
check((values_for(actual_live_rows, "Adapter watts") != [])
      == (actual_adapter["watts"] is not None)
      and (values_for(actual_live_rows, "Adapter current") != [])
      == (actual_adapter["current_ma"] is not None),
      "actual live adapter rows do not match individually proved dictionary facts")
check(not any(label in {"Maximum capacity", "Hardware cycle count"}
              for label, _ in actual_live_fields),
      "actual live battery popup contains a misleading or duplicate row")


live_public = document()
live_public.update({
    "percent": {"state": "value", "value": 70.0},
    "source": "battery",
    "charge": "unavailable",
    "time": {"state": "unavailable", "minutes": None},
    "health": "unknown",
    "condition": "check_battery",
    "cycles": {"state": "unavailable", "value": None},
})
live_hardware = {
    "schema": "battery_hardware_v1",
    "capacities": {
        "raw_current_mah": 3_509,
        "raw_maximum_mah": 5_245,
        "maximum_mah": 5_245,
        "design_mah": 6_249,
        "nominal_mah": 5_397,
        "maximum_to_design_ratio": 5_245 / 6_249,
    },
    "cycle_count": 351,
    "electrical": {
        "signed_current_ma": -2_208,
        "voltage_v": 11.754,
        "temperature_c": 30.71,
    },
    "adapter": {"watts": None, "current_ma": None},
}
stale_hardware = copy.deepcopy(live_hardware)
stale_hardware["cycle_count"] = 101
current_hardware = copy.deepcopy(live_hardware)
current_hardware["cycle_count"] = 202
exercise_hardware_generation_race(live_public, stale_hardware, current_hardware)

empty_hardware = {
    "schema": "battery_hardware_v1",
    "capacities": {
        "raw_current_mah": None, "raw_maximum_mah": None,
        "maximum_mah": None, "design_mah": None, "nominal_mah": None,
        "maximum_to_design_ratio": None,
    },
    "cycle_count": None,
    "electrical": {
        "signed_current_ma": None, "voltage_v": None, "temperature_c": None,
    },
    "adapter": {"watts": None, "current_ma": None},
}
empty_rows = render_popup(live_public, empty_hardware)
check("No battery hardware readings were reported."
      in [label for kind, label, _ in empty_rows if kind == "note"],
      "successful empty hardware read vanished without a concrete result")
ratio_mismatch = copy.deepcopy(empty_hardware)
ratio_mismatch["capacities"].update({
    "raw_maximum_mah": 5_000,
    "maximum_mah": 4_000,
    "design_mah": 5_000,
    "maximum_to_design_ratio": 0.8,
})
ratio_mismatch_rows = render_popup(live_public, ratio_mismatch)
check(values_for(ratio_mismatch_rows, "Raw maximum capacity") == ["5000 mAh"]
      and values_for(ratio_mismatch_rows, "Raw design capacity") == ["5000 mAh"]
      and values_for(ratio_mismatch_rows, "Raw maximum / design") == [],
      "raw mismatch rendered a ratio claim or hid independently proved capacities")

live_rows = render_popup(live_public, live_hardware)
live_fields = fields(live_rows)
check(not any(label in {"Charge", "Remaining", "Until full", "Health"}
              for label, _ in live_fields),
      "unproved live charge, time, or qualitative health was rendered")
check(values_for(live_rows, "Cycles") == ["351"],
      "the live hardware cycle count was not rendered exactly once")
check(not any(label.startswith("Adapter ") for label, _ in live_fields),
      "detached adapter numeric rows were rendered")
check(values_for(live_rows, "Raw maximum capacity") == ["5245 mAh"]
      and values_for(live_rows, "Raw design capacity") == ["6249 mAh"]
      and len(values_for(live_rows, "Raw maximum / design")) == 1,
      "raw capacity facts do not have exact non-health labels")
check(not any(label in {"Maximum capacity", "Hardware cycle count"}
              for label, _ in live_fields),
      "a misleading capacity or duplicate cycle row was rendered")
check(not any(value in {"Unknown", "Unavailable", "—"}
              for _, value in live_fields),
      "the healthy live battery popup contains a placeholder")

attached_public = document()
attached_hardware = copy.deepcopy(live_hardware)
attached_hardware["cycle_count"] = 42
attached_hardware["adapter"] = {"watts": 96, "current_ma": 4_700}
public_pending = render_popup(
    attached_public, attached_hardware,
    delay_public=True, all_snapshots=True,
)
check(len(public_pending) == 3
      and "Reading battery status…" in [label for kind, label, _ in public_pending[0] if kind == "note"]
      and values_for(public_pending[0], "Cycles") == []
      and values_for(public_pending[0], "Charge") == []
      and values_for(public_pending[0], "Source") == []
      and values_for(public_pending[0], "Raw maximum capacity") == ["5245 mAh"]
      and values_for(public_pending[-1], "Cycles") == ["42"]
      and values_for(public_pending[-1], "Charge") == ["Charging"],
      "hardware-first/public-pending ordering produced an unproved public or cycle claim")

stale_public = copy.deepcopy(attached_public)
stale_public.update({
    "source": "battery",
    "charge": "discharging",
    "time": {"state": "minutes", "minutes": 90},
})
power_replacement = render_popup(
    attached_public, attached_hardware,
    delay_public=True, power_change_before_public=True,
    stale_public_value=stale_public, all_snapshots=True,
)
check(len(power_replacement) == 5
      and values_for(power_replacement[2], "Source") == []
      and values_for(power_replacement[2], "Charge") == []
      and values_for(power_replacement[2], "Cycles") == []
      and "Reading battery status…"
      in [label for kind, label, _ in power_replacement[2] if kind == "note"]
      and values_for(power_replacement[-1], "Source") == ["AC"]
      and values_for(power_replacement[-1], "Charge") == ["Charging"]
      and values_for(power_replacement[-1], "Cycles") == ["42"],
      "pre-power-change public callback replaced the current request")

delayed_match = render_popup(
    attached_public, attached_hardware, delay_hardware=True, all_snapshots=True,
)
check(len(delayed_match) == 2
      and values_for(delayed_match[0], "Cycles") == []
      and values_for(delayed_match[1], "Cycles") == ["42"],
      "public cycle count was claimed before matching hardware reconciliation")
attached_rows = render_popup(attached_public, attached_hardware)
check(values_for(attached_rows, "Charge") == ["Charging"]
      and values_for(attached_rows, "Until full") == ["0h 30m"],
      "consistent charge and time facts were not rendered")
check(values_for(attached_rows, "Health") == [],
      "attached battery state produced a qualitative health claim")
check(values_for(attached_rows, "Cycles") == ["42"],
      "matching public and hardware cycles were not rendered once")
public_only_hardware = copy.deepcopy(attached_hardware)
public_only_hardware["cycle_count"] = None
public_only_rows = render_popup(attached_public, public_only_hardware)
check(values_for(public_only_rows, "Cycles") == ["42"],
      "exact public-only cycle count was not rendered once")
check(values_for(attached_rows, "Adapter watts") == ["96 W"]
      and values_for(attached_rows, "Adapter current") == ["4700 mA"],
      "proved attached-adapter values were not rendered")

hardware_failure = render_popup(attached_public, None, hardware_code=1)
check(values_for(hardware_failure, "Cycles") == ["42"]
      and "Hardware read failed. Retrying automatically; reopen to retry now."
      in [label for kind, label, _ in hardware_failure if kind == "note"],
      "failed hardware reconciliation did not fall back to the exact public cycle count")
delayed_hardware_failure = render_popup(
    attached_public, None, hardware_code=1,
    delay_hardware=True, all_snapshots=True,
)
check(len(delayed_hardware_failure) == 2
      and values_for(delayed_hardware_failure[0], "Cycles") == []
      and values_for(delayed_hardware_failure[1], "Cycles") == ["42"],
      "hardware failure claimed public cycles before the failure was known")

hung_hardware = render_popup(
    attached_public, attached_hardware,
    drop_hardware=True, expire_requests=True, all_snapshots=True,
)
check(len(hung_hardware) == 2
      and values_for(hung_hardware[0], "Cycles") == []
      and values_for(hung_hardware[1], "Cycles") == ["42"]
      and "Hardware read failed. Retrying automatically; reopen to retry now."
      in [label for kind, label, _ in hung_hardware[1] if kind == "note"],
      "hung hardware transport did not reach a concrete bounded failure state")
hung_public = render_popup(
    attached_public, attached_hardware,
    drop_public=True, expire_requests=True, all_snapshots=True,
)
check(len(hung_public) == 2
      and values_for(hung_public[0], "Cycles") == []
      and "Reading battery status…"
      in [label for kind, label, _ in hung_public[0] if kind == "note"]
      and values_for(hung_public[1], "Cycles") == ["42"]
      and "Status read failed. Retrying automatically; reopen to retry now."
      in [label for kind, label, _ in hung_public[1] if kind == "note"],
      "hung public transport did not reach a concrete bounded failure state")

partial_adapter = copy.deepcopy(attached_hardware)
partial_adapter["adapter"] = {"watts": 96, "current_ma": None}
partial_rows = render_popup(attached_public, partial_adapter)
check(values_for(partial_rows, "Adapter watts") == ["96 W"]
      and values_for(partial_rows, "Adapter current") == [],
      "adapter current was not independently conditional")
partial_adapter["adapter"] = {"watts": None, "current_ma": 4_700}
partial_rows = render_popup(attached_public, partial_adapter)
check(values_for(partial_rows, "Adapter watts") == []
      and values_for(partial_rows, "Adapter current") == ["4700 mA"],
      "adapter watts was not independently conditional")

contradictory_hardware = copy.deepcopy(attached_hardware)
contradictory_hardware["cycle_count"] = 43
contradictory_rows = render_popup(attached_public, contradictory_hardware)
check(values_for(contradictory_rows, "Cycles") == [],
      "contradictory exact cycle counts produced a visible claim")
delayed_contradiction = render_popup(
    attached_public, contradictory_hardware,
    delay_hardware=True, all_snapshots=True,
)
check(len(delayed_contradiction) == 2
      and values_for(delayed_contradiction[0], "Cycles") == []
      and values_for(delayed_contradiction[1], "Cycles") == [],
      "contradictory cycles were claimed during async reconciliation")

automatic_retry = render_popup(
    None, None, public_code=1, hardware_code=1,
    routine_ticks=4, all_snapshots=True,
)
check(len(automatic_retry) == 2
      and "Status read failed. Retrying automatically; reopen to retry now."
      in [label for kind, label, _ in automatic_retry[-1] if kind == "note"]
      and "Hardware read failed. Retrying automatically; reopen to retry now."
      in [label for kind, label, _ in automatic_retry[-1] if kind == "note"],
      "failure copy does not match observed automatic retry behavior")

failure_snapshots = render_popup(
    None, None, public_code=1, hardware_code=1,
    delay_hardware=True, all_snapshots=True,
)
check(len(failure_snapshots) == 2,
      "delayed hardware callback did not exercise both popup states")
initial_failure = failure_snapshots[0]
initial_notes = [label for kind, label, _ in initial_failure if kind == "note"]
initial_sections = [label for kind, label, _ in initial_failure if kind == "section"]
initial_links = [label for kind, label, _ in initial_failure if kind == "link"]
check(initial_notes == ["Status read failed. Retrying automatically; reopen to retry now."]
      and "Hardware readings" not in initial_sections
      and initial_links == ["Open System Settings · select Battery"],
      "status failure exposed a hardware loading placeholder before async readback")

failure_rows = failure_snapshots[-1]
failure_notes = [label for kind, label, _ in failure_rows if kind == "note"]
failure_links = [label for kind, label, _ in failure_rows if kind == "link"]
check("Status read failed. Retrying automatically; reopen to retry now." in failure_notes
      and "Hardware read failed. Retrying automatically; reopen to retry now." in failure_notes
      and failure_links == ["Open System Settings · select Battery"],
      "battery transport failure lacks exact retry and Settings recovery copy")
check(not any(value in {"Unknown", "Unavailable", "—"}
              for _, value in fields(failure_rows)),
      "battery failure rendering fell back to a placeholder")
print("Battery public and hardware popup contracts passed")
