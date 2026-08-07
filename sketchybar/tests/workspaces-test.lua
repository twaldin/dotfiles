package.path = os.getenv("SKETCHYBAR_CONFIG_DIR") .. "/?.lua;" .. os.getenv("SKETCHYBAR_CONFIG_DIR") .. "/?/init.lua;" .. package.path
local initial_space_count = require("settings").space_count
local objects, commands = {}, {}
local yabai_spaces = nil
local window_query_count = 0
local window_result = { { space = 1, app = "Safari", ["has-focus"] = true } }
local window_exit = 0
local defer_windows = false
local pending_windows = {}
local function merge(target, source)
  for key, value in pairs(source or {}) do
    if type(value) == "table" then target[key] = target[key] or {}; merge(target[key], value) else target[key] = value end
  end
end
local function add(_, name, properties)
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
end
sbar = {
  add = add,
  exec = function(command, callback)
    commands[#commands + 1] = tostring(command)
    if not callback then return end
    if tostring(command):find("query.*%-%-spaces") then
      if yabai_spaces then callback(yabai_spaces, 0) else callback({}, 1) end
    elseif tostring(command):find("yabai%-windows%.sh") and tostring(command):find("all") then
      window_query_count = window_query_count + 1
      if defer_windows then
        pending_windows[#pending_windows + 1] = callback
      else
        callback(window_result, window_exit)
      end
    else callback("", 0) end
  end,
  delay = function(_, callback) callback() end,
}
require("items.workspaces")
local function check(condition, message) if not condition then error(message, 0) end end
check(initial_space_count == 9, "canonical shipped Space invariant must default to nine")
for index = 1, 9 do
  check(objects["space." .. index].properties.drawing ~= false, "no-Yabai fallback must retain nine visual Spaces")
  check(objects["space." .. index].properties.associated_space == index, "no-Yabai fallback associations must remain bounded 1..9")
  check(objects["space." .. index].properties.label.drawing == false, "failing availability must clear all app ligatures")
end
check(window_query_count == 0, "failing Space availability must not query successful windows output")
commands = {}
for _, callback in ipairs(objects["space.1"].subscriptions["mouse.clicked"] or {}) do callback({ BUTTON = "left" }) end
for _, callback in ipairs(objects["space.1"].subscriptions["mouse.scrolled"] or {}) do callback({ SCROLL_DELTA = 1 }) end
for _, command in ipairs(commands) do check(not command:find("focus%-space%.sh"), "no-Yabai click and scroll must both fail closed") end

local function refresh_spaces()
  for _, callback in ipairs(objects["space.1"].subscriptions.routine or {}) do callback({}) end
end
local function action_routes_focus()
  commands = {}
  for _, callback in ipairs(objects["space.1"].subscriptions["mouse.clicked"] or {}) do callback({ BUTTON = "left" }) end
  for _, callback in ipairs(objects["space.1"].subscriptions["mouse.scrolled"] or {}) do callback({ SCROLL_DELTA = 1 }) end
  local count = 0
  for _, command in ipairs(commands) do if command:find("focus%-space%.sh") then count = count + 1 end end
  return count == 2
end

yabai_spaces = {
  { index = 9, display = 1 }, { index = 4, display = 2 }, { index = 3, display = 1 },
  { index = 7, display = 1 }, { index = 1, display = 1 }, { index = 5, display = 1 },
  { index = 8, display = 1 }, { index = 2, display = 1 }, { index = 6, display = 1 },
  { index = 4, display = 1 },
}
refresh_spaces()
for index = 1, 9 do check(objects["space." .. index].properties.associated_space == index, "shuffled exact Yabai invariant must sort to global indices 1..9") end
check(window_query_count == 1 and objects["space.1"].properties.label.drawing == true, "accepted exact Yabai invariant may query and render windows")
check(action_routes_focus(), "exact Yabai invariant enables supported click and scroll routes")

window_result, window_exit = {}, 1
refresh_spaces()
check(window_query_count == 2 and objects["space.1"].properties.label.drawing == false, "failed windows response must clear apps and focused injection")
window_result, window_exit = {}, 0
refresh_spaces()
check(window_query_count == 3 and objects["space.1"].properties.label.drawing == false, "empty windows response must clear apps and focused injection")
window_result = { { space = 2, app = "Safari", ["has-focus"] = false } }
refresh_spaces()
check(window_query_count == 4 and objects["space.1"].properties.label.drawing == false and objects["space.2"].properties.label.drawing == true, "focus-less response must not retain the prior focused app")
window_result = { { space = 1, app = "Safari", ["has-focus"] = true } }
refresh_spaces()
check(window_query_count == 5 and objects["space.1"].properties.label.drawing == true, "accepted current windows response restores current apps")
defer_windows = true
refresh_spaces()
check(window_query_count == 6 and #pending_windows == 1, "stale callback fixture must hold one accepted windows response")
local pre_switch_label = objects["space.1"].properties.label.string
for _, callback in ipairs(objects["space.1"].subscriptions.front_app_switched or {}) do callback({ INFO = "Calendar" }) end
local switched_label = objects["space.1"].properties.label.string
check(window_query_count == 7 and #pending_windows == 2 and switched_label == pre_switch_label, "front-app event content must stay ignored until guarded replacement data arrives")
pending_windows[1](window_result, 0)
check(objects["space.1"].properties.label.string == switched_label, "pre-switch windows callback must not overwrite current front-app state")

yabai_spaces = { { index = 1, display = 1 }, { index = 2, display = 1 } }
refresh_spaces()
for index = 1, 9 do
  check(objects["space." .. index].properties.drawing ~= false and objects["space." .. index].properties.associated_space == index, "Yabai subset must use static bounded fallback")
  check(objects["space." .. index].properties.label.drawing == false, "Yabai subset must clear live app ligatures")
end
check(window_query_count == 7, "Yabai subset must not query windows")
pending_windows[2](window_result, 0)
check(objects["space.1"].properties.label.drawing == false, "stale out-of-order windows callback must not restore cleared apps")
defer_windows = false
for _, callback in ipairs(objects["space.1"].subscriptions.front_app_switched or {}) do callback({ INFO = "Safari" }) end
check(objects["space.1"].properties.label.drawing == false and window_query_count == 7, "static fallback must ignore front-app content and not query windows")
check(not action_routes_focus(), "Yabai subset must not enable workspace actions")

yabai_spaces = {
  { index = 2, display = 1 }, { index = 3, display = 1 }, { index = 4, display = 1 }, { index = 5, display = 1 },
  { index = 6, display = 1 }, { index = 7, display = 1 }, { index = 8, display = 1 }, { index = 9, display = 1 },
}
refresh_spaces()
for index = 1, 9 do check(objects["space." .. index].properties.associated_space == index and objects["space." .. index].properties.label.drawing == false, "non-1-based Yabai data must use content-free static fallback") end
check(window_query_count == 7, "non-1-based Yabai data must not query windows")
check(not action_routes_focus(), "non-1-based Yabai data must not enable workspace actions")
print("Workspace exact-Yabai and static no-Yabai fallback tests passed")
