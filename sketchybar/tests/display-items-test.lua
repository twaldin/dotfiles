package.path = os.getenv("SKETCHYBAR_CONFIG_DIR") .. "/?.lua;" .. package.path

local function check(condition, message)
  if not condition then error(message, 2) end
end

package.loaded.colors = {
  transparent = 0, popup = 1, surface = 2, surface2 = 3, right_hover = 4,
  border = 5, primary = 6, muted = 7, normal = 6, active = 6, accent = 8,
  blue = 9, cyan = 10, purple = 11, orange = 12, green = 13, warning = 14,
  domain = { display = 12 }, state = { actionable = 12 },
}
package.loaded.settings = {
  config_dir = os.getenv("SKETCHYBAR_CONFIG_DIR"), control_width = 28,
  spacing = { item = 4 }, surface_height = 28, popup_width = 340,
  links = { displays = "/fixed/displays" },
  popup_layout = {
    gutter = 12, value_width = 96, column_gap = 8,
    heading_height = 34, section_height = 28, row_height = 30, axis_height = 18,
  },
  type = {
    bar_control = "Test:14", popup_head = "Test:11", popup_row = "Test:11",
    popup_section = "Test:9", popup_axis = "Test:9", popup_action_icon = "Test:13",
  },
}
package.loaded["lib.hover"] = {
  bind = function() end,
  foreground = function(_, color) return color end,
  set_popup_open = function() return true end,
  is_active = function() return false end,
  clear = function() end,
}

local function merge(target, source)
  for key, value in pairs(source or {}) do
    if type(value) == "table" then
      target[key] = type(target[key]) == "table" and target[key] or {}
      merge(target[key], value)
    else
      target[key] = value
    end
  end
end

local function fake(name, properties)
  local object = { name = name, properties = properties or {}, subscriptions = {}, removed = false }
  function object:set(update) merge(object.properties, update) end
  function object:subscribe(events, callback)
    if type(events) ~= "table" then events = { events } end
    for _, event in ipairs(events) do
      object.subscriptions[event] = object.subscriptions[event] or {}
      object.subscriptions[event][#object.subscriptions[event] + 1] = callback
    end
  end
  function object:push() end
  return object
end

local objects = {}
local delayed = {}
sbar = {
  add = function(kind, name, width_or_properties, properties)
    local object = fake(name, properties or width_or_properties)
    object.kind = kind
    objects[name] = object
    return object
  end,
  remove = function(object) object.removed = true end,
  delay = function(seconds, callback)
    delayed[#delayed + 1] = { seconds = seconds, callback = callback }
  end,
}

local function run_delayed(index)
  local timer = delayed[index]
  check(timer and type(timer.callback) == "function", "missing display timer " .. tostring(index))
  timer.callback()
end

local function run_latest_delay(seconds)
  for index = #delayed, 1, -1 do
    if delayed[index].seconds == seconds then
      run_delayed(index)
      return
    end
  end
  error("missing display timer for " .. tostring(seconds) .. " seconds")
end

local exec_calls = {}
package.loaded["lib.shell"] = {
  exec = function(argv, callback)
    local copy = {}
    for index, value in ipairs(argv) do copy[index] = value end
    exec_calls[#exec_calls + 1] = { argv = copy, callback = callback }
    return true
  end,
  open = function() end,
  ellipsis = function(value) return value end,
}
package.loaded["lib.popup"] = nil
package.loaded["items.display"] = nil

local function fire(object, event, env)
  for _, callback in ipairs(object.subscriptions[event] or {}) do callback(env or {}) end
end

local function respond(index, output, code)
  local call = exec_calls[index]
  check(call and type(call.callback) == "function", "missing display helper callback " .. tostring(index))
  call.callback(output, code)
end

local HANDLE_ONE = "v1_" .. string.rep("1", 32) .. "_" .. string.rep("a", 64)
local HANDLE_TWO = "v1_" .. string.rep("2", 32) .. "_" .. string.rep("b", 64)
local HANDLE_THREE = "v1_" .. string.rep("3", 32) .. "_" .. string.rep("c", 64)
local RAW_UUID = "DEADBEEF-1111-2222-3333-444455556666"

local function view(handle, brightness, mute, status)
  local value = {
    schema = 3, ok = true, brightness = brightness or 80,
    volume = 55, contrast = 70, mute = mute == nil and false or mute,
    resolution = "2560x1440", refresh_rate = 60, hi_dpi = true, main = false,
    color_depth = 10, mode_number = 3, modes = {},
    target_handle = handle,
    controls = { brightness = true, hardware_contrast = true, volume = true, mute = true },
  }
  if status then value.status = status end
  return value
end

local display = require("items.display")
check(exec_calls[1] and exec_calls[1].argv[2] == "state", "display starts with read-only state")
respond(1, view(HANDLE_ONE, 80, false), 0)
check(display.properties.label.string == "Display confirmed",
  "all-display bar label must not claim one display's values")

fire(display, "mouse.clicked", { BUTTON = "left" })
check(exec_calls[2] and exec_calls[2].argv[2] == "state", "popup open refreshes display state")
local first_brightness = objects["popup.display.brightness_slider"]
check(not first_brightness or first_brightness.properties.drawing == false,
  "popup exposed a control before confirming the display under the pointer")
check(objects["popup.display.confirming_target"].properties.label.string
  == "Confirming the display under the pointer…",
  "popup did not explain pointer-target confirmation")
check(objects["popup.display.heading"].properties.label.string == "DISPLAY  ·  —",
  "pending popup header retained a prior display value")
check(objects["popup.display.open_heading"].properties.drawing ~= false
  and objects["popup.display.betterdisplay"].properties.drawing ~= false
  and objects["popup.display.settings"].properties.drawing ~= false,
  "pending popup omitted its app and System Settings handoffs")
for index = 1, 11 do
  check(objects["popup.display.confirming_space_" .. index].properties.drawing ~= false,
    "pending popup did not reserve its stable pointer area")
end
if first_brightness then
  fire(first_brightness, "mouse.clicked", { BUTTON = "left", PERCENTAGE = "75" })
end
check(#exec_calls == 2, "unconfirmed popup control retained a callback")
fire(display, "display_change")
check(#exec_calls == 2, "in-flight display change started a duplicate read")
respond(2, view(HANDLE_ONE, 81, false), 0)
check(exec_calls[3] and exec_calls[3].argv[2] == "state",
  "in-flight display change did not start one coalesced follow-up read")
check(not objects["popup.display.brightness_slider"]
    or objects["popup.display.brightness_slider"].properties.drawing == false,
  "coalesced popup confirmation exposed a control before the final read")
respond(3, view(HANDLE_ONE, 80, false), 0)
check(#exec_calls == 3, "coalesced display refresh started more than one follow-up")

local brightness = objects["popup.display.brightness_slider"]
local contrast = objects["popup.display.contrast_slider"]
local volume = objects["popup.display.volume_slider"]
local mute = objects["popup.display.mute_action"]
check(brightness.properties.drawing ~= false and contrast.properties.drawing ~= false
  and volume.properties.drawing ~= false and mute.properties.drawing ~= false,
  "brightness, hardware contrast, volume, and mute controls render")
check(mute.properties.label.string == "Turn display mute on", "mute action is explicit on")

fire(display, "display_change")
local unknown_role = view(HANDLE_ONE, 80, false)
unknown_role.main = nil
respond(#exec_calls, unknown_role, 0)
check(objects["popup.display.main"].properties.label.string == "—",
  "unproved display role rendered a visible claim")
brightness = objects["popup.display.brightness_slider"]
contrast = objects["popup.display.contrast_slider"]
volume = objects["popup.display.volume_slider"]
mute = objects["popup.display.mute_action"]

local before = #exec_calls
fire(brightness, "mouse.clicked", { BUTTON = "right", PERCENTAGE = "75" })
fire(brightness, "mouse.clicked", { BUTTON = "left", PERCENTAGE = "nan" })
fire(brightness, "mouse.clicked", { BUTTON = "left", PERCENTAGE = "101" })
check(#exec_calls == before, "slider rejects hostile values and non-left clicks")
fire(brightness, "mouse.clicked", { BUTTON = "left", PERCENTAGE = "75" })
check(#exec_calls == before + 1, "brightness slider starts one action")
local action = exec_calls[#exec_calls]
check(#action.argv == 6 and action.argv[2] == "action" and action.argv[3] == "brightness"
  and action.argv[4] == "0.8" and action.argv[5] == "0.75" and action.argv[6] == HANDLE_ONE,
  "click captures displayed expected value and opaque handle")
for _, argument in ipairs(action.argv) do
  check(not tostring(argument):find(RAW_UUID, 1, true), "raw UUID reached public action argv")
end

check(brightness.properties.drawing == false and contrast.properties.drawing == false
  and volume.properties.drawing == false and mute.properties.drawing == false,
  "busy display controls become visibly inert")
local busy_count = #exec_calls
fire(brightness, "mouse.clicked", { BUTTON = "left", PERCENTAGE = "90" })
fire(contrast, "mouse.clicked", { BUTTON = "left", PERCENTAGE = "90" })
fire(volume, "mouse.clicked", { BUTTON = "left", PERCENTAGE = "90" })
fire(mute, "mouse.clicked", { BUTTON = "left" })
check(#exec_calls == busy_count, "busy controls lose all callbacks")
fire(display, "display_change")
fire(display, "system_woke")
check(#exec_calls == busy_count, "busy freshness events started duplicate reads")
respond(#exec_calls, view(HANDLE_TWO, 75, false, "applied"), 0)
check(display.properties.label.string == "Display confirmed",
  "native applied response did not keep the neutral all-display label")
check(exec_calls[#exec_calls].argv[2] == "state",
  "busy freshness events did not coalesce to one follow-up state read")
local coalesced_action_read = #exec_calls
respond(coalesced_action_read, view(HANDLE_TWO, 75, false), 0)
check(#exec_calls == coalesced_action_read,
  "busy freshness events started more than one follow-up state read")
check(objects["popup.display.brightness_slider"].properties.slider.percentage == 75,
  "post-write state refreshes the displayed slider")

-- An action during a pure read discards that read and starts one fresh follow-up.
fire(display, "display_change")
local stale_read_index = #exec_calls
local action_during_read = objects["popup.display.brightness_slider"]
fire(action_during_read, "mouse.clicked", { BUTTON = "left", PERCENTAGE = "70" })
local during_read_action_index = #exec_calls
check(during_read_action_index == stale_read_index + 1
  and exec_calls[during_read_action_index].argv[2] == "action",
  "confirmed control did not start an action during a pure read")
respond(stale_read_index, view(HANDLE_ONE, 20, false), 0)
check(display.properties.label.string == "Display confirmed",
  "invalidated pure read overwrote the neutral display state")
check(#exec_calls == during_read_action_index,
  "invalidated pure read started a follow-up before the action completed")
respond(during_read_action_index, view(HANDLE_TWO, 70, false, "applied"), 0)
local action_followup = #exec_calls
check(exec_calls[action_followup].argv[2] == "state",
  "action during read did not start one fresh follow-up")
respond(action_followup, view(HANDLE_TWO, 70, false), 0)
check(#exec_calls == action_followup and display.properties.label.string == "Display confirmed",
  "action during read did not settle on one fresh confirmed state")

-- A freshness event queued during a failed action starts exactly one read.
mute = objects["popup.display.mute_action"]
fire(mute, "mouse.clicked", { BUTTON = "left" })
local failed_action_index = #exec_calls
fire(display, "display_change")
check(#exec_calls == failed_action_index, "failed-action freshness started an early read")
respond(failed_action_index, { schema = 3, ok = false, status = "conflict" }, 65)
local failed_action_read = #exec_calls
check(exec_calls[failed_action_read].argv[2] == "state",
  "failed action did not start its coalesced freshness read")
respond(failed_action_read, view(HANDLE_TWO, 75, false), 0)
check(#exec_calls == failed_action_read,
  "failed action drained one freshness request into duplicate reads")

-- Mute always sends the exact desired and expected states, never a toggle.
mute = objects["popup.display.mute_action"]
fire(mute, "mouse.clicked", { BUTTON = "left" })
action = exec_calls[#exec_calls]
check(action.argv[3] == "mute" and action.argv[4] == "off" and action.argv[5] == "on"
  and action.argv[6] == HANDLE_TWO, "mute sends explicit off-to-on action")
respond(#exec_calls, { schema = 3, ok = false, status = "conflict" }, 65)
check(objects["popup.display.action_error"].properties.label.string
  == "Display state changed before the action. Try again.", "conflict has one fixed UI message")
check(exec_calls[#exec_calls].argv[2] == "state", "failed transaction refreshes read-only state")
respond(#exec_calls, view(HANDLE_TWO, 75, false), 0)

-- Restored and failed recovery statuses are also fixed text, never native payload text.
for _, fixture in ipairs({
  { status = "restored", code = 70, text = "The change failed. The prior display value was restored." },
  { status = "recovery_failed", code = 70, text = "The change failed and display recovery was not confirmed." },
  { status = "artifact_rejected", code = 69, text = "The display control helper rejected the installed BetterDisplay app." },
}) do
  mute = objects["popup.display.mute_action"]
  fire(mute, "mouse.clicked", { BUTTON = "left" })
  local index = #exec_calls
  respond(index, { schema = 3, ok = false, status = fixture.status }, fixture.code)
  check(objects["popup.display.action_error"].properties.label.string == fixture.text,
    fixture.status .. " does not use fixed UI text")
  respond(#exec_calls, view(HANDLE_TWO, 75, false), 0)
end

-- A failed action followed by an unconfirmed read must not reactivate a stale target handle.
mute = objects["popup.display.mute_action"]
fire(mute, "mouse.clicked", { BUTTON = "left" })
respond(#exec_calls, { schema = 3, ok = false, status = "conflict" }, 65)
check(exec_calls[#exec_calls].argv[2] == "state", "failed action starts an exact-target state refresh")
local stale_mute = mute
respond(#exec_calls, nil, 1)
check(display.properties.label.string == "Display state unavailable",
  "failed post-action refresh did not clear stale display state")
check(stale_mute.properties.drawing == false, "failed post-action refresh left stale controls visible")
before = #exec_calls
fire(stale_mute, "mouse.clicked", { BUTTON = "left" })
check(#exec_calls == before, "failed post-action refresh retained a stale target callback")

-- A read-only state without an approved native handle stays useful but has no controls.
fire(display, "display_change")
local read_only = view(nil, 74, false)
read_only.target_handle = nil
read_only.controls = nil
respond(#exec_calls, read_only, 0)
check(display.properties.label.string == "Display confirmed",
  "native-helper absence did not preserve neutral read-only display state")
local old_slider = objects["popup.display.brightness_slider"]
check(old_slider.properties.drawing == false, "missing target handle removes display callbacks")
before = #exec_calls
fire(old_slider, "mouse.clicked", { BUTTON = "left", PERCENTAGE = "50" })
check(#exec_calls == before, "missing native helper cannot start an action")

-- A built-in ProMotion screen keeps its truthful symbolic mode and omits unsupported DDC rows.
fire(display, "display_change")
local built_in = view(HANDLE_TWO, 100, false)
built_in.volume = nil
built_in.contrast = nil
built_in.mute = nil
built_in.refresh_rate = "ProMotion"
built_in.modes = {
  { number = 66, resolution = "1800x1169", width = 1800, height = 1169,
    hi_dpi = true, refresh_rate = "ProMotion", color_depth = 10,
    current = true, default = false, native = false },
}
built_in.resolution = "1800x1169"
built_in.mode_number = 66
built_in.controls = { brightness = true, hardware_contrast = false, volume = false, mute = false }
respond(#exec_calls, built_in, 0)
check(objects["popup.display.refresh"].properties.label.string == "ProMotion",
  "symbolic ProMotion refresh state is rendered directly")
local promotion_mode = objects["popup.display.mode_1"]
check(promotion_mode.properties.label.string == "ProMotion",
  "symbolic ProMotion mode is rendered directly in the value column")
check(promotion_mode.properties.label.max_chars == 16
  and #promotion_mode.properties.label.string <= promotion_mode.properties.label.max_chars,
  "symbolic mode refresh exceeds its rendered value bound")
check(promotion_mode.properties.icon.max_chars == 28
  and promotion_mode.properties.icon.string == "Current · 1800×1169 · HiDPI",
  "mode identity did not use the wider left column")
check(objects["popup.display.brightness_value"].properties.label.string == "100%"
  and objects["popup.display.brightness_slider"].properties.drawing ~= false,
  "built-in brightness remains a real readable and controllable value")
for _, suffix in ipairs({ "image_heading", "contrast_value", "contrast_slider",
  "sound_heading", "volume_value", "volume_slider", "mute", "mute_action" }) do
  check(objects["popup.display." .. suffix].properties.drawing == false,
    "unsupported built-in display row was not omitted: " .. suffix)
end

-- Ranged variable refresh remains a first-class rendered value.
fire(display, "display_change")
local ranged = view(HANDLE_TWO, 100, false)
ranged.contrast = nil
ranged.volume = nil
ranged.mute = nil
ranged.refresh_rate = "48-60Hz"
ranged.modes = {
  { number = 67, resolution = "1800x1169", width = 1800, height = 1169,
    hi_dpi = true, refresh_rate = "48-60Hz", color_depth = 10,
    current = true, default = false, native = true },
}
ranged.mode_number = 67
ranged.controls = { brightness = true, hardware_contrast = false, volume = false, mute = false }
respond(#exec_calls, ranged, 0)
check(objects["popup.display.refresh"].properties.label.string == "48-60Hz"
  and objects["popup.display.mode_1"].properties.label.string == "48-60Hz",
  "ranged variable refresh is not rendered directly")

-- Only current, default, and native modes own rendered rows.
fire(display, "display_change")
local filtered_modes = view(HANDLE_TWO, 100, false)
filtered_modes.modes = {
  { number = 50, resolution = "1280x720", width = 1280, height = 720,
    hi_dpi = true, refresh_rate = 60, color_depth = 10,
    current = false, default = false, native = false },
  { number = 51, resolution = "1800x1169", width = 1800, height = 1169,
    hi_dpi = true, refresh_rate = 60, color_depth = 10,
    current = true, default = false, native = false },
  { number = 52, resolution = "1512x982", width = 1512, height = 982,
    hi_dpi = true, refresh_rate = 60, color_depth = 10,
    current = false, default = true, native = false },
}
filtered_modes.mode_number = 51
respond(#exec_calls, filtered_modes, 0)
check(objects["popup.display.mode_1"].properties.icon.string
    == "Current · 1800×1169 · HiDPI"
  and objects["popup.display.mode_2"].properties.icon.string
    == "Default · 1512×982 · HiDPI",
  "renderer did not retain exactly the current and default mode rows")
check(not objects["popup.display.mode_3"]
  or objects["popup.display.mode_3"].properties.drawing == false,
  "unflagged compatible mode consumed a rendered row")

-- Partial display-audio capability never invents the other row or action.
fire(display, "display_change")
local volume_only = view(HANDLE_TWO, 100, false)
volume_only.contrast = nil
volume_only.mute = nil
volume_only.controls.hardware_contrast = false
volume_only.controls.mute = false
respond(#exec_calls, volume_only, 0)
check(objects["popup.display.volume_value"].properties.drawing ~= false
  and objects["popup.display.volume_slider"].properties.drawing ~= false,
  "present display volume remains visible and controllable")
for _, suffix in ipairs({ "mute", "mute_action", "mute_inactive" }) do
  check(objects["popup.display." .. suffix].properties.drawing == false,
    "absent display mute row or action was not omitted: " .. suffix)
end

fire(display, "display_change")
local mute_only = view(HANDLE_TWO, 100, false)
mute_only.contrast = nil
mute_only.volume = nil
mute_only.controls.hardware_contrast = false
mute_only.controls.volume = false
respond(#exec_calls, mute_only, 0)
check(objects["popup.display.mute"].properties.drawing ~= false
  and objects["popup.display.mute_action"].properties.drawing ~= false,
  "present display mute remains visible and controllable")
for _, suffix in ipairs({ "volume_value", "volume_slider", "volume_inactive" }) do
  check(objects["popup.display." .. suffix].properties.drawing == false,
    "absent display volume row or action was not omitted: " .. suffix)
end

-- Hostile schemas fail closed and cannot retain prior callbacks.
local hostile = view(HANDLE_THREE, 60, false)
hostile.raw_uuid = RAW_UUID
fire(display, "display_change")
respond(#exec_calls, hostile, 0)
check(display.properties.label.string == "Display state unavailable", "extra hostile state key fails closed")
check(old_slider.properties.drawing == false, "hostile state leaves old slider hidden")
before = #exec_calls
fire(old_slider, "mouse.clicked", { BUTTON = "left", PERCENTAGE = "50" })
check(#exec_calls == before, "hostile state cannot retain a callback")

local hostile_array = view(HANDLE_THREE, 80, false)
hostile_array.modes = { injected = true }
local hostile_resolution = view(HANDLE_THREE, 80, false)
hostile_resolution.resolution = "99999x99999"
local hostile_refresh = view(HANDLE_THREE, 80, false)
hostile_refresh.refresh_rate = "ProMotion · injected"
local hostile_range = view(HANDLE_THREE, 80, false)
hostile_range.refresh_rate = "60-48Hz"
local hostile_mode_refresh = view(HANDLE_THREE, 80, false)
hostile_mode_refresh.modes = {
  { number = 66, resolution = "1800x1169", width = 1800, height = 1169,
    hi_dpi = true, refresh_rate = "UnknownVRR", color_depth = 10,
    current = true, default = false, native = false },
}
local hostile_mode_depth = view(HANDLE_THREE, 80, false)
hostile_mode_depth.modes = {
  { number = 66, resolution = "1800x1169", width = 1800, height = 1169,
    hi_dpi = true, refresh_rate = "ProMotion", color_depth = 99,
    current = true, default = false, native = false },
}
for _, malformed in ipairs({
  { schema = 3, ok = true },
  view("bad", 80, false),
  view(HANDLE_THREE, 0/0, false),
  hostile_array,
  hostile_resolution,
  hostile_refresh,
  hostile_range,
  hostile_mode_refresh,
  hostile_mode_depth,
}) do
  fire(display, "display_change")
  respond(#exec_calls, malformed, 0)
  check(display.properties.label.string == "Display state unavailable", "malformed state did not fail closed")
end

fire(display, "display_change")
local timed_out_read = #exec_calls
local timed_out_slider = objects["popup.display.brightness_slider"]
run_latest_delay(15)
check(display.properties.label.string == "Display state unavailable"
  and objects["popup.display.unavailable"].properties.drawing ~= false
  and (not timed_out_slider or timed_out_slider.properties.drawing == false),
  "display confirmation timeout did not fail closed")
before = #exec_calls
if timed_out_slider then
  fire(timed_out_slider, "mouse.clicked", { BUTTON = "left", PERCENTAGE = "50" })
end
check(#exec_calls == before, "display confirmation timeout retained a stale callback")
respond(timed_out_read, view(HANDLE_THREE, 50, false), 0)
check(display.properties.label.string == "Display state unavailable",
  "late display read revived timed-out state")

local item_source = assert(io.open(os.getenv("SKETCHYBAR_CONFIG_DIR") .. "/items/display.lua")):read("*a")
for _, forbidden in ipairs({ "toggle", "offset", "target_uuid", "identifier=UUID", "http://", "https://", "DDC" }) do
  check(not item_source:lower():find(forbidden:lower(), 1, true), "forbidden public display control: " .. forbidden)
end

print("SketchyBar display sliders, explicit mute, busy inertness, and hostile-schema contract passed")
