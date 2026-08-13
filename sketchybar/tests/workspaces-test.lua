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
  local object = { name = name, properties = properties or {}, subscriptions = {} }
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
  remove = function(object) objects[object.name] = nil end,
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
local unavailable = objects["space.9"]
for _, callback in ipairs(unavailable.subscriptions["mouse.entered"] or {}) do callback({}) end
check(unavailable.properties.icon.color == require("colors").state.actionable
    and unavailable.properties.background.drawing == false,
  "unavailable Space hover must retain the orange static cell without hover fill")
for _, callback in ipairs(unavailable.subscriptions["mouse.exited"] or {}) do callback({}) end

commands = {}
for _, callback in ipairs(unavailable.subscriptions["mouse.clicked"] or {}) do callback({ BUTTON = "left" }) end
for _, callback in ipairs(unavailable.subscriptions["mouse.scrolled"] or {}) do callback({ SCROLL_DELTA = 1 }) end
for _, command in ipairs(commands) do check(not command:find("focus%-space%.sh"), "no-Yabai click and scroll must not route focus") end
check(objects["space.1"].properties.popup.drawing == true,
  "clicking any unavailable Space must open the single recovery popup on Space 1")
check(objects["space.1"].properties.background.drawing == false
    and objects["space.1"].properties.icon.color == require("colors").state.actionable,
  "open recovery popup must not add an active or hover affordance to Space 1")
for _, callback in ipairs(objects["space.1"].subscriptions["mouse.entered"] or {}) do callback({}) end
check(objects["space.1"].properties.background.drawing == false
    and objects["space.1"].properties.icon.color == require("colors").state.actionable,
  "hovering the open recovery host must keep the orange cell visually static")
for _, callback in ipairs(objects["space.1"].subscriptions["mouse.exited"] or {}) do callback({}) end
for index = 2, 9 do
  check(not objects["space." .. index].properties.popup,
    "unavailable Space diagnostics must use only one popup host")
end
local expected_rows = {
  heading = "SPACES  ·  YABAI UNAVAILABLE",
  reason = "Yabai query failed",
  version = "Signed Yabai app version: 7.1.25",
  path = "App path: $HOME/Applications/Yabai.app",
  topology = "Spaces: exactly 9 global indices 1–9",
  display = "Display: all nine Spaces on display 1",
}
for suffix, label in pairs(expected_rows) do
  local row = objects["popup.space.1." .. suffix]
  check(row and row.properties.label.string == label,
    "recovery popup must show the exact bounded Yabai diagnostic: " .. suffix)
end
local recovery_row_count = 0
for name in pairs(objects) do
  if name:match("^popup%.space%.1%.") then recovery_row_count = recovery_row_count + 1 end
end
check(recovery_row_count == 9, "recovery popup must stay bounded to its nine reviewed rows")
for index = 1, 9 do
  commands = {}
  local target = objects["space." .. index]
  for _ = 1, 2 do
    for _, callback in ipairs(target.subscriptions["mouse.clicked"] or {}) do callback({ BUTTON = "left" }) end
  end
  check(objects["space.1"].properties.popup.drawing == true
      and objects["space.1"].properties.background.drawing == false
      and objects["space.1"].properties.icon.color == require("colors").state.actionable,
    "each repeated unavailable Space click must leave one visually static Space 1 diagnostic")
  local current_rows = 0
  for name in pairs(objects) do
    if name:match("^popup%.space%.1%.") then current_rows = current_rows + 1 end
  end
  check(current_rows == 9, "each unavailable Space click must keep exactly nine diagnostic rows")
  for _, command in ipairs(commands) do
    check(not command:find("focus%-space%.sh"), "no unavailable Space may route focus")
  end
end
local guide = objects["popup.space.1.setup_guide"]
check(guide and guide.properties.label.string == "Open official Yabai setup guide",
  "recovery popup must expose one real documentation action")
for _, callback in ipairs(guide.subscriptions["mouse.clicked"] or {}) do callback({ BUTTON = "left" }) end
local opened_guide = false
for _, command in ipairs(commands) do
  if command:find("https://github.com/asmvik/yabai/wiki/Installing%-yabai%-%(latest%-release%)") then opened_guide = true end
end
check(opened_guide, "Yabai recovery action must open the official setup guide")
check(objects["space.1"].properties.popup.drawing == false,
  "real recovery action must close its popup")

local function refresh_spaces()
  for _, callback in ipairs(objects["space.1"].subscriptions.routine or {}) do callback({}) end
end
local function action_routes_focus()
  commands = {}
  for _, callback in ipairs(objects["space.1"].subscriptions["mouse.clicked"] or {}) do callback({ BUTTON = "left" }) end
  for _, callback in ipairs(objects["space.1"].subscriptions["mouse.scrolled"] or {}) do callback({ SCROLL_DELTA = 1 }) end
  local count = 0
  for _, command in ipairs(commands) do if command:find("focus%-space%.sh") then count = count + 1 end end
  if count ~= 2 and objects["space.1"].properties.popup.drawing == true then
    require("lib.popup").close()
  end
  return count == 2
end

local function numeric_string_topology(string_field)
  local result = {}
  for index = 1, 9 do
    result[index] = {
      index = string_field == "index" and tostring(index) or index,
      display = string_field == "display" and "1" or 1,
    }
  end
  return result
end
for _, string_field in ipairs({ "display", "index" }) do
  yabai_spaces = numeric_string_topology(string_field)
  refresh_spaces()
  check(window_query_count == 0 and objects["space.1"].properties.icon.color == require("colors").state.actionable,
    "numeric-string Yabai " .. string_field .. " values must not enable the workspace UI")
  check(not action_routes_focus(),
    "numeric-string Yabai " .. string_field .. " values must not enable workspace actions")
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
local exact_direct_focus, exact_scroll_focus = false, false
for _, command in ipairs(commands) do
  if command:find("focus%-space%.sh") and command:find("'1'", 1, true) then exact_direct_focus = true end
  if command:find("focus%-space%.sh") and command:find("'prev'", 1, true) then exact_scroll_focus = true end
end
check(exact_direct_focus and exact_scroll_focus,
  "healthy Yabai topology must preserve the exact direct and previous-space actions")
check(objects["space.1"].properties.icon.color ~= require("colors").state.actionable,
  "exact Yabai topology did not clear the degraded-state signal")

window_result, window_exit = {}, 1
refresh_spaces()
check(window_query_count == 2 and objects["space.1"].properties.label.drawing == true, "failed windows response must retain the last accepted apps")
window_result, window_exit = {}, 0
refresh_spaces()
check(window_query_count == 3 and objects["space.1"].properties.label.drawing == false, "empty windows response must clear apps and focused injection")
window_result = { { space = 2, app = "Safari", ["has-focus"] = false } }
refresh_spaces()
check(window_query_count == 4 and objects["space.1"].properties.label.drawing == false and objects["space.2"].properties.label.drawing == true, "focus-less response must not retain the prior focused app")
window_result = { { space = 1, app = "Safari", ["has-focus"] = true } }
refresh_spaces()
check(window_query_count == 5 and objects["space.1"].properties.label.drawing == true, "accepted current windows response restores current apps")
for _, callback in ipairs(objects["space.2"].subscriptions.space_change or {}) do callback({ SELECTED = "true" }) end
check(objects["space.2"].properties.label.drawing == false,
  "space switch must not bleed the prior focused app onto the new Space")
for _, callback in ipairs(objects["space.2"].subscriptions.space_change or {}) do callback({ SELECTED = "false" }) end
for _, callback in ipairs(objects["space.1"].subscriptions.space_change or {}) do callback({ SELECTED = "true" }) end
window_result = {
  { space = 1, app = "Safari", role = "AXWindow", ["has-focus"] = true },
  { space = 1, app = "Calendar", role = "AXWindow", ["has-focus"] = false },
  { space = 1, app = "Ghostty", role = "AXWindow", ["has-focus"] = false },
  { space = 1, app = "Activity Monitor", role = "", ["has-focus"] = false },
}
refresh_spaces()
check(window_query_count == 6 and objects["space.1"].properties.label.width == 60,
  "selected workspace receives three current app icons")
check(not objects["space.1"].properties.label.string:find(":activity_monitor:", 1, true),
  "non-window Yabai records cannot leave stale workspace icons")
window_result = {
  { space = 1, app = "Ghostty", role = "AXWindow", ["has-focus"] = true },
  { space = 2, app = "Zen", role = "AXWindow", ["has-focus"] = false },
  { space = 3, app = "Slack", role = "AXWindow", ["has-focus"] = false },
  { space = 4, app = "Discord", role = "AXWindow", ["has-focus"] = false },
}
refresh_spaces()
for index = 1, 4 do
  check(objects["space." .. index].properties.label.drawing == true,
    "all four occupied workspaces must keep icon coverage simultaneously")
end
window_result[1]["has-focus"] = false
window_result[4]["has-focus"] = true
refresh_spaces()
for index = 1, 4 do
  check(objects["space." .. index].properties.label.drawing == true,
    "icon coverage must stay stable when the selected workspace changes")
end
window_result = { { space = 1, app = "Safari", role = "AXWindow", ["has-focus"] = true } }
refresh_spaces()
defer_windows = true
refresh_spaces()
check(window_query_count == 10 and #pending_windows == 1, "stale callback fixture must hold one accepted windows response")
local pre_switch_label = objects["space.1"].properties.label.string
for _, callback in ipairs(objects["space.1"].subscriptions.front_app_switched or {}) do callback({ INFO = "Calendar" }) end
local switched_label = objects["space.1"].properties.label.string
check(window_query_count == 11 and #pending_windows == 2 and switched_label == pre_switch_label, "front-app event content must stay ignored until guarded replacement data arrives")
pending_windows[1](window_result, 0)
check(objects["space.1"].properties.label.string == switched_label, "pre-switch windows callback must not overwrite current front-app state")

yabai_spaces = { { index = 1, display = 1 }, { index = 2, display = 1 } }
refresh_spaces()
for index = 1, 9 do
  check(objects["space." .. index].properties.drawing ~= false and objects["space." .. index].properties.associated_space == index, "Yabai subset must use static bounded fallback")
  check(objects["space." .. index].properties.label.drawing == false, "Yabai subset must clear live app ligatures")
  check(objects["space." .. index].properties.icon.color == require("colors").state.actionable,
    "Yabai topology failure must show the orange degraded-state signal")
  check(objects["space." .. index].properties.background.drawing == false,
    "Yabai topology failure must clear selected backgrounds")
end
for _, callback in ipairs(objects["space.1"].subscriptions.sketchybar_test_hover or {}) do
  callback({ TARGET = "space.1" })
end
for _, callback in ipairs(objects["space.1"].subscriptions.space_change or {}) do
  callback({ SELECTED = "true" })
end
check(objects["space.1"].properties.icon.color == require("colors").state.actionable
    and objects["space.1"].properties.background.drawing == false,
  "unavailable Space must keep the orange signal without hover fill")
for _, callback in ipairs(objects["space.1"].subscriptions.sketchybar_test_hover_exit or {}) do
  callback({ TARGET = "space.1" })
end
check(objects["space.1"].properties.icon.color == require("colors").state.actionable,
  "hover exit must restore the orange degraded-state signal")
for _, callback in ipairs(objects["space.4"].subscriptions["mouse.clicked"] or {}) do callback({ BUTTON = "left" }) end
check(objects["popup.space.1.reason"].properties.label.string == "Yabai topology does not match",
  "recovery popup must distinguish a topology mismatch from a query failure")
for _, callback in ipairs(objects["space.4"].subscriptions["mouse.clicked"] or {}) do callback({ BUTTON = "left" }) end
check(objects["space.1"].properties.popup.drawing == true
    and objects["popup.space.1.reason"].properties.label.string == "Yabai topology does not match",
  "every unavailable Space click must leave a rebuilt recovery popup visible")
check(objects["space.1"].properties.background.drawing == false
    and objects["space.1"].properties.icon.color == require("colors").state.actionable,
  "rebuilt recovery popup must leave its orange host visually static")
require("lib.popup").close()

check(window_query_count == 11, "Yabai subset must not query windows")
pending_windows[2](window_result, 0)
check(objects["space.1"].properties.label.drawing == false, "stale out-of-order windows callback must not restore cleared apps")
defer_windows = false
for _, callback in ipairs(objects["space.1"].subscriptions.front_app_switched or {}) do callback({ INFO = "Safari" }) end
check(objects["space.1"].properties.label.drawing == false and window_query_count == 11, "static fallback must ignore front-app content and not query windows")
check(not action_routes_focus(), "Yabai subset must not enable workspace actions")

yabai_spaces = {
  { index = 2, display = 1 }, { index = 3, display = 1 }, { index = 4, display = 1 }, { index = 5, display = 1 },
  { index = 6, display = 1 }, { index = 7, display = 1 }, { index = 8, display = 1 }, { index = 9, display = 1 },
}
refresh_spaces()
for index = 1, 9 do check(objects["space." .. index].properties.associated_space == index and objects["space." .. index].properties.label.drawing == false, "non-1-based Yabai data must use content-free static fallback") end
check(window_query_count == 11, "non-1-based Yabai data must not query windows")
check(not action_routes_focus(), "non-1-based Yabai data must not enable workspace actions")
local hovered_space = objects["space.1"]
for _, callback in ipairs(hovered_space.subscriptions["mouse.entered"] or {}) do callback({}) end
for _, callback in ipairs(hovered_space.subscriptions.space_change or {}) do callback({ SELECTED = "true" }) end
check(hovered_space.properties.background.drawing == false
    and hovered_space.properties.background.color == require("colors").surface,
  "unavailable Space updates must not restore hover fill")
check(hovered_space.properties.icon.color == require("colors").state.actionable,
  "unavailable Space updates must preserve the orange static foreground")
print("Workspace exact-Yabai and bounded recovery popup tests passed")
