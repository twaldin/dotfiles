local config_dir, bridge_dir, sbarlua_path, state_path, write_path, after_path = ...

local function check(condition, message)
  if not condition then error(message, 2) end
end

check(type(config_dir) == "string" and config_dir ~= "", "config directory is missing")
check(type(bridge_dir) == "string" and bridge_dir ~= "", "bridge directory is missing")
package.path = config_dir .. "/?.lua;" .. config_dir .. "/?/init.lua;" .. package.path
package.cpath = bridge_dir .. "/?.so;" .. package.cpath

local function read(path)
  local file = io.open(path, "rb")
  check(file ~= nil, "wire fixture is unreadable")
  local value = file:read("*a")
  file:close()
  return value
end

local loaded, decoder = pcall(require, "sbar_json_bridge")
check(loaded and type(decoder) == "table" and type(decoder.decode) == "function",
      "exact installed SbarLua decoder bridge did not load")
local raw_state = read(state_path)
local raw_write = read(write_path)
local raw_after = read(after_path)
check(raw_state:find("\\u", 1, true) ~= nil,
      "wire fixture must include JSON-escaped non-ASCII text")
check(raw_state:find('"system_output":null', 1, true) ~= nil,
      "wire fixture must include a null default")
check(raw_state:find('"value":null', 1, true) ~= nil,
      "wire fixture must include an unavailable null capability")
check(raw_write:find('"mute":null', 1, true) ~= nil
      and raw_write:find('"volume":null', 1, true) ~= nil,
      "wire write fixture must include nullable fields")

local state_document = decoder.decode(sbarlua_path, raw_state)
local write_document = decoder.decode(sbarlua_path, raw_write)
local after_document = decoder.decode(sbarlua_path, raw_after)
local exec_calls = {}
sbar = {
  exec = function(command, callback)
    exec_calls[#exec_calls + 1] = { command = command, callback = callback }
  end,
}
package.loaded["settings"] = { paths = { audio_state = "/fixed/audio-state" } }
package.loaded["lib.audio"] = nil
local audio = require("lib.audio")

audio.refresh()
check(#exec_calls == 1 and exec_calls[1].command ==
      "'/fixed/audio-state' 'audio' 'state' 'begin'",
      "wire state must use the first opaque session read")
exec_calls[1].callback(state_document, 0)
local view = audio.view()
check(view.confirmed, "real SbarLua-decoded coordinator state must parse")
check(view.defaults.system_output == nil,
      "real SbarLua null default must remain unavailable")
local unavailable_alerts = audio.choices("system_output")
check(audio.role_settable("system_output") and #unavailable_alerts == 2,
      "real null default must keep eligible recovery choices visible")
for _, choice in ipairs(unavailable_alerts) do
  check(choice.available == false and choice.invoke == nil
        and choice.reason == "current system alert device unavailable",
        "real null default choices must be disabled with an exact reason")
end
check(view.devices[2].name == "Mikrofon Ω 🎧",
      "real SbarLua decoder must preserve non-ASCII display text")
check(view.devices[2].input.mute.available == false
      and view.devices[2].input.mute.settable == false
      and view.devices[2].input.mute.value == nil,
      "real SbarLua null capability must remain unavailable")

local choices = audio.choices("output")
check(#choices == 2, "wire state must expose both eligible output choices")
local result_ok, result_error
check(choices[2].invoke(function(ok, err)
        result_ok = ok; result_error = err
      end), "wire set-default action must start")
check(#exec_calls == 2, "wire set-default command is missing")
exec_calls[2].callback(write_document, 0)
check(#exec_calls == 3, "real decoded write must start exact full-state readback")
exec_calls[3].callback(after_document, 0)
check(result_ok == true and result_error == nil,
      "real decoded nullable write and exact readback must confirm")

print("Exact installed SbarLua coordinator wire contract passed")
