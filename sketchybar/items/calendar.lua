local colors = require("colors")
local settings = require("settings")
local shell = require("lib.shell")
local calendar_model = require("lib.calendar")
local hover = require("lib.hover")

local function spacer(name)
  return sbar.add("item", name, {
    position = "right", drawing = true, updates = false, width = 8,
    icon = { drawing = false, width = 0 }, label = { drawing = false, width = 0 }, background = { drawing = false },
  })
end

local function open_calendar()
  shell.exec({ "/usr/bin/open", "-a", "Calendar" })
end

spacer("calendar.gap.system")

local date_time = sbar.add("item", "calendar", {
  position = "right",
  updates = true,
  update_freq = 30,
  width = 116,
  padding_left = 0,
  padding_right = 0,
  icon = {
    string = "", color = colors.muted, width = 58, align = "right",
    padding_left = 2, padding_right = 3,
    font = { family = settings.font, style = "SemiBold", size = 9.0 },
  },
  label = {
    string = "", color = colors.accent, width = 58, align = "left",
    padding_left = 3, padding_right = 2,
    font = { family = settings.font, style = "Medium", size = 9.0 },
  },
  background = { drawing = false },
})

local function finite_coordinate(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge and math.abs(value) <= 10000000
end

local function exact_pair(value)
  if type(value) ~= "table" then return false end
  local count = 0
  for key in pairs(value) do
    if key ~= 1 and key ~= 2 then return false end
    count = count + 1
  end
  return count == 2
end

local function exact_rect(value)
  if type(value) ~= "table" then return false end
  local count = 0
  for key in pairs(value) do
    if key ~= "origin" and key ~= "size" then return false end
    count = count + 1
  end
  return count == 2 and exact_pair(value.origin) and exact_pair(value.size)
end

local function calendar_anchor_arguments()
  local ok, query = pcall(function() return date_time:query() end)
  if not ok or type(query) ~= "table" or type(query.bounding_rects) ~= "table" then return nil end
  local rects, seen = {}, {}
  for key, rect in pairs(query.bounding_rects) do
    local display_id = type(key) == "string" and key:match("^display%-(%d+)$") or nil
    local numeric_id = display_id and tonumber(display_id) or nil
    if not numeric_id or numeric_id < 1 or numeric_id > 0xffffffff or seen[numeric_id] or #rects >= 16 or
       not exact_rect(rect) then return nil end
    local x, y, width, height = rect.origin[1], rect.origin[2], rect.size[1], rect.size[2]
    if not finite_coordinate(x) or not finite_coordinate(y) or not finite_coordinate(width) or not finite_coordinate(height) or
       width ~= 116 or height ~= 32 then return nil end
    seen[numeric_id] = true
    rects[#rects + 1] = { id = numeric_id, x = x, y = y, width = width, height = height }
  end
  if #rects == 0 then return nil end
  table.sort(rects, function(a, b) return a.id < b.id end)
  local argv = { settings.paths.calendar_panel, "--toggle" }
  for _, rect in ipairs(rects) do
    argv[#argv + 1] = "--anchor-cg"
    argv[#argv + 1] = tostring(rect.x)
    argv[#argv + 1] = tostring(rect.y)
    argv[#argv + 1] = tostring(rect.width)
    argv[#argv + 1] = tostring(rect.height)
  end
  argv[#argv + 1] = "--ical-buddy"
  argv[#argv + 1] = settings.paths.icalbuddy
  return argv
end

local function toggle_calendar_panel()
  local argv = calendar_anchor_arguments()
  if not argv then open_calendar(); return end
  local completed = false
  local ok = pcall(function()
    shell.exec(argv, function(_, exit_code)
      if completed then return end
      completed = true
      exit_code = tonumber(exit_code)
      if exit_code ~= 0 and exit_code ~= 75 then open_calendar() end
    end)
  end)
  if not ok and not completed then
    completed = true
    open_calendar()
  end
end

local function render_clock()
  local hour = os.date("%I"):gsub("^0", "")
  date_time:set({
    width = 116,
    icon = { string = os.date("%a %b ") .. tostring(tonumber(os.date("%d"))) },
    label = { string = hour .. os.date(":%M %p") },
  })
end

date_time:subscribe({ "routine", "system_woke" }, render_clock)
date_time:subscribe("mouse.clicked", function(env)
  if env.BUTTON == "left" then toggle_calendar_panel() end
end)
hover.bind(date_time, { idle_color = colors.muted })
render_clock()

local next_event = sbar.add("item", "calendar.next", {
  position = "right",
  drawing = true,
  updates = true,
  update_freq = 30,
  width = 260,
  padding_left = 0,
  padding_right = 0,
  icon = {
    string = "No upcoming events", color = colors.primary, width = 128, align = "left", max_chars = 18,
    padding_left = 10, padding_right = 4,
    font = { family = settings.font, style = "SemiBold", size = 10.0 },
  },
  label = {
    string = "", color = colors.muted, width = 132, align = "right",
    padding_left = 0, padding_right = 4,
    font = { family = settings.font, style = "Medium", size = 8.5 },
  },
  background = { drawing = false },
})

sbar.add("bracket", "calendar.bracket", { "calendar.next", "calendar" }, {
  background = {
    drawing = true,
    color = colors.surface,
    height = 26,
    corner_radius = 9,
    border_width = 1,
    border_color = colors.border,
    shadow = { drawing = false },
  },
})

local generation = 0
local current_event = nil
local last_good_event = nil
local provider_state = "loading"
local last_query = 0
local query_in_flight = false
local query_queued = false
local active_query_token = nil
local refresh_next

local function render_event()
  local ended = false
  local title, detail, title_color = "No upcoming events", "", colors.primary
  if provider_state == "error" then
    title = last_good_event and (settings.calendar_show_titles and last_good_event.title or "Upcoming event") or "Calendar unavailable"
    detail = "STALE"
    title_color = colors.warning
  elseif current_event then
    local status = calendar_model.countdown(current_event, os.time())
    if status.phase == "ended" then
      current_event = nil
      ended = true
      title, detail = "Refreshing…", ""
    else
      title = settings.calendar_show_titles and current_event.title or "Upcoming event"
      detail = status.detail .. (current_event.meeting_url and " ↗" or "")
    end
  elseif provider_state == "loading" then
    title = "Calendar"
    detail = "LOADING"
  end
  next_event:set({
    width = 260,
    icon = { string = shell.ellipsis(title, 18), color = title_color, width = 128 },
    label = { string = detail, color = provider_state == "error" and colors.warning or colors.muted, width = 132 },
  })
  return ended
end

local function query_bounds()
  local now = os.date("*t")
  local start = os.time({ year = now.year, month = now.month, day = now.day, hour = 0, min = 0, sec = 0, isdst = nil })
  local finish = os.time({ year = now.year, month = now.month, day = now.day + 8, hour = 0, min = 0, sec = 0, isdst = nil })
  return os.date("%Y-%m-%d %H:%M:%S %z", start), os.date("%Y-%m-%d %H:%M:%S %z", finish)
end

local function finish_query(token)
  if active_query_token ~= token then return end
  query_in_flight = false
  active_query_token = nil
  if query_queued then
    query_queued = false
    sbar.delay(0.01, function() refresh_next(true) end)
  end
end

refresh_next = function(force)
  local now = os.time()
  if render_event() then force = true end
  if query_in_flight then
    if force then query_queued = true end
    return
  end
  if not force and now - last_query < 60 then return end
  last_query = now
  generation = generation + 1
  local token = generation
  active_query_token = token
  query_in_flight = true
  local first, last = query_bounds()
  shell.exec({ "/usr/bin/uuidgen" }, function(uuid, uuid_exit)
    if token ~= generation or active_query_token ~= token then return end
    local nonce = type(uuid) == "string" and uuid:match("^%s*(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)%s*$") or nil
    if uuid_exit ~= 0 or not nonce or #nonce ~= 36 then
      provider_state = "error"
      current_event = last_good_event
      render_event()
      finish_query(token)
      return
    end
    local separators = calendar_model.tokens(nonce)
    shell.exec_quiet({
      "/usr/bin/perl", "-e", "alarm 3; exec @ARGV or exit 127", settings.paths.icalbuddy,
      "-uid", "-nc", "-nrd", "-cf", "",
      "-tf", "%H:%M:%S %z", "-df", "%Y-%m-%d",
      "-po", "title,datetime,url,location,notes",
      -- iCalBuddy uses the first and last -ps characters to delimit its separator list;
      -- the emitted field separator is the random token without these pipe delimiters.
      "-ps", "|" .. separators.property .. "|",
      "-b", separators.record, "-ss", "", "-nnr", separators.newline,
      "-iep", "title,datetime,url,location,notes",
      "eventsFrom:" .. first, "to:" .. last,
    }, function(output, exit_code)
      if token ~= generation or active_query_token ~= token then return end
      if exit_code ~= 0 or type(output) ~= "string" then
        provider_state = "error"
        current_event = last_good_event
        render_event()
        finish_query(token)
        return
      end
      local events = calendar_model.parse_events(output, separators)
      if not events then
        provider_state = "error"
        current_event = last_good_event
        render_event()
        finish_query(token)
        return
      end
      current_event = calendar_model.select_summary(events, os.time())
      last_good_event = current_event
      provider_state = "ready"
      render_event()
      finish_query(token)
    end)
  end)
end

next_event:subscribe("routine", function() refresh_next(false) end)
next_event:subscribe("system_woke", function() refresh_next(true) end)
next_event:subscribe("mouse.clicked", function(env)
  if env.BUTTON ~= "left" then return end
  if provider_state == "ready" and current_event and current_event.meeting_url then
    shell.exec({ "/usr/bin/open", current_event.meeting_url }, function(_, exit_code)
      if exit_code ~= 0 then open_calendar() end
    end)
  else
    open_calendar()
  end
end)
hover.bind(next_event, { idle_color = colors.primary })
refresh_next(true)

return date_time
