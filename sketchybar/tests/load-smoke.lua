package.path = os.getenv("SKETCHYBAR_CONFIG_DIR") .. "/?.lua;" .. os.getenv("SKETCHYBAR_CONFIG_DIR") .. "/?/init.lua;" .. package.path

local subscriptions, objects, delayed = {}, {}, {}
local function validate(value, path)
  if type(value) == "function" then error("function leaked into SketchyBar property at " .. path) end
  if path:match("slider%.highlight_color$") and type(value) ~= "number" then
    error("slider highlight color must be numeric at " .. path)
  end
  if type(value) ~= "table" then return end
  for key, child in pairs(value) do validate(child, path .. "." .. tostring(key)) end
end

local function register(events, callback)
  if type(events) ~= "table" then events = { events } end
  for _, event in ipairs(events) do
    subscriptions[event] = subscriptions[event] or {}
    subscriptions[event][#subscriptions[event] + 1] = callback
  end
end

local function object(name, properties)
  validate(properties or {}, "add." .. tostring(name))
  local result = { name = name }
  function result:set(value) validate(value, "set." .. tostring(name)) end
  function result:subscribe(events, callback) register(events, callback) end
  function result:push(value) validate(value, "push." .. tostring(name)) end
  objects[#objects + 1] = result
  return result
end

local function mock_output(command)
  if command:find("connectivity%-state%.py") and command:find("'wifi' 'state'", 1, true) then
    return {
      power = true, ssid = nil, name_available = false,
      association = "associated", security = "wpa3_personal",
      rssi = -47, noise = -89, rate = 1201,
    }, 0
  end
  if command:find("connectivity%-state%.py") and command:find("'bluetooth' 'state'", 1, true) then
    return {
      power = true,
      devices = {
        { address = "00:11:22:33:44:55", name = "Mock headset", connected = true },
        { address = "66:77:88:99:AA:BB", name = "Mock keyboard", connected = false },
      },
    }, 0
  end
  if command:find("'audio' 'state'", 1, true) then
    return {
      schema = 1, ok = true, warning_count = 0,
      defaults = { output = "fixture-output", system_output = "fixture-output", input = "fixture-input" },
      default_settable = { output = true, system_output = true, input = true },
      devices = {
        {
          uid = "fixture-output", name = "Mock Speakers",
          directions = { "output" }, roles = { "output", "system_output" },
          output = {
            volume = { available = true, settable = true, value = 50 },
            mute = { available = true, settable = true, value = false },
          },
        },
        {
          uid = "fixture-input", name = "Mock Microphone",
          directions = { "input" }, roles = { "input" },
          input = {
            volume = { available = true, settable = true, value = 75 },
            mute = { available = true, settable = true, value = false },
          },
        },
      },
    }, 0
  end
  if command:find("network%-sample%.sh") then return "1\ten0\t100\t100\t192.0.2.2\t192.0.2.1\tMock", 0 end
  if command:find("system_profiler") then return { SPBluetoothDataType = { { controller_properties = { controller_state = "attrib_on" }, device_connected = {} } } }, 0 end
  if command:find("gpu%-usage%.py") then return { schema = 1, valid = true, usage_percent = 12.3 }, 0 end
  if command:find("query.*%-%-spaces") or command:find("query.*%-%-windows") then return {}, 0 end
  if command:find("top%-processes%.sh") then return "1%  mock\n2%  mock", 0 end
  if command:find("vpn%-state%.sh") then return "Tailscale on", 0 end
  if command:find("power%-details%.sh") then return "Cycle count\t1", 0 end
  return "", 0
end

sbar = {
  add = function(_, name, ...)
    local arguments = { ... }
    local properties = arguments[#arguments]
    if type(properties) ~= "table" then properties = {} end
    return object(name, properties)
  end,
  remove = function() end,
  bar = function(properties) validate(properties, "bar") end,
  default = function(properties) validate(properties, "default") end,
  exec = function(command, callback)
    if type(callback) == "function" then
      local output, code = mock_output(command)
      callback(output, code)
    end
  end,
  delay = function(seconds, callback) delayed[#delayed + 1] = { seconds, callback } end,
  animate = function(_, _, callback) callback() end,
  trigger = function() end,
}

local ok, err = pcall(require, "init")
if not ok then error("mock config load failed: " .. tostring(err)) end

local function fire(event, env)
  local callbacks = {}
  for _, callback in ipairs(subscriptions[event] or {}) do callbacks[#callbacks + 1] = callback end
  for _, callback in ipairs(callbacks) do callback(env or {}) end
end

-- Representative event payloads catch callbacks that mistake an env table for a function.
fire("routine", { NAME = "smoke", INFO = "0" })
fire("system_woke", { NAME = "smoke" })
fire("front_app_switched", { INFO = "Finder" })
fire("system_metrics_v2", require("tests.stats-fixture").metrics())

-- Build every popup shell without running system commands, then exercise action hover.
for _, target in ipairs({ "calendar", "wifi", "bluetooth", "audio", "microphone", "battery", "cpu", "gpu", "ram", "net", "ssd", "tmp", "front_window" }) do
  fire("sketchybar_test_popup", { TARGET = target })
end
fire("mouse.entered", { NAME = "smoke" })
fire("mouse.exited", { NAME = "smoke" })
fire("mouse.exited.global", { NAME = "smoke" })

print("SketchyBar Lua load/event smoke passed")
