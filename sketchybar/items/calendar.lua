local colors = require("colors")
local settings = require("settings")
local shell = require("lib.shell")
local calendar_model = require("lib.calendar")
local calendar_layout = require("lib.calendar_bar_layout")
local hover = require("lib.hover")

local function open_calendar()
  shell.exec({ "/usr/bin/open", "-a", "Calendar" })
end

local date_hovered = false
local date_time = sbar.add("item", "calendar", {
  position = "right",
  updates = true,
  update_freq = 30,
  width = 116,
  padding_left = 0,
  padding_right = 0,
  icon = {
    string = "", color = colors.muted, width = 58, align = "right",
    padding_left = 0, padding_right = 4, y_offset = 1,
    font = { family = settings.font, style = "SemiBold", size = 9.0 },
  },
  label = {
    string = "", color = colors.accent, width = 58, align = "left",
    padding_left = 4, padding_right = 0, y_offset = 1,
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
  local rects, seen, entry_count = {}, {}, 0
  for key, rect in pairs(query.bounding_rects) do
    entry_count = entry_count + 1
    if entry_count > 64 then return nil end
    local display_id = type(key) == "string" and key:match("^display%-(%d+)$") or nil
    local numeric_id = display_id and tonumber(display_id) or nil
    if numeric_id and numeric_id >= 1 and numeric_id <= 0xffffffff then
      if seen[numeric_id] then return nil end
      seen[numeric_id] = true
      if exact_rect(rect) then
        local x, y, width, height = rect.origin[1], rect.origin[2], rect.size[1], rect.size[2]
        if finite_coordinate(x) and finite_coordinate(y) and finite_coordinate(width) and finite_coordinate(height) and
           width == 116 and height == 32 then
          if #rects >= 16 then return nil end
          rects[#rects + 1] = { id = numeric_id, x = x, y = y, width = width, height = height }
        end
      end
    end
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
  if not argv then return false end
  return pcall(function() shell.exec(argv, function() end) end)
end

local function render_clock()
  local date_text = os.date("%a %b ") .. tostring(tonumber(os.date("%d")))
  local hour = os.date("%I"):gsub("^0", "")
  local time_text = hour .. os.date(":%M %p")
  local advance = calendar_layout.title_narrow_advance
  local gap = calendar_layout.content_gap
  local date_width = #date_text * advance
  local time_width = #time_text * advance
  local outer = math.max(0, (116 - date_width - time_width - gap) / 2)
  date_time:set({
    width = 116,
    icon = {
      string = date_text,
      color = date_hovered and colors.primary or colors.muted,
      width = outer + date_width + (gap / 2),
      padding_left = 0, padding_right = gap / 2, y_offset = 1,
    },
    label = {
      string = time_text,
      color = date_hovered and colors.primary or colors.accent,
      width = outer + time_width + (gap / 2),
      padding_left = gap / 2, padding_right = 0, y_offset = 1,
    },
  })
end

local calendar_glyph = "󰃭"

local function event_layout(title, detail)
  local detail_text = tostring(detail or "")
  local title_budget, detail_width, gap = calendar_layout.title_budget(detail_text)
  local bounded = calendar_model.bounded_event_title(
    calendar_glyph,
    title,
    title_budget,
    calendar_layout.title_narrow_advance,
    calendar_layout.title_fallback_advance,
    calendar_layout.title_oversized_advance)
  local half_gap = math.floor(gap / 2)
  return {
    width = "dynamic",
    estimated_width = (2 * calendar_layout.edge_padding) + gap + bounded.estimated_width + detail_width,
    full_title = bounded.text,
    overflow = bounded.overflow,
    max_chars = 0,
    icon_width = "dynamic",
    icon_left = calendar_layout.edge_padding,
    icon_right = detail_text ~= "" and half_gap or calendar_layout.edge_padding,
    label_width = detail_text ~= "" and "dynamic" or 0,
    label_drawing = detail_text ~= "",
    label_left = detail_text ~= "" and (gap - half_gap) or 0,
    label_right = detail_text ~= "" and calendar_layout.edge_padding or 0,
  }
end

local initial_event_layout = event_layout("Calendar", "LOADING")
local next_event = sbar.add("item", "calendar.next", {
  position = "right",
  drawing = true,
  updates = true,
  update_freq = 30,
  width = initial_event_layout.width,
  padding_left = 0,
  padding_right = 0,
  icon = {
    string = initial_event_layout.full_title, color = colors.primary,
    width = initial_event_layout.icon_width, align = "left", max_chars = initial_event_layout.max_chars,
    padding_left = initial_event_layout.icon_left, padding_right = initial_event_layout.icon_right,
    font = { family = settings.font, style = "SemiBold", size = 9.0 },
  },
  label = {
    string = "LOADING", color = colors.muted, drawing = initial_event_layout.label_drawing,
    width = initial_event_layout.label_width, align = "left",
    padding_left = initial_event_layout.label_left, padding_right = initial_event_layout.label_right,
    font = { family = settings.font, style = "Medium", size = 8.0 },
  },
  background = { drawing = false },
})

local event_surface = sbar.add("bracket", "calendar.event.bracket", { "calendar.next" }, {
  background = {
    drawing = true,
    color = colors.right_event,
    height = 26,
    corner_radius = 0,
    border_width = 0,
    border_color = colors.transparent,
    shadow = { drawing = false },
  },
})

local date_surface = sbar.add("bracket", "calendar.date.bracket", { "calendar" }, {
  background = {
    drawing = true,
    color = colors.right_date,
    height = 26,
    corner_radius = 0,
    border_width = 0,
    border_color = colors.transparent,
    shadow = { drawing = false },
  },
})

date_time:subscribe({ "routine", "system_woke" }, render_clock)
local calendar_click_blocked = false
local calendar_click_generation = 0
date_time:subscribe("mouse.clicked", function(env)
  if env.BUTTON ~= "left" or calendar_click_blocked then return end
  calendar_click_blocked = true
  calendar_click_generation = calendar_click_generation + 1
  local token = calendar_click_generation
  sbar.delay(0.30, function()
    if token == calendar_click_generation then calendar_click_blocked = false end
  end)
  toggle_calendar_panel()
end)
hover.bind_surface(date_time, date_surface, {
  idle_surface = colors.right_date,
  idle_border = colors.transparent,
  hover_border = colors.transparent,
  on_change = function(active)
    date_hovered = active
    render_clock()
  end,
})
render_clock()

local generation = 0
local current_event = nil
local last_good_event = nil
local provider_state = "loading"
local event_hovered = false
local last_query = 0
local query_in_flight = false
local query_queued = false
local active_query_token = nil
local refresh_next

local function event_foregrounds()
  if provider_state == "error" then return colors.warning, colors.warning end
  return event_hovered and colors.primary or colors.accent,
    event_hovered and colors.primary or colors.muted
end

local function paint_event()
  local title_color, detail_color = event_foregrounds()
  next_event:set({ icon = { color = title_color }, label = { color = detail_color } })
end

local function render_event()
  local ended = false
  local title, detail = "No upcoming events", ""
  if provider_state == "error" then
    title = last_good_event and (settings.calendar_show_titles and last_good_event.title or "Upcoming event") or "Calendar unavailable"
    detail = "STALE"
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
  local layout = event_layout(title, detail)
  local title_color, detail_color = event_foregrounds()
  next_event:set({
    width = layout.width,
    icon = {
      string = layout.full_title, color = title_color,
      width = layout.icon_width, max_chars = layout.max_chars,
      padding_left = layout.icon_left, padding_right = layout.icon_right,
    },
    label = {
      string = detail, color = detail_color, drawing = layout.label_drawing,
      width = layout.label_width,
      padding_left = layout.label_left, padding_right = layout.label_right,
    },
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
  if provider_state == "ready" and current_event and calendar_model.countdown(current_event, os.time()).phase == "ended" then
    current_event = nil
    last_good_event = nil
    provider_state = "loading"
    render_event()
    sbar.delay(0, function() refresh_next(true) end)
    open_calendar()
    return
  end
  if provider_state == "ready" and current_event and current_event.meeting_url then
    shell.exec({ "/usr/bin/open", current_event.meeting_url }, function(_, exit_code)
      if exit_code ~= 0 then open_calendar() end
    end)
  else
    open_calendar()
  end
end)
hover.bind_surface(next_event, event_surface, {
  idle_surface = colors.right_event,
  idle_border = colors.transparent,
  hover_border = colors.transparent,
  on_change = function(active)
    event_hovered = active
    paint_event()
  end,
})
refresh_next(true)

return date_time
