local source = debug.getinfo(1, "S").source
local script = source:sub(1, 1) == "@" and source:sub(2) or source
local config_dir = script:match("^(.*)/tests/[^/]+$") or os.getenv("SKETCHYBAR_CONFIG_DIR")
if not config_dir or config_dir == "" then error("cannot determine SketchyBar config directory") end
package.path = config_dir .. "/?.lua;" .. config_dir .. "/?/init.lua;" .. package.path

local function check(value, message) if not value then error(message, 0) end end
local function merge(target, update)
  for key, value in pairs(update or {}) do
    if type(value) == "table" and type(target[key]) == "table" then merge(target[key], value)
    else target[key] = value end
  end
end
local objects = {}
local function add(_, name, properties)
  local item = { name = name, properties = properties or {}, subscriptions = {} }
  function item:set(update) merge(self.properties, update) end
  function item:subscribe(events, callback)
    if type(events) == "string" then events = { events } end
    for _, event in ipairs(events) do
      self.subscriptions[event] = self.subscriptions[event] or {}
      self.subscriptions[event][#self.subscriptions[event] + 1] = callback
    end
  end
  objects[name] = item
  return item
end
sbar = { add = add, delay = function(_, callback) callback() end }

package.loaded["settings"] = {
  config_dir = config_dir, control_width = 28, surface_height = 28,
  spacing = { item = 4 },
  links = { wifi = "/System/Applications/System Settings.app", bluetooth = "/System/Applications/System Settings.app" },
}

local bindings, current, views = {}, {}, {}
local function fresh_view()
  return { fields = {}, notes = {}, links = {}, rows = {}, sections = {} }
end
local function view(host)
  views[host] = views[host] or fresh_view()
  return views[host]
end
package.loaded["lib.popup"] = {
  bind = function(host, options) bindings[host] = options end,
  is_current = function(host, token) return current[host] == token end,
  rebuild = function(host, token, builder)
    views[host] = fresh_view()
    builder(token)
  end,
  header = function(host, _, title, chip)
    view(host).header = { title = title, chip = chip }
  end,
  section = function(host, _, suffix, label)
    view(host).sections[suffix] = label
  end,
  field = function(host, _, suffix, label, value)
    view(host).fields[suffix] = { label = label, value = value }
  end,
  note = function(host, _, suffix, text)
    view(host).notes[suffix] = text
  end,
  link = function(host, _, suffix, label, callback)
    view(host).links[suffix] = { label = label, click = callback }
  end,
  row = function(host, _, suffix, properties)
    local row = { suffix = suffix, label = properties.label.string }
    view(host).rows[suffix] = row
    return row
  end,
  action = function() end,
  on_click = function(row, callback) row.click = callback end,
}

local KEY_A = string.rep("a", 64)
local KEY_B = string.rep("b", 64)
local wifi_fixture = {
  interface_key = string.rep("c", 64), power = true, ssid = "Fixture",
  association = "associated", mode = "station", service_active = true,
  name_available = true, name_permission = "not_required",
  rssi = -48, noise = -94, rate = 866, security = "wpa3_personal",
  phy = "802.11ax", mcs = 8, channel = 69, band = "6 GHz", channel_width = "160 MHz",
}
local bluetooth_fixture = {
  power = true, inventory_available = true, total_count = 1, truncated = false,
  devices = { { key = KEY_A, name = "Headphones", connected = true, paired = true,
    rssi = -48, type = "Headphones", profiles = { "A2DP sink", "AVRCP" },
    battery = { { component = "main", percent = 80 } } } },
}
local action_commands = {}
package.loaded["lib.shell"] = {
  exec = function(command, callback)
    local family, action = command[2], command[3]
    if family == "session" and action == "begin" then callback({}, 0)
    elseif family == "wifi" and action == "state" then callback(wifi_fixture, 0)
    elseif family == "bluetooth" and action == "state" then callback(bluetooth_fixture, 0)
    elseif (family == "wifi" and (action == "set" or action == "authorize-name")) or family == "bluetooth" then
      action_commands[#action_commands + 1] = command
      callback(family == "wifi" and wifi_fixture or bluetooth_fixture, 0)
    else callback(nil, 1) end
  end,
  open = function() end,
  ellipsis = function(value) return value end,
}

local colors = require("colors")
local items = require("items.connectivity")
local wifi, bluetooth = items.wifi, items.bluetooth

local function fire(item, event, env)
  for _, callback in ipairs(item.subscriptions[event] or {}) do callback(env or {}) end
end
local generation = 0
local function render(item)
  generation = generation + 1
  local token = "fixture-" .. generation
  current[item] = token
  views[item] = fresh_view()
  bindings[item].build(token)
  return view(item)
end
local function render_wifi(fixture)
  wifi_fixture = fixture
  fire(wifi, "routine")
  return render(wifi)
end
local function render_bluetooth(fixture)
  bluetooth_fixture = fixture
  fire(bluetooth, "routine")
  return render(bluetooth)
end
local function wifi_state(association, power)
  return {
    interface_key = string.rep("c", 64), power = power ~= false, ssid = nil,
    association = association, mode = association == "ibss" and "ibss"
      or association == "host_ap" and "host_ap" or "station",
    service_active = power ~= false, rssi = nil, noise = nil, rate = nil,
    security = "unknown", name_available = false, name_permission = "not_determined",
    phy = nil, mcs = nil, channel = nil, band = nil, channel_width = nil,
  }
end

local partial = wifi_state("associated")
partial.rssi = -52
partial.mode = "station"
partial.service_active = true
partial.phy = "802.11ax"
partial.mcs = 8
partial.channel = 69
partial.band = "6 GHz"
partial.channel_width = "160 MHz"
local rendered = render_wifi(partial)
check(rendered.fields.service.label == "Service" and rendered.fields.service.value == "Active",
  "Wi-Fi service-active evidence must render")
check(rendered.fields.mode.label == "Mode" and rendered.fields.mode.value == "station",
  "Wi-Fi mode evidence must render")
check(rendered.fields.phy.value == "802.11ax"
  and rendered.fields.channel.value == "69 · 6 GHz · 160 MHz"
  and rendered.fields.mcs.value == "8",
  "Wi-Fi PHY, channel, band, width, and MCS evidence must render")
check(wifi.properties.icon.string == "󰤨",
  "privacy-redacted associated Wi-Fi must retain the connected icon")
check(rendered.rows.name_permission ~= nil
  and rendered.rows.name_permission.label == "Allow network name · Location",
  "associated Wi-Fi with undetermined name permission must offer the real request")
rendered.rows.name_permission.click({ BUTTON = "left" })
local permission_command = action_commands[#action_commands]
check(permission_command[2] == "wifi" and permission_command[3] == "authorize-name",
  "network-name permission row must execute its authorization command")
check(rendered.fields.signal.label == "Signal" and rendered.fields.signal.value == "-52 dBm"
  and rendered.fields.noise.label == "Noise" and rendered.fields.noise.value == "Not reported",
  "RSSI-only Wi-Fi evidence must render independently")
partial.rssi, partial.noise = nil, -97
rendered = render_wifi(partial)
check(rendered.fields.signal.value == "Not reported" and rendered.fields.noise.value == "-97 dBm",
  "noise-only Wi-Fi evidence must render independently")

local association_expectations = {
  associated = { "Associated network", "Associated" },
  link_unverified = { "Association unverified", "Association unverified" },
  not_associated = { "Not connected", "Not associated" },
  ibss = { "IBSS association", "IBSS association" },
  host_ap = { "Host access point", "Host access point" },
  unknown = { "Association not reported", "Association not reported" },
}
for association, expected in pairs(association_expectations) do
  rendered = render_wifi(wifi_state(association))
  check(rendered.fields.network.value == expected[1]
    and rendered.fields.association.value == expected[2],
    "truthful Wi-Fi association wording changed: " .. association)
  if association == "link_unverified" or association == "ibss" or association == "host_ap" then
    check(rendered.fields.network.value ~= "Not connected",
      association .. " must never render as Not connected")
  end
end
local radio_off = wifi_state("radio_off", false)
radio_off.service_active = nil
radio_off.mode = "unknown"
rendered = render_wifi(radio_off)
check(rendered.fields.network.value == "Radio off"
  and rendered.fields.association.value == "Radio off"
  and rendered.fields.service.value == "Not reported",
  "radio-off Wi-Fi wording changed")

rendered = render_bluetooth({
  power = false, inventory_available = false, total_count = nil,
  truncated = false, devices = {},
})
check(rendered.notes.inventory_unavailable == "Paired-device inventory unavailable while Bluetooth is off"
  and rendered.notes.none == nil,
  "radio-off Bluetooth inventory must not render as proved zero")
check(rendered.header.chip == "Off · devices unavailable",
  "radio-off Bluetooth header must disclose unavailable inventory")


rendered = render_bluetooth({
  power = false, inventory_available = true, total_count = 1,
  truncated = false, devices = { {
    key = KEY_A, name = "Headphones", connected = false, paired = true,
    rssi = nil, type = "Audio", profiles = { "A2DP" }, battery = {},
  } },
})
check(rendered.notes.power_required == "Turn on Bluetooth in System Settings to change devices"
  and rendered.fields.device_1.label == "Headphones  ·  Disconnected"
  and rendered.fields.device_1.value == "Read only"
  and rendered.rows.device_1 == nil,
  "radio-off paired Bluetooth devices must be visible read-only facts, not actions")

rendered = render_bluetooth({
  power = true, inventory_available = false, total_count = nil,
  truncated = false, devices = {},
})
check(rendered.notes.inventory_unavailable == "Paired-device inventory unavailable"
  and rendered.header.chip == "On · devices unavailable",
  "known-on Bluetooth state must preserve power when inventory is unavailable")

rendered = render_bluetooth({
  power = true, inventory_available = true, total_count = 0,
  truncated = false, devices = {},
})
check(rendered.notes.none == "No paired devices"
  and rendered.notes.inventory_unavailable == nil,
  "proved-zero Bluetooth inventory must render distinctly")

local many_devices = {}
for index = 1, 12 do
  many_devices[index] = {
    key = index == 1 and KEY_A or (index == 2 and KEY_B or string.format("%064x", index)),
    name = "Device " .. index, connected = index == 1, paired = true,
    rssi = index == 1 and -51 or nil, type = "Peripheral", profiles = { "HID" },
    battery = index == 1 and { { component = "main", percent = 77 } } or {},
  }
end
rendered = render_bluetooth({
  power = true, inventory_available = true, total_count = 15,
  truncated = true, devices = many_devices,
})
check(rendered.links.device_overflow.label == "… and 7 more",
  "proved exact Bluetooth total must include every undisplayed device")
check(rendered.rows.device_8 ~= nil and rendered.rows.device_9 == nil,
  "Bluetooth popup display limit changed")
check(rendered.header.chip == "On · partial device list",
  "truncated Bluetooth inventory must not claim an exact connected count")
check(rendered.notes.device_facts_1 == "Paired · Peripheral · Profile HID · RSSI -51 dBm · Battery 77%"
  and rendered.notes.device_facts_2 == "Paired · Peripheral · Profile HID",
  "Bluetooth paired, type, profile, RSSI, and battery facts must render when present")
check(rendered.rows.device_1.label:find("Connected", 1, true)
  and rendered.rows.device_2.label:find("Disconnected", 1, true),
  "Bluetooth rows must show concrete connection state")

rendered = render_bluetooth({
  power = true, inventory_available = true, total_count = nil,
  truncated = true, devices = many_devices,
})
check(rendered.links.device_overflow.label == "More paired devices"
  and not rendered.links.device_overflow.label:match("%d"),
  "unproved Bluetooth overflow must not claim an exact count")
rendered = render_bluetooth({
  power = true, inventory_available = true, total_count = 11,
  truncated = false, devices = many_devices,
})
check(rendered.links.device_overflow.label == "More paired devices",
  "inconsistent Bluetooth total must not be presented as proved")

rendered = render_bluetooth({
  power = true, inventory_available = true, total_count = 1,
  truncated = false,
  devices = { { key = KEY_A, name = "Headphones", connected = false, paired = true,
    rssi = nil, type = "Headphones", profiles = { "A2DP sink" }, battery = {} } },
})
rendered.rows.device_1.click({ BUTTON = "left" })
local command = action_commands[#action_commands]
check(command[2] == "bluetooth" and command[3] == "connect"
  and command[4] == KEY_A and command[5] == "off",
  "Bluetooth action must preserve opaque-target expected-state arguments")
check(not table.concat(command, " "):find(":", 1, true),
  "Bluetooth action argv must not contain a raw address")

rendered = render_bluetooth({
  power = true, inventory_available = true, total_count = 1,
  truncated = false,
  devices = { { key = KEY_A, name = "Headphones", connected = true, paired = true,
    rssi = -48, type = "Headphones", profiles = { "A2DP sink" },
    battery = { { component = "main", percent = 80 } } } },
})
check(bluetooth.properties.icon.color == colors.blue,
  "connected Bluetooth state must render blue")
rendered.rows.device_1.click({ BUTTON = "left" })
command = action_commands[#action_commands]
check(command[2] == "bluetooth" and command[3] == "disconnect"
  and command[4] == KEY_A and command[5] == "on",
  "Bluetooth disconnect must preserve opaque-target expected-state arguments")

wifi_fixture = wifi_state("associated")
wifi_fixture.interface_key = string.rep("d", 64)
rendered = render_wifi(wifi_fixture)
rendered.rows.toggle.click({ BUTTON = "left" })
command = action_commands[#action_commands]
check(command[2] == "wifi" and command[3] == "set" and command[4] == "off"
  and command[5] == "on" and command[6] == wifi_fixture.interface_key,
  "Wi-Fi action must preserve opaque-target expected-state arguments")

fire(bluetooth, "sketchybar_test_hover", { TARGET = "bluetooth" })
fire(bluetooth, "sketchybar_test_hover_exit", { TARGET = "bluetooth" })
check(bluetooth.properties.icon.color == colors.blue,
  "Bluetooth hover exit must restore connected blue")
print("Connectivity item permission, Wi-Fi link, rich Bluetooth, inventory, and action contracts passed")
