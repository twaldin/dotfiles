local source = debug.getinfo(1, "S").source
local script = source:sub(1, 1) == "@" and source:sub(2) or source
local config_dir = script:match("^(.*)/tests/[^/]+$")
  or os.getenv("SKETCHYBAR_CONFIG_DIR")
assert(config_dir and config_dir ~= "", "cannot determine SketchyBar config directory")
package.path = config_dir .. "/?.lua;" .. config_dir .. "/?/init.lua;" .. package.path

local settings = {
  font = "Mock Font", popup_width = 280, control_width = 28, icon_width = 28,
  paths = { system_controls = "/fixed/system-controls" },
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

local UIDS = { "fixture-output-one", "fixture-output-two", "fixture-input" }

local function document()
  return {
    schema = 1, ok = true, warning_count = 0,
    defaults = { output = UIDS[1], system_output = UIDS[1], input = UIDS[3] },
    default_settable = { output = true, system_output = true, input = true },
    devices = {
      {
        uid = UIDS[1], name = "Primary speakers",
        directions = { "output" }, roles = { "output", "system_output" },
        output = {
          volume = { available = true, settable = true, value = 50 },
          mute = { available = true, settable = true, value = false },
        },
      },
      {
        uid = UIDS[2], name = "Secondary speakers",
        directions = { "output" }, roles = {},
        output = {
          volume = { available = true, settable = true, value = 25 },
          mute = { available = true, settable = true, value = false },
        },
      },
      {
        uid = UIDS[3], name = "Desk microphone",
        directions = { "input" }, roles = { "input" },
        input = {
          volume = { available = true, settable = true, value = 75 },
          mute = { available = true, settable = true, value = false },
        },
      },
    },
  }
end

local function selected_second(level)
  local value = document()
  value.defaults.output = UIDS[2]
  value.devices[1].roles = { "system_output" }
  value.devices[2].roles = { "output" }
  value.devices[2].output.volume.value = level or 25
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
complete(1, document(), 0)
check(audio_item.properties.label.string:find("50 percent", 1, true), "audio semantic label uses confirmed level")
check(microphone_item.properties.label.string:find("not muted", 1, true), "microphone semantic label uses real mute")

fire(audio_item, "sketchybar_test_popup", { TARGET = "audio" })
check(#exec_calls == 2, "popup open requests one shared refresh")
complete(2, document(), 0)
local output_choice = objects["popup.audio.output_choice_2"]
check(output_choice and output_choice.properties.label.string == "Use Secondary speakers for sound output",
      "output choice has exact safe action text")
local system_choice = objects["popup.audio.alert_choice_2"]
check(system_choice and system_choice.properties.label.string == "Use Secondary speakers for system alerts",
      "system alert choice has exact safe action text")

local before = #exec_calls
fire(output_choice, "mouse.clicked", { BUTTON = "right", INFO = UIDS[1] })
check(#exec_calls == before, "right click cannot select an audio target")
fire(output_choice, "mouse.clicked", { BUTTON = "left", INFO = UIDS[1] })
check(#exec_calls == before + 1, "left click invokes captured output choice")
check(exec_calls[#exec_calls].command:find("'set%-default' 'output' 'fixture%-output%-two'") ~= nil,
      "output action uses captured private UID")
complete(before + 1, "ignored", 0)
check(#exec_calls == before + 2, "set-default requires a fresh full state read")
complete(before + 2, selected_second(), 0)
check(audio_item.properties.label.string:find("Secondary speakers", 1, true),
      "UI renders only confirmed post-write default")

local slider = objects["popup.audio.level"]
before = #exec_calls
fire(slider, "mouse.clicked", { BUTTON = "right", PERCENTAGE = "80" })
fire(slider, "mouse.clicked", { BUTTON = "left", PERCENTAGE = UIDS[1] })
check(#exec_calls == before, "slider rejects wrong button and hostile value")
fire(slider, "mouse.clicked", { BUTTON = "left", PERCENTAGE = "80" })
check(#exec_calls == before + 1, "bounded left slider value starts one write")
check(exec_calls[#exec_calls].command:find("'set%-volume' 'output' '80'") ~= nil,
      "slider uses fixed output role and bounded number")
complete(before + 1, nil, 0)
complete(before + 2, selected_second(80), 0)

fire(microphone_item, "sketchybar_test_popup", { TARGET = "microphone" })
before = #exec_calls
check(before >= 1, "microphone popup opens")
local unavailable = selected_second(80)
unavailable.devices[3].input.mute = { available = false, settable = false }
complete(before, unavailable, 0)
local unsupported = objects["popup.microphone.mute_unavailable"]
check(unsupported and unsupported.properties.label.string == "Microphone mute is not supported by this device",
      "unsupported microphone mute has exact text")
check(not unsupported.subscriptions["mouse.clicked"],
      "unsupported microphone mute has no action handler")

before = #exec_calls
audio.refresh()
local muted = selected_second(80)
muted.devices[3].input.mute.value = true
complete(before + 1, muted, 0)
check(microphone_item.properties.icon.string == "󰍭", "microphone icon uses real input mute")
check(microphone_item.properties.label.string:find("muted", 1, true),
      "microphone semantic label reports confirmed mute")

fire(audio_item, "sketchybar_test_popup", { TARGET = "audio" })
local priorOutputChoice = objects["popup.audio.output_choice_1"]
local priorAlertChoice = objects["popup.audio.alert_choice_1"]
before = #exec_calls
local unsettableOutput = selected_second(80)
unsettableOutput.default_settable.output = false
unsettableOutput.default_settable.system_output = false
complete(before, unsettableOutput, 0)
local outputUnsettable = objects["popup.audio.output_unsettable"]
local alertsUnsettable = objects["popup.audio.alerts_unsettable"]
check(outputUnsettable and not outputUnsettable.subscriptions["mouse.clicked"],
      "unsettable output role is a passive row")
check(alertsUnsettable and not alertsUnsettable.subscriptions["mouse.clicked"],
      "unsettable system alert role is a passive row")
check(objects["popup.audio.output_choice_1"] == priorOutputChoice
      and objects["popup.audio.alert_choice_1"] == priorAlertChoice,
      "unsettable output roles do not create choice rows")

fire(microphone_item, "sketchybar_test_popup", { TARGET = "microphone" })
local priorInputChoice = objects["popup.microphone.input_choice_1"]
before = #exec_calls
local unsettableInput = selected_second(80)
unsettableInput.default_settable.input = false
complete(before, unsettableInput, 0)
local inputUnsettable = objects["popup.microphone.input_unsettable"]
check(inputUnsettable and not inputUnsettable.subscriptions["mouse.clicked"],
      "unsettable input role is a passive row")
check(objects["popup.microphone.input_choice_1"] == priorInputChoice,
      "unsettable input role does not create a choice row")

local function scan(value, path, visited)
  visited = visited or {}
  if type(value) == "string" then
    for _, uid in ipairs(UIDS) do check(not value:find(uid, 1, true), "UID leaked at " .. path) end
  elseif type(value) == "table" and not visited[value] then
    visited[value] = true
    for key, child in pairs(value) do scan(child, path .. "." .. tostring(key), visited) end
  end
end
for name, object in pairs(objects) do scan(object.properties, "object." .. name) end

local audio_source = assert(io.open(config_dir .. "/items/audio.lua", "r")):read("*a")
local microphone_source = assert(io.open(config_dir .. "/items/microphone.lua", "r")):read("*a")
for _, source_text in ipairs({ audio_source, microphone_source }) do
  check(not source_text:find("osascript", 1, true), "AppleScript audio write remains")
  check(not source_text:find("SwitchAudioSource", 1, true), "SwitchAudioSource runtime remains")
  check(not source_text:find("audio%-state%.sh"), "legacy audio-state runtime remains")
  check(not source_text:find("env.INFO", 1, true), "volume_change event data must not become state")
end

print("Audio and microphone item contracts passed")
