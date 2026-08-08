package.path = os.getenv("SKETCHYBAR_CONFIG_DIR") .. "/?.lua;" .. os.getenv("SKETCHYBAR_CONFIG_DIR") .. "/?/init.lua;" .. package.path
local text = require("lib.text")
local ranges = require("lib.text_ranges")
local shell = require("lib.shell")
local function check(condition, message) if not condition then error(message) end end
local function signature(values)
  local result = {}
  for _, value in ipairs(values) do result[#result + 1] = string.format("%X-%X", value[1], value[2]) end
  return table.concat(result, ",")
end
check(ranges.unicode_version == "17.0.0", "text sanitizer Unicode version must remain pinned")
check(signature(ranges.format) == "AD-AD,600-605,61C-61C,6DD-6DD,70F-70F,890-891,8E2-8E2,180E-180E,200B-200F,202A-202E,2060-2064,2066-206F,FEFF-FEFF,FFF9-FFFB,110BD-110BD,110CD-110CD,13430-1343F,1BCA0-1BCA3,1D173-1D17A,E0001-E0001,E0020-E007F", "Unicode 17 Cf generated ranges changed")
check(signature(ranges.default_ignorable) == "AD-AD,34F-34F,61C-61C,115F-1160,17B4-17B5,180B-180F,200B-200F,202A-202E,2060-206F,3164-3164,FE00-FE0F,FEFF-FEFF,FFA0-FFA0,FFF0-FFF8,1BCA0-1BCA3,1D173-1D17A,E0000-E0FFF", "Unicode 17 Default_Ignorable generated ranges changed")
local hostile = { 0x061d, 0x202e, 0x200b, 0xe000, 0xfe0f, 0xfff0, 0xfff8, 0x13440, 0xfdd0, 0xe0000, 0xe0fff, 0x10ffff }
local parts = { "Window" }
for _, codepoint in ipairs(hostile) do parts[#parts + 1] = utf8.char(codepoint) end
parts[#parts + 1] = "Title"
local external = table.concat(parts)
for _, kind in ipairs({ "window/app", "media", "device", "network", "battery state", "battery remaining/full", "battery health/capacity", "battery adapter" }) do
  check(shell.display(external) == "Window Title", kind .. " text must use shared invisible-control sanitation")
end
check(shell.display("invalid" .. string.char(0xff) .. "text") == "", "invalid UTF-8 must fail closed")
check(shell.display([[Allowed 🎉 \"quoted"]]) == "Allowed 🎉 /’quoted’", "allowed text and legacy slash/quote normalization must remain")
check(text.clean("abcdef", 3, 32) == "abc", "character limit must be exact")
check(text.clean("éé", 8, 2) == "é", "UTF-8 byte limit must preserve whole scalars")
check(text.clean("ok", 2, 2) == "ok" and text.clean("ok", 1, 2) == "o", "size boundaries must be preserved")
local family = "👩" .. utf8.char(0x200d) .. "💻" .. utf8.char(0x200d) .. "👩"
check(text.clean(family, 32, 128) == family, "valid chained GB11 emoji must preserve contextual ZWJ")
check(text.clean("A" .. utf8.char(0x200d) .. "💻", 32, 128) == "A 💻", "non-EP ZWJ must remain sanitized")
local emoji_with_vs = "👩" .. utf8.char(0xfe0f) .. utf8.char(0x200d) .. "💻"
check(text.clean(emoji_with_vs, 32, 128) == "👩" .. utf8.char(0x200d) .. "💻", "removed variation selector must not break valid GB11 context")
check(text.clean(family, 2, 128) == "👩", "character limit cannot emit a dangling contextual ZWJ")
local bounded_display = shell.display(string.rep('"', 1024))
check(utf8.len(bounded_display) == 512 and #bounded_display == 1536, "post-normalization display text must remain within scalar and byte budgets")
local hostile_prefix = string.rep(utf8.char(0x200b), 1024)
check(text.clean(hostile_prefix .. "Visible", 7, 7) == "Visible", "removed leading scalars must not consume visible budgets")
check(text.clean("A" .. hostile_prefix .. "B", 3, 3) == "A B", "removed interstitial runs must consume only one separator when visible text follows")
print("Shared external text sanitation contracts passed")
