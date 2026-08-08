package.path = os.getenv("SKETCHYBAR_CONFIG_DIR") .. "/?.lua;" .. os.getenv("SKETCHYBAR_CONFIG_DIR") .. "/?/init.lua;" .. package.path
local objects = {}
local function merge(target, source)
  for key, value in pairs(source or {}) do
    if type(value) == "table" then target[key] = target[key] or {}; merge(target[key], value) else target[key] = value end
  end
end
sbar = {
  add = function(_, name, properties)
    local object = { properties = properties or {}, subscriptions = {} }
    function object:set(update) merge(object.properties, update) end
    function object:subscribe(events, callback)
      if type(events) ~= "table" then events = { events } end
      for _, event in ipairs(events) do
        object.subscriptions[event] = object.subscriptions[event] or {}
        object.subscriptions[event][#object.subscriptions[event] + 1] = callback
      end
    end
    objects[name] = object
    return object
  end,
  exec = function() error("workspace privacy quarantine executed a command") end,
  delay = function(_, callback) callback() end,
}
local function check(value, message) if not value then error(message, 0) end end
require("items.workspaces")
check(require("settings").space_count == 9, "canonical Space count must stay nine")
for index = 1, 9 do
  local item = objects["space." .. index]
  check(item ~= nil, "all nine fixed Space hosts must exist")
  check(item.properties.associated_space == index, "Space association must be fixed 1..9")
  check(item.properties.width == 24 and item.properties.icon.width == 24, "Space geometry must stay 24 points")
  check(item.properties.label.drawing == false, "Space host must not contain app identity")
  check(item.subscriptions["mouse.clicked"] == nil and item.subscriptions["mouse.scrolled"] == nil,
        "Space actions must stay disabled until exact readback")
end
local first = objects["space.1"]
for _, callback in ipairs(first.subscriptions.space_change or {}) do callback({ SELECTED = "true" }) end
check(first.properties.background.drawing == true, "selected Space must retain fixed highlight")
for _, callback in ipairs(first.subscriptions["mouse.entered"] or {}) do callback({}) end
for _, callback in ipairs(first.subscriptions.space_change or {}) do callback({ SELECTED = "true" }) end
check(first.properties.background.color == require("colors").hover, "Space event must preserve active hover")
print("Workspace privacy quarantine contract passed")
