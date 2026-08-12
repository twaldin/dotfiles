local text = require("lib.text")
local grapheme = require("lib.unicode_grapheme_ranges")
local width_ranges = require("lib.calendar_width_ranges")
local M = {}

local function leap(year)
  return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

function M.days_in_month(year, month)
  local days = { 31, leap(year) and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  return days[month]
end

function M.shift_month(year, month, delta)
  local value = year * 12 + (month - 1) + delta
  return math.floor(value / 12), value % 12 + 1
end

function M.shift_year(year, month, delta)
  return year + delta, month
end

function M.date_key(date)
  return string.format("%04d-%02d-%02d", date.year, date.month, date.day)
end

function M.month_cells(year, month)
  local first_weekday = tonumber(os.date("%w", os.time({ year = year, month = month, day = 1, hour = 12 })))
  local result = {}
  for index = 0, 41 do
    local value = os.date("*t", os.time({ year = year, month = month, day = 1 - first_weekday + index, hour = 12 }))
    result[index + 1] = {
      year = value.year, month = value.month, day = value.day,
      in_month = value.year == year and value.month == month,
      key = string.format("%04d-%02d-%02d", value.year, value.month, value.day),
    }
  end
  return result
end

local function compact_duration(seconds)
  seconds = math.max(0, tonumber(seconds) or 0)
  local minutes = math.max(1, math.ceil(seconds / 60))
  if minutes < 60 then return tostring(minutes) .. "m" end
  local hours = math.floor(minutes / 60)
  minutes = minutes % 60
  if hours < 24 then return tostring(hours) .. "h" .. (minutes > 0 and (tostring(minutes) .. "m") or "") end
  local days = math.floor(hours / 24)
  if days >= 99 then return "99d+" end
  hours = hours % 24
  return tostring(days) .. "d" .. (hours > 0 and (tostring(hours) .. "h") or "")
end
M.compact_duration = compact_duration

function M.countdown(event, now)
  now = tonumber(now) or os.time()
  if type(event) ~= "table" or not event.title then return { phase = "none", detail = "" } end
  local start_time, end_time = tonumber(event.start), tonumber(event["end"])
  if not start_time or not end_time or end_time <= start_time then return { phase = "unavailable", detail = "time unavailable" } end
  if event.allDay then
    if now < start_time then return { phase = "before", detail = "in " .. compact_duration(start_time - now) } end
    if now < end_time then return { phase = "all_day", detail = "all day" } end
    return { phase = "ended", detail = "ended" }
  end
  if now < start_time then
    return { phase = "before", detail = "in " .. compact_duration(start_time - now) }
  end
  if now < end_time then return { phase = "during", detail = "ends " .. compact_duration(end_time - now) } end
  return { phase = "ended", detail = "ended" }
end

function M.format_time(timestamp)
  return os.date("%I:%M %p", timestamp):gsub("^0", "")
end

function M.format_date(timestamp)
  return os.date("%b %d", timestamp)
end

local function split_plain(value, separator)
  local result, start = {}, 1
  while true do
    local first, last = value:find(separator, start, true)
    if not first then result[#result + 1] = value:sub(start); break end
    result[#result + 1] = value:sub(start, first - 1)
    start = last + 1
  end
  return result
end

function M.clean_text(value, max_chars, max_bytes)
  return text.clean(value, max_chars, max_bytes)
end

local function in_range(value, first, last)
  return value >= first and value <= last
end

local function known_narrow_scalar(value)
  return in_range(value, 0x20, 0x7e)
    or value == 0xf00ed -- trusted calendar glyph; user PUA is removed earlier
end

local function scalar_kind(value)
  if known_narrow_scalar(value) then return "narrow" end
  if width_ranges.contains(width_ranges.oversized, value) then return "oversized" end
  return "fallback"
end

local function hangul_kind(value)
  if grapheme.contains(grapheme.hangul_l, value) then return "L" end
  if grapheme.contains(grapheme.hangul_v, value) then return "V" end
  if grapheme.contains(grapheme.hangul_t, value) then return "T" end
  if in_range(value, 0xac00, 0xd7a3) then
    return (value - 0xac00) % 28 == 0 and "LV" or "LVT"
  end
  return nil
end

local function title_clusters(value)
  local clusters = {}
  local function blank_cluster()
    return {
      text = "", units = 0,
      narrow_units = 0, fallback_units = 0, oversized_units = 0,
      prepend = false, regional = 0, hangul = nil,
      ep_extend_run = false, zwj_after_ep = false,
      incb_active = false, incb_linker = false,
    }
  end
  local function append_scalar(cluster, character, scalar)
    cluster.text = cluster.text .. character
    cluster.units = cluster.units + 1
    local kind = scalar_kind(scalar)
    cluster[kind .. "_units"] = cluster[kind .. "_units"] + 1
  end
  local function start_blank_cluster()
    local cluster = blank_cluster()
    clusters[#clusters + 1] = cluster
    return cluster
  end
  local function start_cluster(character, scalar, properties)
    local cluster = start_blank_cluster()
    append_scalar(cluster, character, scalar)
    for key, property in pairs(properties or {}) do cluster[key] = property end
    return cluster
  end
  local ok = pcall(function()
    for _, scalar in utf8.codes(value) do
      local character = utf8.char(scalar)
      local current = clusters[#clusters]
      local is_gcb_extend = grapheme.contains(grapheme.extend, scalar)
        or grapheme.contains(grapheme.emoji_modifier, scalar)
      local is_spacing_mark = grapheme.contains(grapheme.spacing_mark, scalar)
      local is_extend = is_gcb_extend or is_spacing_mark
      local is_extended_pictographic = grapheme.contains(grapheme.extended_pictographic, scalar)
      local is_prepend = grapheme.contains(grapheme.prepend, scalar)
      local is_regional = grapheme.contains(grapheme.regional_indicator, scalar)
      local is_zwj = grapheme.contains(grapheme.zwj, scalar)
      local hangul = hangul_kind(scalar)
      local incb_consonant = grapheme.contains(grapheme.incb_consonant, scalar)
      local incb_extend = grapheme.contains(grapheme.incb_extend, scalar)
      local incb_linker = grapheme.contains(grapheme.incb_linker, scalar)
      local joins_indic = current and current.incb_active and current.incb_linker and incb_consonant
      local joins_hangul = current and (
        (current.hangul == "L" and (hangul == "L" or hangul == "V" or hangul == "LV" or hangul == "LVT"))
        or ((current.hangul == "LV" or current.hangul == "V") and (hangul == "V" or hangul == "T"))
        or ((current.hangul == "LVT" or current.hangul == "T") and hangul == "T")
      )
      if is_prepend then
        if current and current.prepend then
          append_scalar(current, character, scalar)
        else
          start_cluster(character, scalar, { prepend = true })
        end
      elseif is_zwj then
        if not current then current = start_blank_cluster() end
        append_scalar(current, character, scalar)
        current.zwj_after_ep = current.ep_extend_run == true
        current.ep_extend_run, current.hangul, current.regional = false, nil, 0
        if current.incb_active and (incb_extend or incb_linker) then
          current.incb_linker = current.incb_linker or incb_linker
        else
          current.incb_active, current.incb_linker = false, false
        end
      elseif is_extend then
        if not current then current = start_blank_cluster() end
        append_scalar(current, character, scalar)
        current.zwj_after_ep = false
        current.ep_extend_run = current.ep_extend_run and is_gcb_extend
        current.hangul, current.regional = nil, 0
        if current.incb_active and (incb_extend or incb_linker) then
          current.incb_linker = current.incb_linker or incb_linker
        else
          current.incb_active, current.incb_linker = false, false
        end
      elseif current and current.zwj_after_ep and is_extended_pictographic then
        append_scalar(current, character, scalar)
        current.zwj_after_ep, current.ep_extend_run = false, true
        current.hangul, current.regional = hangul, 0
        current.incb_active, current.incb_linker = false, false
      elseif joins_hangul then
        append_scalar(current, character, scalar)
        current.zwj_after_ep, current.ep_extend_run = false, is_extended_pictographic
        current.hangul, current.regional = hangul, 0
        current.incb_active, current.incb_linker = false, false
      elseif joins_indic then
        append_scalar(current, character, scalar)
        current.zwj_after_ep, current.ep_extend_run = false, is_extended_pictographic
        current.hangul, current.regional = hangul, 0
        current.incb_active, current.incb_linker = true, false
      elseif current and current.prepend then
        append_scalar(current, character, scalar)
        current.prepend = false
        current.zwj_after_ep, current.ep_extend_run = false, is_extended_pictographic
        current.hangul = hangul
        current.regional = is_regional and 1 or 0
        current.incb_active, current.incb_linker = incb_consonant, false
      elseif is_regional and current and current.regional == 1 then
        append_scalar(current, character, scalar)
        current.zwj_after_ep, current.ep_extend_run = false, is_extended_pictographic
        current.regional, current.hangul = 2, nil
        current.incb_active, current.incb_linker = false, false
      else
        start_cluster(character, scalar, {
          regional = is_regional and 1 or 0,
          hangul = hangul,
          ep_extend_run = is_extended_pictographic,
          incb_active = incb_consonant,
        })
      end
    end
  end)
  return ok and clusters or nil
end

-- SketchyBar measures a dynamic text lane with CoreText. This function only
-- chooses a cluster-safe bounded prefix. Pinned narrow glyphs use their exact
-- advance; fallback scalars reserve complete-scan-verified conservative tiers.
function M.bounded_event_title(glyph, title, budget, narrow_advance, fallback_advance, oversized_advance)
  glyph = tostring(glyph or "")
  title = tostring(title or "")
  budget = math.max(1, tonumber(budget) or 1)
  narrow_advance = math.max(1, tonumber(narrow_advance) or 1)
  fallback_advance = math.max(narrow_advance, tonumber(fallback_advance) or narrow_advance)
  oversized_advance = math.max(fallback_advance, tonumber(oversized_advance) or fallback_advance)
  local full = glyph .. " " .. title
  local clusters = title_clusters(full)
  if not clusters then
    return { text = glyph .. " Calendar event", overflow = true, estimated_width = budget }
  end
  local function advance(cluster)
    return narrow_advance * (cluster.narrow_units or 0)
      + fallback_advance * (cluster.fallback_units or 0)
      + oversized_advance * (cluster.oversized_units or 0)
  end
  local total = 0
  for _, cluster in ipairs(clusters) do total = total + advance(cluster) end
  local function rounded(value) return math.ceil(value + 1.5) end
  if rounded(total) <= budget then
    return { text = full, overflow = false, estimated_width = rounded(total) }
  end
  local ellipsis, used = "…", 0
  local raw_limit = math.max(0, budget - 1.5 - narrow_advance)
  local parts = {}
  for _, cluster in ipairs(clusters) do
    local width = advance(cluster)
    if used + width > raw_limit then break end
    parts[#parts + 1] = cluster.text
    used = used + width
  end
  return {
    text = table.concat(parts) .. ellipsis,
    overflow = true,
    estimated_width = rounded(used + narrow_advance),
  }
end

local function valid_day(year, month, day)
  return year and month and day and year >= 1900 and year <= 2200 and month >= 1 and month <= 12 and day >= 1 and day <= M.days_in_month(year, month)
end

-- Gregorian civil date to Unix days, independent of host locale.
local function civil_days(year, month, day)
  year = year - (month <= 2 and 1 or 0)
  local era = math.floor(year / 400)
  local year_of_era = year - era * 400
  local adjusted_month = month + (month > 2 and -3 or 9)
  local day_of_year = math.floor((153 * adjusted_month + 2) / 5) + day - 1
  local day_of_era = year_of_era * 365 + math.floor(year_of_era / 4) - math.floor(year_of_era / 100) + day_of_year
  return era * 146097 + day_of_era - 719468
end

local function epoch_with_offset(date, hour, minute, second, offset)
  local year, month, day = date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  year, month, day = tonumber(year), tonumber(month), tonumber(day)
  if not valid_day(year, month, day) then return nil end
  hour, minute, second = tonumber(hour), tonumber(minute), tonumber(second)
  local sign, off_hour, off_minute = tostring(offset or ""):match("^([+-])(%d%d)(%d%d)$")
  off_hour, off_minute = tonumber(off_hour), tonumber(off_minute)
  if not hour or hour > 23 or not minute or minute > 59 or not second or second > 59 or not sign or off_hour > 23 or off_minute > 59 then return nil end
  local offset_seconds = (off_hour * 60 + off_minute) * 60 * (sign == "-" and -1 or 1)
  return civil_days(year, month, day) * 86400 + hour * 3600 + minute * 60 + second - offset_seconds
end

local function local_midnight(date)
  local year, month, day = date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  year, month, day = tonumber(year), tonumber(month), tonumber(day)
  if not valid_day(year, month, day) then return nil end
  return os.time({ year = year, month = month, day = day, hour = 0, min = 0, sec = 0, isdst = nil })
end

local function parse_datetime(value)
  local all_day_start, all_day_end = value:match("^(%d%d%d%d%-%d%d%-%d%d) %- (%d%d%d%d%-%d%d%-%d%d)$")
  if not all_day_start then all_day_start = value:match("^(%d%d%d%d%-%d%d%-%d%d)$") end
  if all_day_start then
    local start_time = local_midnight(all_day_start)
    local end_time = all_day_end and local_midnight(all_day_end) or start_time
    if end_time then
      local day = os.date("*t", end_time)
      end_time = os.time({ year = day.year, month = day.month, day = day.day + 1, hour = 0, min = 0, sec = 0, isdst = nil })
    end
    if start_time and end_time and end_time > start_time then
      local start_day = os.date("*t", start_time)
      local end_day = os.date("*t", end_time)
      local duration_days = civil_days(end_day.year, end_day.month, end_day.day) - civil_days(start_day.year, start_day.month, start_day.day)
      return start_time, end_time, true, duration_days
    end
    return nil
  end
  local first, second = value:match("^(.-) %- (.-)$")
  if not first then return nil end
  local date, hour, minute, second_value, offset = first:match("^(%d%d%d%d%-%d%d%-%d%d) at (%d%d):(%d%d):(%d%d) ([+-]%d%d%d%d)$")
  if not date then return nil end
  local end_date, end_hour, end_minute, end_second, end_offset = second:match("^(%d%d%d%d%-%d%d%-%d%d) at (%d%d):(%d%d):(%d%d) ([+-]%d%d%d%d)$")
  if not end_date then
    end_hour, end_minute, end_second, end_offset = second:match("^(%d%d):(%d%d):(%d%d) ([+-]%d%d%d%d)$")
    end_date = date
  end
  if not end_hour then return nil end
  local start_time = epoch_with_offset(date, hour, minute, second_value, offset)
  local end_time = epoch_with_offset(end_date, end_hour, end_minute, end_second, end_offset)
  if start_time and end_time and end_time <= start_time and end_date == date then end_time = end_time + 86400 end
  if start_time and end_time and end_time > start_time then return start_time, end_time, false end
  return nil
end

function M.tokens(seed)
  local nonce = tostring(seed or "0"):gsub("[^%w]", "")
  return { record = "__SB_REC_" .. nonce .. "__", property = "__SB_PROP_" .. nonce .. "__", newline = "__SB_NL_" .. nonce .. "__" }
end

function M.parse_events(output, tokens)
  output = tostring(output or "")
  if #output > 1024 * 1024 then return nil, "overflow" end
  if output:match("^%s*$") then return {} end
  local records = split_plain(output, tokens.record)
  if records[1]:match("%S") or #records - 1 > 512 then return nil, "records" end
  local events, identities = {}, {}
  for index = 2, #records do
    local record = records[index]:gsub("[\r\n]+$", "")
    if record == "" or #record > 65536 then return nil, "record" end
    local properties = split_plain(record, tokens.property)
    if #properties < 3 then return nil, "partial" end
    for _, property in ipairs(properties) do if #property > 16384 then return nil, "property" end end
    local title = M.clean_text(properties[1], 256, 1024)
    local start_time, end_time, all_day, duration_days = parse_datetime(properties[2])
    if not start_time then return nil, "datetime" end
    if not title then title = "Upcoming event" end
    local uid
    for property_index = 3, #properties do
      local property = properties[property_index]
      if property:sub(1, 5) == "uid: " and not uid and property_index == #properties then
        uid = M.clean_text(property:sub(6), 512, 2048)
      else
        return nil, "property"
      end
    end
    if not uid then return nil, "uid" end
    local identity = uid .. "\0" .. tostring(start_time)
    if identities[identity] then return nil, "duplicate" end
    identities[identity] = true
    events[#events + 1] = {
      title = title, start = start_time, ["end"] = end_time, allDay = all_day, duration_days = duration_days,
      sort_id = identity,
    }
  end
  table.sort(events, function(left, right)
    if left.start ~= right.start then return left.start < right.start end
    if left["end"] ~= right["end"] then return left["end"] < right["end"] end
    local lt, rt = left.title:lower(), right.title:lower()
    if lt ~= rt then return lt < rt end
    return left.sort_id < right.sort_id
  end)
  for index, event in ipairs(events) do event.sort_id, event.sort_rank = nil, index end
  return events
end

local function eligible(event, now)
  return type(event) == "table" and event.title and tonumber(event.start) and tonumber(event["end"]) and event["end"] > now
end

function M.select_summary(events, now)
  now = tonumber(now) or os.time()
  local ongoing, upcoming, all_day = {}, {}, {}
  for _, event in ipairs(events or {}) do
    if eligible(event, now) then
      if event.allDay then all_day[#all_day + 1] = event
      elseif event.start <= now then ongoing[#ongoing + 1] = event
      else upcoming[#upcoming + 1] = event end
    end
  end
  local function sort(values, active)
    table.sort(values, function(left, right)
      local la, ra = active and left["end"] or left.start, active and right["end"] or right.start
      if la ~= ra then return la < ra end
      if left.start ~= right.start then return left.start < right.start end
      return tonumber(left.sort_rank or 0) < tonumber(right.sort_rank or 0)
    end)
  end
  sort(ongoing, true); sort(upcoming, false); sort(all_day, false)
  return ongoing[1] or upcoming[1] or all_day[1]
end

return M
