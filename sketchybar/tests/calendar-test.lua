package.path = os.getenv("SKETCHYBAR_CONFIG_DIR") .. "/?.lua;" .. package.path
local calendar = require("lib.calendar")
local shell = require("lib.shell")
local function equal(actual, expected, label) assert(actual == expected, label .. ": " .. tostring(actual) .. " ~= " .. tostring(expected)) end
local year, month = calendar.shift_month(2026, 1, -1); equal(year, 2025, "Dec previous year"); equal(month, 12, "Dec previous month")
year, month = calendar.shift_month(2026, 12, 1); equal(year, 2027, "Jan next year"); equal(month, 1, "Jan next month")
equal(calendar.days_in_month(2028, 2), 29, "leap February"); equal(calendar.days_in_month(2027, 2), 28, "ordinary February")
local cells = calendar.month_cells(2026, 8); equal(#cells, 42, "cell count"); equal(cells[1].key, "2026-07-26", "first overflow"); equal(cells[7].key, "2026-08-01", "Saturday mapping"); equal(cells[42].key, "2026-09-05", "last overflow")
equal(calendar.countdown({title="x", start=2000, ["end"]=2900}, 1400).detail, "in 10m · 15m", "before countdown")
equal(calendar.countdown({title="x", start=2000, ["end"]=2900}, 2420).detail, "ends in 8m · 15m", "during countdown keeps duration")
equal(calendar.countdown({title="x", start=2000, ["end"]=2900}, 3000).phase, "ended", "ended countdown")
equal(calendar.countdown({title="x", start=2000, ["end"]=2900}, 2000).phase, "during", "start equals now active")
equal(calendar.countdown({title="x", start=2000, ["end"]=2900}, 2900).phase, "ended", "end equals now ended")
equal(calendar.countdown({title="x", start=2000, ["end"]=1900}, 1800).phase, "unavailable", "invalid interval")
equal(calendar.countdown({title="x", start=1000, ["end"]=2000, allDay=true}, 500).detail, "in 9m · all day", "future all-day countdown")
equal(calendar.countdown({title="x", start=1000, ["end"]=2000, allDay=true}, 1200).detail, "all day", "active all-day countdown")
equal(calendar.countdown({title="x", start=1000, ["end"]=2000, allDay=true}, 2000).phase, "ended", "all-day exclusive end")
equal(calendar.meeting_url({url="https://zoom.us/j/123", notes="https://meet.google.com/abc-defg-hij"}), "https://zoom.us/j/123", "explicit URL preferred")
equal(calendar.meeting_url({notes="join https://meet.google.com/abc-defg-hij."}), "https://meet.google.com/abc-defg-hij", "notes URL")
equal(calendar.meeting_url({url="https://example.com/not-meeting", notes="join https://us02web.zoom.us/j/123?pwd=a&amp;b=c"}), "https://us02web.zoom.us/j/123?pwd=a&b=c", "unsafe explicit falls through and decodes HTML")
assert(calendar.safe_meeting_url("https://teams.microsoft.com/l/meetup-join/19%3ameeting") ~= nil, "Teams join")
assert(calendar.safe_meeting_url("https://zoom.us/wc/join/123456789") ~= nil, "Zoom web join")
assert(calendar.safe_meeting_url("https://zoom.us:443/j/123456789") ~= nil, "explicit HTTPS port")
assert(calendar.safe_meeting_url("https://zoom.us:444/j/123456789") == nil, "unsafe port")
assert(calendar.safe_meeting_url("https://zoom.us/j/" .. string.rep("1", 5000)) == nil, "bounded meeting URL")
assert(calendar.safe_meeting_url("https://acme.webex.com/meet/person") ~= nil, "Webex meet")
assert(calendar.safe_meeting_url("http://zoom.us/j/123") == nil, "HTTPS required")
assert(calendar.safe_meeting_url("https://zoom.us/") == nil, "meeting path required")
assert(calendar.safe_meeting_url("https://zoom.us.evil.example/j/1") == nil, "suffix attack")
assert(calendar.safe_meeting_url("https://zoom.us@evil.example/j/1") == nil, "userinfo attack")
assert(calendar.safe_meeting_url("javascript:alert(1)") == nil, "scheme attack")

local tokens = { record = "__R__", property = "__P__", newline = "__N__" }
local output = "__R__Later__P__2026-08-07 at 15:45:00 -0700 - 16:15:00 -0700__P__uid: later\n" ..
  "__R__Earlier__P__2026-08-07 at 09:00:00 -0700 - 09:15:00 -0700__P__notes: Join https://meet.google.com/abc-defg-hij.__P__uid: earlier\n"
local parsed, parse_error = calendar.parse_events(output, tokens)
assert(parsed and not parse_error and #parsed == 2, "structured event parse")
equal(parsed[1].title, "Earlier", "chronological structured sort")
equal(parsed[1].meeting_url, "https://meet.google.com/abc-defg-hij", "structured safe link")
assert(parsed[1].sort_id == nil and parsed[1].sort_rank == 1 and parsed[2].sort_rank == 2, "raw UID discarded after stable sort")
local multiline = "__R__Lines__P__2026-08-07 at 10:00:00 -0700 - 11:00:00 -0700__P__notes: first__N__second__N__https://zoom.us/wc/join/123456789__P__uid: lines"
local raw_all_day = "__R__Multi-day raw__P__2026-08-20 - 2026-08-22__P__uid: raw-multi-day"
local raw_all_day_events = assert(calendar.parse_events(raw_all_day, tokens))
equal(raw_all_day_events[1].duration_days, 3, "icalBuddy inclusive all-day range becomes exclusive three-calendar-day interval")
local raw_single_day = assert(calendar.parse_events("__R__Single raw__P__2026-08-20__P__uid: raw-single", tokens))
equal(raw_single_day[1].duration_days, 1, "single all-day output remains one calendar day")
local dst_all_day = assert(calendar.parse_events("__R__DST raw__P__2026-03-07 - 2026-03-09__P__uid: raw-dst", tokens))[1]
equal(dst_all_day.duration_days, 3, "DST-spanning all-day range keeps three calendar days")
equal(os.date("%Y-%m-%d", dst_all_day["end"]), "2026-03-10", "DST range exclusive end follows final displayed day")
local dst_before = os.time({ year = 2026, month = 3, day = 6, hour = 12, min = 0, sec = 0, isdst = nil })
local dst_final_day = os.time({ year = 2026, month = 3, day = 9, hour = 12, min = 0, sec = 0, isdst = nil })
assert(calendar.select_summary({ dst_all_day }, dst_before) == dst_all_day, "DST all-day event is upcoming before first day")
assert(calendar.select_summary({ dst_all_day }, dst_final_day) == dst_all_day, "DST all-day event includes final displayed day")
assert(calendar.select_summary({ dst_all_day }, dst_all_day["end"]) == nil, "DST all-day event ends at exclusive local midnight")
equal(calendar.countdown(dst_all_day, dst_before).phase, "before", "DST all-day countdown is upcoming before start")
equal(calendar.countdown(dst_all_day, dst_final_day).detail, "all day", "DST all-day countdown is active on final day")
equal(calendar.countdown(dst_all_day, dst_all_day["end"]).phase, "ended", "DST all-day countdown ends at exclusive midnight")
local multiline_events = assert(calendar.parse_events(multiline, tokens))
equal(multiline_events[1].meeting_url, "https://zoom.us/wc/join/123456789", "all newline sentinels decoded before safe-link extraction")
assert(calendar.parse_events("__R____R__Broken__P__2026-08-07__P__uid: x", tokens) == nil, "adjacent sentinel rejected")
assert(calendar.parse_events("__R__Broken only title", tokens) == nil, "partial record rejected")
assert(calendar.parse_events("__R__A__P__2026-08-07__P__uid: same__R__B__P__2026-08-07__P__uid: same", tokens) == nil, "duplicate identity rejected")
local clean = calendar.clean_text("  Alpha\n\226\128\174 Beta  ", 32, 128)
equal(clean, "Alpha Beta", "UTF-8 control and whitespace sanitation")
local invisible_format = { 0x00ad, 0x034f, 0x0600, 0x0605, 0x061c, 0x061d, 0x06dd, 0x070f, 0x0890, 0x0891, 0x08e2, 0x115f, 0x1160, 0x17b4, 0x17b5, 0x180b, 0x180f, 0x200b, 0x200c, 0x200d, 0x200e, 0x200f, 0x202a, 0x202e, 0x2060, 0x2066, 0x206f, 0x3164, 0xfe00, 0xfe0e, 0xfe0f, 0xfeff, 0xffa0, 0xfff0, 0xfff8, 0xfff9, 0xfffb, 0x110bd, 0x110cd, 0x13430, 0x1343f, 0x13440, 0x13455, 0x1bca0, 0x1bca3, 0x1d173, 0x1d17a, 0xfdd0, 0xfdef, 0xfffe, 0xffff, 0x1fffe, 0xe0000, 0xe0001, 0xe0020, 0xe007f, 0xe0fff, 0xe0100, 0xe01ef, 0x10ffff }
local hostile_parts = { "Visible" }
for _, codepoint in ipairs(invisible_format) do hostile_parts[#hostile_parts + 1] = utf8.char(codepoint) end
hostile_parts[#hostile_parts + 1] = "Text"
equal(calendar.clean_text(table.concat(hostile_parts), 128, 512), "Visible Text", "Unicode format and invisible controls are removed")
equal(shell.display(table.concat(hostile_parts) .. utf8.char(0xe000)), "Visible Text", "shared non-calendar display sanitation removes hostile and private-use scalars")
equal(shell.display("invalid" .. string.char(0xff) .. "text"), "", "shared display sanitation rejects invalid UTF-8")
equal(calendar.clean_text(string.rep(utf8.char(0x200b), 1024) .. "Visible", 7, 7), "Visible", "calendar removed scalars do not consume the visible budget")
local chosen = calendar.select_summary({
  { title = "ended", start = 100, ["end"] = 200, sort_id = "e" },
  { title = "upcoming", start = 500, ["end"] = 600, sort_id = "u" },
  { title = "ongoing later", start = 250, ["end"] = 450, sort_id = "o2" },
  { title = "ongoing soon", start = 260, ["end"] = 400, sort_id = "o1" },
}, 300)
equal(chosen.title, "ongoing soon", "ongoing event ending soonest selected")
local next_chosen = calendar.select_summary({
  { title = "at boundary", start = 300, ["end"] = 400, sort_id = "a" },
  { title = "later", start = 301, ["end"] = 350, sort_id = "b" },
}, 300)
equal(next_chosen.title, "at boundary", "start equals now is active summary")
assert(calendar.select_summary({{ title = "ended boundary", start = 200, ["end"] = 300, sort_id = "x" }}, 300) == nil, "end equals now excluded")
local future_all_day = { title = "future all day", start = 500, ["end"] = 900, allDay = true, sort_rank = 1 }
equal(calendar.select_summary({ future_all_day }, 300).title, "future all day", "future all-day fallback selection")
equal(calendar.countdown(future_all_day, 300).detail, "in 4m · all day", "future all-day summary is not presented as active")


local max_before = calendar.countdown({ title = "x", start = 1000 + 8 * 86400, ["end"] = 1000 + 38 * 86400 }, 1000).detail .. " ↗"
local max_active = calendar.countdown({ title = "x", start = 1000 - 22 * 86400, ["end"] = 1000 + 8 * 86400 }, 1000).detail .. " ↗"
assert(#max_before <= 24 and #max_active <= 24, "fixed supporting column has bounded before/active text")
equal(calendar.compact_duration(1000 * 86400), "99d+", "large day values are capped")
equal(calendar.countdown({ title = "x", start = 0, ["end"] = 1000 * 86400 }, 1).detail .. " ↗", "ends in 99d+ · 99d+ ↗", "longest active detail fixture")
equal(calendar.countdown({ title = "x", start = 1000 * 86400, ["end"] = 2000 * 86400 }, 0).detail .. " ↗", "in 99d+ · 99d+ ↗", "longest before detail fixture")

print("Calendar pure tests passed")
