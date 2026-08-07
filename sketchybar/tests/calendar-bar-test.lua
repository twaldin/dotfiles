package.path = os.getenv("SKETCHYBAR_CONFIG_DIR") .. "/?.lua;" .. package.path
local objects, subscriptions, commands = {}, {}, {}
local open_failure = false
local emit_safe = true
local provider_error = false
local helper_exit = 0
local query_error = false
local query_count = 0
local query_rects = {
  ["display-10"] = { origin = { 1212, 0 }, size = { 116, 32 } },
  ["display-2"] = { origin = { -800, 100 }, size = { 116, 32 } },
}
local defer_uuid, defer_query = false, false
local deferred_uuid, deferred_query = {}, {}
local fixture_title = "Synthetic review"
local function merge(target, source)
  for key, value in pairs(source or {}) do
    if type(value) == "table" then target[key] = target[key] or {}; merge(target[key], value) else target[key] = value end
  end
end
local function register(events, callback)
  if type(events) ~= "table" then events = { events } end
  for _, event in ipairs(events) do subscriptions[event] = subscriptions[event] or {}; table.insert(subscriptions[event], callback) end
end
local function item(kind, name, members, properties)
  local value = { kind = kind, name = name, members = members, properties = properties or {} }
  function value:set(update) merge(value.properties, update) end
  function value:query()
    query_count = query_count + 1
    if query_error then error("synthetic query failure") end
    return { bounding_rects = query_rects }
  end
  function value:subscribe(events, callback)
    register(events, callback)
    if type(events) ~= "table" then events = { events } end
    value.subscriptions = value.subscriptions or {}
    for _, event_name in ipairs(events) do
      value.subscriptions[event_name] = value.subscriptions[event_name] or {}
      table.insert(value.subscriptions[event_name], callback)
    end
  end
  objects[name] = value
  return value
end
sbar = {
  add = function(kind, name, third, fourth)
    if kind == "bracket" then return item(kind, name, third, fourth) end
    return item(kind, name, nil, third)
  end,
  exec = function(command, callback)
    command = tostring(command)
    table.insert(commands, command)
    if not callback then return end
    if command:find("/usr/bin/uuidgen", 1, true) then
      if defer_uuid then table.insert(deferred_uuid, callback); return end
      callback("01234567-89AB-CDEF-0123-456789ABCDEF\n", 0)
    elseif command:find("calendar-panel", 1, true) then
      callback("", helper_exit)
    elseif command:find("icalBuddy", 1, true) then
      if provider_error then callback("", 1); return end
      local property = assert(command:match("(__SB_PROP_[%x]+__)"))
      local record = assert(command:match("(__SB_REC_[%x]+__)"))
      local start_time, end_time = os.time() + 3600, os.time() + 4500
      local range = os.date("%Y-%m-%d at %H:%M:%S %z", start_time) .. " - " .. os.date("%Y-%m-%d at %H:%M:%S %z", end_time)
      local url = emit_safe and "https://zoom.us/wc/join/123456789" or "https://zoom.us.evil.example/j/123456789"
      local output = record .. fixture_title .. property .. range .. property .. "url: " .. url .. property .. "uid: synthetic"
      if defer_query then table.insert(deferred_query, { callback = callback, output = output }); return end
      callback(output, 0)
    elseif command:find("/usr/bin/open", 1, true) then
      callback("", open_failure and 1 or 0)
    else
      callback("", 0)
    end
  end,
  delay = function(_, callback) callback() end,
}
require("items.calendar")
local initial_query_command = commands[2] or ""
assert(initial_query_command:find("'/usr/bin/perl' '-e' 'alarm 3; exec @ARGV or exit 127'", 1, true), "provider uses exact non-shell three-second alarm wrapper")
assert(initial_query_command:find("'-ps' '|__SB_PROP_", 1, true), "icalBuddy command uses documented pipe-delimited separator-list syntax")
local function equal(actual, expected, label) assert(actual == expected, label .. ": " .. tostring(actual) .. " ~= " .. tostring(expected)) end
local date, event, bracket = objects.calendar, objects["calendar.next"], objects["calendar.bracket"]
assert(date and event and bracket, "calendar unit objects")
equal(date.properties.width, 116, "fixed date width")
equal(date.properties.label.color, require("colors").accent, "time uses quiet accent color")
equal(event.properties.width, 260, "fixed event width")
equal(event.properties.icon.width, 128, "fixed title width")
equal(event.properties.label.width, 132, "fixed supporting width")
assert(event.properties.label.max_chars == nil, "supporting text is never character-clipped")
assert(event.properties.display == nil and date.properties.display == nil, "bracket children share multi-display scope")
equal(event.properties.label.padding_left, 0, "supporting width has no hidden left inset")
equal(event.properties.label.padding_right, 4, "supporting width has no hidden right inset")
assert(event.properties.label.string:find("↗", 1, true), "safe selected event has fixed meeting affordance")
assert(not event.properties.icon.string:find("↗", 1, true), "meeting affordance is outside ellipsizable title")
equal(event.properties.icon.string, "Synthetic review", "title lane preserves the fitting 16-character synthetic title")
equal(event.properties.icon.max_chars, 18, "title lane uses the measured 18-character width cap")
fixture_title = "ABCDEFGHIJKLMNOPQRSTUV"
event.subscriptions.system_woke[1]({})
equal(event.properties.icon.string, "ABCDEFGHIJKLMNOPQ…", "overflow title uses a UTF-8-safe 17-glyph plus ellipsis budget")
fixture_title = "Synthetic review"
event.subscriptions.system_woke[1]({})
equal(event.properties.icon.string, "Synthetic review", "fitting title remains intact after overflow refresh")
assert(event.properties.label.string:match("^in "), "before-start countdown is visible")
assert(event.properties.label.string:find(" · ", 1, true), "duration marker is visible")
assert(date.properties.background.drawing == false and event.properties.background.drawing == false, "no resting child pills")
assert(bracket.properties.background.drawing == true and bracket.properties.background.height == 26, "one shared resting surface")
equal(#bracket.members, 2, "combined bracket members")
equal(bracket.members[1], "calendar.next", "event first in bracket")
equal(bracket.members[2], "calendar", "date time second in bracket")
assert(objects["calendar.gap.next"] == nil, "no internal floating gap")
assert(date.properties.label.string:match("^%d?%d:%d%d [AP]M$"), "12-hour time with AM/PM")
assert(not date.properties.label.string:match("^0"), "no leading time zero")
assert(date.subscriptions.system_woke and #date.subscriptions.system_woke == 1, "date and time refresh after wake")
assert(date.subscriptions["mouse.clicked"] and #date.subscriptions["mouse.clicked"] == 1, "one explicit date click route")
commands, query_count = {}, 0
date.subscriptions["mouse.clicked"][1]({ BUTTON = "right" })
date.subscriptions["mouse.clicked"][1]({ BUTTON = "middle" })
equal(#commands, 0, "non-left date clicks have no action")
equal(query_count, 0, "non-left date clicks do not query geometry")
date.subscriptions["mouse.clicked"][1]({ BUTTON = "left" })
equal(query_count, 1, "left date click synchronously queries content-free geometry once")
equal(#commands, 1, "valid date click launches native helper once")
assert(commands[1]:find("calendar%-panel' '%-%-toggle'") and commands[1]:find("'--ical%-buddy' '/opt/homebrew/bin/icalBuddy'"), "native route uses quoted helper argv")
local display2 = commands[1]:find("'--anchor%-cg' '%-800' '100' '116' '32'")
local display10 = commands[1]:find("'--anchor%-cg' '1212' '0' '116' '32'")
assert(display2 and display10 and display2 < display10, "all exact display rects are sorted by numeric public query key")
assert(not commands[1]:find("/usr/bin/open", 1, true), "successful native launch does not open Calendar")

query_rects = { ["display-1"] = { origin = { 0 / 0, 0 }, size = { 116, 32 } } }
commands = {}
date.subscriptions["mouse.clicked"][1]({ BUTTON = "left" })
equal(#commands, 1, "invalid query geometry falls back exactly once")
assert(commands[1]:find("%-a") and commands[1]:find("Calendar", 1, true), "invalid geometry fails closed to Calendar")

query_rects = { ["display-1"] = { origin = { 1212, 0 }, size = { 116, 32 } } }
helper_exit, commands = 75, {}
date.subscriptions["mouse.clicked"][1]({ BUTTON = "left" })
equal(#commands, 1, "moved-pointer helper exit is a no-op without fallback")
assert(commands[1]:find("calendar%-panel") and not commands[1]:find("/usr/bin/open", 1, true), "dedicated pointer abort preserves focus")

helper_exit, commands = 5, {}
date.subscriptions["mouse.clicked"][1]({ BUTTON = "left" })
equal(#commands, 2, "helper configuration failure falls back once")
assert(commands[2]:find("%-a") and commands[2]:find("Calendar", 1, true), "helper failure fallback targets Calendar")

local settings_for_helper = require("settings")
local real_helper_path = settings_for_helper.paths.calendar_panel
settings_for_helper.paths.calendar_panel = "/missing calendar helper"
helper_exit, commands = 127, {}
date.subscriptions["mouse.clicked"][1]({ BUTTON = "left" })
equal(#commands, 2, "missing quoted helper falls back once")
assert(commands[1]:find("'/missing calendar helper'", 1, true), "missing helper path remains one quoted argv value")
settings_for_helper.paths.calendar_panel = real_helper_path

query_error, helper_exit, commands = true, 0, {}
date.subscriptions["mouse.clicked"][1]({ BUTTON = "left" })
equal(#commands, 1, "query failure falls back once without helper launch")
assert(commands[1]:find("%-a") and commands[1]:find("Calendar", 1, true), "query failure targets Calendar")
query_error = false

query_rects = {}
for index = 1, 16 do query_rects["display-" .. index] = { origin = { index * 120, 0 }, size = { 116, 32 } } end
commands = {}
date.subscriptions["mouse.clicked"][1]({ BUTTON = "left" })
equal(select(2, commands[1]:gsub("'%-%-anchor%-cg'", "")), 16, "bounded maximum display candidate count launches")
query_rects["display-17"] = { origin = { 2040, 0 }, size = { 116, 32 } }
commands = {}
date.subscriptions["mouse.clicked"][1]({ BUTTON = "left" })
equal(#commands, 1, "candidate overflow fails closed once")
assert(commands[1]:find("%-a") and commands[1]:find("Calendar", 1, true), "candidate overflow does not launch helper")
query_rects = { ["display-1"] = { origin = { 1212, 0 }, size = { 116, 32 } } }

commands = {}
assert(event.subscriptions["mouse.clicked"] and #event.subscriptions["mouse.clicked"] == 1, "one explicit event click route")
event.subscriptions["mouse.clicked"][1]({ BUTTON = "right" })
equal(#commands, 0, "right click has no calendar action")
event.subscriptions["mouse.clicked"][1]({ BUTTON = "middle" })
equal(#commands, 0, "middle click has no calendar action")
event.subscriptions["mouse.clicked"][1]({ BUTTON = "left" })
equal(#commands, 1, "safe meeting opens once")
assert(commands[1]:find("https://zoom.us/wc/join/123456789", 1, true), "safe click uses allowlisted URL")
commands, open_failure = {}, true
event.subscriptions["mouse.clicked"][1]({ BUTTON = "left" })
equal(#commands, 2, "failed safe open has one Calendar fallback")
assert(commands[1]:find("https://zoom.us/wc/join/123456789", 1, true), "failed route first attempts safe URL")
assert(commands[2]:find("%-a") and commands[2]:find("Calendar", 1, true), "failed route falls back to Calendar once")
open_failure = false
emit_safe = false
assert(event.subscriptions.system_woke and #event.subscriptions.system_woke == 1, "forced provider refresh route")
event.subscriptions.system_woke[1]({})
assert(not event.properties.label.string:find("↗", 1, true), "unsafe selected event has no meeting affordance")
commands = {}
event.subscriptions["mouse.clicked"][1]({ BUTTON = "left" })
equal(#commands, 1, "unsafe event opens Calendar directly once")
assert(commands[1]:find("%-a") and commands[1]:find("Calendar", 1, true), "unsafe event never routes URL")
local settings = require("settings")
settings.calendar_show_titles = false
provider_error, emit_safe = false, true
event.subscriptions.system_woke[1]({})
equal(event.properties.icon.string, "Upcoming event", "title privacy applies to ready state")
provider_error = true
event.subscriptions.system_woke[1]({})
equal(event.properties.icon.string, "Upcoming event", "title privacy applies to stale state")
equal(event.properties.label.string, "STALE", "failed provider exposes stale state")
assert(not event.properties.label.string:find("↗", 1, true), "stale state hides meeting affordance")
commands = {}
event.subscriptions["mouse.clicked"][1]({ BUTTON = "left" })
equal(#commands, 1, "stale provider opens Calendar directly once")
assert(commands[1]:find("%-a") and not commands[1]:find("zoom.us", 1, true), "stale provider never opens retained meeting URL")
provider_error = false
settings.calendar_show_titles = true
-- An in-flight UUID chain coalesces forced refreshes instead of overlapping.
defer_uuid, deferred_uuid = true, {}
commands = {}
event.subscriptions.system_woke[1]({})
for _ = 1, 8 do event.subscriptions.system_woke[1]({}) end
equal(#deferred_uuid, 1, "repeated wakes keep one UUID chain in flight")
equal(#commands, 1, "repeated wakes launch only one UUID command")
deferred_uuid[1]("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\n", 0)
equal(#deferred_uuid, 2, "one coalesced forced refresh starts after first chain finishes")
defer_uuid = false
deferred_uuid[2]("11111111-2222-3333-4444-555555555555\n", 0)
local query_commands = 0
for _, command in ipairs(commands) do if command:find("alarm 3; exec @ARGV", 1, true) then query_commands = query_commands + 1 end end
equal(query_commands, 2, "coalesced wakes produce two sequential bounded queries")
-- A provider that never calls back holds one bounded chain and one queued refresh.
defer_query, deferred_query = true, {}
fixture_title = "Old generation"
commands = {}
event.subscriptions.system_woke[1]({})
for _ = 1, 8 do event.subscriptions.system_woke[1]({}) end
equal(#deferred_query, 1, "hung provider has one in-flight query")
local bounded_commands = 0
for _, command in ipairs(commands) do if command:find("alarm 3; exec @ARGV", 1, true) then bounded_commands = bounded_commands + 1 end end
equal(bounded_commands, 1, "hung provider cannot accumulate query processes")
fixture_title = "New generation"
deferred_query[1].callback(deferred_query[1].output, 0)
equal(#deferred_query, 2, "hung provider completion starts one coalesced query")
local old_title = event.properties.icon.string
deferred_query[1].callback(deferred_query[1].output, 0)
equal(event.properties.icon.string, old_title, "late duplicate provider callback cannot replace current generation")
deferred_query[2].callback(deferred_query[2].output, 0)
equal(event.properties.icon.string, "New generation", "current provider callback replaces summary")
defer_query = false
for _, callback in ipairs(subscriptions.routine or {}) do callback({}) end
equal(date.properties.width, 116, "routine preserves date geometry")
equal(event.properties.width, 260, "routine preserves event geometry")
print("Calendar combined bracket geometry passed")
