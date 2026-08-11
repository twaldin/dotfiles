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
package.loaded["lib.popup"] = {
  bind = function() end,
  is_current = function() return false end,
}
local bluetooth_fixture = {
  power = true,
  devices = { { connected = true } },
}
package.loaded["lib.shell"] = {
  exec = function(command, callback)
    local family, action = command[2], command[3]
    if family == "session" and action == "begin" then callback({}, 0)
    elseif family == "wifi" and action == "state" then callback({ power = true, ssid = "Fixture" }, 0)
    elseif family == "bluetooth" and action == "state" then callback(bluetooth_fixture, 0)
    else callback(nil, 1) end
  end,
  open = function() end,
  ellipsis = function(value) return value end,
}

local colors = require("colors")
local items = require("items.connectivity")
local bluetooth = items.bluetooth
check(bluetooth.properties.icon.color == colors.blue,
  "connected Bluetooth state must render blue")
local function fire(event, env)
  for _, callback in ipairs(bluetooth.subscriptions[event] or {}) do callback(env or {}) end
end
fire("sketchybar_test_hover", { TARGET = "bluetooth" })
fire("sketchybar_test_hover_exit", { TARGET = "bluetooth" })
check(bluetooth.properties.icon.color == colors.blue,
  "Bluetooth hover exit must restore connected blue")
print("Bluetooth connected hover color contract passed")
