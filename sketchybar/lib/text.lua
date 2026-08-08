local M = {}

local ranges = require("lib.text_ranges")
local grapheme = require("lib.unicode_grapheme_ranges")

local function in_ranges(codepoint, ranges)
  for _, range in ipairs(ranges) do
    if codepoint >= range[1] and codepoint <= range[2] then return true end
  end
  return false
end

function M.safe_scalar(codepoint)
  if codepoint <= 0x1f or (codepoint >= 0x7f and codepoint <= 0x9f) then return false end
  if in_ranges(codepoint, ranges.format) or in_ranges(codepoint, ranges.default_ignorable) or in_ranges(codepoint, ranges.defensive_semantic_format) then return false end
  if (codepoint >= 0xd800 and codepoint <= 0xdfff) or (codepoint >= 0xe000 and codepoint <= 0xf8ff) then return false end
  if (codepoint >= 0xf0000 and codepoint <= 0xffffd) or (codepoint >= 0x100000 and codepoint <= 0x10fffd) then return false end
  if (codepoint >= 0xfdd0 and codepoint <= 0xfdef) or codepoint % 0x10000 >= 0xfffe then return false end
  return true
end

function M.separator_scalar(codepoint)
  return codepoint == 0x20 or codepoint == 0x00a0 or codepoint == 0x1680
    or (codepoint >= 0x2000 and codepoint <= 0x200a) or codepoint == 0x2028
    or codepoint == 0x2029 or codepoint == 0x202f or codepoint == 0x205f or codepoint == 0x3000
end

function M.clean(value, max_chars, max_bytes)
  value = tostring(value or "")
  max_chars = math.max(0, tonumber(max_chars) or 512)
  max_bytes = math.max(0, tonumber(max_bytes) or 4096)
  local parts, count, bytes = {}, 0, 0
  local pending_separator, pending_zwj, ep_extend_run = false, false, false

  local function append_scalar(codepoint)
    local scalar = utf8.char(codepoint)
    local separator_count = pending_separator and count > 0 and 1 or 0
    if count + separator_count + 1 > max_chars
      or bytes + separator_count + #scalar > max_bytes then return false end
    if separator_count == 1 then
      parts[#parts + 1] = " "
      count, bytes = count + 1, bytes + 1
    end
    parts[#parts + 1] = scalar
    count, bytes = count + 1, bytes + #scalar
    pending_separator = false
    return true
  end

  local ok = pcall(function()
    for _, codepoint in utf8.codes(value) do
      local is_ep = grapheme.contains(grapheme.extended_pictographic, codepoint)
      local is_extend = grapheme.contains(grapheme.extend, codepoint)
        or grapheme.contains(grapheme.emoji_modifier, codepoint)

      if pending_zwj then
        pending_zwj = false
        if is_ep and M.safe_scalar(codepoint) then
          local scalar = utf8.char(codepoint)
          if count + 2 > max_chars or bytes + 3 + #scalar > max_bytes then break end
          parts[#parts + 1] = utf8.char(0x200d)
          parts[#parts + 1] = scalar
          count, bytes = count + 2, bytes + 3 + #scalar
          pending_separator, ep_extend_run = false, true
          goto continue
        end
        if count > 0 then pending_separator = true end
        ep_extend_run = false
      end

      if codepoint == 0x200d then
        if ep_extend_run then
          pending_zwj = true
        elseif count > 0 then
          pending_separator = true
        end
        ep_extend_run = false
      elseif is_extend and ep_extend_run and not M.safe_scalar(codepoint) then
        -- Remove default-ignorable extenders without breaking a valid GB11
        -- look-behind. The invisible scalar does not enter display text.
      elseif not M.safe_scalar(codepoint) or M.separator_scalar(codepoint) then
        if count > 0 then pending_separator = true end
        ep_extend_run = false
      else
        if not append_scalar(codepoint) then break end
        if is_ep then
          ep_extend_run = true
        elseif not is_extend then
          ep_extend_run = false
        end
      end
      ::continue::
    end
  end)
  if not ok or count == 0 then return nil end
  return table.concat(parts)
end

return M
