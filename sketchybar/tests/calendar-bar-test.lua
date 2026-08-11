package.path = os.getenv("SKETCHYBAR_CONFIG_DIR") .. "/?.lua;" .. package.path

local real_time = os.time
local fixed_now = real_time({ year = 2026, month = 8, day = 7, hour = 10, min = 55, sec = 0, isdst = nil })
os.time = function(value) return value == nil and fixed_now or real_time(value) end

local objects, subscriptions, commands, creation_order, delayed = {}, {}, {}, {}, {}
local open_failure, emit_empty, provider_error = false, false, false
local helper_exit, query_error, query_count = 0, false, 0
local query_rects = {
  ["display-10"] = { origin = { 1212, 0 }, size = { 116, 32 } },
  ["display-2"] = { origin = { -800, 100 }, size = { 116, 32 } },
}
local defer_uuid, defer_query = true, false
local deferred_uuid, deferred_query = {}, {}
local fixture_title = "Synthetic review"
local start_offset, event_duration = 3600, 1500

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, child in pairs(value) do result[key] = copy(child) end
  return result
end

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

local function register(owner, events, callback)
  if type(events) ~= "table" then events = { events } end
  for _, event in ipairs(events) do
    subscriptions[event] = subscriptions[event] or {}
    subscriptions[event][#subscriptions[event] + 1] = { owner = owner, callback = callback }
  end
end

local function item(kind, name, members, properties)
  local value = {
    kind = kind, name = name, members = members and copy(members) or nil,
    properties = copy(properties or {}), initial = copy(properties or {}),
    set_history = {}, subscriptions = {},
  }
  function value:set(update)
    value.set_history[#value.set_history + 1] = copy(update)
    merge(value.properties, update)
  end
  function value:query()
    query_count = query_count + 1
    if query_error then error("synthetic query failure") end
    return { bounding_rects = copy(query_rects) }
  end
  function value:subscribe(events, callback)
    register(value, events, callback)
    if type(events) ~= "table" then events = { events } end
    for _, event_name in ipairs(events) do
      value.subscriptions[event_name] = value.subscriptions[event_name] or {}
      value.subscriptions[event_name][#value.subscriptions[event_name] + 1] = callback
    end
  end
  objects[name] = value
  creation_order[#creation_order + 1] = name
  return value
end

sbar = {
  add = function(kind, name, third, fourth)
    if kind == "bracket" then return item(kind, name, third, fourth) end
    return item(kind, name, nil, third)
  end,
  exec = function(command, callback)
    command = tostring(command)
    commands[#commands + 1] = command
    if not callback then return end
    if command:find("/usr/bin/uuidgen", 1, true) then
      if defer_uuid then deferred_uuid[#deferred_uuid + 1] = callback; return end
      callback("01234567-89AB-CDEF-0123-456789ABCDEF\n", 0)
    elseif command:find("calendar-panel", 1, true) then
      callback("", helper_exit)
    elseif command:find("icalBuddy", 1, true) then
      if provider_error then callback("", 1); return end
      if emit_empty then callback("", 0); return end
      local property = assert(command:match("(__SB_PROP_[%x]+__)"), "synthetic property token")
      local record = assert(command:match("(__SB_REC_[%x]+__)"), "synthetic record token")
      local start_time, end_time = fixed_now + start_offset, fixed_now + start_offset + event_duration
      local range = os.date("%Y-%m-%d at %H:%M:%S %z", start_time) .. " - " .. os.date("%Y-%m-%d at %H:%M:%S %z", end_time)
      local output = record .. fixture_title .. property .. range .. property .. "uid: synthetic"
      if defer_query then deferred_query[#deferred_query + 1] = { callback = callback, output = output }; return end
      callback(output, 0)
    elseif command:find("/usr/bin/open", 1, true) then
      callback("", open_failure and 1 or 0)
    else
      callback("", 0)
    end
  end,
  delay = function(seconds, callback)
    delayed[#delayed + 1] = { seconds = seconds, callback = callback, ran = false }
  end,
}

local function equal(actual, expected, label)
  assert(actual == expected, label)
end

local function run_delay(index)
  local entry = assert(delayed[index], "missing synthetic delay")
  assert(not entry.ran, "synthetic delay ran twice")
  entry.ran = true
  entry.callback()
end

local function fire(object, event, env)
  for _, callback in ipairs(object.subscriptions[event] or {}) do callback(env or {}) end
end

require("items.calendar")
local colors = require("colors")
local settings = require("settings")
local calendar_layout = require("lib.calendar_bar_layout")
local popup = require("lib.popup")
local popup_close_count = 0
local original_schedule_close = popup.schedule_close
popup.schedule_close = function(...)
  popup_close_count = popup_close_count + 1
  return original_schedule_close(...)
end

local glyph = "󰃭"
local date = assert(objects.calendar, "date item exists")
local event = assert(objects["calendar.next"], "event item exists")
assert(objects["calendar.gap.next"] == nil, "calendar surfaces touch without a gap item")
assert(objects["calendar.gap.system"] == nil, "calendar and system groups touch without a gap item")
local event_surface = assert(objects["calendar.event.bracket"], "event surface exists")
local date_surface = assert(objects["calendar.date.bracket"], "date surface exists")
assert(objects["calendar.bracket"] == nil, "old combined surface is absent")
equal(event.properties.padding_left, 0, "calendar has no exceptional exterior gap")
equal(event.properties.padding_right, 0, "calendar segment has no exceptional exterior gap")

-- Loading state exists before the deferred synthetic provider starts.
equal(event.properties.icon.string, glyph .. " Calendar", "loading title is generic")
equal(event.properties.label.string, "LOADING", "loading detail")
local initial_uuid = assert(deferred_uuid[1], "initial bounded provider chain")
defer_uuid = false
initial_uuid("01234567-89AB-CDEF-0123-456789ABCDEF\n", 0)
local initial_query_command = commands[2] or ""
assert(initial_query_command:find("'/usr/bin/perl' '-e' 'alarm 3; exec @ARGV or exit 127'", 1, true), "provider uses exact timeout wrapper")
assert(initial_query_command:find("'-ps' '|__SB_PROP_", 1, true), "provider uses delimited synthetic separator")
assert(initial_query_command:find("'-po' 'title,datetime'", 1, true)
  and initial_query_command:find("'-iep' 'title,datetime'", 1, true),
  "display-only provider requests only rendered Calendar properties")
for _, private_property in ipairs({ "url", "location", "notes" }) do
  assert(not initial_query_command:find(private_property, 1, true),
    "provider requests private unused Calendar property: " .. private_property)
end

-- The date anchor and event maximum come from the shared notch-safe layout.
equal(date.properties.width, 148, "date width")
assert(math.abs(date.properties.icon.width + date.properties.label.width - 148) < 0.0001,
  "date lanes fill exact anchor")
equal(date.properties.icon.padding_left, 0, "date outer edge uses computed lane margin")
equal(date.properties.icon.padding_right, calendar_layout.content_gap / 2, "date half-gap")
equal(date.properties.label.padding_left, calendar_layout.content_gap / 2, "time half-gap")
equal(date.properties.label.padding_right, 0, "time outer edge uses computed lane margin")
local date_advance = #date.properties.icon.string * calendar_layout.title_narrow_advance
local time_advance = #date.properties.label.string * calendar_layout.title_narrow_advance
local date_left_margin = date.properties.icon.width - date.properties.icon.padding_right - date_advance
local time_right_margin = date.properties.label.width - date.properties.label.padding_left - time_advance
assert(math.abs(date_left_margin - time_right_margin) < 0.0001, "date/time visible content has equal outer margins")
equal(date.properties.icon.padding_right + date.properties.label.padding_left,
  calendar_layout.content_gap, "date/time internal gap")
equal(date.properties.icon.y_offset, 1, "date baseline is optically centered")
equal(date.properties.label.y_offset, 1, "time baseline is optically centered")
equal(event.properties.icon.align, "left", "title alignment")
equal(event.properties.icon.font.style, "SemiBold", "title weight")
equal(event.properties.icon.font.size, 11.5, "title font size")
equal(event.properties.label.align, "left", "detail left alignment")
equal(event.properties.label.font.style, "Medium", "detail weight")
equal(event.properties.label.font.size, 10.0, "detail font size")
assert(event.properties.label.max_chars == nil, "detail has no character cap")

local function assert_dynamic_event_layout(label)
  local icon, detail = event.properties.icon, event.properties.label
  assert(utf8.len(icon.string), label .. " valid title UTF-8")
  assert(utf8.len(detail.string), label .. " valid detail UTF-8")
  equal(icon.padding_left, 8, label .. " left edge padding")
  equal(event.properties.width, "dynamic", label .. " CoreText-sized event")
  equal(icon.width, "dynamic", label .. " CoreText-sized title lane")
  equal(icon.max_chars, 0, label .. " title is already cluster-safe bounded")
  if detail.string == "" then
    equal(icon.padding_right, 8, label .. " empty-detail right edge")
    equal(detail.width, 0, label .. " empty detail lane")
    equal(detail.drawing, false, label .. " empty detail hidden")
  else
    equal(icon.padding_right + detail.padding_left, calendar_layout.content_gap, label .. " title/detail gap")
    equal(detail.padding_right, 8, label .. " right edge padding")
    equal(detail.width, "dynamic", label .. " CoreText-sized detail lane")
    equal(detail.drawing, true, label .. " detail visible")
  end
end

assert_dynamic_event_layout("ready")
equal(event.properties.icon.max_chars, 0, "short title needs no native scalar clip")
assert(math.abs(date.properties.icon.width + date.properties.label.width - 148) < 0.0001, "date field sum")
local right_order = {}
for _, name in ipairs(creation_order) do
  if name == "calendar" or name == "calendar.next" then right_order[#right_order + 1] = name end
end
assert(table.concat(right_order, ",") == "calendar,calendar.next", "touching right-item creation order")

for _, entry in ipairs({
  { event_surface, "calendar.next", colors.right_event },
  { date_surface, "calendar", colors.right_date },
}) do
  local surface, member, idle_color = entry[1], entry[2], entry[3]
  equal(#surface.members, 1, "one bracket member")
  equal(surface.members[1], member, "exact bracket member")
  local background = surface.properties.background
  assert(background.drawing == true and background.color == idle_color, "leveled resting bracket fill")
  assert(background.height == 28 and background.corner_radius == 0, "sharp fixed-height bracket")
  assert(background.border_width == 0 and background.border_color == colors.transparent, "continuous bracket has no outline")
  assert(background.shadow.drawing == false, "bracket shadow disabled")
end
assert(event_surface.properties.background ~= date_surface.properties.background, "surface property tables are independent")
assert(date.properties.background.drawing == false and event.properties.background.drawing == false, "children never draw pills")
assert(event.properties.display == nil and date.properties.display == nil, "multi-display scope unchanged")
equal(date.properties.label.color, colors.accent, "time accent unchanged")
assert(date.properties.label.string:match("^%d?%d:%d%d [AP]M$") and not date.properties.label.string:match("^0"), "date clock format unchanged")

-- Complete sanitized titles stay whole; overflow uses a cluster-safe ellipsis.
assert(event.properties.icon.string:sub(1, #glyph + 1) == glyph .. " "
  and event.properties.icon.string:find("Synthetic", 1, true), "ready synthetic title remains recognizable")
assert(not event.properties.label.string:find("↗", 1, true), "meeting marker is removed from the static surface")
fixture_title = "Team sync" -- common short title must remain complete.
fire(event, "system_woke")
equal(event.properties.icon.string, glyph .. " " .. fixture_title, "target-length model title remains complete")
assert_dynamic_event_layout("fitting title")
equal(event.properties.icon.max_chars, 0, "fitting title is complete without clipping")
assert(not event.properties.icon.string:find("…", 1, true), "fitting title has no ellipsis")
fixture_title = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
fire(event, "system_woke")
assert(event.properties.icon.string ~= glyph .. " " .. fixture_title, "overflow title is bounded before display")
assert(event.properties.icon.string:sub(-3) == "…", "overflow title has a visible ellipsis")
assert_dynamic_event_layout("overflow title")
fixture_title = string.rep("会", 20)
fire(event, "system_woke")
assert(event.properties.icon.string:sub(-3) == "…", "CJK overflow stays bounded")
assert(utf8.len(event.properties.icon.string), "CJK bounded title remains valid UTF-8")
fixture_title = string.rep("🙂", 20)
fire(event, "system_woke")
assert(event.properties.icon.string:sub(-3) == "…", "emoji overflow stays bounded")
fixture_title = "Cafe" .. utf8.char(0x0301)
fire(event, "system_woke")
equal(event.properties.icon.string, glyph .. " " .. fixture_title, "decomposed fitting title remains complete")
fixture_title = utf8.char(0x202e) .. "Visible\t" .. utf8.char(0xe123) .. "   text" .. utf8.char(0x200b)
fire(event, "system_woke")
equal(event.properties.icon.string, glyph .. " Visible text", "hostile title is cleaned before trusted glyph prefix")
assert(not event.properties.icon.string:find(utf8.char(0xe123), 1, true), "untrusted private-use scalar removed")
for name, object in pairs(objects) do
  assert(not name:find("Visible", 1, true), "provider content excluded from item names")
  for _, member in ipairs(object.members or {}) do assert(not member:find("Visible", 1, true), "provider content excluded from bracket metadata") end
end
fixture_title = "Synthetic review"
fire(event, "system_woke")

-- Countdown states and detail semantics remain in the intrinsic left-aligned lane.
assert(event.properties.label.string:match("^in "), "before-start countdown")
assert(event.properties.label.string:match("^in "), "compact upcoming countdown")
start_offset, event_duration = -600, 2100
fire(event, "system_woke")
assert(event.properties.label.string:match("^ends "), "during-event countdown")
assert(not event.properties.label.string:find(" · ", 1, true), "bar detail omits duration")
start_offset, event_duration = 3600, 1500

-- Calendar surfaces are display-only. They never subscribe to clicks or open apps/URLs.
assert(not date.subscriptions["mouse.clicked"], "date surface is static")
assert(not event.subscriptions["mouse.clicked"], "event surface is static")
assert(not event.properties.label.string:find("↗", 1, true), "meeting marker is absent")

-- Display-only Calendar surfaces expose no hover affordance or state transition.
for _, surface_item in ipairs({ event, date }) do
  assert(not surface_item.subscriptions["mouse.entered"], "display-only surface has no hover entry")
  assert(not surface_item.subscriptions["mouse.exited"], "display-only surface has no hover exit")
  assert(not surface_item.subscriptions["mouse.exited.global"], "display-only surface has no global hover exit")
end

-- Privacy-off is generic for ready and stale, and stale links are never actionable.
settings.calendar_show_titles = false
provider_error = false
fire(event, "system_woke")
equal(event.properties.icon.string, glyph .. " Upcoming event", "privacy-off ready title")
provider_error = true
fire(event, "system_woke")
equal(event.properties.icon.string, glyph .. " Upcoming event", "privacy-off stale title")
equal(event.properties.label.string, "STALE", "stale detail")
equal(event.properties.icon.color, colors.warning, "warning title remains visible")
equal(event.properties.label.color, colors.warning, "warning detail remains visible")
-- Warning state remains visible without implying an unavailable action.
equal(event.properties.icon.color, colors.warning, "warning title remains visible without hover")
equal(event.properties.label.color, colors.warning, "warning detail remains visible without hover")

-- Empty and provider-error-without-cache states retain generic fixed geometry.
settings.calendar_show_titles, provider_error, emit_empty = true, false, true
fire(event, "system_woke")
equal(event.properties.icon.string, glyph .. " No upcoming events", "empty title")
provider_error, emit_empty = true, false
fire(event, "system_woke")
assert(event.properties.icon.string:sub(1, #glyph + 10) == glyph .. " Calendar " and event.properties.icon.string:find("…", 1, true), "uncached provider error generic")
equal(event.properties.label.string, "STALE", "uncached provider error detail")

-- Forced refreshes coalesce and late callbacks cannot replace current state.
provider_error, defer_uuid, deferred_uuid = false, true, {}
commands = {}
fire(event, "system_woke")
for _ = 1, 8 do fire(event, "system_woke") end
equal(#deferred_uuid, 1, "one UUID chain in flight")
deferred_uuid[1]("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\n", 0)
local coalesced_delay = #delayed
equal(delayed[coalesced_delay].seconds, 0.01, "coalesced refresh delay")
run_delay(coalesced_delay)
equal(#deferred_uuid, 2, "one coalesced forced refresh")
defer_uuid = false
deferred_uuid[2]("11111111-2222-3333-4444-555555555555\n", 0)
local query_commands = 0
for _, command in ipairs(commands) do if command:find("alarm 3; exec @ARGV", 1, true) then query_commands = query_commands + 1 end end
equal(query_commands, 2, "coalesced wakes use sequential bounded queries")

defer_query, deferred_query = true, {}
fixture_title = "Synthetic old generation"
commands = {}
fire(event, "system_woke")
for _ = 1, 8 do fire(event, "system_woke") end
equal(#deferred_query, 1, "hung provider has one query")
fixture_title = "Synthetic new generation"
deferred_query[1].callback(deferred_query[1].output, 0)
run_delay(#delayed)
equal(#deferred_query, 2, "hung completion starts one coalesced query")
local current_title = event.properties.icon.string
deferred_query[1].callback(deferred_query[1].output, 0)
equal(event.properties.icon.string, current_title, "duplicate old callback ignored")
deferred_query[2].callback(deferred_query[2].output, 0)
assert(event.properties.icon.string:sub(1, #glyph + 1) == glyph .. " " and event.properties.icon.string:find("Synthetic new", 1, true), "current callback wins")
defer_query = false

-- Every render update preserves bounded intrinsic geometry; hover never changes the child background.
for _, update in ipairs(event.set_history) do
  if update.width ~= nil then
    equal(update.width, "dynamic", "event update uses native dynamic width")
    assert(update.icon and update.label, "event geometry update is atomic")
    equal(update.icon.width, "dynamic", "event update uses native title width")
    equal(update.icon.padding_left, 8, "event update left edge")
    if update.label.string == "" then
      equal(update.icon.padding_right, 8, "event empty update right edge")
      equal(update.label.width, 0, "event empty update label width")
      equal(update.label.drawing, false, "event empty update label hidden")
    else
      equal(update.icon.padding_right + update.label.padding_left, calendar_layout.content_gap, "event update content gap")
      equal(update.label.padding_right, 8, "event update right edge")
      equal(update.label.width, "dynamic", "event update uses native detail width")
      equal(update.label.drawing, true, "event detail update visible")
    end
  end
  assert(not (update.icon and (update.icon.font ~= nil or update.icon.align ~= nil)), "render does not change title font/alignment")
  assert(not (update.label and (update.label.max_chars ~= nil or update.label.font ~= nil or update.label.align ~= nil)), "render does not change detail font/alignment")
  assert(not update.background, "event child background never updated")
end
for _, update in ipairs(date.set_history) do
  if update.width ~= nil then equal(update.width, 148, "date update width") end
  assert(not update.background, "date child background never updated")
end
for _, surface in ipairs({ event_surface, date_surface }) do
  for _, update in ipairs(surface.set_history) do
    local background = assert(update.background, "surface update only")
    assert(background.height == nil and background.corner_radius == nil and background.border_width == nil and background.shadow == nil, "hover does not change geometry")
    assert(background.drawing == true, "surface stays drawn")
  end
end
equal(event.properties.width, "dynamic", "final event width remains native dynamic")
equal(date.properties.width, 148, "final anchor width")

os.time = real_time
print("Calendar split surface geometry passed")
