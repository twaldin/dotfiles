local M = {}

local ranges = require("lib.text_ranges")

local function in_ranges(codepoint, ranges)
  for _, range in ipairs(ranges) do
    if codepoint >= range[1] and codepoint <= range[2] then return true end
  end
  return false
end

local function safe_scalar(codepoint)
  if codepoint <= 0x1f or (codepoint >= 0x7f and codepoint <= 0x9f) then return false end
  if in_ranges(codepoint, ranges.format) or in_ranges(codepoint, ranges.default_ignorable) or in_ranges(codepoint, ranges.defensive_semantic_format) then return false end
  if (codepoint >= 0xd800 and codepoint <= 0xdfff) or (codepoint >= 0xe000 and codepoint <= 0xf8ff) then return false end
  if (codepoint >= 0xf0000 and codepoint <= 0xffffd) or (codepoint >= 0x100000 and codepoint <= 0x10fffd) then return false end
  if (codepoint >= 0xfdd0 and codepoint <= 0xfdef) or codepoint % 0x10000 >= 0xfffe then return false end
  return true
end

local function separator_scalar(codepoint)
  return codepoint == 0x20 or codepoint == 0x00a0 or codepoint == 0x1680
    or (codepoint >= 0x2000 and codepoint <= 0x200a) or codepoint == 0x2028
    or codepoint == 0x2029 or codepoint == 0x202f or codepoint == 0x205f or codepoint == 0x3000
end

function M.clean(value, max_chars, max_bytes)
  value = tostring(value or "")
  max_chars = math.max(0, tonumber(max_chars) or 512)
  max_bytes = math.max(0, tonumber(max_bytes) or 4096)
  local parts, count, bytes = {}, 0, 0
  local pending_separator = false
  local ok = pcall(function()
    for _, codepoint in utf8.codes(value) do
      if not safe_scalar(codepoint) or separator_scalar(codepoint) then
        if count > 0 then pending_separator = true end
      else
        local scalar = utf8.char(codepoint)
        local separator_count = pending_separator and count > 0 and 1 or 0
        local separator_bytes = separator_count
        if count + separator_count + 1 > max_chars or bytes + separator_bytes + #scalar > max_bytes then break end
        if separator_count == 1 then
          parts[#parts + 1] = " "
          count, bytes = count + 1, bytes + 1
        end
        parts[#parts + 1] = scalar
        count, bytes = count + 1, bytes + #scalar
        pending_separator = false
      end
    end
  end)
  if not ok or count == 0 then return nil end
  return table.concat(parts)
end

return M
