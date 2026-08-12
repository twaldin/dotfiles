local source = debug.getinfo(1, "S").source
local script = source:sub(1, 1) == "@" and source:sub(2) or source
local config_dir = script:match("^(.*)/tests/[^/]+$")
  or os.getenv("SKETCHYBAR_CONFIG_DIR")
if not config_dir or config_dir == "" then error("cannot determine SketchyBar config directory") end
package.path = config_dir .. "/?.lua;" .. config_dir .. "/?/init.lua;" .. package.path

local settings = {
  font = "Mock Font", popup_width = 280, control_width = 28, icon_width = 28,
  surface_height = 26, spacing = { item = 4 },
  popup_layout = {
    gutter = 12, value_width = 80, column_gap = 8,
    heading_height = 32, section_height = 26, row_height = 28, axis_height = 16,
  },
  type = {
    bar_control = "Mock Font", popup_head = "Mock Font", popup_row = "Mock Font",
    popup_section = "Mock Font", popup_axis = "Mock Font",
  },
  paths = { audio_state = "/fixed/audio-state" },
}
package.loaded["settings"] = settings

local objects, exec_calls, delayed = {}, {}, {}

local function check(condition, message)
  if not condition then error(message, 2) end
end

local function validate(value, path)
  if type(value) == "function" then error("function leaked into property at " .. path) end
  if type(value) ~= "table" then return end
  for key, child in pairs(value) do validate(child, path .. "." .. tostring(key)) end
end

local function merge(target, source_table)
  for key, value in pairs(source_table or {}) do
    if type(value) == "table" and type(target[key]) == "table" then merge(target[key], value)
    elseif type(value) == "table" then
      target[key] = {}
      merge(target[key], value)
    else target[key] = value end
  end
end

local function make_object(name, properties)
  validate(properties or {}, "add." .. name)
  local object = { name = name, properties = {}, subscriptions = {}, removed = false }
  merge(object.properties, properties or {})
  function object:set(value)
    validate(value, "set." .. name)
    merge(self.properties, value)
  end
  function object:subscribe(events, callback)
    if type(events) ~= "table" then events = { events } end
    for _, event in ipairs(events) do
      self.subscriptions[event] = self.subscriptions[event] or {}
      self.subscriptions[event][#self.subscriptions[event] + 1] = callback
    end
  end
  objects[name] = object
  return object
end

sbar = {
  add = function(_, name, ...)
    local arguments = { ... }
    local properties = arguments[#arguments]
    if type(properties) ~= "table" then properties = {} end
    return make_object(name, properties)
  end,
  remove = function(name)
    if objects[name] then objects[name].removed = true end
  end,
  exec = function(command, callback)
    exec_calls[#exec_calls + 1] = { command = command, callback = callback }
  end,
  delay = function(seconds, callback)
    delayed[#delayed + 1] = { seconds = seconds, callback = callback }
  end,
}

local function fire(object, event, env)
  for _, callback in ipairs(object.subscriptions[event] or {}) do callback(env or {}) end
end

local function complete(index, output, code)
  check(exec_calls[index] and type(exec_calls[index].callback) == "function", "missing exec callback " .. index)
  exec_calls[index].callback(output, code or 0)
end

local function write_doc(action, role, key, observed)
  local value = { schema = 1, ok = true, action = action, role = role, key = key }
  if action == "set_volume" then value.volume = observed end
  if action == "set_mute" then value.mute = observed end
  return value
end

local KEYS = { string.rep("a", 64), string.rep("b", 64), string.rep("c", 64) }
local RAW_IDS = { "raw-output-identity", "raw-second-output-identity", "raw-input-identity" }

local function document()
  return {
    schema = 1, ok = true, warning_count = 0,
    defaults = { output = KEYS[1], system_output = KEYS[1], input = KEYS[3] },
    default_settable = { output = true, system_output = true, input = true },
    devices = {
      {
        key = KEYS[1], name = "Primary speakers",
        directions = { "output" }, eligible_roles = { "output", "system_output" }, roles = { "output", "system_output" },
        output = {
          volume = { available = true, settable = true, value = 50 },
          mute = { available = true, settable = true, value = false },
        },
      },
      {
        key = KEYS[2], name = "Secondary speakers",
        directions = { "output" }, eligible_roles = { "output", "system_output" }, roles = {},
        output = {
          volume = { available = true, settable = true, value = 25 },
          mute = { available = true, settable = true, value = false },
        },
      },
      {
        key = KEYS[3], name = "Desk microphone",
        directions = { "input" }, eligible_roles = { "input" }, roles = { "input" },
        input = {
          volume = { available = true, settable = true, value = 75 },
          mute = { available = true, settable = true, value = false },
          active = false,
        },
      },
    },
  }
end

local function selected_second(level)
  local value = document()
  value.defaults.output = KEYS[2]
  value.devices[1].roles = { "system_output" }
  value.devices[2].roles = { "output" }
  value.devices[2].output.volume.value = level or 25
  return value
end

local function microphone_level(level)
  local value = selected_second(80)
  value.devices[3].input.volume.value = level
  return value
end

package.loaded["lib.audio"] = nil
package.loaded["lib.popup"] = nil
package.loaded["lib.hover"] = nil
package.loaded["items.audio"] = nil
package.loaded["items.microphone"] = nil
local audio_item = require("items.audio")
local microphone_item = require("items.microphone")
local audio = require("lib.audio")

check(#exec_calls == 1, "audio and microphone must coalesce their initial state read")
check(microphone_item.properties.update_freq == 2,
      "microphone active-use polling must keep the two-second request cadence")
fire(audio_item, "sketchybar_test_popup", { TARGET = "audio" })
check(objects["popup.audio.level_unavailable"].properties.label.string == "Audio state is unavailable"
      and objects["popup.audio.mute_unavailable"].properties.label.string == "Audio state is unavailable"
      and objects["popup.audio.output_state_unavailable"].properties.label.string == "Audio state is unavailable"
      and objects["popup.audio.alerts_state_unavailable"].properties.label.string == "Audio state is unavailable",
      "unconfirmed output rows must not claim device capabilities")
fire(microphone_item, "sketchybar_test_popup", { TARGET = "microphone" })
check(objects["popup.microphone.level_unavailable"].properties.label.string == "Microphone state is unavailable"
      and objects["popup.microphone.mute_unavailable"].properties.label.string == "Microphone state is unavailable"
      and objects["popup.microphone.input_state_unavailable"].properties.label.string == "Microphone state is unavailable",
      "unconfirmed microphone rows must not claim device capabilities")
check(#exec_calls == 1, "unconfirmed popup builds must coalesce the initial read")
complete(1, document(), 0)
local healthy_output_icon = audio_item.properties.icon.string
local healthy_output_color = audio_item.properties.icon.color
local healthy_input_icon = microphone_item.properties.icon.string
local healthy_input_color = microphone_item.properties.icon.color
check(healthy_input_icon:find("○", 1, true),
      "confirmed idle use must have a distinct idle glyph")
check(audio_item.properties.label.string:find("50 percent", 1, true), "audio semantic label uses confirmed level")
check(microphone_item.properties.label.string:find("not muted", 1, true), "microphone semantic label uses real mute")
check(microphone_item.properties.label.string:find("idle", 1, true),
      "microphone semantic label reports confirmed idle use")
local active_state_row = objects["popup.microphone.active_state"]
local microphone_heading = objects["popup.microphone.heading"]
check(active_state_row
      and active_state_row.properties.label.string == "Microphone is idle"
      and microphone_heading.properties.label.string:find("IDLE", 1, true),
      "microphone popup reports confirmed idle use in visible text")

local before = #exec_calls
audio.refresh()
local active_microphone = document()
active_microphone.devices[3].input.active = true
complete(before + 1, active_microphone, 0)
local active_input_color = microphone_item.properties.icon.color
local active_input_icon = microphone_item.properties.icon.string
check(active_input_color ~= healthy_input_color
      and active_input_icon ~= healthy_input_icon
      and active_input_icon:find("•", 1, true)
      and microphone_item.properties.label.string:find("active", 1, true)
      and active_state_row.properties.label.string == "Microphone is active"
      and microphone_heading.properties.label.string:find("ACTIVE", 1, true),
      "active microphone use must have distinct glyph, color, query diagnostic, and visible popup state")
fire(microphone_item, "sketchybar_test_hover", { TARGET = "microphone" })
check(microphone_item.properties.icon.color == active_input_color
      and microphone_item.properties.icon.string == active_input_icon,
      "active microphone glyph and color must survive hover")
fire(microphone_item, "sketchybar_test_hover_exit", { TARGET = "microphone" })
check(microphone_item.properties.icon.color == active_input_color
      and microphone_item.properties.icon.string == active_input_icon,
      "active microphone hover exit must preserve its glyph and color")

before = #exec_calls
audio.refresh()
fire(microphone_item, "routine", { TARGET = "microphone" })
check(#exec_calls == before + 1
      and not microphone_item.properties.icon.string:find("•", 1, true)
      and not microphone_item.properties.icon.string:find("○", 1, true)
      and active_state_row.properties.drawing == false,
      "busy cadence tick must hide the stale use claim and coalesce a retry")
complete(before + 1, active_microphone, 0)
check(#exec_calls == before + 2
      and microphone_item.properties.icon.string:find("•", 1, true),
      "completed busy read must restore confirmed use and start its retry")
complete(before + 2, active_microphone, 0)

before = #exec_calls
audio.refresh()
local absent_active = document()
absent_active.devices[3].input.active = nil
complete(before + 1, absent_active, 0)
check(not microphone_item.properties.label.string:find("active", 1, true)
      and not microphone_item.properties.label.string:find("idle", 1, true)
      and not microphone_item.properties.icon.string:find("•", 1, true)
      and not microphone_item.properties.icon.string:find("○", 1, true)
      and microphone_item.properties.icon.string ~= healthy_input_icon
      and not microphone_heading.properties.label.string:find("ACTIVE", 1, true)
      and not microphone_heading.properties.label.string:find("IDLE", 1, true)
      and active_state_row.properties.drawing == false,
      "absent active-use property must be distinct from idle and omit every use claim")

before = #exec_calls
audio.refresh()
local unresolved_use = document()
unresolved_use.devices[3].input.active = nil
unresolved_use.devices[3].input.mute = { available = false, settable = false }
complete(before + 1, unresolved_use, 0)
local unresolved_input_icon = microphone_item.properties.icon.string
local unresolved_input_color = microphone_item.properties.icon.color
check(unresolved_input_icon == "󰍮"
      and unresolved_input_color ~= healthy_input_color,
      "present input with unresolved capabilities must use an unclaimed rendering")
fire(microphone_item, "sketchybar_test_hover", { TARGET = "microphone" })
check(microphone_item.properties.icon.color == unresolved_input_color,
      "unresolved input rendering must remain distinct during hover")
fire(microphone_item, "sketchybar_test_hover_exit", { TARGET = "microphone" })

before = #exec_calls
fire(audio_item, "sketchybar_test_popup", { TARGET = "audio" })
check(#exec_calls == before + 1, "popup open requests one shared refresh")
complete(before + 1, document(), 0)
local output_choice = objects["popup.audio.output_choice_2"]
check(output_choice and output_choice.properties.label.string == "Secondary speakers",
      "output choice has exact safe action text")
local system_choice = objects["popup.audio.alert_choice_2"]
check(system_choice and system_choice.properties.label.string == "Secondary speakers",
      "system alert choice has exact safe action text")

before = #exec_calls
fire(output_choice, "mouse.clicked", { BUTTON = "right", INFO = RAW_IDS[1] })
check(#exec_calls == before, "right click cannot select an audio target")
fire(output_choice, "mouse.clicked", { BUTTON = "left", INFO = RAW_IDS[1] })
check(#exec_calls == before + 1, "left click invokes captured output choice")
check(exec_calls[#exec_calls].command:find("'set%-default' 'output' 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'") ~= nil,
      "output action uses captured private handle")
complete(before + 1, write_doc("set_default", "output", KEYS[2]), 0)
check(#exec_calls == before + 2, "set-default requires a fresh full state read")
complete(before + 2, selected_second(), 0)
check(audio_item.properties.label.string:find("Secondary speakers", 1, true),
      "UI renders only confirmed post-write default")

local slider = objects["popup.audio.level"]
before = #exec_calls
fire(slider, "mouse.clicked", { BUTTON = "right", PERCENTAGE = "80" })
fire(slider, "mouse.clicked", { BUTTON = "left", PERCENTAGE = RAW_IDS[1] })
check(#exec_calls == before, "slider rejects wrong button and hostile value")
fire(slider, "mouse.clicked", { BUTTON = "left", PERCENTAGE = "80" })
check(#exec_calls == before + 1, "bounded left slider value starts one write")
check(exec_calls[#exec_calls].command:find("'set%-volume' 'output' '80'") ~= nil,
      "slider uses fixed output role and bounded number")
local busy_output_level = objects["popup.audio.level_unavailable"]
check(slider.properties.drawing == false
      and busy_output_level.properties.label.string == "Level control is inactive while audio controls are busy",
      "busy output slider must be hidden and replaced by an inert explanation")
local busy_output_before = #exec_calls
fire(slider, "mouse.clicked", { BUTTON = "left", PERCENTAGE = "90" })
check(#exec_calls == busy_output_before,
      "hidden busy output slider must not retain an active callback")
complete(before + 1, write_doc("set_volume", "output", KEYS[2], 80), 0)
complete(before + 2, selected_second(80), 0)

before = #exec_calls
audio.refresh()
local output_warnings = selected_second(80)
output_warnings.warning_count = 10000
complete(before + 1, output_warnings, 0)
local output_warning = objects["popup.audio.state_incomplete"]
check(output_warning and output_warning.properties.label.string == "Some audio state could not be read"
      and output_warning.properties.label.max_chars == 40
      and not output_warning.properties.label.string:find("10000", 1, true),
      "audio warning count must render as one bounded, non-enumerating omission note")
before = #exec_calls
audio.refresh()
complete(before + 1, selected_second(80), 0)
check(output_warning.properties.drawing == false,
      "zero audio warning count must hide the omission note")

fire(microphone_item, "sketchybar_test_popup", { TARGET = "microphone" })
before = #exec_calls
check(before >= 1, "microphone popup opens")
local unavailable = selected_second(80)
unavailable.devices[3].input.mute = { available = false, settable = false }
unavailable.devices[3].input.active = true
complete(before, unavailable, 0)
local unsupported = objects["popup.microphone.mute_unavailable"]
check(unsupported and unsupported.properties.label.string == "Microphone mute is not supported by this device",
      "unsupported microphone mute has exact text")
check(microphone_item.properties.icon.string == "󰍮•"
      and microphone_item.properties.icon.color == active_input_color
      and microphone_item.properties.label.string:find("active", 1, true),
      "active-use color and semantic state must survive unavailable mute")
local unsupported_before = #exec_calls
fire(unsupported, "mouse.clicked", { BUTTON = "left" })
check(#exec_calls == unsupported_before,
      "unsupported microphone mute has no active action metadata")

local input_slider = objects["popup.microphone.level"]
before = #exec_calls
fire(input_slider, "mouse.clicked", { BUTTON = "left", PERCENTAGE = "65" })
check(#exec_calls == before + 1
      and exec_calls[#exec_calls].command:find("'set%-volume' 'input' '65'") ~= nil,
      "bounded microphone slider value starts one fixed-role write")
local busy_input_level = objects["popup.microphone.level_unavailable"]
check(input_slider.properties.drawing == false
      and busy_input_level.properties.label.string == "Level control is inactive while audio controls are busy",
      "busy microphone slider must be hidden and replaced by an inert explanation")
local busy_input_before = #exec_calls
fire(input_slider, "mouse.clicked", { BUTTON = "left", PERCENTAGE = "70" })
check(#exec_calls == busy_input_before,
      "hidden busy microphone slider must not retain an active callback")
complete(before + 1, write_doc("set_volume", "input", KEYS[3], 65), 0)
complete(before + 2, microphone_level(65), 0)

before = #exec_calls
audio.refresh()
local input_warnings = microphone_level(65)
input_warnings.warning_count = 1
complete(before + 1, input_warnings, 0)
local input_warning = objects["popup.microphone.state_incomplete"]
check(input_warning and input_warning.properties.label.string == "Some audio state could not be read"
      and input_warning.properties.label.max_chars == 40,
      "microphone popup must render the bounded audio omission note")

before = #exec_calls
audio.refresh()
local muted = selected_second(80)
muted.devices[3].input.mute.value = true
complete(before + 1, muted, 0)
check(microphone_item.properties.icon.string == "󰍭○", "microphone icon uses real input mute and confirmed idle use")
check(microphone_item.properties.label.string:find("muted", 1, true),
      "microphone semantic label reports confirmed mute")

fire(audio_item, "sketchybar_test_popup", { TARGET = "audio" })
before = #exec_calls
local unsettableOutput = selected_second(80)
unsettableOutput.default_settable.output = false
unsettableOutput.default_settable.system_output = false
complete(before, unsettableOutput, 0)
local outputUnsettable = objects["popup.audio.output_unsettable"]
local alertsUnsettable = objects["popup.audio.alerts_unsettable"]
local unsettable_before = #exec_calls
local hiddenOutputChoice = objects["popup.audio.output_choice_1"]
local hiddenAlertChoice = objects["popup.audio.alert_choice_1"]
fire(outputUnsettable, "mouse.clicked", { BUTTON = "left" })
fire(alertsUnsettable, "mouse.clicked", { BUTTON = "left" })
fire(hiddenOutputChoice, "mouse.clicked", { BUTTON = "left" })
fire(hiddenAlertChoice, "mouse.clicked", { BUTTON = "left" })
check(outputUnsettable and #exec_calls == unsettable_before,
      "unsettable output role has no active action metadata")
check(alertsUnsettable and #exec_calls == unsettable_before,
      "unsettable system alert role has no active action metadata")
check(hiddenOutputChoice.properties.drawing == false
      and hiddenAlertChoice.properties.drawing == false
      and #exec_calls == unsettable_before,
      "unsettable output roles must hide and disable prior choice rows")

fire(microphone_item, "sketchybar_test_popup", { TARGET = "microphone" })
before = #exec_calls
local unsettableInput = selected_second(80)
unsettableInput.default_settable.input = false
complete(before, unsettableInput, 0)
local inputUnsettable = objects["popup.microphone.input_unsettable"]
local input_unsettable_before = #exec_calls
local hiddenInputChoice = objects["popup.microphone.input_choice_1"]
fire(inputUnsettable, "mouse.clicked", { BUTTON = "left" })
fire(hiddenInputChoice, "mouse.clicked", { BUTTON = "left" })
check(inputUnsettable and #exec_calls == input_unsettable_before,
      "unsettable input role has no active action metadata")
check(hiddenInputChoice.properties.drawing == false
      and #exec_calls == input_unsettable_before,
      "unsettable input role must hide and disable prior choice rows")

fire(audio_item, "sketchybar_test_popup", { TARGET = "audio" })
before = #exec_calls
local unknownOutputs = selected_second(80)
unknownOutputs.defaults.output = nil
unknownOutputs.defaults.system_output = nil
unknownOutputs.devices[1].roles = {}
unknownOutputs.devices[2].roles = {}
complete(before, unknownOutputs, 0)
local outputDefaultUnavailable = objects["popup.audio.output_default_unavailable"]
local alertsDefaultUnavailable = objects["popup.audio.alerts_default_unavailable"]
local outputLevelUnavailable = objects["popup.audio.level_unavailable"]
local outputMuteUnavailable = objects["popup.audio.mute_unavailable"]
local disabledOutput = objects["popup.audio.output_choice_disabled_1"]
local disabledAlert = objects["popup.audio.alert_choice_disabled_1"]
check(audio_item.properties.icon.string == "󰖁"
      and audio_item.properties.icon.string ~= healthy_output_icon
      and audio_item.properties.icon.color ~= healthy_output_color,
      "unknown output default must use a distinct unavailable bar icon and color")
fire(audio_item, "sketchybar_test_hover", { TARGET = "audio" })
fire(audio_item, "sketchybar_test_hover_exit", { TARGET = "audio" })
check(audio_item.properties.icon.color ~= healthy_output_color,
      "unknown output hover exit must restore the unavailable color")
local unknown_output_before = #exec_calls
fire(outputDefaultUnavailable, "mouse.clicked", { BUTTON = "left" })
fire(alertsDefaultUnavailable, "mouse.clicked", { BUTTON = "left" })
fire(disabledOutput, "mouse.clicked", { BUTTON = "left" })
fire(disabledAlert, "mouse.clicked", { BUTTON = "left" })
check(outputDefaultUnavailable
      and outputDefaultUnavailable.properties.label.string == "Current sound output is unavailable"
      and #exec_calls == unknown_output_before,
      "unknown output default must render an inert explanation")
check(alertsDefaultUnavailable
      and alertsDefaultUnavailable.properties.label.string == "Current system alert device is unavailable"
      and #exec_calls == unknown_output_before,
      "unknown system alert default must render an inert explanation")
check(outputLevelUnavailable.properties.label.string == "Current sound output is unavailable"
      and outputMuteUnavailable.properties.label.string == "Current sound output is unavailable",
      "unknown output default must not claim device capability limits")
check(disabledOutput.properties.label.string:find("current sound output unavailable", 1, true)
      and disabledAlert.properties.label.string:find("current system alert device unavailable", 1, true)
      and #exec_calls == unknown_output_before,
      "eligible recovery devices must remain visible but disabled with an exact reason")

fire(microphone_item, "sketchybar_test_popup", { TARGET = "microphone" })
before = #exec_calls
local unknownInput = unknownOutputs
unknownInput.defaults.input = nil
unknownInput.devices[3].roles = {}
complete(before, unknownInput, 0)
local inputDefaultUnavailable = objects["popup.microphone.input_default_unavailable"]
local inputLevelUnavailable = objects["popup.microphone.level_unavailable"]
local inputMuteUnavailable = objects["popup.microphone.mute_unavailable"]
local disabledInput = objects["popup.microphone.input_choice_disabled_1"]
check(microphone_item.properties.icon.string == "󰍮"
      and microphone_item.properties.icon.string ~= healthy_input_icon
      and microphone_item.properties.icon.color ~= healthy_input_color
      and microphone_item.properties.icon.color ~= unresolved_input_color,
      "unknown input default must differ from idle and present-but-unresolved input")
local unknown_input_color = microphone_item.properties.icon.color
fire(microphone_item, "sketchybar_test_hover", { TARGET = "microphone" })
check(microphone_item.properties.icon.color ~= unknown_input_color
      and microphone_item.properties.icon.color ~= unresolved_input_color,
      "unknown input keeps the ordinary shared hover cue")
fire(microphone_item, "sketchybar_test_hover_exit", { TARGET = "microphone" })
check(microphone_item.properties.icon.color == unknown_input_color,
      "unknown input hover exit must restore the unavailable color")
local unknown_input_before = #exec_calls
fire(inputDefaultUnavailable, "mouse.clicked", { BUTTON = "left" })
fire(disabledInput, "mouse.clicked", { BUTTON = "left" })
check(inputDefaultUnavailable
      and inputDefaultUnavailable.properties.label.string == "Current microphone is unavailable"
      and #exec_calls == unknown_input_before,
      "unknown input default must render an inert explanation")
check(inputLevelUnavailable.properties.label.string == "Current microphone is unavailable"
      and inputMuteUnavailable.properties.label.string == "Current microphone is unavailable",
      "unknown input default must not claim device capability limits")
check(disabledInput.properties.label.string:find("current microphone unavailable", 1, true)
      and #exec_calls == unknown_input_before,
      "eligible microphone recovery devices must remain visible but disabled")

local function scan(value, path, visited)
  visited = visited or {}
  if type(value) == "string" then
    for _, sensitive in ipairs({ KEYS, RAW_IDS }) do
      for _, key in ipairs(sensitive) do
        check(not value:find(key, 1, true), "audio identity leaked at " .. path)
      end
    end
  elseif type(value) == "table" and not visited[value] then
    visited[value] = true
    for key, child in pairs(value) do scan(child, path .. "." .. tostring(key), visited) end
  end
end
for name, object in pairs(objects) do scan(object.properties, "object." .. name) end
for _, call in ipairs(exec_calls) do
  check(call.command:find("'/fixed/audio-state'", 1, true) == 1,
        "all audio reads and writes must use the first-party coordinator")
  for _, identity in ipairs(RAW_IDS) do
    check(not call.command:find(identity, 1, true),
          "raw CoreAudio identity entered an item command")
  end
end

local audio_file = io.open(config_dir .. "/items/audio.lua", "r")
local microphone_file = io.open(config_dir .. "/items/microphone.lua", "r")
check(audio_file ~= nil and microphone_file ~= nil, "audio item sources must be readable")
local audio_source = audio_file:read("*a")
local microphone_source = microphone_file:read("*a")
audio_file:close()
microphone_file:close()
for _, source_text in ipairs({ audio_source, microphone_source }) do
  check(not source_text:find("osascript", 1, true), "AppleScript audio write remains")
  check(not source_text:find("SwitchAudioSource", 1, true), "SwitchAudioSource runtime remains")
  check(not source_text:find("audio%-state%.sh"), "legacy audio-state runtime remains")
  check(not source_text:find("env.INFO", 1, true), "volume_change event data must not become state")
end

print("Audio and microphone item contracts passed")
